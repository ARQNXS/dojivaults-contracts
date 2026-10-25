// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Ownable2StepUpgradeable, OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {GainsPrice} from "./GainsPrice.sol";
import {GTrade} from "./IGainsDiamond.sol";
import {MIN_RISK_NAV} from "../VaultTypes.sol";

/// @dev Upper bound of every policy's maxEpochDuration (file level so GainsTypes can derive PAIR_CAP_RAISE_DELAY from it).
uint256 constant POLICY_MAX_EPOCH_DURATION = 30 days;

/// @notice What a Gains policy reads from its factory: curation, per pair price config and the sequencer feed.
interface IGainsCuration {
    function isAssetCurated(uint32 asset) external view returns (bool);
    function pairFeed(uint32 asset) external view returns (GainsPrice.Feed memory);
    function sequencerFeed() external view returns (address);
    function sequencerGracePeriod() external view returns (uint256);
}

/// @title GainsVaultPolicy
/// @notice Risk policy for one GainsVault. Tightening applies immediately, loosening waits for a timelock
///         so depositors always get time to exit before the manager is allowed to take more risk.
///         Exit before effect (GR2-CFG-01): a loosening or a new pair waits at least one full epoch plus
///         EXIT_MARGIN after it is queued, whatever the timelock delay, so a redeemer who asked to leave reaches an
///         overdue epoch (no new risk; anyone's triggerEmergency) before it applies. A new maxEpochDuration applies
///         from the next epoch: the vault snapshots each epoch's deadline at settle (GR2-CFG-02).
///         Also the vault's order and flatten co-processor, and its price source: each allowed pair's Chainlink
///         feed, staleness limit and NAV band are copied from the factory when the pair is allowed, so the
///         factory owner can never change the prices an existing vault is valued at (PLAN.md 4.3).
/// @dev Deployed as an EIP-1167 clone of a fixed implementation and initialized once. Not upgradeable.
///      Same RiskConfig, timelocks and checkpoint rule as round 4 VaultPolicy; assets are Gains pair indexes.
///      Owned by whoever owns the vault (GR1-12): owner() reads the vault's owner, so a vault transfer moves the
///      policy with it, and the policy's own ownership can be neither transferred nor renounced.
contract GainsVaultPolicy is Initializable, Ownable2StepUpgradeable {
    uint256 public constant BPS = 10_000;
    uint256 public constant MIN_TIMELOCK = 1 days;
    uint256 public constant MAX_TIMELOCK = 30 days;
    /// @notice Upper bound of maxEpochDuration. GR2-KEY-01b: the factory's pair-cap raise delay is derived from it.
    uint256 public constant MAX_EPOCH_DURATION = POLICY_MAX_EPOCH_DURATION;
    /// @notice A queued loosening must be applied within this window after its eta or it expires (audit M-03).
    uint256 public constant GRACE_PERIOD = 14 days;
    /// @notice settle() needs a NAV checkpoint (checkRisk or settle) no older than this (audit C-01).
    uint256 public constant CHECKPOINT_MAX_AGE = 1 days;
    /// @dev Hard cap for a custom flatten slippage: 3% is wide enough for any curated perp (audit N2-03).
    uint256 public constant MAX_FLATTEN_SLIPPAGE_BPS = 300;
    /// @notice checkRisk() moves the checkpoint at most once per interval, by at most maxNavMoveBps.
    uint256 public constant CHECKPOINT_INTERVAL = 1 hours;
    /// @notice NAV error bound (PLAN.md 4.3): 2 x band x vault leverage <= maxNavMoveBps / 4.
    uint256 public constant NAV_BOUND_FACTOR = 8;
    /// @notice Notice on top of the longest epoch deadline a waiting redeemer can have (GR2-CFG-01): time for the
    ///         forced exit itself (overdue, then triggerEmergency) to land before the change.
    uint256 public constant EXIT_MARGIN = 1 days;

    struct RiskConfig {
        uint32 maxLeverageBps; // vault leverage: open notional / NAV, e.g. 30_000 = 3x
        uint32 maxDailyLossBps; // equity loss within one UTC day
        uint32 maxDrawdownBps; // share price drop from its lifetime peak
        uint32 maxSlippageBps; // max distance of a market order's expected price from the Chainlink price, and its slippage
        uint64 maxOrderNotional; // USD, 6 decimals, per order (collateral x leverage)
        uint64 maxEpochDuration; // seconds after which anyone can settle or force an unwind
        uint32 maxNavMoveBps; // settle() reverts when NAV moved more than this since the last checkpoint (audit C-01); >= 500, lowering is timelocked (N-03)
        uint32 maxFlattenSlippageBps; // cap for a custom flatten slippage (audit M-04)
    }

    struct PendingConfig {
        RiskConfig config;
        uint64 eta;
        bool exists;
    }

    /// @notice One new exposure to check (open, increase or leverage raise).
    /// @param notional the order's new notional (collateral x leverage, 6 decimals); 0 for a leverage raise
    /// @param minCollateral Gains' minimum collateral (5 x min fee), 0 to skip (increase, leverage raise). Gains' own
    ///        minimum is the only size floor: pairMinPositionSizeUsd is its fee basis, not a minimum.
    /// @param nav vault NAV, 6 decimals
    /// @param openNotional the vault's open notional before this order, 6 decimals
    struct Order {
        uint32 pair;
        bool long;
        bool market;
        uint64 expectedPrice;
        uint16 maxSlippageP;
        uint256 collateral;
        uint256 notional;
        uint256 minCollateral;
        uint256 nav;
        uint256 openNotional;
    }

    RiskConfig internal _config;
    PendingConfig internal _pending;

    uint256 public timelockDelay;
    uint256 public pendingTimelockDelay;
    uint256 public pendingTimelockEta;
    /// @notice Factory whose curated pairs bound this policy's allowlist and supply the price config. Required: a
    ///         standalone vault's policy names a factory as its curation and price source.
    address public factory;

    mapping(uint32 asset => bool) public isAssetAllowed;
    mapping(uint32 asset => uint256 eta) public assetAllowEta;
    uint32[] internal _assetList;
    mapping(uint32 asset => bool) internal _listed;

    /// @notice The vault this policy belongs to: the only caller of setPairFeed (through the vault's timelock).
    address public vault;
    /// @notice L2 sequencer uptime feed and grace period, copied from the factory at initialization.
    address public sequencerFeed;
    uint256 public sequencerGracePeriod;
    /// @dev Price config per pair, copied from the factory when the pair is allowed. Kept when a pair is disallowed,
    ///      so trades still open on it keep a price.
    mapping(uint32 asset => GainsPrice.Feed) internal _feeds;
    /// @notice Latest deadline an epoch can still have from a maxEpochDuration that has since been lowered (the vault
    ///         keeps each epoch's deadline from its settle). Only ever moves up; read by the notice rule.
    uint64 public epochDeadlineCeiling;

    event ConfigApplied(RiskConfig config);
    event ConfigQueued(RiskConfig config, uint256 eta);
    event ConfigCancelled();
    event AssetDisallowed(uint32 indexed asset);
    event AssetAllowQueued(uint32 indexed asset, uint256 eta);
    event AssetAllowed(uint32 indexed asset);
    event TimelockQueued(uint256 delay, uint256 eta);
    event TimelockUpdated(uint256 delay);
    event FeedSet(uint32 indexed asset, address feed, uint32 maxAge, uint16 bandBps);
    event SequencerFeedSet(address feed, uint256 gracePeriod);

    error InvalidConfig();
    error NotReady();
    error Expired();
    error NothingPending();
    error InvalidPair();
    error InvalidTimelock();
    error AssetNotCurated(uint32 asset);
    error SlippageTooHigh();
    error StaleCheckpoint();
    error NavMoved(uint256 nav, uint256 checkpoint);
    error LeverageAboveNavBound(uint32 asset);
    error ZeroAddress();
    error NotVault();
    error FeedNotCurated(uint32 asset);
    error OwnershipFollowsVault();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address owner_,
        RiskConfig calldata config_,
        uint32[] calldata assets_,
        uint256 timelockDelay_,
        address factory_,
        address vault_
    ) external initializer {
        __Ownable_init(owner_);
        __Ownable2Step_init();
        if (timelockDelay_ < MIN_TIMELOCK || timelockDelay_ > MAX_TIMELOCK) revert InvalidTimelock();
        if (factory_ == address(0) || vault_ == address(0)) revert ZeroAddress();
        _validate(config_);
        _config = config_;
        timelockDelay = timelockDelay_;
        factory = factory_;
        vault = vault_;
        sequencerFeed = IGainsCuration(factory_).sequencerFeed();
        sequencerGracePeriod = IGainsCuration(factory_).sequencerGracePeriod();
        for (uint256 i; i < assets_.length; ++i) {
            _allow(assets_[i]);
        }
        emit ConfigApplied(config_);
        emit TimelockUpdated(timelockDelay_);
    }

    // ------------------------------------------------------------------
    // Ownership: the vault's owner (GR1-12)
    // ------------------------------------------------------------------
    function owner() public view override returns (address) {
        return OwnableUpgradeable(vault).owner();
    }

    function transferOwnership(address) public pure override {
        revert OwnershipFollowsVault();
    }

    function acceptOwnership() public pure override {
        revert OwnershipFollowsVault();
    }

    function renounceOwnership() public pure override {
        revert OwnershipFollowsVault();
    }

    // ------------------------------------------------------------------
    // Views
    // ------------------------------------------------------------------
    function config() external view returns (RiskConfig memory) {
        return _config;
    }

    function pendingConfig() external view returns (PendingConfig memory) {
        return _pending;
    }

    function allowedAssets() external view returns (uint32[] memory out) {
        uint256 n;
        for (uint256 i; i < _assetList.length; ++i) {
            if (isAssetAllowed[_assetList[i]]) ++n;
        }
        out = new uint32[](n);
        n = 0;
        for (uint256 i; i < _assetList.length; ++i) {
            if (isAssetAllowed[_assetList[i]]) out[n++] = _assetList[i];
        }
    }

    function maxLeverageBps() external view returns (uint256) {
        return _config.maxLeverageBps;
    }

    function maxDailyLossBps() external view returns (uint256) {
        return _config.maxDailyLossBps;
    }

    function maxDrawdownBps() external view returns (uint256) {
        return _config.maxDrawdownBps;
    }

    function maxSlippageBps() external view returns (uint256) {
        return _config.maxSlippageBps;
    }

    function maxOrderNotional() external view returns (uint256) {
        return _config.maxOrderNotional;
    }

    function maxEpochDuration() external view returns (uint256) {
        return _config.maxEpochDuration;
    }

    function maxNavMoveBps() external view returns (uint256) {
        return _config.maxNavMoveBps;
    }

    function maxFlattenSlippageBps() external view returns (uint256) {
        return _config.maxFlattenSlippageBps;
    }

    /// @notice Earliest eta for a change that widens exposure and is queued now (the vault's queue and allowAsset
    ///         use it): at least the timelock, one full epoch plus EXIT_MARGIN (the longer of the current and the
    ///         pending epoch length), and EXIT_MARGIN past any deadline left from a lowered epoch length.
    function noticeEta() external view returns (uint256) {
        return _noticeEta(_pending.exists ? _pending.config.maxEpochDuration : 0);
    }

    /// @notice The three breach limits in one call (the vault reads them in checkRisk).
    function riskLimits() external view returns (uint256 leverage, uint256 dailyLoss, uint256 drawdown) {
        return (_config.maxLeverageBps, _config.maxDailyLossBps, _config.maxDrawdownBps);
    }

    /// @notice Price config of a pair (zero feed = never allowed here).
    function feedOf(uint32 asset) external view returns (GainsPrice.Feed memory) {
        return _feeds[asset];
    }

    /// @notice Highest vault leverage (bps) the NAV error bound allows for `asset` under maxNavMoveBps (PLAN.md 4.3).
    function navBoundLeverageBps(uint32 asset, uint256 navMoveBps) public view returns (uint256) {
        uint256 band = _feeds[asset].bandBps;
        if (band == 0) return type(uint256).max;
        return (navMoveBps * BPS) / (NAV_BOUND_FACTOR * band);
    }

    // ------------------------------------------------------------------
    // Prices (GainsPrice). Reverts PriceStale(pair) / SequencerDown(); never called on an exit path.
    // ------------------------------------------------------------------
    /// @notice Chainlink price of `asset`, 1e10.
    function price(uint32 asset) public view returns (uint64) {
        return GainsPrice.read(_feeds[asset], sequencerFeed, sequencerGracePeriod, asset);
    }

    /// @notice Chainlink price and NAV band of `asset` (GainsNav).
    function navPrice(uint32 asset) external view returns (uint64 px1e10, uint16 bandBps) {
        return (price(asset), _feeds[asset].bandBps);
    }

    /// @notice Validates a new exposure (PLAN.md 4.2, 4.5). Reduce-only actions never come here: exits are not checked.
    /// @dev Market orders: the expected price must be within maxSlippageBps of the Chainlink price on the side that
    ///      costs the vault (audit L-01 analog), and Gains' slippage within the same bound. Limit and stop orders
    ///      rest at their trigger, which Gains validates against its own oracle. Projected vault leverage =
    ///      (open notional + new notional) / NAV (audit M-04).
    function checkOrder(Order calldata o) external view returns (bool ok, string memory reason) {
        if (o.pair > type(uint16).max) return (false, "invalid pair");
        if (!isAssetAllowed[o.pair]) return (false, "asset not allowed");
        if (o.expectedPrice == 0) return (false, "no price");
        if (uint256(o.maxSlippageP) > uint256(_config.maxSlippageBps) * GTrade.SLIPPAGE_PER_BPS) return (false, "slippage");
        if (o.market) {
            uint256 mark = price(o.pair);
            uint256 band = (mark * _config.maxSlippageBps) / BPS;
            if (o.long && o.expectedPrice > mark + band) return (false, "price above band");
            if (!o.long && uint256(o.expectedPrice) + band < mark) return (false, "price below band");
        }
        if (o.notional > _config.maxOrderNotional) return (false, "notional too large");
        if (o.minCollateral != 0 && o.collateral < o.minCollateral) return (false, "collateral below min");
        if ((o.openNotional + o.notional) * BPS > uint256(_config.maxLeverageBps) * o.nav) return (false, "leverage");
        return (true, "");
    }

    /// @notice Gains closing slippage (1e3 percent) for a flatten (audit M-04: custom slippage is capped here).
    /// @param slippageBps 0 = the policy band, capped like a custom one (GR1-41); otherwise at most maxFlattenSlippageBps
    function flattenSlippage(uint256 slippageBps) external view returns (uint16) {
        if (slippageBps == 0) {
            slippageBps = _config.maxSlippageBps < _config.maxFlattenSlippageBps ? _config.maxSlippageBps : _config.maxFlattenSlippageBps;
        } else if (slippageBps > _config.maxFlattenSlippageBps) revert SlippageTooHigh();
        return uint16(slippageBps * GTrade.SLIPPAGE_PER_BPS);
    }

    /// @notice NAV checkpoint rule, identical to round 4 VaultPolicy.nextCheckpoint (audit C-01, N-03, N-12).
    /// @return next the checkpoint NAV to store
    /// @return update false when the previous checkpoint must be kept
    function nextCheckpoint(uint256 prev, uint256 at, uint256 nav, bool settling)
        external
        view
        returns (uint256 next, bool update)
    {
        if (at == 0 || prev == 0) {
            if (settling && at == 0) revert StaleCheckpoint();
            return (nav, true);
        }
        // A dust checkpoint (every depositor left) bounds nothing worth protecting: a 1 USDC donation would otherwise
        // hold normal settles for days (GR1-23).
        if (prev < MIN_RISK_NAV) return (nav, true);
        uint256 cap = (prev * _config.maxNavMoveBps) / BPS;
        if (settling) {
            if (block.timestamp > at + CHECKPOINT_MAX_AGE) revert StaleCheckpoint();
            if ((nav > prev ? nav - prev : prev - nav) > cap) revert NavMoved(nav, prev);
        } else {
            if (block.timestamp < at + CHECKPOINT_INTERVAL) return (prev, false);
            if (nav > prev + cap) nav = prev + cap;
            else if (nav + cap < prev) nav = prev - cap;
        }
        return (nav, true);
    }

    // ------------------------------------------------------------------
    // Config changes
    // ------------------------------------------------------------------
    /// @notice Applies `next` immediately if it is at least as strict as the current config on every field,
    ///         otherwise queues it behind the timelock. Either way it must satisfy the NAV bound for every allowed
    ///         pair (checked again when a queued config is applied).
    function proposeConfig(RiskConfig calldata next) external onlyOwner {
        _validate(next);
        _checkNavBound(next);
        if (_isTighter(next, _config)) {
            _setConfig(next);
            delete _pending;
            emit ConfigApplied(next);
        } else {
            // Exit before effect: no other config can apply before this one, so the current epoch length bounds
            // every deadline a redeemer can be waiting for until the eta.
            uint64 eta = uint64(_noticeEta(0));
            _pending = PendingConfig({config: next, eta: eta, exists: true});
            emit ConfigQueued(next, eta);
        }
    }

    function applyPendingConfig() external {
        if (!_pending.exists) revert NothingPending();
        _checkEta(_pending.eta);
        _checkNavBound(_pending.config);
        _setConfig(_pending.config);
        emit ConfigApplied(_pending.config);
        delete _pending;
    }

    function cancelPendingConfig() external onlyOwner {
        if (!_pending.exists) revert NothingPending();
        delete _pending;
        emit ConfigCancelled();
    }

    // ------------------------------------------------------------------
    // Asset allowlist
    // ------------------------------------------------------------------
    function disallowAsset(uint32 asset) external onlyOwner {
        isAssetAllowed[asset] = false;
        assetAllowEta[asset] = 0;
        emit AssetDisallowed(asset);
    }

    function queueAllowAsset(uint32 asset) external onlyOwner {
        if (asset > type(uint16).max) revert InvalidPair();
        _checkCurated(asset);
        uint256 eta = _noticeEta(_pending.exists ? _pending.config.maxEpochDuration : 0);
        assetAllowEta[asset] = eta;
        emit AssetAllowQueued(asset, eta);
    }

    function allowAsset(uint32 asset) external {
        uint256 eta = assetAllowEta[asset];
        if (eta == 0) revert NothingPending();
        _checkEta(eta);
        assetAllowEta[asset] = 0;
        _allow(asset);
    }

    /// @notice Feed rotation: replaces the price config of a pair this policy has allowed, e.g. when Chainlink
    ///         deprecates a feed and settle is blocked by PriceStale. Only the vault calls it, after its owner queued
    ///         setPairFeed through the vault timelock. Only the exact feed / staleness / band combination the
    ///         factory curates for the pair right now is accepted, and the vault-leverage bound is checked again.
    function setPairFeed(uint32 asset, address feed, uint32 maxAge, uint16 bandBps) external {
        if (msg.sender != vault) revert NotVault();
        if (!_listed[asset] || !IGainsCuration(factory).isAssetCurated(asset)) revert AssetNotCurated(asset);
        GainsPrice.Feed memory f = IGainsCuration(factory).pairFeed(asset);
        if (feed == address(0) || f.feed != feed || f.maxAge != maxAge || f.bandBps != bandBps) revert FeedNotCurated(asset);
        _feeds[asset] = f;
        emit FeedSet(asset, f.feed, f.maxAge, f.bandBps);
        if (_config.maxLeverageBps > navBoundLeverageBps(asset, _config.maxNavMoveBps)) revert LeverageAboveNavBound(asset);
    }

    /// @notice Sequencer uptime feed rotation (GR1-10): sets the feed and grace period the vault owner queued, which
    ///         were the factory's when queued (GV-03: a later change in the factory is not adopted by an execution;
    ///         the owner queues it again). Only the vault calls it, after the timelock. The grace period is bounded.
    function setSequencerFeed(address feed, uint256 gracePeriod) external {
        if (msg.sender != vault) revert NotVault();
        if (feed == address(0)) revert ZeroAddress();
        GainsPrice.checkSequencerGrace(gracePeriod);
        sequencerFeed = feed;
        sequencerGracePeriod = gracePeriod;
        emit SequencerFeedSet(feed, gracePeriod);
    }

    // ------------------------------------------------------------------
    // Timelock delay (raising it is instant, lowering it is timelocked). The exit notice does not depend on it:
    // every widening change waits at least an epoch plus EXIT_MARGIN anyway (_noticeEta), so a lower delay never
    // shortens a depositor's exit window.
    // ------------------------------------------------------------------
    function proposeTimelockDelay(uint256 delay) external onlyOwner {
        if (delay < MIN_TIMELOCK || delay > MAX_TIMELOCK) revert InvalidTimelock();
        if (delay >= timelockDelay) {
            timelockDelay = delay;
            pendingTimelockEta = 0;
            emit TimelockUpdated(delay);
        } else {
            pendingTimelockDelay = delay;
            pendingTimelockEta = block.timestamp + timelockDelay;
            emit TimelockQueued(delay, pendingTimelockEta);
        }
    }

    function applyTimelockDelay() external {
        if (pendingTimelockEta == 0) revert NothingPending();
        _checkEta(pendingTimelockEta);
        timelockDelay = pendingTimelockDelay;
        pendingTimelockEta = 0;
        emit TimelockUpdated(timelockDelay);
    }

    // ------------------------------------------------------------------
    // Internal
    // ------------------------------------------------------------------
    function _checkEta(uint256 eta) internal view {
        if (block.timestamp < eta) revert NotReady();
        if (block.timestamp > eta + GRACE_PERIOD) revert Expired();
    }

    /// @dev Exit before effect (GR2-CFG-01). A redeemer waiting now sits in an epoch whose deadline is at most
    ///      now + the current epoch length, or epochDeadlineCeiling when the length was lowered during that epoch.
    ///      `otherEpoch` is a longer length that may apply before the eta (the pending config, for changes queued
    ///      beside it).
    function _noticeEta(uint256 otherEpoch) internal view returns (uint256 eta) {
        uint256 e = _config.maxEpochDuration;
        if (otherEpoch > e) e = otherEpoch;
        eta = block.timestamp + e + EXIT_MARGIN;
        uint256 c = uint256(epochDeadlineCeiling) + EXIT_MARGIN;
        if (c > eta) eta = c;
        uint256 t = block.timestamp + timelockDelay;
        if (t > eta) eta = t;
    }

    /// @dev A lower maxEpochDuration only shortens the next epochs: an epoch already running keeps the deadline its
    ///      settle stored, at most now + the old length. Remember it for later notices.
    function _setConfig(RiskConfig memory next) internal {
        if (next.maxEpochDuration < _config.maxEpochDuration) {
            uint256 c = block.timestamp + _config.maxEpochDuration;
            if (c > epochDeadlineCeiling) epochDeadlineCeiling = uint64(c);
        }
        _config = next;
    }

    function _checkCurated(uint32 asset) internal view {
        if (!IGainsCuration(factory).isAssetCurated(asset)) revert AssetNotCurated(asset);
    }

    /// @dev Copies the pair's price config from the factory (snapshot, PLAN.md 4.3) and checks the NAV bound under
    ///      the current config.
    function _allow(uint32 asset) internal {
        if (asset > type(uint16).max) revert InvalidPair();
        _checkCurated(asset);
        GainsPrice.Feed memory f = IGainsCuration(factory).pairFeed(asset);
        if (f.feed == address(0)) revert AssetNotCurated(asset);
        _feeds[asset] = f;
        emit FeedSet(asset, f.feed, f.maxAge, f.bandBps);
        if (_config.maxLeverageBps > navBoundLeverageBps(asset, _config.maxNavMoveBps)) revert LeverageAboveNavBound(asset);
        isAssetAllowed[asset] = true;
        if (!_listed[asset]) {
            _listed[asset] = true;
            _assetList.push(asset);
        }
        emit AssetAllowed(asset);
    }

    /// @dev PLAN.md 4.3: maxLeverageBps x 8 x band <= maxNavMoveBps x 10,000 for every pair ever allowed: a
    ///      disallowed pair may still have trades open and is valued at its band (GR1-31).
    function _checkNavBound(RiskConfig memory c) internal view {
        for (uint256 i; i < _assetList.length; ++i) {
            uint32 a = _assetList[i];
            if (c.maxLeverageBps > navBoundLeverageBps(a, c.maxNavMoveBps)) revert LeverageAboveNavBound(a);
        }
    }

    function _validate(RiskConfig memory c) internal pure {
        if (
            c.maxLeverageBps == 0 || c.maxLeverageBps > 500_000 // 50x hard ceiling
                || c.maxDailyLossBps == 0 || c.maxDailyLossBps > BPS || c.maxDrawdownBps == 0
                || c.maxDrawdownBps > BPS || c.maxSlippageBps == 0 || c.maxSlippageBps > 2_000
                || c.maxOrderNotional == 0 || c.maxEpochDuration < 1 hours || c.maxEpochDuration > MAX_EPOCH_DURATION
                || c.maxNavMoveBps < 500 || c.maxNavMoveBps > BPS || c.maxFlattenSlippageBps == 0
                || c.maxFlattenSlippageBps > MAX_FLATTEN_SLIPPAGE_BPS
        ) revert InvalidConfig();
    }

    function _isTighter(RiskConfig memory a, RiskConfig memory b) internal pure returns (bool) {
        return a.maxLeverageBps <= b.maxLeverageBps && a.maxDailyLossBps <= b.maxDailyLossBps
            && a.maxDrawdownBps <= b.maxDrawdownBps && a.maxSlippageBps <= b.maxSlippageBps
            && a.maxOrderNotional <= b.maxOrderNotional && a.maxEpochDuration <= b.maxEpochDuration
            // A lower maxNavMoveBps slows settlement down, so for liveness raising it is the tightening (N-03).
            && a.maxNavMoveBps >= b.maxNavMoveBps && a.maxFlattenSlippageBps <= b.maxFlattenSlippageBps;
    }
}
