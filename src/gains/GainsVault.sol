// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {Ownable2StepUpgradeable, OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IGainsDiamond} from "./IGainsDiamond.sol";
import {GainsVaultPolicy} from "./GainsVaultPolicy.sol";
import {GainsVaultLogic} from "./GainsVaultLogic.sol";
import {GainsVaultGovernance} from "./GainsVaultGovernance.sol";
import {GainsVaultMath} from "./GainsVaultMath.sol";
import {GainsNav} from "./GainsNav.sol";
import {
    IGainsVaultErrors,
    IGainsVaultEvents,
    InitParams,
    MAX_POSITIONS as MAX_POSITIONS_,
    OpenParams,
    VaultStorage
} from "./GainsTypes.sol";
import {
    BreachReason,
    GRACE_PERIOD as GRACE_PERIOD_,
    IVaultFactory,
    LEVERAGE_CLEAR_COOLDOWN as LEVERAGE_CLEAR_COOLDOWN_,
    MIN_DEPOSIT as MIN_DEPOSIT_,
    RESUME_COOLDOWN as RESUME_COOLDOWN_,
    INSIDER_MIN_EPOCH_AGE as INSIDER_MIN_EPOCH_AGE_
} from "../VaultTypes.sol";

/// @title GainsVault
/// @notice Non custodial USDC vault on Arbitrum that trades gTrade (Gains Network v10) perps as the trader itself.
///
/// Flow (round 4 HyperVault, with the venue swapped)
///  - Depositors use async requests (ERC-7540 style): requestDeposit / requestRedeem, then claim after the
///    epoch settles. Synchronous ERC-4626 entrypoints do not exist because NAV includes trades on the diamond.
///  - The vault contract address IS the Gains trader: collateral leaves it only into its own trades and orders on
///    the diamond, and every payout (close, SL, TP, liquidation, timeout cancel) comes back to it.
///  - Execution: the manager or the platform agent (the wallet the factory bound to this vault) calls the vault, the
///    vault runs policy.checkOrder against Chainlink and calls the diamond (decision D1). Managers never hold a key.
///  - NAV = idle USDC + GainsNav: trades valued at the adverse edge of Chainlink +- band through Gains' own close
///    path, plus resting and pending order collateral. A stale feed or a down sequencer freezes deposits, settle and
///    new risk with a named error; exits (close, reduce, cancel, timed-out cancel, flatten) never read a price.
///  - Anyone can call checkRisk(). Every loss is measured on the share price, so deposits, redemptions and fee
///    mints never move it (R-01). A risk breach derisks, it does not shut the vault: reduce only, agent kept.
///    Leverage clears by itself (clearLeverageBreach, anyone, once every limit is met), daily loss at the next UTC
///    day, drawdown when the owner calls resume(). The guardian / sentinel / owner full stop (triggerBreach) and
///    emergency revoke the agent; the cold guardian clears those (or the owner after a timelock from the breach).
///    Only the cold guardian ends an emergency.
///  - If an epoch with pending redemptions is overdue, anyone can trigger emergency mode; the unwind (close,
///    flatten, settle) is for the owner, manager, operator, sentinel and guardian only. Emergency settlements
///    only pay exits: a partial fill pro rata to the liquidity on hand, the unpaid shares returned to the
///    redeemers (who may request again). Depositors always request redemptions and claim as normal.
///  - An optional treasury operator (the platform keeper by default) may settle, reduce trades to free USDC for
///    redemptions, and unwind in a breach or emergency, nothing else. Anyone may cancel a timed-out order.
///
/// Layout: this contract holds the ERC-20 shares, ownership, the read-only surface and thin entry points. The
/// logic lives in linked libraries (GainsVaultLogic, GainsVaultGovernance, GainsNav) that run by delegatecall on the
/// single `VaultStorage` struct below. Read-only helpers for integrators live in GainsVaultLens.
/// Deployment: EIP-1167 clone of a fixed implementation, initialized once by the factory. Not upgradeable.
contract GainsVault is Initializable, ERC20Upgradeable, Ownable2StepUpgradeable, IGainsVaultEvents, IGainsVaultErrors {
    using SafeERC20 for IERC20;
    using GainsVaultMath for VaultStorage;

    VaultStorage internal $;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(InitParams calldata p) external initializer {
        __ERC20_init(p.name, p.symbol);
        __Ownable_init(p.owner);
        __Ownable2Step_init();
        GainsVaultGovernance.initialize($, p);
    }

    // ==================================================================
    // Roles. Factory vaults read the guardian (cold) and the sentinel (hot) from the factory, so the platform can
    // rotate them for every vault at once; standalone vaults have one fixed guardian that is also the sentinel.
    // ==================================================================
    function guardian() public view returns (address) {
        return $.factory != address(0) ? IVaultFactory($.factory).guardian() : $.guardian;
    }

    function sentinel() public view returns (address) {
        return $.factory != address(0) ? IVaultFactory($.factory).sentinel() : $.guardian;
    }

    modifier onlySelf() {
        if (msg.sender != address(this)) revert Unauthorized();
        _;
    }

    // ==================================================================
    // ERC-4626 style accounting (shares only; no sync deposit/mint/withdraw/redeem)
    // ==================================================================
    function asset() external view returns (address) {
        return address($.asset);
    }

    function decimals() public pure override returns (uint8) {
        return 12;
    }

    /// @notice Net asset value in USDC (6 decimals): idle USDC + GainsNav. Reverts PriceStale / SequencerDown.
    function totalAssets() public view returns (uint256) {
        return $.totalAssets();
    }

    function convertToShares(uint256 assets) external view returns (uint256) {
        return GainsVaultMath.toShares(assets, totalAssets(), totalSupply(), Math.Rounding.Floor);
    }

    function convertToAssets(uint256 shares) external view returns (uint256) {
        return GainsVaultMath.toAssets(shares, totalAssets(), totalSupply(), Math.Rounding.Floor);
    }

    /// @dev Rounding follows the ERC-4626 reference. Pending fees are not included: GainsVaultLens.preview* are.
    function previewDeposit(uint256 assets) external view returns (uint256) {
        return GainsVaultMath.toShares(assets, totalAssets(), totalSupply(), Math.Rounding.Floor);
    }

    function previewMint(uint256 shares) external view returns (uint256) {
        return GainsVaultMath.toAssets(shares, totalAssets(), totalSupply(), Math.Rounding.Ceil);
    }

    function previewWithdraw(uint256 assets) external view returns (uint256) {
        return GainsVaultMath.toShares(assets, totalAssets(), totalSupply(), Math.Rounding.Ceil);
    }

    function previewRedeem(uint256 shares) external view returns (uint256) {
        return GainsVaultMath.toAssets(shares, totalAssets(), totalSupply(), Math.Rounding.Floor);
    }

    function idleAssets() external view returns (uint256) {
        return $.idleAssets();
    }

    /// @notice What is on the diamond: trades and orders value (6 decimals), open notional for vault leverage, and
    ///         the count of open trades + resting orders + pending orders, and of pending orders alone.
    function venue() external view returns (GainsNav.Snapshot memory) {
        return $.venue(true);
    }

    /// @notice An order that holds collateral is pending on the diamond (timed out or not): settle waits. Closes,
    ///         partial closes and leverage increases do not hold settle (GR1-04). No price read.
    function ordersPending() external view returns (bool) {
        return $.ordersPending();
    }

    /// @notice Assets per one whole share (10 ** decimals()).
    function sharePrice() external view returns (uint256) {
        return $.sharePrice();
    }

    /// @notice Expected fill of the pending redemptions if an exit-only settle ran now (10_000 = in full).
    function emergencyFillBps() external view returns (uint256) {
        return $.emergencyFillBps();
    }

    /// @notice USDC the redemptions (pending at the checkpoint NAV + claimable) need beyond the vault's USDC and the
    ///         closes in flight: the most the operator may reduce outside a breach. No price read.
    function redemptionShortfall() external view returns (uint256) {
        return $.redemptionShortfall();
    }

    // ==================================================================
    // Depositor flow
    // ==================================================================
    function requestDeposit(uint256 assets, address controller) external returns (uint256) {
        return GainsVaultGovernance.requestDeposit($, assets, controller);
    }

    function requestRedeem(uint256 shares, address controller, address owner_) external returns (uint256) {
        return GainsVaultGovernance.requestRedeem($, shares, controller, owner_);
    }

    function cancelDepositRequest() external {
        GainsVaultGovernance.cancelDepositRequest($);
    }

    function cancelRedeemRequest() external {
        GainsVaultGovernance.cancelRedeemRequest($);
    }

    function claim(address controller) external {
        GainsVaultGovernance.claim($, controller);
    }

    // ==================================================================
    // Settlement, fees, hosting
    // ==================================================================
    /// @dev A vault that has never been checkpointed runs the risk check itself first, so the first settle does
    ///      not depend on a keeper (audit I2-04).
    function settle() external {
        GainsNav.sync($.diamond, type(uint256).max); // GR2-LIVE-01
        if ($.checkpointAt == 0) GainsVaultGovernance.checkRisk($);
        GainsVaultLogic.settle($, guardian(), sentinel());
    }

    function accrueFees() external {
        GainsVaultLogic.accrueFees($);
    }

    function leaveHosted() external {
        GainsVaultLogic.leaveHosted($);
    }

    function lowerProtocolShare(uint16 newBps) external {
        GainsVaultLogic.lowerProtocolShare($, newBps);
    }

    // ==================================================================
    // Trading (PLAN.md 4.2)
    // ==================================================================
    /// @notice Manager or agent: market trade (request) or limit / stop order, policy checked.
    function openTrade(OpenParams calldata p) external {
        GainsNav.sync($.diamond, type(uint256).max); // GR2-LIVE-01
        GainsVaultLogic.openTrade($, p);
    }

    /// @notice Anyone: brings the vault's Gains index set up to date, at most `maxSteps` unseen indexes per call
    ///         (GR2-LIVE-01). Every state-changing path that reads NAV also does it, and every close, reduce and
    ///         flatten pulls up to MAX_POSITIONS (each creates at most that many pending-order indexes, GR2 XF-03).
    ///         sync never reverts on an unreadable diamond, so it never blocks an exit (GR1-08).
    function syncIndexes(uint256 maxSteps) external returns (uint256 steps) {
        return GainsNav.sync($.diamond, maxSteps);
    }

    /// @notice The vault's open trades and pending orders, read through its index set (GR2-LIVE-01); for the lens.
    function openItems() external view returns (IGainsDiamond.Trade[] memory trades, IGainsDiamond.PendingOrder[] memory orders) {
        trades = GainsNav.readTrades($.diamond, address(this));
        orders = GainsNav.readPendingOrders($.diamond, address(this));
    }

    /// @notice The vault's tracked Gains indexes and cursors (GR2-LIVE-01).
    function indexSet() external view returns (uint32 tradeCursor, uint32 orderCursor, uint32[] memory trades, uint32[] memory orders) {
        return GainsNav.indexSet();
    }

    /// @notice Manager or agent: adds collateral and / or size (request), policy checked.
    function increaseTrade(uint32 index, uint120 collateralDelta, uint24 leverageDelta, uint64 expectedPrice, uint16 maxSlippageP)
        external
    {
        GainsNav.sync($.diamond, type(uint256).max); // GR2-LIVE-01
        GainsVaultLogic.increaseTrade($, index, collateralDelta, leverageDelta, expectedPrice, maxSlippageP);
    }

    /// @notice Manager or agent: leverage at constant size (request). Lowering pulls collateral; raising is checked.
    function updateLeverage(uint32 index, uint24 newLeverage) external {
        GainsNav.sync($.diamond, type(uint256).max); // GR2-LIVE-01
        GainsVaultLogic.updateLeverage($, index, newLeverage);
    }

    /// @notice Market close (request). Manager, agent, guardian; owner, operator, sentinel while breached. No price read.
    function closeTrade(uint32 index, uint64 expectedPrice) external {
        GainsNav.sync($.diamond, MAX_POSITIONS_); // GR2 XF-03: bounded, so exits never let unseen indexes pile up
        GainsVaultLogic.closeTrade($, index, expectedPrice, guardian(), sentinel());
    }

    /// @notice Partial close (request). As closeTrade; outside a breach also the operator, a collateral reduce of at
    ///         most redemptionShortfall() plus a fee allowance (2% + 1 USDC, GainsTypes). No price read.
    function reduceTrade(uint32 index, uint120 collateralDelta, uint24 leverageDelta, uint64 expectedPrice) external {
        GainsNav.sync($.diamond, MAX_POSITIONS_); // GR2 XF-03: bounded, so exits never let unseen indexes pile up
        GainsVaultLogic.reduceTrade($, index, collateralDelta, leverageDelta, expectedPrice, guardian(), sentinel());
    }

    /// @notice Manager or agent; the sentinel while breached (SL only tightens while breached).
    function setSlTp(uint32 index, uint64 sl, uint64 tp) external {
        GainsVaultLogic.setSlTp($, index, sl, tp, sentinel());
    }

    /// @notice Manager, agent or sentinel: cancels a resting limit / stop order. No price read.
    function cancelOrder(uint32 index) external {
        GainsVaultLogic.cancelOrder($, index, sentinel());
    }

    /// @notice Anyone: cancels a market order Gains did not fill within its timeout. No price read.
    function cancelTimedOut(uint32 orderIndex) external {
        GainsVaultLogic.cancelTimedOut($, orderIndex);
    }

    /// @notice Closes the trades of a pair and cancels its resting orders, at most `maxTrades` per call (round 4
    ///         flatten roles). No price read. `remaining` > 0: call again for the next batch.
    function flatten(uint16 pairIndex, uint256 slippageBps, uint64 expectedPrice, uint256 maxTrades)
        external
        returns (uint256 sent, uint256 remaining)
    {
        GainsNav.sync($.diamond, MAX_POSITIONS_); // GR2 XF-03: bounded, so exits never let unseen indexes pile up
        return GainsVaultLogic.flatten($, pairIndex, slippageBps, expectedPrice, maxTrades, guardian(), sentinel());
    }

    /// @notice flatten by trade index, decoding nothing (for a Gains trade list the vault cannot read, GR1-08). Same
    ///         callers and slippage rules as flatten. No price read.
    function flattenIndices(uint32[] calldata indices, uint256 slippageBps, uint64 expectedPrice) external returns (uint256 sent) {
        GainsNav.sync($.diamond, MAX_POSITIONS_); // GR2 XF-03: bounded, so exits never let unseen indexes pile up
        return GainsVaultLogic.flattenIndices($, indices, slippageBps, expectedPrice, guardian(), sentinel());
    }

    // ==================================================================
    // Agent
    // ==================================================================
    /// @notice Timelocked (queue + execute). Only the platform agent bound to this vault on the factory.
    function setAgent(address newAgent) external onlySelf {
        if ($.hardStop()) revert ReduceOnlyMode();
        GainsVaultLogic.setAgent($, newAgent);
    }

    /// @notice Instant: owner, guardian, sentinel or the factory (when the agent is unregistered).
    function revokeAgent() external {
        if (msg.sender != owner() && msg.sender != guardian() && msg.sender != sentinel() && msg.sender != $.factory) {
            revert Unauthorized();
        }
        GainsVaultLogic.revokeAgent($);
    }

    // ==================================================================
    // Risk, breach, emergency
    // ==================================================================
    function checkRisk() external returns (uint256 leverageBps, uint256 dailyLossBps, uint256 drawdownBps) {
        GainsNav.sync($.diamond, type(uint256).max); // GR2-LIVE-01
        return GainsVaultGovernance.checkRisk($);
    }

    function triggerBreach() external {
        GainsVaultGovernance.triggerBreach($, guardian(), sentinel());
    }

    function triggerEmergency() external {
        GainsVaultGovernance.triggerEmergency($, guardian());
    }

    function clearBreach() external {
        GainsVaultGovernance.clearBreach($, guardian());
    }

    /// @notice Anyone: lifts a leverage breach once every limit is met again (after LEVERAGE_CLEAR_COOLDOWN).
    function clearLeverageBreach() external {
        GainsVaultGovernance.clearLeverageBreach($);
    }

    /// @notice Owner: ends a drawdown breach and restarts the peak from the current share price.
    function resume() external {
        GainsVaultGovernance.resume($);
    }

    // ==================================================================
    // Treasury operator
    // ==================================================================
    /// @notice Owner: grants the operator (settle, reduce, unwind only); zero removes it.
    function setOperator(address operator_) external {
        GainsVaultGovernance.setOperator($, operator_);
    }

    /// @notice Owner, guardian or sentinel: removes the operator.
    function revokeOperator() external {
        GainsVaultGovernance.revokeOperator($, guardian(), sentinel());
    }

    /// @notice Guardian only: ends the emergency once every redeemer has been paid in full (audit W-01b).
    function exitEmergency() external {
        GainsVaultGovernance.exitEmergency($, guardian());
    }

    // ==================================================================
    // Switches and owner actions
    // ==================================================================
    function setDepositsPaused(bool paused) external {
        GainsVaultGovernance.setDepositsPaused($, paused, guardian(), sentinel());
    }

    function setTradingPaused(bool paused) external {
        GainsVaultGovernance.setTradingPaused($, paused, guardian(), sentinel());
    }

    function setDepositCap(uint256 cap) external {
        GainsVaultGovernance.setDepositCap($, cap);
    }

    function lowerFees(uint16 mgmtBps, uint16 perfBps) external {
        GainsVaultGovernance.lowerFees($, mgmtBps, perfBps);
    }

    /// @notice Recovers tokens sent here by mistake. Cannot touch the vault asset or its own shares.
    function rescueToken(IERC20 token, address to) external onlyOwner {
        if (address(token) == address($.asset) || address(token) == address(this)) revert UnsupportedAsset();
        token.safeTransfer(to, token.balanceOf(address(this)));
    }

    /// @dev A vault without an owner could never clear a breach or leave hosted (audit I-03).
    function renounceOwnership() public pure override {
        revert Unauthorized();
    }

    // ==================================================================
    // Timelock
    // ==================================================================
    function queue(bytes calldata data) external returns (bytes32) {
        return GainsVaultGovernance.queue($, data);
    }

    function execute(bytes calldata data) external {
        GainsVaultGovernance.execute($, data);
    }

    function cancel(bytes32 id) external {
        GainsVaultGovernance.cancel($, id, guardian());
    }

    function setManager(address newManager) external onlySelf {
        GainsVaultGovernance.setManager($, newManager);
    }

    function setFees(uint16 mgmtBps, uint16 perfBps) external onlySelf {
        GainsVaultGovernance.setFees($, mgmtBps, perfBps);
    }

    function setFeeRecipient(address recipient) external onlySelf {
        GainsVaultGovernance.setFeeRecipient($, recipient);
    }

    function setTimelockDelay(uint256 delay) external onlySelf {
        GainsVaultGovernance.setTimelockDelay($, delay);
    }

    /// @notice Timelocked (queue + execute). Feed rotation: the pair's Chainlink feed, staleness limit and NAV band,
    ///         exactly as the factory curates them at execution; the vault-leverage bound is checked again (policy).
    function setPairFeed(uint16 pairIndex, address feed, uint32 maxAge, uint16 bandBps) external onlySelf {
        $.policy.setPairFeed(pairIndex, feed, maxAge, bandBps);
    }

    /// @notice Timelocked (queue + execute). Sequencer uptime feed rotation (GR1-10): the feed and grace period are
    ///         the factory's at queue time (checked when queued, GV-03) and are adopted as queued.
    function setSequencerFeed(address feed, uint256 gracePeriod) external onlySelf {
        $.policy.setSequencerFeed(feed, gracePeriod);
    }

    // ==================================================================
    // Storage getters
    // ==================================================================
    function policy() external view returns (GainsVaultPolicy) {
        return $.policy;
    }

    function diamond() external view returns (IGainsDiamond) {
        return $.diamond;
    }

    function collateralIndex() external view returns (uint8) {
        return $.collateralIndex;
    }

    function factory() external view returns (address) {
        return $.factory;
    }

    function protocolShareBps() external view returns (uint16) {
        return $.protocolShareBps;
    }

    function baseShareBps() external view returns (uint16) {
        return $.baseShareBps;
    }

    function hosted() external view returns (bool) {
        return $.hosted;
    }

    function manager() external view returns (address) {
        return $.manager;
    }

    function feeRecipient() external view returns (address) {
        return $.feeRecipient;
    }

    function agent() external view returns (address) {
        return $.agent;
    }

    function managementFeeBps() external view returns (uint16) {
        return $.managementFeeBps;
    }

    function performanceFeeBps() external view returns (uint16) {
        return $.performanceFeeBps;
    }

    /// @notice Performance fee rate that takes over at the next settle (0 = none scheduled).
    function pendingPerformanceFeeBps() external view returns (uint16) {
        return $.pendingPerformanceFeeBps;
    }

    function timelockDelay() external view returns (uint256) {
        return $.timelockDelay;
    }

    function depositCap() external view returns (uint256) {
        return $.depositCap;
    }

    function queuedEta(bytes32 id) external view returns (uint256) {
        return $.queuedEta[id];
    }

    function queuedAt(bytes32 id) external view returns (uint256) {
        return $.queuedAt[id];
    }

    function depositsPaused() external view returns (bool) {
        return $.depositsPaused;
    }

    function tradingPaused() external view returns (bool) {
        return $.tradingPaused;
    }

    function breached() external view returns (bool) {
        return $.breached;
    }

    function emergency() external view returns (bool) {
        return $.emergency;
    }

    function breachedAt() external view returns (uint64) {
        return $.breachedAt;
    }

    /// @notice Why the vault is in reduce only mode (BreachReason: 0 none, 1 leverage, 2 daily loss, 3 drawdown,
    ///         4 guardian, 5 emergency).
    function breachReason() external view returns (BreachReason) {
        return $.breachReason;
    }

    function operator() external view returns (address) {
        return $.operator;
    }

    /// @notice Insider deposits waiting for the next epoch's settlement.
    function deferredDepositAssets() external view returns (uint256) {
        return $.deferredDepositAssets;
    }

    /// @notice When the current emergency started (audit W-01b).
    function emergencyAt() external view returns (uint64) {
        return $.emergencyAt;
    }

    function currentEpoch() external view returns (uint256) {
        return $.currentEpoch;
    }

    function epochStartedAt() external view returns (uint64) {
        return $.epochStartedAt;
    }

    /// @notice This epoch's deadline, fixed when it started (GR2-CFG-02).
    function epochDeadline() external view returns (uint64) {
        return $.epochDeadline;
    }

    function lastFeeAccrual() external view returns (uint64) {
        return $.lastFeeAccrual;
    }

    function pendingDepositAssets() external view returns (uint256) {
        return $.pendingDepositAssets;
    }

    function pendingRedeemShares() external view returns (uint256) {
        return $.pendingRedeemShares;
    }

    function claimableRedeemAssets() external view returns (uint256) {
        return $.claimableRedeemAssets;
    }

    function epochs(uint256 epoch)
        external
        view
        returns (
            uint256 depositAssets,
            uint256 depositShares,
            uint256 redeemShares,
            uint256 redeemAssets,
            uint256 redeemBurned,
            uint256 nav,
            uint256 sharePrice_,
            uint64 settledAt
        )
    {
        return (
            $.epochs[epoch].depositAssets,
            $.epochs[epoch].depositShares,
            $.epochs[epoch].redeemShares,
            $.epochs[epoch].redeemAssets,
            $.epochs[epoch].redeemBurned,
            $.epochs[epoch].nav,
            $.epochs[epoch].sharePrice,
            $.epochs[epoch].settledAt
        );
    }

    /// @notice Carry run of a redemption-only epoch: carriedFrom = origin + 1 (0 = not carried) and pricedIn = the
    ///         epoch that priced that run + 1 (0 = not yet).
    function carry(uint256 epoch) external view returns (uint256 carriedFrom, uint256 pricedIn) {
        carriedFrom = $.epochs[epoch].carriedFrom;
        if (carriedFrom != 0) pricedIn = $.carryPricedIn[carriedFrom - 1];
    }

    /// @notice When the owner last resumed trading after a drawdown breach (0 = never).
    function lastResumeAt() external view returns (uint64) {
        return $.lastResumeAt;
    }

    function RESUME_COOLDOWN() external pure returns (uint256) {
        return RESUME_COOLDOWN_;
    }

    function INSIDER_MIN_EPOCH_AGE() external pure returns (uint256) {
        return INSIDER_MIN_EPOCH_AGE_;
    }

    function requests(address controller) external view returns (uint256 epoch, uint256 depositAssets, uint256 redeemShares) {
        return ($.requests[controller].epoch, $.requests[controller].depositAssets, $.requests[controller].redeemShares);
    }

    function highWaterMark() external view returns (uint256) {
        return $.highWaterMark;
    }

    function peakSharePrice() external view returns (uint256) {
        return $.peakSharePrice;
    }

    function riskDay() external view returns (uint256) {
        return $.riskDay;
    }

    /// @notice Share price at the first risk check of the UTC day: the daily loss reference.
    function dayStartSharePrice() external view returns (uint256) {
        return $.dayStartSharePrice;
    }

    function checkpointNav() external view returns (uint192) {
        return $.checkpointNav;
    }

    function checkpointAt() external view returns (uint64) {
        return $.checkpointAt;
    }

    /// @notice The checkpoint value the last ratchet replaced (GR2-KEY-06).
    function priorCheckpointNav() external view returns (uint192) {
        return $.priorCheckpointNav;
    }

    /// @notice The NAV a redemption-only or exit-only settle would pay redemptions at now (GR2-KEY-06).
    function redemptionNav() external view returns (uint256) {
        return $.redemptionCap($.totalAssets());
    }

    // ------------------------------------------------------------------
    // Constants
    // ------------------------------------------------------------------
    function GRACE_PERIOD() external pure returns (uint256) {
        return GRACE_PERIOD_;
    }

    function MIN_DEPOSIT() external pure returns (uint256) {
        return MIN_DEPOSIT_;
    }

    function LEVERAGE_CLEAR_COOLDOWN() external pure returns (uint256) {
        return LEVERAGE_CLEAR_COOLDOWN_;
    }

    function MAX_POSITIONS() external pure returns (uint256) {
        return MAX_POSITIONS_;
    }
}
