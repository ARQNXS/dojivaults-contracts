// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ICoreDepositWallet} from "./hypercore/HyperCore.sol";
import {VaultPolicy} from "./VaultPolicy.sol";

/// @dev Shared definitions for HyperVault and its linked logic libraries (VaultLogic, VaultGovernance).
///      The vault keeps every mutable field in one `VaultStorage` struct so the libraries can operate on it
///      through delegatecall; the ERC-20 and Ownable state lives in OpenZeppelin's namespaced slots.

uint256 constant BPS = 10_000;
uint256 constant YEAR = 365 days;
uint256 constant MAX_MANAGEMENT_FEE_BPS = 500; // 5% per year
uint256 constant MAX_PERFORMANCE_FEE_BPS = 3_000; // 30% of gains above the high water mark
uint256 constant MAX_PROTOCOL_SHARE_BPS = 5_000; // 50% of manager fees
uint256 constant MIN_TIMELOCK = 1 days;
uint256 constant MAX_TIMELOCK = 30 days;
/// @dev A queued change must be executed within this window after its eta (audit M-03).
uint256 constant GRACE_PERIOD = 14 days;
/// @dev Exit before effect (hl-r2 H01): a queued change waits at least this long past the running epoch's deadline.
uint256 constant EXIT_MARGIN = 1 days;
/// @dev EVM blocks during which a bridge transfer is in flight. Nothing bridges, settles or accrues inside it.
uint256 constant BRIDGE_SETTLE_BLOCKS = 10;
/// @dev A bridge whose transfer has not landed after BRIDGE_SETTLE_BLOCKS keeps the window open until it lands,
///      at most this many blocks after the bridge (R-02): the USDC in transit is never read as a NAV drop.
uint256 constant MAX_BRIDGE_WAIT_BLOCKS = 60;
/// @dev A transfer that has still not landed after MAX_BRIDGE_WAIT_BLOCKS is treated as in transit by the risk
///      check, settle and every treasury action for at most this many blocks after the bridge (R3-01 residual): a
///      late landing never reads as a daily loss or drawdown. Only the bridged amount is carried; trading losses
///      meanwhile still count. After this, whatever is missing counts as lost. The sentinel alerts from 30 blocks.
uint256 constant MAX_UNLANDED_BLOCKS = 300;
/// @dev XF-01: in emergency an owner-chosen role (manager, owner, operator) may bridge to EVM only this many blocks after
///      the previous bridge, so even an unlanded window (MAX_UNLANDED_BLOCKS) leaves 30 blocks for the exit settle.
uint256 constant EMERGENCY_BRIDGE_COOLDOWN = MAX_UNLANDED_BLOCKS + 30;
/// @dev Smallest deposit request (I3-07): no dust requests, and arming the insider settle delay costs real money.
uint256 constant MIN_DEPOSIT = 10e6;
/// @dev A leverage breach can be cleared by anyone this long after it fired, once every limit is met again.
uint256 constant LEVERAGE_CLEAR_COOLDOWN = 15 minutes;
/// @dev A settle that prices insider deposits must run at least this long after its epoch started (R3-02): two
///      settles in one block can no longer price an insider at a NAV of their choosing.
uint256 constant INSIDER_MIN_EPOCH_AGE = 1 hours;
/// @dev The owner may resume() a drawdown breach only this long after it fired (depositors get a day to see it).
uint256 constant RESUME_COOLDOWN = 24 hours;
/// @dev Rounding and the 1 USDC Core activation fee: a bridge counts as landed within this much of its amount.
uint256 constant BRIDGE_LANDING_TOLERANCE = 1e6;
/// @dev HLR2-A02 / A08: a transfer still missing past MAX_UNLANDED_BLOCKS while the NAV reads short by it holds every
///      settle and bridge for at most this long (about a day of 1 s blocks), or until it lands or the guardian writes
///      it off. After that, whatever is still missing counts as lost (R3-08).
uint256 constant UNRESOLVED_WAIT_BLOCKS = 86_400;
/// @dev HLR2-A08 part 3 / E01e: NAV left in a vault whose every share was burned belongs to nobody who is still in it
///      (a transfer that landed after the exits, a rise the exit price withheld). Up to this much (the launch seed and
///      rounding) still goes to the next first depositor, as at launch; above it, settle mints it to the guardian.
uint256 constant ORPHAN_DUST = 10e6;
/// @dev Below this NAV the share price is dominated by the virtual offset (rounding), and there is nothing to protect:
///      daily loss and drawdown read 0. Leverage still counts (positions are real at any size).
uint256 constant MIN_RISK_NAV = 1e6;
/// @dev Smallest bridge unless the full available amount is smaller (audit H-02).
uint256 constant MIN_BRIDGE = 100e6;
uint8 constant DECIMALS_OFFSET = 6;
uint256 constant ONE_SHARE = 10 ** (6 + DECIMALS_OFFSET);
/// @dev HL-PROXY: anyone may re-pin the account mode (CoreWriter action 16) at most this often; the vault's own roles
///      and settle() re-pin it whenever they run. Every pin is one HyperCore action of the vault's account.
uint256 constant MODE_PIN_INTERVAL = 10 minutes;
/// @dev HL-PROXY: the Order ticket's cloid prefix (the manager's orders); an agent order never carries it.
uint128 constant TICKET_CLOID_PREFIX = 0xd0a1d0a1;
/// @dev The HyperCore api wallet name. HL-PROXY: no agent is approved under it any more; revokeAgent still overwrites
///      the slot with a burn address (older approvals, defensive).
string constant AGENT_NAME = "dojipad";
// HLO-07: veto window between a factory vault's launch with an agent and the first deposit / the agent's HyperCore
// approval. Equal to MIN_TIMELOCK, the window a replacement agent (setAgent) already waits behind.
uint256 constant AGENT_WARMUP = 1 days;
// HLR2-E01: an exit-only settle pays at min(NAV, checkpoint) only while the checkpoint is younger than this (equal to
// VaultPolicy.CHECKPOINT_INTERVAL, the earliest moment checkRisk may walk it again).
uint256 constant EXIT_CHECKPOINT_FRESH = 1 hours;

/// @dev Why the vault is in reduce only mode. LEVERAGE, DAILY_LOSS and DRAWDOWN come from checkRisk() and keep the
///      agent (the platform executor honours reduce only); GUARDIAN and EMERGENCY are full stops that revoke it.
///      Ordered by severity: a breach only ever escalates.
enum BreachReason {
    NONE,
    LEVERAGE,
    DAILY_LOSS,
    DRAWDOWN,
    GUARDIAN,
    EMERGENCY
}

struct EpochResult {
    uint256 depositAssets; // queued deposits priced in this epoch (refunded when depositShares == 0)
    uint256 depositShares; // shares minted for them
    uint256 redeemShares; // shares queued for redemption (requested), pro rata base for the payout
    uint256 redeemAssets; // USDC paid for them (a partial fill in emergency)
    uint256 redeemBurned; // shares burned for that payout; redeemShares - redeemBurned go back to the redeemers
    uint256 nav; // NAV after the flows were applied
    uint256 sharePrice;
    uint64 settledAt;
    // Redemption-only epoch (daily loss / drawdown breach): its queued deposits were carried, not priced. Holds
    // origin + 1 of the carry run they belong to (0 = not carried); carryPricedIn[origin] says where they priced.
    uint256 carriedFrom;
}

struct Request {
    uint256 epoch;
    uint256 depositAssets;
    uint256 redeemShares;
}

struct VaultStorage {
    // set once at initialization
    IERC20 asset;
    VaultPolicy policy;
    ICoreDepositWallet coreDepositWallet;
    address factory;
    uint16 protocolShareBps;
    uint16 baseShareBps;
    bool hosted;
    // roles and config
    address manager;
    address guardian; // standalone vaults only; factory vaults read guardian() and sentinel() from the factory
    address feeRecipient;
    address agent;
    uint16 managementFeeBps;
    uint16 performanceFeeBps;
    uint256 timelockDelay;
    uint256 depositCap;
    mapping(bytes32 id => uint256 eta) queuedEta;
    mapping(bytes32 id => uint256 at) queuedAt;
    // state flags
    bool depositsPaused;
    bool tradingPaused;
    bool breached;
    bool emergency;
    uint64 breachedAt;
    // epochs and requests
    uint256 currentEpoch;
    uint64 epochStartedAt;
    uint64 lastFeeAccrual;
    uint256 pendingDepositAssets;
    uint256 pendingRedeemShares;
    uint256 claimableRedeemAssets;
    mapping(uint256 epoch => EpochResult) epochs;
    mapping(address controller => Request) requests;
    // bridge window
    uint256 equityAtBridge; // idle + core equity right before the latest bridge; NAV inside the window
    uint256 bridgeAmount; // what the latest bridge moved; invisible on both sides until HyperCore applies it
    uint256 lastBridgeBlock;
    // fees and risk
    uint256 highWaterMark; // assets per share unit at the last performance fee charge
    uint256 peakSharePrice; // lifetime peak, scaled for fee dilution only, never reset
    uint256 riskDay;
    uint256 dayStartSharePrice; // share price at the first risk check of the UTC day (R-01: flows never move it)
    uint192 checkpointNav; // NAV checkpoint ratcheted by checkRisk() and set by settle()
    uint64 checkpointAt;
    uint256 lock;
    // A performance fee raise waits here until the next settle has charged the running epoch at the old rate (N2-02).
    uint16 pendingPerformanceFeeBps;
    // When the current emergency started (audit W-01 / W-01b): only the cold guardian ends an emergency, and only
    // once nothing is pending and the last settle of this emergency paid every redemption in full.
    uint64 emergencyAt;
    // Round 4
    BreachReason breachReason;
    // Treasury operator (owner grants, owner / sentinel / guardian revoke): settle, bridges and moveUsd only.
    address operator;
    // Deposits by the manager, owner or fee recipient: priced in the NEXT epoch (no insider pricing in the current).
    uint256 deferredDepositAssets;
    // R-02: what the latest bridge is waiting for. A bridge has landed when its destination side shows the amount
    // (Core: spot USDC or Core equity up by it; EVM: the USDC balance up by it, net of deposits and claims since);
    // the first transaction that sees it latches `bridgeLanded`.
    bool bridgeToCoreDir;
    bool bridgeLanded;
    uint256 coreAtBridge;
    uint256 spotAtBridge;
    uint256 evmAtBridge;
    uint256 evmInSinceBridge;
    uint256 evmOutSinceBridge;
    // Decision 4: a redemption-only settle carries the deposit queue. carryOrigin = first epoch of the open carry
    // run + 1 (0 = none); carryPricedIn[origin] = the epoch that finally priced (or refunded) that run + 1.
    uint256 carryOrigin;
    mapping(uint256 origin => uint256 pricedIn) carryPricedIn;
    // When the owner last resumed after a drawdown breach (the vault page tells depositors).
    uint64 lastResumeAt;
    // R3-02: the deposit queue contains insider deposits (rolled in from deferredDepositAssets). Cleared by the settle
    // that prices or refunds the queue; a cancel does not clear it (the safe direction: at most a 1 h wait).
    bool insiderInQueue;
    // hl-r2 H01 / XB01: this epoch's forced-exit deadline, fixed when the epoch starts (settle, initialize) from the
    // maxEpochDuration in force then. A later policy change applies from the next epoch, in either direction.
    uint64 epochDeadline;
    // HLR2-XA01: set when the guardian, the sentinel or the factory revokes a live agent (the monitor's ACT). Until
    // the guardian clears it (clearBreach), deposits are closed and every settle is redemption-only: no share is
    // minted at a NAV the revoked agent may have deflated. The vault owner cannot clear it.
    bool depositHold;
    // HLO-07: a factory vault launched with an agent accepts no deposit and cannot approve the agent on HyperCore
    // before this time. The guardian or the sentinel vetoes a binding the platform does not hold in the meantime
    // (factory.unregisterPlatformAgent, which revokes it here).
    uint64 agentActiveAt;
    // HLR2-E06: the running full stop (GUARDIAN reason) was imposed or re-imposed by the guardian or the sentinel.
    // Such a stop freezes every settle until the guardian acts or the epoch is overdue. A full stop imposed by the
    // vault owner alone settles redemption-only instead, so the owner cannot freeze the exits.
    bool platformHold;
    // HLR2-E01: the last checkRisk ratchet was capped below the NAV it saw, so the checkpoint still trails the NAV
    // and more hourly steps are due. An exit-only settle never pays at a trailing checkpoint.
    bool checkpointLagging;
    // HL-PROXY: when the vault last sent the account-mode pin (CoreWriter action 16, Standard / "disabled").
    uint64 modePinnedAt;
    // HLR2-A04: spot USDC + perp cash (rawUsd + signed entry notional, no unrealised PnL) right before the latest
    // bridge. An EVM -> Core transfer has landed when spot AND this sum are up by the amount: a perp -> spot move
    // raises spot only, a realised gain raises the sum only, a fill in a listed market changes neither.
    int256 cashAtBridge;
    bool cashKnown; // cashAtBridge was read (false: a precompile read failed, or the seed)
    // HLR2-A02 / A08: latched by the first sync that sees spot + perp cash up (to Core) or down (to EVM) by half the
    // amount since the bridge. The verdict "missing" then does not drift with the trading PnL of the hours after.
    bool creditSeen;
    bool debitSeen;
    // HLR2-A02 / A08: the guardian wrote the latest (missing) transfer off; settles price without it.
    bool bridgeWrittenOff;
    // HLR2-A08 part 3: a settle has minted shares before (a vault back at supply 0 is not a fresh launch).
    bool everMinted;
    // WP1 agent limits: the platform agent's orders that add risk, in 24 hourly buckets (index hour % 24), two per
    // word: hour (uint32) << 96 | orders (uint16) << 80 | opened notional (uint80, USD 6 decimals).
    uint256[12] agentFlow;
}

struct InitParams {
    IERC20 asset;
    string name;
    string symbol;
    address owner;
    address manager;
    address guardian; // ignored on factory vaults (the factory's guardian / sentinel apply)
    address feeRecipient;
    uint16 managementFeeBps;
    uint16 performanceFeeBps;
    uint256 timelockDelay;
    uint256 depositCap;
    VaultPolicy policy;
    ICoreDepositWallet coreDepositWallet;
    address factory;
    uint16 protocolShareBps;
    uint16 baseShareBps;
    bool hosted;
    address agent; // platform agent bound to this vault on the factory, zero for manual mode
    address operator; // treasury operator (settle, bridges, moveUsd), zero for none
    uint256 seedUsdc; // USDC the factory placed here, bridged to HyperCore spot to open the Core account
}

interface IVaultFactory {
    function protocolFeeRecipient() external view returns (address);
    function platformAgentFor(address agent) external view returns (address vault);
    function guardian() external view returns (address);
    function sentinel() external view returns (address);
    function maxDepositCap() external view returns (uint256);
}

/// @dev Events are declared once here; the libraries emit them with `emit IHyperVaultEvents.X(...)` so they
///      show up in the vault's ABI and logs.
interface IHyperVaultEvents {
    event DepositRequested(address indexed controller, address indexed sender, uint256 indexed epoch, uint256 assets);
    event RedeemRequested(address indexed controller, address indexed owner, uint256 indexed epoch, uint256 shares);
    event DepositCancelled(address indexed controller, uint256 assets);
    event RedeemCancelled(address indexed controller, uint256 shares);
    event Claimed(address indexed controller, uint256 epoch, uint256 shares, uint256 assets);
    event EpochSettled(
        uint256 indexed epoch, uint256 nav, uint256 depositAssets, uint256 depositShares, uint256 redeemShares, uint256 redeemAssets
    );
    event FeesAccrued(uint256 feeShares, uint256 protocolShares, uint256 sharePrice);
    event BridgedToCore(uint256 amount);
    event BridgedToEvm(uint256 amount);
    event CoreGasFunded(address indexed funder, uint256 hype);
    event UsdMoved(uint256 amount, bool toPerp);
    event OrderSent(uint32 indexed asset, bool isBuy, uint64 limitPx, uint64 sz, bool reduceOnly, uint8 tif, uint128 cloid);
    /// @dev HL-PROXY: a non reduce-only order was not sent because the pre-trade risk check put the vault in reduce only.
    event OrderRefused(uint32 indexed asset, uint128 cloid, address caller);
    /// @dev HL-PROXY: the vault sent CoreWriter action 16 (abstraction 1, Standard mode) for its own account.
    event AccountModePinned(address caller);
    event Flattened(uint32 indexed asset, int64 szi, uint64 limitPx, address caller);
    event AgentSet(address indexed agent);
    event AgentSynced(address indexed agent);
    event AgentRevoked(address indexed agent);
    event AgentRevokeResent();
    event BridgeWrittenOff(uint256 amount);
    event OrphanedNavReserved(address indexed to, uint256 assets, uint256 shares);
    event RiskChecked(uint256 leverageBps, uint256 dailyLossBps, uint256 drawdownBps, uint256 equity);
    event Breached(string reason, address caller);
    event BreachCleared();
    event DepositHold(bool held);
    event Resumed(uint256 peakBefore, uint256 peakAfter);
    event OperatorSet(address indexed operator);
    event EmergencyTriggered(address caller);
    event EmergencyExited();
    event DepositsPaused(bool paused);
    event TradingPaused(bool paused);
    event ManagerUpdated(address manager);
    event FeeRecipientUpdated(address recipient);
    event FeesUpdated(uint16 managementFeeBps, uint16 performanceFeeBps);
    event FeesScheduled(uint16 performanceFeeBps);
    event TimelockUpdated(uint256 delay);
    event DepositCapUpdated(uint256 cap);
    event Queued(bytes32 indexed id, bytes data, uint256 eta);
    event Executed(bytes32 indexed id);
    event Cancelled(bytes32 indexed id);
    event LeftHosted(uint16 protocolShareBps);
    event ProtocolShareLowered(uint16 protocolShareBps);
}

interface IHyperVaultErrors {
    error Unauthorized();
    error ZeroAmount();
    error ZeroAddress();
    error DepositsClosed();
    error CapExceeded();
    error NothingToCancel();
    error RequestNotSettled();
    error BridgeInFlight();
    error TransferUnresolved();
    error NotUnresolved();
    error BridgeTooSmall();
    error CoreAccountInactive();
    error InsufficientIdle(uint256 idle, uint256 needed);
    error InsufficientLiquidity(uint256 available, uint256 needed);
    error OrderRejected(string reason);
    error ReduceOnlyMode();
    error TradingIsPaused();
    error InvalidFee();
    error InvalidShare();
    error InvalidTimelock();
    error NotQueued();
    error NotReady();
    error Expired();
    error CallFailed(bytes reason);
    error NotOverdue();
    error InEmergency();
    error UnsupportedAsset();
    error NotHosted();
    error Reentrancy();
    error NotPlatformAgent();
    error RedemptionsPending();
    error NotClearable();
    error RequestPending();
    error EpochTooYoung();
    error DepositTooSmall();
    error AgentWarmingUp(uint256 activeAt);
    error CheckpointBehind(uint256 checkpoint, uint256 nav);
    /// @dev HL-PROXY: the precompiles show a balance layout the Standard account mode cannot produce (see
    ///      VaultMath.modeSuspect); NAV is not priced and no risk is added until the mode pin has landed.
    error AccountModeMismatch();
}
