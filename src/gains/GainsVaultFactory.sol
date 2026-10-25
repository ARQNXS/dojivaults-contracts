// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

import {IGainsDiamond} from "./IGainsDiamond.sol";
import {GainsPrice, IChainlinkFeed} from "./GainsPrice.sol";
import {GainsVault} from "./GainsVault.sol";
import {GainsVaultPolicy} from "./GainsVaultPolicy.sol";
import {DEFAULT_PAIR_SKEW_CAP_BPS, InitParams, MAX_PAIR_SKEW_CAP_BPS, PAIR_CAP_RAISE_DELAY} from "./GainsTypes.sol";
import {MIN_DEPOSIT as MIN_DEPOSIT_} from "../VaultTypes.sol";

/// @title GainsVaultFactory
/// @notice One transaction vault launch: clones a GainsVault and a GainsVaultPolicy from fixed implementations,
///         initializes both, pulls the manager's USDC seed (EIP-2612 permit or prior approval) into the vault and
///         forwards ETH to the bound agent wallet for Arbitrum gas (PLAN.md 4.4). Round 4 HyperVaultFactory with the
///         HyperCore parts (Core deposit wallet, HYPE value) replaced; curation now carries each pair's Chainlink
///         feed, staleness limit and NAV band, which a policy copies when it allows the pair.
///
/// Platform controls (audit C-01, D-1, D-2, D-3, I-06, N-06, N-07, V-04):
///  - Only platform agents trade factory vaults. A launch carries the agent registrar's signature over
///    (agent, predicted vault, deadline); create() binds the agent to the vault it deploys and to nothing else, so
///    the registrar can no longer pre-bind a predicted address and block a creator's salt (V-04). A replacement
///    agent for an existing vault is registered by the registrar or the owner and set through the vault's
///    timelock; unregistering revokes the agent on its vault.
///  - Two rotatable platform roles that every factory vault reads live: the sentinel (hot, risk reducing
///    actions only) and the guardian (cold, breach clears and emergencies). The vault owner cannot replace them.
///  - Policies may only allowlist curated pairs, and every factory vault has a deposit cap at or below the
///    platform maximum. A curated pair's band bounds the policy's max vault leverage (PLAN.md 4.3).
///  - Every factory vault's notional on a pair is capped at a fraction of the pair's skew depth that the guardian sets
///    per pair (GR2-KEY-01b): lowered at once (guardian or sentinel), raised only PAIR_CAP_RAISE_DELAY after the
///    guardian queued it, never above MAX_PAIR_SKEW_CAP_BPS. A pair never set takes no new exposure.
/// @dev Clones are EIP-1167 minimal proxies. The implementations are immutable here.
contract GainsVaultFactory is Ownable2Step {
    using SafeERC20 for IERC20;

    uint16 public constant BPS = 10_000;
    uint16 public constant MAX_PROTOCOL_SHARE_BPS = 5_000; // 50% of manager fees
    /// @notice Smallest deposit request on every vault (enforced by the vault, I3-07): 10 USDC.
    uint256 public constant MIN_DEPOSIT = MIN_DEPOSIT_;

    address public immutable vaultImplementation;
    address public immutable policyImplementation;
    IERC20 public immutable usdc;
    IGainsDiamond public immutable diamond;
    /// @notice Arbitrum L2 sequencer uptime feed and the grace period after it comes back (copied into each policy).
    ///         Never zero (a zero feed would silently skip the sequencer check). The owner can rotate it; each vault
    ///         adopts the current one through its own timelock (setSequencerFeed, GR1-10).
    address public sequencerFeed;
    uint256 public sequencerGracePeriod;

    // Config for FUTURE vaults. Existing vaults keep the share they were created with.
    address public protocolFeeRecipient;
    uint16 public baseShareBps = 1_000; // 10% of fees, own signals
    uint16 public hostedShareBps = 3_300; // 33% of fees, DojiPad hosted strategy
    uint256 public minSeedUsdc = 1e6; // 1 USDC (no Core activation fee on Gains)
    /// @notice ETH forwarded to the bound agent wallet for Arbitrum gas. Stage 0: a market request is ~1.4M gas, so
    ///         0.001 ETH covers about 30 requests at 0.02 gwei (PLAN.md 4.4).
    uint256 public minAgentGas = 0.001 ether;

    /// @notice Cold platform guardian: clears breaches, cancels queued items, triggers emergencies, unpauses.
    address public guardian;
    /// @notice Hot platform sentinel (the executor's monitor): revoke, pause, force reduce only, cancel orders.
    address public sentinel;
    /// @notice Wallet that registers platform agents before launches (the executor), separate from the owner.
    address public agentRegistrar;
    /// @notice Upper bound for every factory vault's depositCap.
    uint256 public maxDepositCap = 50_000e6;

    bool public openLaunch;
    mapping(address launcher => bool) public launcherAllowed;
    /// @notice The one vault a platform agent may be approved on (zero = not a platform agent).
    mapping(address agent => address vault) public platformAgentFor;
    /// @notice The agent bound to a vault address. One per predicted vault before launch (audit N2-04); an
    ///         existing vault may bind a replacement for a rotation through its timelock.
    mapping(address vault => address agent) public agentOfVault;
    mapping(uint32 asset => bool) public isAssetCurated;
    uint32[] internal _curated;
    /// @dev Chainlink feed, staleness limit and NAV band per pair index.
    mapping(uint32 asset => GainsPrice.Feed) internal _pairFeed;

    address[] internal _vaults;
    mapping(address => bool) public isVault;
    mapping(address vault => address policy) public policyOf;

    /// @dev GR2-KEY-01b, per pair: the cap in bps of the pair's 1 % skew depth (0 = no new exposure), whether it was
    ///      ever set above 0, and a queued raise (eta 0 = none).
    struct PairCap {
        uint16 bps;
        bool set;
        uint16 queuedBps;
        uint64 eta;
    }

    mapping(uint16 pair => PairCap) internal _pairCap;

    struct CreateParams {
        string name;
        string symbol;
        address owner;
        address manager;
        address feeRecipient;
        uint16 managementFeeBps;
        uint16 performanceFeeBps;
        uint256 timelockDelay;
        uint256 depositCap;
        GainsVaultPolicy.RiskConfig risk;
        uint32[] assets;
        address agent; // zero for manual mode, otherwise a platform agent signed for this launch by the registrar
        bytes agentSig; // registrar signature over agentDigest(agent, predicted vault, agentDeadline)
        uint256 agentDeadline;
        address operator; // treasury operator (the platform keeper by default), zero for none
        bool hosted;
        uint256 seedUsdc; // >= minSeedUsdc, pulled from msg.sender into the vault (idle USDC)
        bytes32 salt;
    }

    /// @dev EIP-2612 permit for `usdc` with spender = this factory. deadline == 0 skips the permit and relies on
    ///      an existing allowance (the fallback approve path).
    struct PermitData {
        uint256 value;
        uint256 deadline;
        uint8 v;
        bytes32 r;
        bytes32 s;
    }

    event VaultCreated(
        address indexed vault,
        address indexed policy,
        address indexed owner,
        address manager,
        address agent,
        bool hosted,
        uint16 protocolShareBps,
        bytes32 salt
    );
    event ProtocolFeeRecipientUpdated(address recipient);
    event SharesUpdated(uint16 baseShareBps, uint16 hostedShareBps);
    event ProtocolShareLowered(address indexed vault, uint16 shareBps);
    event MinSeedUpdated(uint256 minSeedUsdc);
    event MinAgentGasUpdated(uint256 minAgentGas);
    event LauncherAllowed(address indexed launcher, bool allowed);
    event OpenLaunchSet(bool open);
    event GuardianUpdated(address guardian);
    event SentinelUpdated(address sentinel);
    event AgentRegistrarUpdated(address registrar);
    event PlatformAgentRegistered(address indexed agent, address indexed vault, bool registered);
    event AssetCurated(uint32 indexed asset, bool curated);
    event PairFeedSet(uint32 indexed asset, address feed, uint32 maxAge, uint16 bandBps);
    event MaxDepositCapUpdated(uint256 cap);
    event SequencerFeedUpdated(address feed, uint256 gracePeriod);
    event PairSkewCapSet(uint16 indexed pair, uint16 bps);
    event PairSkewCapQueued(uint16 indexed pair, uint16 bps, uint256 eta);
    event PairSkewCapCancelled(uint16 indexed pair);

    error LaunchClosed();
    error InvalidShare();
    error SeedTooSmall(uint256 sent, uint256 min);
    error AgentGasTooSmall(uint256 sent, uint256 min);
    error AgentGasFailed();
    error InvalidFeed();
    error NotAVault();
    error ZeroAddress();
    error NotPlatformAgent(address agent);
    error AssetNotCurated(uint32 asset);
    error CapAboveMax(uint256 cap, uint256 max);
    error NotRegistrar();
    error AgentAlreadyBound(address agent, address vault);
    error VaultAlreadyHasAgent(address vault, address agent);
    error LiveAgent(address agent, address vault);
    error RolesCollide();
    error BadAgentSignature();
    error NotGuardian();
    error InvalidPairCap(uint16 bps);
    error NotQueued();
    error NotReady(uint256 eta);

    constructor(
        address owner_,
        address vaultImplementation_,
        address policyImplementation_,
        IERC20 usdc_,
        IGainsDiamond diamond_,
        address sequencerFeed_,
        uint256 sequencerGracePeriod_,
        address protocolFeeRecipient_,
        address guardian_,
        address sentinel_
    ) Ownable(owner_) {
        if (
            vaultImplementation_ == address(0) || policyImplementation_ == address(0) || address(usdc_) == address(0)
                || address(diamond_) == address(0) || protocolFeeRecipient_ == address(0) || guardian_ == address(0)
                || sentinel_ == address(0) || sequencerFeed_ == address(0)
        ) revert ZeroAddress();
        GainsPrice.checkSequencerGrace(sequencerGracePeriod_);
        _checkRoles(owner_, guardian_, sentinel_, address(0));
        vaultImplementation = vaultImplementation_;
        policyImplementation = policyImplementation_;
        usdc = usdc_;
        diamond = diamond_;
        sequencerFeed = sequencerFeed_;
        sequencerGracePeriod = sequencerGracePeriod_;
        protocolFeeRecipient = protocolFeeRecipient_;
        guardian = guardian_;
        sentinel = sentinel_;
    }

    /// @notice True when `agent` is bound to some vault (registered and not yet unregistered).
    function isPlatformAgent(address agent) external view returns (bool) {
        return platformAgentFor[agent] != address(0);
    }

    // ------------------------------------------------------------------
    // Views
    // ------------------------------------------------------------------
    function vaults() external view returns (address[] memory) {
        return _vaults;
    }

    function vaultCount() external view returns (uint256) {
        return _vaults.length;
    }

    /// @notice Price config of a pair (read by GainsVaultPolicy when it allows the pair).
    function pairFeed(uint32 asset) external view returns (GainsPrice.Feed memory) {
        return _pairFeed[asset];
    }

    /// @notice Curated pair indices (those currently enabled).
    function curatedAssets() external view returns (uint32[] memory out) {
        uint256 n;
        for (uint256 i; i < _curated.length; ++i) {
            if (isAssetCurated[_curated[i]]) ++n;
        }
        out = new uint32[](n);
        n = 0;
        for (uint256 i; i < _curated.length; ++i) {
            if (isAssetCurated[_curated[i]]) out[n++] = _curated[i];
        }
    }

    /// @notice Address a `create` by `creator` with `salt` will deploy to. Salts are scoped per creator.
    function predictVaultAddress(address creator, bytes32 salt) public view returns (address) {
        return Clones.predictDeterministicAddress(vaultImplementation, _scopedSalt(creator, salt), address(this));
    }

    function canLaunch(address launcher) public view returns (bool) {
        return openLaunch || launcherAllowed[launcher];
    }

    /// @notice What the agent registrar signs (EIP-191 personal message of this hash) to let `vault` launch with
    ///         `agent`: bound to this chain, this factory, the agent, the predicted vault and a deadline.
    function agentDigest(address agent, address vault, uint256 deadline) public view returns (bytes32) {
        return keccak256(abi.encode("DojiPad platform agent", block.chainid, address(this), agent, vault, deadline));
    }

    // ------------------------------------------------------------------
    // Launch
    // ------------------------------------------------------------------
    /// @notice Deploys and activates a vault in one transaction.
    /// @param p vault, policy, agent and seed configuration. The guardian and sentinel are the platform's.
    /// @param permit USDC permit for at least p.seedUsdc with this factory as spender; deadline 0 = use allowance
    /// @dev msg.value (>= minAgentGas) is forwarded to the bound agent wallet for Arbitrum gas; a manual-mode launch
    ///      (no agent) sends none.
    function create(CreateParams calldata p, PermitData calldata permit)
        external
        payable
        returns (address vault, address policy)
    {
        if (!canLaunch(msg.sender)) revert LaunchClosed();
        if (guardian == sentinel) revert RolesCollide();
        if (p.seedUsdc < minSeedUsdc) revert SeedTooSmall(p.seedUsdc, minSeedUsdc);
        if (p.agent != address(0) ? msg.value < minAgentGas : msg.value != 0) revert AgentGasTooSmall(msg.value, minAgentGas);
        if (p.agent != address(0) && platformAgentFor[p.agent] != predictVaultAddress(msg.sender, p.salt)) {
            // Not pre-bound by the (cold) owner: the registrar's signature for exactly this launch binds it now.
            if (p.agentSig.length == 0) revert NotPlatformAgent(p.agent);
            address predicted = predictVaultAddress(msg.sender, p.salt);
            if (platformAgentFor[p.agent] != address(0)) revert AgentAlreadyBound(p.agent, platformAgentFor[p.agent]);
            if (agentOfVault[predicted] != address(0)) revert VaultAlreadyHasAgent(predicted, agentOfVault[predicted]);
            if (block.timestamp > p.agentDeadline) revert BadAgentSignature();
            address signer = ECDSA.recover(MessageHashUtils.toEthSignedMessageHash(agentDigest(p.agent, predicted, p.agentDeadline)), p.agentSig);
            if (signer == address(0) || (signer != agentRegistrar && signer != owner())) revert BadAgentSignature();
            platformAgentFor[p.agent] = predicted;
            agentOfVault[predicted] = p.agent;
            emit PlatformAgentRegistered(p.agent, predicted, true);
        }
        if (p.depositCap == 0 || p.depositCap > maxDepositCap) revert CapAboveMax(p.depositCap, maxDepositCap);
        for (uint256 i; i < p.assets.length; ++i) {
            if (!isAssetCurated[p.assets[i]]) revert AssetNotCurated(p.assets[i]);
        }

        if (permit.deadline != 0) {
            // A front run permit with the same signature would already have set the allowance; never let
            // that brick the launch, the transferFrom below is the real check.
            try IERC20Permit(address(usdc)).permit(
                msg.sender, address(this), permit.value, permit.deadline, permit.v, permit.r, permit.s
            ) {} catch {}
        }

        vault = Clones.cloneDeterministic(vaultImplementation, _scopedSalt(msg.sender, p.salt));
        policy = Clones.clone(policyImplementation);
        GainsVaultPolicy(policy).initialize(p.owner, p.risk, p.assets, p.timelockDelay, address(this), vault);

        // Seed goes straight to the vault, where it is idle USDC.
        usdc.safeTransferFrom(msg.sender, vault, p.seedUsdc);

        uint16 share = p.hosted ? hostedShareBps : baseShareBps;
        GainsVault(vault).initialize(
            InitParams({
                asset: usdc,
                name: p.name,
                symbol: p.symbol,
                owner: p.owner,
                manager: p.manager,
                guardian: address(0),
                feeRecipient: p.feeRecipient,
                managementFeeBps: p.managementFeeBps,
                performanceFeeBps: p.performanceFeeBps,
                timelockDelay: p.timelockDelay,
                depositCap: p.depositCap,
                policy: GainsVaultPolicy(policy),
                diamond: diamond,
                factory: address(this),
                protocolShareBps: share,
                baseShareBps: baseShareBps,
                hosted: p.hosted,
                agent: p.agent,
                operator: p.operator
            })
        );
        _vaults.push(vault);
        isVault[vault] = true;
        policyOf[vault] = policy;
        // Gas for the agent wallet, which signs every Arbitrum transaction of this vault (decision D1). Last, after
        // every state write (checks-effects-interactions).
        if (msg.value > 0) {
            (bool ok,) = p.agent.call{value: msg.value}("");
            if (!ok) revert AgentGasFailed();
        }
        emit VaultCreated(vault, policy, p.owner, p.manager, p.agent, p.hosted, share, p.salt);
    }

    // ------------------------------------------------------------------
    // Platform agents. An agent is bound to exactly one vault, for good (audit N-07). New vaults bind theirs in
    // create() from the registrar's signature. Here: the registrar or the owner registers a replacement agent for
    // an EXISTING vault (set on the vault through its timelock); only the cold owner may still pre-bind a predicted
    // address. The hot registrar key can no longer bind a predicted vault and block a creator's salt (V-04).
    // ------------------------------------------------------------------
    function registerPlatformAgent(address agent, address vault) external {
        if (msg.sender != agentRegistrar && msg.sender != owner()) revert NotRegistrar();
        if (agent == address(0) || vault == address(0)) revert ZeroAddress();
        if (!isVault[vault] && msg.sender != owner()) revert NotRegistrar();
        if (platformAgentFor[agent] != address(0)) revert AgentAlreadyBound(agent, platformAgentFor[agent]);
        if (agentOfVault[vault] != address(0) && !isVault[vault]) revert VaultAlreadyHasAgent(vault, agentOfVault[vault]);
        platformAgentFor[agent] = vault;
        agentOfVault[vault] = agent;
        emit PlatformAgentRegistered(agent, vault, true);
    }

    /// @notice Marks the agent unusable. An agent that is live on its vault is also revoked there, which only the
    ///         owner, the guardian or the sentinel may trigger: the registrar alone cannot stop a vault (audit I2-03).
    function unregisterPlatformAgent(address agent) external {
        bool platformRole = msg.sender == owner() || msg.sender == guardian || msg.sender == sentinel;
        if (msg.sender != agentRegistrar && !platformRole) revert NotRegistrar();
        address vault = platformAgentFor[agent];
        if (vault == address(0)) return;
        if (isVault[vault] && GainsVault(vault).agent() == agent) {
            if (!platformRole) revert LiveAgent(agent, vault);
            GainsVault(vault).revokeAgent();
        }
        delete platformAgentFor[agent];
        if (agentOfVault[vault] == agent) delete agentOfVault[vault];
        emit PlatformAgentRegistered(agent, vault, false);
    }

    // ------------------------------------------------------------------
    // Owner config (future vaults only, except lowerProtocolShare)
    // ------------------------------------------------------------------
    function setProtocolFeeRecipient(address recipient) external onlyOwner {
        if (recipient == address(0)) revert ZeroAddress();
        protocolFeeRecipient = recipient;
        emit ProtocolFeeRecipientUpdated(recipient);
    }

    function setShares(uint16 baseShareBps_, uint16 hostedShareBps_) external onlyOwner {
        if (baseShareBps_ > MAX_PROTOCOL_SHARE_BPS || hostedShareBps_ > MAX_PROTOCOL_SHARE_BPS) revert InvalidShare();
        baseShareBps = baseShareBps_;
        hostedShareBps = hostedShareBps_;
        emit SharesUpdated(baseShareBps_, hostedShareBps_);
    }

    /// @notice Lowers one existing vault's locked protocol share. The vault rejects anything that is not lower.
    function lowerProtocolShare(address vault, uint16 newBps) external onlyOwner {
        if (!isVault[vault]) revert NotAVault();
        GainsVault(vault).lowerProtocolShare(newBps);
        emit ProtocolShareLowered(vault, newBps);
    }

    function setMinSeedUsdc(uint256 amount) external onlyOwner {
        minSeedUsdc = amount;
        emit MinSeedUpdated(amount);
    }

    function setMinAgentGas(uint256 amount) external onlyOwner {
        minAgentGas = amount;
        emit MinAgentGasUpdated(amount);
    }

    function setLauncherAllowed(address launcher, bool allowed) external onlyOwner {
        launcherAllowed[launcher] = allowed;
        emit LauncherAllowed(launcher, allowed);
    }

    function setOpenLaunch(bool open) external onlyOwner {
        openLaunch = open;
        emit OpenLaunchSet(open);
    }

    /// @notice Rotates the cold guardian for every factory vault at once (vaults read it live).
    function setGuardian(address guardian_) external onlyOwner {
        if (guardian_ == address(0)) revert ZeroAddress();
        _checkRoles(owner(), guardian_, sentinel, agentRegistrar);
        _checkRoles(pendingOwner(), guardian_, sentinel, agentRegistrar);
        guardian = guardian_;
        emit GuardianUpdated(guardian_);
    }

    /// @notice Rotates the sequencer uptime feed for new vaults; existing vaults adopt it through their timelock. The
    ///         grace period is bounded (1 h to 1 day, GV-03).
    function setSequencerFeed(address feed, uint256 gracePeriod) external onlyOwner {
        if (feed == address(0)) revert ZeroAddress();
        GainsPrice.checkSequencerGrace(gracePeriod);
        sequencerFeed = feed;
        sequencerGracePeriod = gracePeriod;
        emit SequencerFeedUpdated(feed, gracePeriod);
    }

    /// @notice Rotates the hot sentinel for every factory vault at once (vaults read it live).
    function setSentinel(address sentinel_) external onlyOwner {
        if (sentinel_ == address(0)) revert ZeroAddress();
        _checkRoles(owner(), guardian, sentinel_, agentRegistrar);
        _checkRoles(pendingOwner(), guardian, sentinel_, agentRegistrar);
        sentinel = sentinel_;
        emit SentinelUpdated(sentinel_);
    }

    function setAgentRegistrar(address registrar) external onlyOwner {
        _checkRoles(owner(), guardian, sentinel, registrar);
        _checkRoles(pendingOwner(), guardian, sentinel, registrar);
        agentRegistrar = registrar;
        emit AgentRegistrarUpdated(registrar);
    }

    /// @dev Two step, and the incoming owner may not be one of the hot roles. Owner == guardian is allowed: one
    ///      cold multisig may hold both (audit I2-05 / I2-06).
    function transferOwnership(address newOwner) public override onlyOwner {
        _checkRoles(newOwner, guardian, sentinel, agentRegistrar);
        super.transferOwnership(newOwner);
    }

    /// @dev A factory without an owner could never rotate a role again (audit V-03).
    function renounceOwnership() public view override onlyOwner {
        revert RolesCollide();
    }

    /// @notice Curates (or removes) a pair. Curating sets its price config: Chainlink `feed`, staleness limit
    ///         `maxAge` (heartbeat + margin) and NAV band `bandBps` (deviation threshold + measured spread, PLAN.md
    ///         4.3). Existing vaults keep the config their policy copied; this applies to new allowlistings, and is the
    ///         only combination an existing vault may rotate to (setPairFeed, through the vault timelock).
    function setAssetCurated(uint32 asset, bool curated, address feed, uint32 maxAge, uint16 bandBps) external onlyOwner {
        if (curated) {
            if (asset > type(uint16).max || feed == address(0) || maxAge == 0 || bandBps == 0 || bandBps > GainsPrice.MAX_BAND_BPS) {
                revert InvalidFeed();
            }
            _pairFeed[asset] = GainsPrice.Feed({feed: feed, maxAge: maxAge, bandBps: bandBps, decimals: IChainlinkFeed(feed).decimals()});
            emit PairFeedSet(asset, feed, maxAge, bandBps);
        }
        if (!isAssetCurated[asset] && curated) {
            bool listed;
            for (uint256 i; i < _curated.length; ++i) {
                if (_curated[i] == asset) listed = true;
            }
            if (!listed) _curated.push(asset);
        }
        isAssetCurated[asset] = curated;
        emit AssetCurated(asset, curated);
    }

    function setMaxDepositCap(uint256 cap) external onlyOwner {
        maxDepositCap = cap;
        emit MaxDepositCapUpdated(cap);
    }

    // ------------------------------------------------------------------
    // GR2-KEY-01b: per-pair skew cap (every factory vault reads it at each open, increase and limit / stop placement)
    // ------------------------------------------------------------------
    /// @notice A factory vault's maximum notional on `pair`, in bps of the pair's 1 % skew depth. 0 = no new exposure.
    function pairSkewCapBps(uint16 pair) external view returns (uint16) {
        return _pairCap[pair].bps;
    }

    function pairSkewCap(uint16 pair) external view returns (PairCap memory) {
        return _pairCap[pair];
    }

    /// @notice Lowers `pair`'s cap at once and drops a queued raise (guardian or sentinel: risk reducing). The guardian
    ///         may also set a pair never set before at once, up to DEFAULT_PAIR_SKEW_CAP_BPS: no vault could trade it yet.
    ///         Any other raise goes through queuePairSkewCap.
    function setPairSkewCap(uint16 pair, uint16 bps) external {
        bool g = msg.sender == guardian;
        if (!g && msg.sender != sentinel) revert NotGuardian();
        PairCap storage c = _pairCap[pair];
        if (bps > c.bps && !(g && !c.set && bps <= DEFAULT_PAIR_SKEW_CAP_BPS)) revert InvalidPairCap(bps);
        if (c.eta != 0) {
            (c.queuedBps, c.eta) = (0, 0);
            emit PairSkewCapCancelled(pair);
        }
        _applyPairCap(c, pair, bps);
    }

    /// @notice Queues a raise of `pair`'s cap (guardian). It applies PAIR_CAP_RAISE_DELAY later, through
    ///         executePairSkewCap; a new queue replaces the old one and restarts the wait.
    function queuePairSkewCap(uint16 pair, uint16 bps) external {
        if (msg.sender != guardian) revert NotGuardian();
        PairCap storage c = _pairCap[pair];
        if (bps <= c.bps || bps > MAX_PAIR_SKEW_CAP_BPS) revert InvalidPairCap(bps);
        uint64 eta = uint64(block.timestamp + PAIR_CAP_RAISE_DELAY);
        (c.queuedBps, c.eta) = (bps, eta);
        emit PairSkewCapQueued(pair, bps, eta);
    }

    /// @notice Applies a queued raise once its wait is over (guardian).
    function executePairSkewCap(uint16 pair) external {
        if (msg.sender != guardian) revert NotGuardian();
        PairCap storage c = _pairCap[pair];
        if (c.eta == 0) revert NotQueued();
        if (block.timestamp < c.eta) revert NotReady(c.eta);
        uint16 bps = c.queuedBps;
        (c.queuedBps, c.eta) = (0, 0);
        _applyPairCap(c, pair, bps);
    }

    /// @notice Drops a queued raise (guardian or sentinel).
    function cancelPairSkewCap(uint16 pair) external {
        if (msg.sender != guardian && msg.sender != sentinel) revert NotGuardian();
        PairCap storage c = _pairCap[pair];
        if (c.eta == 0) revert NotQueued();
        (c.queuedBps, c.eta) = (0, 0);
        emit PairSkewCapCancelled(pair);
    }

    // ------------------------------------------------------------------
    // Internal
    // ------------------------------------------------------------------
    function _applyPairCap(PairCap storage c, uint16 pair, uint16 bps) internal {
        c.bps = bps;
        if (bps > 0) c.set = true;
        emit PairSkewCapSet(pair, bps);
    }

    function _scopedSalt(address creator, bytes32 salt) internal pure returns (bytes32) {
        return keccak256(abi.encode(creator, salt));
    }

    /// @dev The hot roles (sentinel, registrar) are distinct from each other and from the cold ones (owner,
    ///      guardian); guardian != sentinel always. A zero registrar means none (audit I2-05). The setters run the
    ///      check against the pending owner too, so an accepted transfer never creates a collision (audit V-03);
    ///      a zero pending owner is skipped.
    function _checkRoles(address owner_, address guardian_, address sentinel_, address registrar_) internal pure {
        if (owner_ == address(0)) {
            if (guardian_ == sentinel_) revert RolesCollide();
            if (registrar_ != address(0) && (registrar_ == guardian_ || registrar_ == sentinel_)) revert RolesCollide();
            return;
        }
        if (guardian_ == sentinel_ || sentinel_ == owner_) revert RolesCollide();
        if (registrar_ != address(0) && (registrar_ == owner_ || registrar_ == guardian_ || registrar_ == sentinel_)) {
            revert RolesCollide();
        }
    }
}
