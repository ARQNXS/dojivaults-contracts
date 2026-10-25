// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {Ownable2StepUpgradeable, OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {ICoreDepositWallet} from "./hypercore/HyperCore.sol";
import {VaultPolicy} from "./VaultPolicy.sol";
import {VaultLogic} from "./VaultLogic.sol";
import {VaultGovernance} from "./VaultGovernance.sol";
import {VaultMath} from "./VaultMath.sol";
import {
    BRIDGE_SETTLE_BLOCKS as BRIDGE_SETTLE_BLOCKS_,
    BreachReason,
    GRACE_PERIOD as GRACE_PERIOD_,
    IHyperVaultErrors,
    IHyperVaultEvents,
    IVaultFactory,
    InitParams,
    LEVERAGE_CLEAR_COOLDOWN as LEVERAGE_CLEAR_COOLDOWN_,
    MAX_BRIDGE_WAIT_BLOCKS as MAX_BRIDGE_WAIT_BLOCKS_,
    MAX_UNLANDED_BLOCKS as MAX_UNLANDED_BLOCKS_,
    MIN_DEPOSIT as MIN_DEPOSIT_,
    RESUME_COOLDOWN as RESUME_COOLDOWN_,
    INSIDER_MIN_EPOCH_AGE as INSIDER_MIN_EPOCH_AGE_,
    MIN_BRIDGE as MIN_BRIDGE_,
    VaultStorage
} from "./VaultTypes.sol";

/// @title HyperVault
/// @notice Non custodial USDC vault on HyperEVM that trades Hyperliquid perps from its own HyperCore account.
///
/// Flow
///  - Depositors use async requests (ERC-7540 style): requestDeposit / requestRedeem, then claim after the
///    epoch settles. Synchronous ERC-4626 entrypoints do not exist because NAV lives partly on HyperCore.
///  - The vault contract address IS the HyperCore trading account. Funds never leave the contract's control.
///  - Execution: onchain orders via CoreWriter only, every order checked against VaultPolicy. The manager or the
///    platform agent (the EVM wallet the factory bound to this vault, driven by the DojiPad executor) calls
///    placeOrder; the agent is never approved as a HyperCore API wallet (HL-PROXY), so it cannot move funds,
///    trade spot or other dexes, or change the account mode. The account is pinned to the Standard mode.
///  - Anyone can call checkRisk(). Every loss is measured on the share price, so deposits, redemptions and fee
///    mints never move it (R-01). A risk breach derisks, it does not shut the vault: reduce only, agent kept.
///    Leverage clears by itself (clearLeverageBreach, anyone, once every limit is met), daily loss at the next UTC
///    day, drawdown when the owner calls resume(). The guardian / sentinel / owner full stop (triggerBreach) and
///    emergency revoke the agent; the cold guardian clears those (or the owner after a timelock from the breach).
///    Only the cold guardian ends an emergency.
///  - If an epoch with pending redemptions is overdue, anyone can trigger emergency mode; the unwind (flatten,
///    bridge back, settle) is for the owner, manager, operator, sentinel and guardian only. Emergency settlements
///    only pay exits: a partial fill pro rata to the liquidity on hand, the unpaid shares returned to the
///    redeemers (who may request again). Depositors always request redemptions and claim as normal.
///  - An optional treasury operator (the platform keeper by default) may settle, bridge and move USDC between spot
///    and perp, nothing else.
///
/// Layout: this contract holds the ERC-20 shares, ownership, the read-only surface and thin entry points. The
/// logic lives in two linked libraries (VaultLogic, VaultGovernance) that run by delegatecall on the single
/// `VaultStorage` struct below. Read-only helpers for integrators live in HyperVaultLens.
/// Deployment: EIP-1167 clone of a fixed implementation, initialized once by the factory. Not upgradeable.
contract HyperVault is Initializable, ERC20Upgradeable, Ownable2StepUpgradeable, IHyperVaultEvents, IHyperVaultErrors {
    using SafeERC20 for IERC20;
    using VaultMath for VaultStorage;

    VaultStorage internal $;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(InitParams calldata p) external payable initializer {
        __ERC20_init(p.name, p.symbol);
        __Ownable_init(p.owner);
        __Ownable2Step_init();
        VaultGovernance.initialize($, p, msg.value);
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

    /// @notice Net asset value in USDC (6 decimals). Inside a bridge window it is the pre-bridge snapshot.
    function totalAssets() public view returns (uint256) {
        return $.totalAssets();
    }

    function convertToShares(uint256 assets) external view returns (uint256) {
        return VaultMath.toShares(assets, totalAssets(), totalSupply(), Math.Rounding.Floor);
    }

    function convertToAssets(uint256 shares) external view returns (uint256) {
        return VaultMath.toAssets(shares, totalAssets(), totalSupply(), Math.Rounding.Floor);
    }

    /// @dev Rounding follows the ERC-4626 reference. Pending fees are not included: HyperVaultLens.preview* are.
    function previewDeposit(uint256 assets) external view returns (uint256) {
        return VaultMath.toShares(assets, totalAssets(), totalSupply(), Math.Rounding.Floor);
    }

    function previewMint(uint256 shares) external view returns (uint256) {
        return VaultMath.toAssets(shares, totalAssets(), totalSupply(), Math.Rounding.Ceil);
    }

    function previewWithdraw(uint256 assets) external view returns (uint256) {
        return VaultMath.toShares(assets, totalAssets(), totalSupply(), Math.Rounding.Ceil);
    }

    function previewRedeem(uint256 shares) external view returns (uint256) {
        return VaultMath.toAssets(shares, totalAssets(), totalSupply(), Math.Rounding.Floor);
    }

    function idleAssets() external view returns (uint256) {
        return $.idleAssets();
    }

    function coreEquity() external view returns (uint256) {
        return VaultMath.coreEquity();
    }

    /// @notice In flight or late (unlanded, at most MAX_UNLANDED_BLOCKS): settle and treasury actions wait.
    function bridgePending() external view returns (bool) {
        return $.bridgePending();
    }

    /// @notice A transfer is late past MAX_UNLANDED_BLOCKS and the NAV reads short by it: settles and bridges wait
    ///         (at most UNRESOLVED_WAIT_BLOCKS) until it lands or the guardian writes it off.
    function bridgeUnresolved() external view returns (bool) {
        return $.bridgeUnresolved();
    }

    function bridgeInFlight() external view returns (bool) {
        return $.bridgeInFlight();
    }

    /// @notice Assets per one whole share (10 ** decimals()).
    function sharePrice() external view returns (uint256) {
        return $.sharePrice();
    }

    /// @notice Expected fill of the pending redemptions if an exit-only settle ran now (10_000 = in full).
    function emergencyFillBps() external view returns (uint256) {
        return $.emergencyFillBps();
    }

    // ==================================================================
    // Depositor flow
    // ==================================================================
    function requestDeposit(uint256 assets, address controller) external returns (uint256) {
        return VaultLogic.requestDeposit($, assets, controller);
    }

    function requestRedeem(uint256 shares, address controller, address owner_) external returns (uint256) {
        return VaultLogic.requestRedeem($, shares, controller, owner_);
    }

    function cancelDepositRequest() external {
        VaultLogic.cancelDepositRequest($);
    }

    function cancelRedeemRequest() external {
        VaultLogic.cancelRedeemRequest($);
    }

    function claim(address controller) external {
        VaultLogic.claim($, controller);
    }

    // ==================================================================
    // Settlement, fees, hosting
    // ==================================================================
    /// @dev A vault that has never been checkpointed runs the risk check itself first, so the first settle does
    ///      not depend on a keeper (audit I2-04).
    function settle() external {
        if ($.checkpointAt == 0) VaultGovernance.checkRisk($);
        VaultLogic.settle($, guardian(), sentinel());
    }

    function accrueFees() external {
        VaultLogic.accrueFees($);
    }

    function leaveHosted() external {
        VaultLogic.leaveHosted($);
    }

    function lowerProtocolShare(uint16 newBps) external {
        VaultLogic.lowerProtocolShare($, newBps);
    }

    // ==================================================================
    // Bridging
    // ==================================================================
    function bridgeToCore(uint256 amount) external {
        VaultLogic.bridgeToCore($, amount);
    }

    function bridgeToEvm(uint256 amount) external {
        VaultLogic.bridgeToEvm($, amount, guardian(), sentinel());
    }

    /// @notice Anyone (the keeper): records that the latest bridge has landed, so the window can never reopen (R-02).
    function syncBridge() external {
        VaultLogic.syncBridge($);
    }

    function fundCoreGas() external payable {
        VaultLogic.fundCoreGas($, msg.value);
    }

    function moveUsd(uint256 amount, bool toPerp) external {
        VaultLogic.moveUsd($, amount, toPerp);
    }

    // ==================================================================
    // Trading
    // ==================================================================
    /// @notice Manager or platform agent. An order that adds risk runs the risk check first (HL-PROXY, the HL twin of
    ///         Gains GR2-KEY-01): when that check puts the vault in reduce only the order is not sent (OrderRefused)
    ///         and the breach stays recorded. In a breach that already exists such an order reverts, as before.
    /// @dev `limitPx` and `sz` are both in 1e8 scale, the units the HyperCore limit order action takes, and are
    ///      forwarded unchanged. `flatten` is the only path that starts from a raw precompile value, so it is the
    ///      only one that converts (`PxMath.size1e8`, `PxMath.boundedLimitPx1e8`).
    function placeOrder(uint32 asset_, bool isBuy, uint64 limitPx, uint64 sz, bool reduceOnly, uint8 tif, uint128 cloid) external {
        bool trader = msg.sender == $.manager || (msg.sender == $.agent && $.agent != address(0));
        if (!reduceOnly && trader && !$.breached && !$.emergency) {
            VaultGovernance.checkRisk($);
            if ($.breached || $.emergency) {
                emit OrderRefused(asset_, cloid, msg.sender);
                return;
            }
        }
        VaultLogic.placeOrder($, asset_, isBuy, limitPx, sz, reduceOnly, tif, cloid);
    }

    function cancelOrder(uint32 asset_, uint64 oid) external {
        VaultLogic.cancelOrder($, asset_, oid, sentinel());
    }

    function flatten(uint32 asset_, uint256 slippageBps) external {
        VaultLogic.flatten($, asset_, slippageBps, guardian(), sentinel());
    }

    // ==================================================================
    // Agent
    // ==================================================================
    /// @notice Timelocked (queue + execute). Only the platform agent bound to this vault on the factory.
    function setAgent(address newAgent) external onlySelf {
        if ($.hardStop()) revert ReduceOnlyMode();
        VaultLogic.setAgent($, newAgent);
    }

    /// @notice HL-PROXY: re-pins the HyperCore account to the Standard mode (CoreWriter action 16, abstraction 1).
    ///         Vault roles at any time, anyone else once per MODE_PIN_INTERVAL. Replaces syncAgent(): there is no
    ///         HyperCore approval to send for the agent any more.
    function pinAccountMode() external {
        VaultLogic.pinAccountMode($, guardian(), sentinel());
    }

    /// @notice WP1: the agent's opened notional in the rolling 24 hours and its orders that add risk in the sliding hour,
    ///         against VaultPolicy.agentLimits().
    function agentFlow() external view returns (uint256 used, uint256 orders) {
        return VaultLogic.agentFlow($);
    }

    /// @notice Kept for ABI compatibility (executor, integrators): same as pinAccountMode(). It approves nothing on
    ///         HyperCore any more (HL-PROXY).
    function syncAgent() external {
        VaultLogic.pinAccountMode($, guardian(), sentinel());
    }

    /// @notice When the account mode was last pinned (0 = never).
    function modePinnedAt() external view returns (uint64) {
        return $.modePinnedAt;
    }

    /// @notice HL-PROXY marker for the executor: 1 = orders go through placeOrder (no HyperCore API wallet).
    function orderPath() external pure returns (uint256) {
        return 1;
    }

    /// @notice true while the precompiles show a balance layout the Standard account mode cannot produce.
    function accountModeSuspect() external view returns (bool) {
        return VaultMath.modeSuspect();
    }

    /// @notice Instant: owner, guardian, sentinel or the factory (when the agent is unregistered). A platform revoke
    ///         of a live agent (guardian, sentinel, factory) also holds deposits until the guardian clears
    ///         (HLR2-XA01): the revoked agent may have deflated the NAV, so no settle prices a deposit meanwhile.
    function revokeAgent() external {
        if (msg.sender != owner() && msg.sender != guardian() && msg.sender != sentinel() && msg.sender != $.factory) {
            revert Unauthorized();
        }
        if (msg.sender != owner() && $.agent != address(0) && !$.depositHold) {
            $.depositHold = true;
            emit DepositHold(true);
        }
        VaultLogic.revokeAgent($);
    }

    function depositHold() external view returns (bool) {
        return $.depositHold;
    }

    // ==================================================================
    // Risk, breach, emergency
    // ==================================================================
    function checkRisk() external returns (uint256 leverageBps, uint256 dailyLossBps, uint256 drawdownBps) {
        return VaultGovernance.checkRisk($);
    }

    function triggerBreach() external {
        VaultGovernance.triggerBreach($, guardian(), sentinel());
    }

    function triggerEmergency() external {
        VaultGovernance.triggerEmergency($, guardian());
    }

    function clearBreach() external {
        VaultGovernance.clearBreach($, guardian());
    }

    /// @notice Guardian: writes off the late transfer that holds settles (HLR2-A02 / A08).
    function writeOffBridge() external {
        VaultGovernance.writeOffBridge($, guardian());
    }

    /// @notice Anyone: lifts a leverage breach once every limit is met again (after LEVERAGE_CLEAR_COOLDOWN).
    function clearLeverageBreach() external {
        VaultGovernance.clearLeverageBreach($);
    }

    /// @notice Owner: ends a drawdown breach and restarts the peak from the current share price.
    function resume() external {
        VaultGovernance.resume($);
    }

    // ==================================================================
    // Treasury operator
    // ==================================================================
    /// @notice Owner: grants the operator (settle, bridges, moveUsd only); zero removes it.
    function setOperator(address operator_) external {
        VaultGovernance.setOperator($, operator_);
    }

    /// @notice Owner, guardian or sentinel: removes the operator.
    function revokeOperator() external {
        VaultGovernance.revokeOperator($, guardian(), sentinel());
    }

    /// @notice Guardian only: ends the emergency once every redeemer has been paid in full (audit W-01b).
    function exitEmergency() external {
        VaultGovernance.exitEmergency($, guardian());
    }

    // ==================================================================
    // Switches and owner actions
    // ==================================================================
    function setDepositsPaused(bool paused) external {
        VaultGovernance.setDepositsPaused($, paused, guardian(), sentinel());
    }

    function setTradingPaused(bool paused) external {
        VaultGovernance.setTradingPaused($, paused, guardian(), sentinel());
    }

    function setDepositCap(uint256 cap) external {
        VaultGovernance.setDepositCap($, cap);
    }

    function lowerFees(uint16 mgmtBps, uint16 perfBps) external {
        VaultGovernance.lowerFees($, mgmtBps, perfBps);
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
        return VaultGovernance.queue($, data);
    }

    function execute(bytes calldata data) external {
        VaultGovernance.execute($, data);
    }

    function cancel(bytes32 id) external {
        VaultGovernance.cancel($, id, guardian());
    }

    function setManager(address newManager) external onlySelf {
        VaultGovernance.setManager($, newManager);
    }

    function setFees(uint16 mgmtBps, uint16 perfBps) external onlySelf {
        VaultGovernance.setFees($, mgmtBps, perfBps);
    }

    function setFeeRecipient(address recipient) external onlySelf {
        VaultGovernance.setFeeRecipient($, recipient);
    }

    function setTimelockDelay(uint256 delay) external onlySelf {
        VaultGovernance.setTimelockDelay($, delay);
    }

    // ==================================================================
    // Storage getters
    // ==================================================================
    function policy() external view returns (VaultPolicy) {
        return $.policy;
    }

    function coreDepositWallet() external view returns (ICoreDepositWallet) {
        return $.coreDepositWallet;
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

    /// @notice True while a full stop imposed by the guardian or the sentinel freezes every settle (HLR2-E06). A full
    ///         stop imposed by the vault owner alone leaves this false and settles redemption-only.
    function platformHold() external view returns (bool) {
        return $.platformHold;
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

    /// @notice This epoch's forced-exit deadline, fixed when it started (hl-r2 H01 / XB01).
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

    function equityAtBridge() external view returns (uint256) {
        return $.equityAtBridge;
    }

    function bridgeAmount() external view returns (uint256) {
        return $.bridgeAmount;
    }

    function lastBridgeBlock() external view returns (uint256) {
        return $.lastBridgeBlock;
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

    /// @notice HLO-07: before this time a factory vault launched with an agent takes no deposit and the agent's
    ///         orders revert AgentWarmingUp (the platform's veto window). Zero for a vault launched without an agent.
    function agentActiveAt() external view returns (uint64) {
        return $.agentActiveAt;
    }

    /// @notice True while the checkpoint trails the NAV after a capped checkRisk step (HLR2-E01): an exit-only
    ///         settle waits for the next step instead of paying at it.
    function checkpointLagging() external view returns (bool) {
        return $.checkpointLagging;
    }

    // ------------------------------------------------------------------
    // Constants
    // ------------------------------------------------------------------
    function GRACE_PERIOD() external pure returns (uint256) {
        return GRACE_PERIOD_;
    }

    function BRIDGE_SETTLE_BLOCKS() external pure returns (uint256) {
        return BRIDGE_SETTLE_BLOCKS_;
    }

    function MIN_BRIDGE() external pure returns (uint256) {
        return MIN_BRIDGE_;
    }

    function MAX_BRIDGE_WAIT_BLOCKS() external pure returns (uint256) {
        return MAX_BRIDGE_WAIT_BLOCKS_;
    }

    function MAX_UNLANDED_BLOCKS() external pure returns (uint256) {
        return MAX_UNLANDED_BLOCKS_;
    }

    function MIN_DEPOSIT() external pure returns (uint256) {
        return MIN_DEPOSIT_;
    }

    function LEVERAGE_CLEAR_COOLDOWN() external pure returns (uint256) {
        return LEVERAGE_CLEAR_COOLDOWN_;
    }
}
