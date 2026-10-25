// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IGainsDiamond} from "./IGainsDiamond.sol";
import {GainsVaultPolicy, POLICY_MAX_EPOCH_DURATION} from "./GainsVaultPolicy.sol";
import {BreachReason, EpochResult, Request} from "../VaultTypes.sol";

/// @dev Gains-only definitions for GainsVault and its linked libraries. Everything shared with round 4 (constants,
///      BreachReason, EpochResult, Request, IVaultFactory) comes from VaultTypes.sol unchanged. The storage struct
///      is round 4's VaultStorage with the HyperCore fields removed and the diamond added; the field order of the
///      shared part is kept so an auditor can diff it line by line.

/// @dev Gas-safety ceiling, not a strategy limit: open trades + resting limit/stop orders + pending orders per vault.
///      Every one of them is valued with a handful of diamond reads (PLAN.md 4.3), so this bounds the NAV gas. Only new
///      exposure (openTrade, increaseTrade, new limit / stop orders) is refused at the ceiling; exits never are.
uint256 constant MAX_POSITIONS = 20;
/// @dev Exit before effect (GR2-CFG-01): a queued change waits at least this long past the running epoch's deadline.
uint256 constant EXIT_MARGIN = 1 days;
/// @dev Gains' hard minimum collateral is 5 x the pair's minimum fee (InsufficientCollateral, STAGE0.md A5).
uint256 constant MIN_COLLATERAL_FEE_MULTIPLE = 5;
/// @dev GR2-KEY-01 (cap) and GR2-KEY-01b (its size, now per pair): the vault's notional on one pair (open trades +
///      resting orders + pending orders + the new order) is at most a fraction f of the pair's 1 % skew depth (Gains
///      getPairSkewDepth, in USD at the Chainlink price). Factory vaults read f per pair from the factory
///      (IGainsPairCaps.pairSkewCapBps: set by the guardian, lowered at once, raised only after PAIR_CAP_RAISE_DELAY,
///      0 = no new exposure, never above MAX_PAIR_SKEW_CAP_BPS); a standalone vault uses DEFAULT_PAIR_SKEW_CAP_BPS.
///      Skew impact moves the pair's price by size / (2 x depth) per 1 % (PriceImpactUtils, divider 2). An opposite
///      trader of size A who opens while the vault holds +V on the pair and closes after the vault has closed and
///      reopened -V (a double swing) captures 2 V A / (200 depth) = f / 100 of A at V = f x depth. His cheapest round
///      trip on the live diamond: ETH / BTC 2 x 3.5 bps fee x 0.429 (counter-trade fee multiplier: his trade lowers the
///      skew the vault built) x 0.75 (top volume tier) x 0.5 (top GNS staking tier) + 1 bp spread = 2.13 bps; SOL
///      2 x 5 bps x 0.4 x 0.375 = 1.5 bps (no spread; its cumulative-volume impact only adds to it). f = 1 % caps the
///      capture at 1 bp: below every curated pair's cheapest round trip (margin 2.1x BTC / ETH, 1.5x SOL at the top
///      discounts; 4x without fee tiers). At 5 % the double swing nets a profit with the counter-trade discount alone
///      (KEY01bForkFixTest). A pair's cap must stay below 100 x its cheapest opposite round trip (in bps): with lower fees
///      than BTC / ETH / SOL, below 1 % (KEYS.md, extraction bounds).
uint256 constant DEFAULT_PAIR_SKEW_CAP_BPS = 100;
/// @dev GR2-KEY-01b: hard ceiling of a factory pair cap (10 % of the skew depth: 10 bps of capture per double swing).
uint256 constant MAX_PAIR_SKEW_CAP_BPS = 1_000;
/// @dev GR2-KEY-01b: a raise of a factory pair cap waits this long after the guardian queues it (a lowering is
///      immediate). Exit before effect: the longest epoch any policy accepts plus one day (31 days), so a depositor of
///      every vault who asks to redeem when the raise is queued is paid (an overdue epoch can be settled by anyone)
///      before it applies, with a day to spare (EXIT_MARGIN, the shared exit-before-effect rule). Derived from the
///      policy's bound, never a separate number.
uint256 constant PAIR_CAP_RAISE_DELAY = POLICY_MAX_EPOCH_DURATION + EXIT_MARGIN;
/// @dev GR2-KEY-01b turnover budget: notional the manager / agent may open (market opens, resting limit / stop
///      placements, size increases) is a token bucket of TURNOVER_NAV_MULTIPLE x NAV that refills linearly over one
///      day. 20 = four full turnovers of the 5x leverage cap per day; at the measured round-trip costs (8.0 bps BTC /
///      ETH, 13.6 bps SOL) churn can then destroy at most 1.6 % / 2.7 % of NAV per day at the steady rate before any
///      keeper or human acts. The worst single 24 h window is a full bucket plus a day's refill, just under 2 x that
///      (40 x NAV opened: 3.2 % / 5.4 %), still inside the daily-loss limit the loss gate enforces.
///      Closes and reduces never spend it (exits are never refused for turnover).
uint256 constant TURNOVER_NAV_MULTIPLE = 20;
/// @dev GR2-KEY-01b minimum hold: the manager / agent may not reduce or close exposure on a pair within MIN_HOLD of
///      the vault's last new-risk request on that pair, nor a trade within MIN_HOLD_L2_BLOCKS of its last size increase
///      as Gains records it (TradeInfo.lastPosIncreaseBlock, ArbSys L2 blocks: covers late limit / stop fills).
///      10 minutes: longer than Gains' protection-close window at any value Gains may set (<= 10 minutes,
///      PriceImpactUtils.MAX_PROTECTION_CLOSE_FACTOR_DURATION; live 750 blocks ~ 200 s), so no profitable vault close
///      ever pays the 20x protection factor, and two keeper intervals (5 min) for the churn alarm. Never applies to the
///      guardian, to any exit in a breach or emergency, or to the operator. Never applies to Gains' own closes either:
///      a take profit, stop loss or liquidation executed by Gains' bots does not pass through the vault, and setSlTp is
///      not held, so the trade's stop loss always fires (KEYS.md: what this leaves to the turnover budget).
uint256 constant MIN_HOLD = 10 minutes;
/// @dev MIN_HOLD in Arbitrum L2 blocks at 250 ms (Arbitrum's floor; 264-269 ms measured): always at least MIN_HOLD.
uint256 constant MIN_HOLD_L2_BLOCKS = 2_400;
/// @dev The operator's reduce outside a breach may exceed the redemption shortfall by this much (2% of it plus 1 USDC):
///      Gains keeps its closing fee from the collateral a reduce returns, so a reduce of exactly the shortfall always
///      comes back short by that fee and the redemptions never settle without the manager (Stage 3 fork gate). Covers
///      the fee in one reduce up to about 30x leverage; above that the residual shrinks every round. What is freed beyond
///      the redemptions stays idle on the vault.
uint256 constant OPERATOR_REDUCE_BUFFER_BPS = 200;
uint256 constant OPERATOR_REDUCE_BUFFER = 1e6;

/// @dev The operator's reduceTrade cap outside a breach: the shortfall plus the fee allowance, nothing without one.
function operatorReduceCap(uint256 shortfall) pure returns (uint256) {
    return shortfall == 0 ? 0 : shortfall + shortfall * OPERATOR_REDUCE_BUFFER_BPS / 10_000 + OPERATOR_REDUCE_BUFFER;
}

struct VaultStorage {
    // set once at initialization
    IERC20 asset;
    GainsVaultPolicy policy;
    IGainsDiamond diamond;
    address factory;
    uint16 protocolShareBps;
    uint16 baseShareBps;
    bool hosted;
    uint8 collateralIndex; // the asset's collateral index on the diamond (3 for USDC on Arbitrum)
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
    // Treasury operator (owner grants, owner / sentinel / guardian revoke): settle, the breach / emergency unwind
    // and cancelling timed-out orders only.
    address operator;
    // Deposits by the manager, owner or fee recipient: priced in the NEXT epoch (no insider pricing in the current).
    uint256 deferredDepositAssets;
    // Decision 4: a redemption-only settle carries the deposit queue. carryOrigin = first epoch of the open carry
    // run + 1 (0 = none); carryPricedIn[origin] = the epoch that finally priced (or refunded) that run + 1.
    uint256 carryOrigin;
    mapping(uint256 origin => uint256 pricedIn) carryPricedIn;
    // When the owner last resumed after a drawdown breach (the vault page tells depositors).
    uint64 lastResumeAt;
    // R3-02: the deposit queue contains insider deposits (rolled in from deferredDepositAssets). Cleared by the settle
    // that prices or refunds the queue; a cancel does not clear it (the safe direction: at most a 1 h wait).
    bool insiderInQueue;
    // GR2-KEY-06: the checkpoint value the last checkRisk ratchet replaced (a settle sets it to the new checkpoint). While
    // the checkpoint is younger than CHECKPOINT_INTERVAL, redemption-only and exit-only settles pay at most
    // max(checkpointNav, priorCheckpointNav): a checkpoint taken at a dip cannot hold redemptions at the dip.
    uint192 priorCheckpointNav;
    // GR2-CFG-01 / CFG-02 / GR2-KEY-06: this epoch's deadline, fixed when the epoch starts (settle, initialize) from
    // the maxEpochDuration in force then. A later policy change applies from the next epoch; overdue stays overdue.
    uint64 epochDeadline;
    // GR2-KEY-01b: turnover bucket (opened notional, refills over a day) and the last new-risk request, vault-wide and
    // per pair (minimum hold of the manager's / agent's exits)
    uint128 turnoverUsed;
    uint64 turnoverAt;
    uint64 lastRiskAt;
    mapping(uint16 pair => uint64 at) pairRiskAt;
}

/// @dev GR2-KEY-01b: the factory's per-pair cap, in bps of the pair's 1 % skew depth (0 = no new exposure).
interface IGainsPairCaps {
    function pairSkewCapBps(uint16 pair) external view returns (uint16);
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
    GainsVaultPolicy policy;
    IGainsDiamond diamond;
    address factory;
    uint16 protocolShareBps;
    uint16 baseShareBps;
    bool hosted;
    address agent; // platform agent bound to this vault on the factory, zero for manual mode
    address operator; // treasury operator (settle, unwind, timed-out cancels), zero for none
}

/// @notice Arguments of GainsVault.openTrade (one struct: the agent's executor builds it from a signal).
/// @param tradeType 0 market, 1 limit, 2 stop
/// @param expectedPrice market: the expected fill (slippage reference); limit / stop: the trigger price. 1e10
/// @param maxSlippageP Gains slippage, 1e3 percent (1% = 1000)
struct OpenParams {
    uint16 pairIndex;
    bool long;
    uint120 collateral;
    uint24 leverage;
    uint64 expectedPrice;
    uint16 maxSlippageP;
    uint64 tp;
    uint64 sl;
    uint8 tradeType;
}

/// @dev Events are declared once here; the libraries emit them with `emit IGainsVaultEvents.X(...)` so they show up
///      in the vault's ABI and logs. Same names and fields as IHyperVaultEvents wherever the behavior is the same.
interface IGainsVaultEvents {
    event DepositRequested(address indexed controller, address indexed sender, uint256 indexed epoch, uint256 assets);
    event RedeemRequested(address indexed controller, address indexed owner, uint256 indexed epoch, uint256 shares);
    event DepositCancelled(address indexed controller, uint256 assets);
    event RedeemCancelled(address indexed controller, uint256 shares);
    event Claimed(address indexed controller, uint256 epoch, uint256 shares, uint256 assets);
    event EpochSettled(
        uint256 indexed epoch, uint256 nav, uint256 depositAssets, uint256 depositShares, uint256 redeemShares, uint256 redeemAssets
    );
    event FeesAccrued(uint256 feeShares, uint256 protocolShares, uint256 sharePrice);
    // Gains trading (replaces OrderSent / bridging / Core gas)
    event TradeRequested(uint16 indexed pairIndex, bool long, uint256 collateral, uint24 leverage, uint64 expectedPrice, uint8 tradeType, address caller);
    event CloseRequested(uint32 indexed index, uint64 expectedPrice, address caller);
    event ReduceRequested(uint32 indexed index, uint120 collateralDelta, uint24 leverageDelta, uint64 expectedPrice, address caller);
    event IncreaseRequested(uint32 indexed index, uint120 collateralDelta, uint24 leverageDelta, uint64 expectedPrice, address caller);
    event LeverageUpdateRequested(uint32 indexed index, uint24 newLeverage, uint256 collateralDelta, address caller);
    event SlTpUpdated(uint32 indexed index, uint64 sl, uint64 tp, address caller);
    event OrderCancelled(uint32 indexed index, address caller);
    event TimeoutCancelled(uint32 indexed orderIndex, address caller);
    event Flattened(uint16 indexed pairIndex, uint32 index, uint64 expectedPrice, address caller);
    event AgentSet(address indexed agent);
    event AgentRevoked(address indexed agent);
    event RiskChecked(uint256 leverageBps, uint256 dailyLossBps, uint256 drawdownBps, uint256 equity);
    event Breached(string reason, address caller);
    event BreachCleared();
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

/// @dev Same names and arguments as IHyperVaultErrors where the behavior is the same; HyperCore-only errors removed.
///      PriceStale, SequencerDown and NoPriceFeed are raised by GainsPrice (in the policy) and listed here so the
///      vault ABI decodes them.
interface IGainsVaultErrors {
    error Unauthorized();
    error ZeroAmount();
    error ZeroAddress();
    error DepositsClosed();
    error CapExceeded();
    error NothingToCancel();
    error RequestNotSettled();
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
    // Gains
    error OrdersPending();
    error TooManyPositions(uint256 openPositions, uint256 maxPositions);
    error ReduceAboveShortfall(uint256 shortfall, uint256 collateralDelta);
    error PolicyMismatch();
    error SlNotTighter();
    error EpochOverdue();
    error PendingOrderExists(uint32 index);
    error DiamondLayoutChanged();
    error PriceStale(uint256 pairIndex);
    error SequencerDown();
    error NoPriceFeed(uint256 pairIndex);
}
