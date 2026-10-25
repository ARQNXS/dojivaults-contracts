// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Ownable2StepUpgradeable, OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {HyperCore} from "./hypercore/HyperCore.sol";
import {PxMath} from "./libraries/PxMath.sol";

interface IFactoryCuration {
    function isAssetCurated(uint32 asset) external view returns (bool);
}

/// @title VaultPolicy
/// @notice Risk policy for one HyperVault. Tightening applies immediately, loosening waits for a timelock
///         so depositors always get time to exit before the manager is allowed to take more risk.
///         Exit before effect (hl-r2 H01): a loosening or a new asset waits at least one full epoch plus
///         EXIT_MARGIN after it is queued, whatever the timelock delay, so a redeemer who asked to leave reaches a
///         forced exit (overdue epoch, then anyone's triggerEmergency) before it applies. A new maxEpochDuration
///         applies from the next epoch: the vault snapshots each epoch's deadline at settle.
///         Also the vault's order and flatten co-processor: the pure checks live here so the vault stays
///         under the EIP-170 size limit.
/// @dev Deployed as an EIP-1167 clone of a fixed implementation and initialized once. Not upgradeable.
contract VaultPolicy is Initializable, Ownable2StepUpgradeable {
    uint256 public constant BPS = 10_000;
    uint256 public constant MIN_TIMELOCK = 1 days;
    uint256 public constant MAX_TIMELOCK = 30 days;
    /// @notice A queued loosening must be applied within this window after its eta or it expires (audit M-03).
    uint256 public constant GRACE_PERIOD = 14 days;
    /// @notice settle() needs a NAV checkpoint (checkRisk or settle) no older than this (audit C-01).
    uint256 public constant CHECKPOINT_MAX_AGE = 1 days;
    /// @dev Hard cap for a custom flatten slippage: 3% is wide enough for any curated perp (audit N2-03).
    uint256 public constant MAX_FLATTEN_SLIPPAGE_BPS = 300;
    /// @notice checkRisk() moves the checkpoint at most once per interval, by at most maxNavMoveBps.
    uint256 public constant CHECKPOINT_INTERVAL = 1 hours;
    /// @notice Notice on top of the longest epoch deadline a waiting redeemer can have (hl-r2 H01): time for the
    ///         forced exit itself (overdue, then triggerEmergency, which freezes new risk) to land before the change.
    uint256 public constant EXIT_MARGIN = 1 days;
    /// @notice Agent turnover budget (WP1, HL-PROXY F5; the Gains GR2-KEY-01b shape): notional the platform agent may
    ///         open in the rolling 24 hours (hourly buckets), in bps of NAV. 200_000 = 20x NAV, the Gains value: four
    ///         full turns of a 5x book a day. What churn can burn in a day is the budget times the round-trip cost:
    ///         about 2% of NAV at 10 bps (4.5 bps taker each side plus spread, small orders), about 8% at 40 bps (orders
    ///         large enough to walk the book, about 16 bps a side), and up to twice that in a true 24 hours across a
    ///         clock-hour boundary (the oldest bucket leaves the window whole). The policy's daily loss limit, checked
    ///         before each order of the agent that adds risk, is the day's ceiling (WP5-HL-01). The platform vault runs
    ///         10x (its owner tightens it right after launch). Reduce-only orders never spend it. The vault cannot see
    ///         fills: an IOC that adds risk spends its full notional even when it fills nothing.
    uint256 public constant DEFAULT_AGENT_TURNOVER_BPS = 200_000;
    uint256 public constant MAX_AGENT_TURNOVER_BPS = 1_000_000;
    /// @notice Agent order-rate cap (WP1): orders that add risk the platform agent may send in a sliding hour.
    ///         Reduce-only orders are never counted or refused. 120: 40x the busiest measured hour of the platform
    ///         strategy (3), and 3x the opening side of a full flip of a 10M vault at 5x in $5M slices with every IOC
    ///         tried 4 times (40). The sliding hour can hold up to about 1.5x the cap across a clock-hour boundary.
    uint256 public constant DEFAULT_AGENT_ORDERS_PER_HOUR = 120;
    uint256 public constant MAX_AGENT_ORDERS_PER_HOUR = 1_000;

    struct RiskConfig {
        uint32 maxLeverageBps; // account notional / equity, e.g. 30_000 = 3x
        uint32 maxDailyLossBps; // equity loss within one UTC day
        uint32 maxDrawdownBps; // share price drop from its lifetime peak
        uint32 maxSlippageBps; // max distance of an onchain limit order from mark
        uint64 maxOrderNotional; // USD, 6 decimals, per onchain order
        uint64 maxEpochDuration; // seconds after which anyone can settle or force an unwind
        uint32 maxNavMoveBps; // settle() reverts when NAV moved more than this since the last checkpoint (audit C-01); >= 500, lowering is timelocked (N-03)
        uint32 maxFlattenSlippageBps; // cap for a custom flatten slippage (audit M-04)
    }

    struct PendingConfig {
        RiskConfig config;
        uint64 eta;
        bool exists;
    }

    /// @notice Limits on the platform agent's orders that add risk (WP1). Kept beside RiskConfig so the launch ABI is
    ///         unchanged: every policy starts at the defaults; the owner tightens at once, a loosening waits the notice.
    struct AgentLimits {
        uint32 maxTurnoverBps; // opened notional in the rolling 24 h, bps of NAV (0: the agent opens nothing)
        uint16 maxOrdersPerHour; // orders that add risk per sliding hour (0: the agent opens nothing)
    }

    struct PendingAgentLimits {
        AgentLimits limits;
        uint64 eta;
        bool exists;
    }

    RiskConfig internal _config;
    PendingConfig internal _pending;

    uint256 public timelockDelay;
    uint256 public pendingTimelockDelay;
    uint256 public pendingTimelockEta;
    /// @notice Factory whose curated asset list bounds this policy's allowlist. Zero for standalone vaults.
    address public factory;

    mapping(uint32 asset => bool) public isAssetAllowed;
    mapping(uint32 asset => uint256 eta) public assetAllowEta;
    uint32[] internal _assetList;
    mapping(uint32 asset => bool) internal _listed;
    /// @notice Latest deadline an epoch can still have from a maxEpochDuration that has since been lowered (the vault
    ///         keeps each epoch's deadline from its settle). Only ever moves up; read by the notice rule.
    uint64 public epochDeadlineCeiling;
    AgentLimits internal _agentLimits;
    PendingAgentLimits internal _pendingAgentLimits;

    event ConfigApplied(RiskConfig config);
    event ConfigQueued(RiskConfig config, uint256 eta);
    event ConfigCancelled();
    event AssetDisallowed(uint32 indexed asset);
    event AssetAllowQueued(uint32 indexed asset, uint256 eta);
    event AssetAllowed(uint32 indexed asset);
    event TimelockQueued(uint256 delay, uint256 eta);
    event TimelockUpdated(uint256 delay);
    event AgentLimitsApplied(AgentLimits limits);
    event AgentLimitsQueued(AgentLimits limits, uint256 eta);
    event AgentLimitsCancelled();

    error InvalidConfig();
    error NotReady();
    error Expired();
    error NothingPending();
    error SpotNotSupported();
    error InvalidTimelock();
    error AssetNotCurated(uint32 asset);
    error SlippageTooHigh();
    error StaleCheckpoint();
    error NavMoved(uint256 nav, uint256 checkpoint);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address owner_, RiskConfig calldata config_, uint32[] calldata assets_, uint256 timelockDelay_, address factory_)
        external
        initializer
    {
        __Ownable_init(owner_);
        __Ownable2Step_init();
        if (timelockDelay_ < MIN_TIMELOCK || timelockDelay_ > MAX_TIMELOCK) revert InvalidTimelock();
        _validate(config_);
        _config = config_;
        timelockDelay = timelockDelay_;
        factory = factory_;
        AgentLimits memory a = AgentLimits(uint32(DEFAULT_AGENT_TURNOVER_BPS), uint16(DEFAULT_AGENT_ORDERS_PER_HOUR));
        _agentLimits = a;
        emit AgentLimitsApplied(a);
        for (uint256 i; i < assets_.length; ++i) {
            _allow(assets_[i]);
        }
        emit ConfigApplied(config_);
        emit TimelockUpdated(timelockDelay_);
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

    /// @notice Every market ever allowed, removed ones included (they may still hold a position). HLR2-A03 / A04:
    ///         the vault reads the entry notional of these to tell a landed transfer from a fill.
    function listedAssets() external view returns (uint32[] memory) {
        return _assetList;
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

    function agentLimits() external view returns (AgentLimits memory) {
        return _agentLimits;
    }

    function pendingAgentLimits() external view returns (PendingAgentLimits memory) {
        return _pendingAgentLimits;
    }

    /// @notice The three breach limits in one call (the vault reads them in checkRisk).
    function riskLimits() external view returns (uint256 leverage, uint256 dailyLoss, uint256 drawdown) {
        return (_config.maxLeverageBps, _config.maxDailyLossBps, _config.maxDrawdownBps);
    }

    /// @notice Validates an onchain order. Reduce only orders skip the notional, allowlist and leverage caps so the
    ///         vault can always de-risk.
    /// @param limitPx price * 1e8
    /// @param sz size * 1e8
    /// @param markPx1e8 current mark price * 1e8
    /// @param accountValue perp account value, 6 decimals (audit M-04: projected leverage is checked per order)
    /// @param ntlPos open notional, 6 decimals
    function checkOrder(
        uint32 asset,
        bool isBuy,
        uint64 limitPx,
        uint64 sz,
        bool reduceOnly,
        uint256 markPx1e8,
        int64 accountValue,
        uint64 ntlPos
    ) external view returns (bool ok, string memory reason) {
        if (asset >= HyperCore.SPOT_ASSET_OFFSET) return (false, "spot not supported");
        if (!isAssetAllowed[asset] && !reduceOnly) return (false, "asset not allowed");
        if (markPx1e8 == 0) return (false, "no mark");
        uint256 band = (markPx1e8 * _config.maxSlippageBps) / BPS;
        if (isBuy && limitPx > markPx1e8 + band) return (false, "price above band");
        if (!isBuy && uint256(limitPx) + band < markPx1e8) return (false, "price below band");
        if (!reduceOnly) {
            // notional (6 decimals) = px1e8 * sz1e8 / 1e10, measured at the worse of limit and mark (audit L-01)
            uint256 px = limitPx > markPx1e8 ? limitPx : markPx1e8;
            uint256 notional = (px * uint256(sz)) / 1e10;
            if (notional > _config.maxOrderNotional) return (false, "notional too large");
            uint256 equity = accountValue > 0 ? uint256(uint64(accountValue)) : 0;
            if ((uint256(ntlPos) + notional) * BPS > uint256(_config.maxLeverageBps) * equity) return (false, "leverage");
        }
        return (true, "");
    }

    /// @notice Bounded IOC price and 1e8 size for closing a position (audit M-04: custom slippage is capped here).
    /// @param slippageBps 0 = the policy band; otherwise at most maxFlattenSlippageBps
    function flattenOrder(uint256 rawMark, uint8 szDecimals, int64 szi, uint256 slippageBps)
        external
        view
        returns (bool isBuy, uint64 px, uint64 sz)
    {
        // XF-02 (hl-r2 cross-review): the default close band never exceeds the flatten cap, so a loosened
        // maxSlippageBps (up to 20%) cannot widen an emergency or breach flatten beyond maxFlattenSlippageBps (<= 3%).
        if (slippageBps == 0) {
            slippageBps = _config.maxSlippageBps < _config.maxFlattenSlippageBps ? _config.maxSlippageBps : _config.maxFlattenSlippageBps;
        }
        else if (slippageBps > _config.maxFlattenSlippageBps) revert SlippageTooHigh();
        isBuy = szi < 0; // short closes with a buy
        uint256 absSzi = szi < 0 ? uint256(-int256(szi)) : uint256(int256(szi));
        px = PxMath.boundedLimitPx1e8(rawMark, szDecimals, isBuy, slippageBps);
        sz = PxMath.size1e8(absSzi, szDecimals);
    }

    /// @notice NAV checkpoint rule for HyperVault (audit C-01). checkRisk() (`settling` false) advances the
    ///         checkpoint at most once per CHECKPOINT_INTERVAL and by at most maxNavMoveBps per step; a normal
    ///         settle() (`settling` true) must be within maxNavMoveBps of a checkpoint younger than
    ///         CHECKPOINT_MAX_AGE. A sudden NAV move (hidden funds, a manipulated mark) therefore cannot be
    ///         settled before the monitor and the guardian have had several intervals to react; honest moves
    ///         ratchet through. Exit-only settles never use this rule (they price at min(NAV, checkpoint)).
    ///
    ///         No checkpoint yet (`at == 0`) or a checkpoint at zero NAV (`prev == 0`, audit N-12): a settle is
    ///         refused until checkRisk() has recorded a checkpoint, and checkRisk() records the live NAV as is.
    ///         With a zero checkpoint there is no share value to protect: either no shares exist (the first mint
    ///         rule prices deposits at 1 USDC per share regardless of NAV) or the vault is already breached by
    ///         the drawdown that took it to zero, which closes normal settlement.
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
    ///         otherwise queues it behind the timelock.
    function proposeConfig(RiskConfig calldata next) external onlyOwner {
        _validate(next);
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
    // Agent limits (WP1): tightening both is instant, anything else waits the exit notice like a loosening.
    // ------------------------------------------------------------------
    function proposeAgentLimits(AgentLimits calldata next) external onlyOwner {
        if (next.maxTurnoverBps > MAX_AGENT_TURNOVER_BPS || next.maxOrdersPerHour > MAX_AGENT_ORDERS_PER_HOUR) {
            revert InvalidConfig();
        }
        AgentLimits memory cur = _agentLimits;
        if (next.maxTurnoverBps <= cur.maxTurnoverBps && next.maxOrdersPerHour <= cur.maxOrdersPerHour) {
            _agentLimits = next;
            delete _pendingAgentLimits;
            emit AgentLimitsApplied(next);
        } else {
            uint64 eta = uint64(_noticeEta(_pending.exists ? _pending.config.maxEpochDuration : 0));
            _pendingAgentLimits = PendingAgentLimits({limits: next, eta: eta, exists: true});
            emit AgentLimitsQueued(next, eta);
        }
    }

    function applyAgentLimits() external {
        if (!_pendingAgentLimits.exists) revert NothingPending();
        _checkEta(_pendingAgentLimits.eta);
        AgentLimits memory next = _pendingAgentLimits.limits;
        _agentLimits = next;
        delete _pendingAgentLimits;
        emit AgentLimitsApplied(next);
    }

    function cancelAgentLimits() external onlyOwner {
        if (!_pendingAgentLimits.exists) revert NothingPending();
        delete _pendingAgentLimits;
        emit AgentLimitsCancelled();
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
        if (asset >= HyperCore.SPOT_ASSET_OFFSET) revert SpotNotSupported();
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

    /// @dev Exit before effect (hl-r2 H01). A redeemer waiting now sits in an epoch whose deadline is at most
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

    /// @dev A lower maxEpochDuration only shortens the next epochs (hl-r2 XB01): an epoch already running keeps the
    ///      deadline its settle stored, at most now + the old length. Remember it for later notices.
    function _setConfig(RiskConfig memory next) internal {
        if (next.maxEpochDuration < _config.maxEpochDuration) {
            uint256 c = block.timestamp + _config.maxEpochDuration;
            if (c > epochDeadlineCeiling) epochDeadlineCeiling = uint64(c);
        }
        _config = next;
    }

    function _checkCurated(uint32 asset) internal view {
        if (factory != address(0) && !IFactoryCuration(factory).isAssetCurated(asset)) revert AssetNotCurated(asset);
    }

    function _allow(uint32 asset) internal {
        if (asset >= HyperCore.SPOT_ASSET_OFFSET) revert SpotNotSupported();
        _checkCurated(asset);
        isAssetAllowed[asset] = true;
        if (!_listed[asset]) {
            _listed[asset] = true;
            _assetList.push(asset);
        }
        emit AssetAllowed(asset);
    }

    function _validate(RiskConfig memory c) internal pure {
        if (
            c.maxLeverageBps == 0 || c.maxLeverageBps > 500_000 // 50x hard ceiling
                || c.maxDailyLossBps == 0 || c.maxDailyLossBps > BPS || c.maxDrawdownBps == 0
                || c.maxDrawdownBps > BPS || c.maxSlippageBps == 0 || c.maxSlippageBps > 2_000
                || c.maxOrderNotional == 0 || c.maxEpochDuration < 1 hours || c.maxEpochDuration > 30 days
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
