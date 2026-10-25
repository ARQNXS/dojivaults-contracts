// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {HyperCore} from "./hypercore/HyperCore.sol";
import {VaultLogic} from "./VaultLogic.sol";
import {VaultMath} from "./VaultMath.sol";
import {
    AGENT_WARMUP,
    BPS,
    BreachReason,
    EpochResult,
    GRACE_PERIOD,
    IHyperVaultErrors as E,
    IHyperVaultEvents as Ev,
    IVaultFactory,
    InitParams,
    LEVERAGE_CLEAR_COOLDOWN,
    MAX_MANAGEMENT_FEE_BPS,
    RESUME_COOLDOWN,
    MIN_RISK_NAV,
    MAX_PERFORMANCE_FEE_BPS,
    MAX_PROTOCOL_SHARE_BPS,
    EXIT_MARGIN,
    MAX_TIMELOCK,
    MIN_TIMELOCK,
    VaultStorage
} from "./VaultTypes.sol";

/// @title VaultGovernance
/// @notice Initialization, risk checks, breach and emergency state, safety switches and the owner timelock of
///         HyperVault. Linked as an external library: every function runs by delegatecall on the vault's storage.
///
/// Roles on a factory vault (read live from the factory, rotatable by the factory owner, audit N-06):
///  - sentinel (hot, the executor's monitor): revokeAgent, revokeOperator, pause deposits, pause trading,
///    triggerBreach, cancelOrder, breach / emergency flatten, emergency bridge back and settle
///  - guardian (cold): clearBreach, exitEmergency, cancel queued items, triggerEmergency, unpause, revokeOperator,
///    flatten (custom slippage in emergency), emergency bridge back and settle
///  - owner: everything sensitive through queue + execute after the timelock, plus the switches above, setOperator,
///    resume() after a drawdown breach
///  - operator (granted by the owner, the platform keeper by default): settle, bridgeToCore, bridgeToEvm, moveUsd
///    and the breach / emergency flatten
///  - anyone: checkRisk, clearLeverageBreach, accrueFees, claims and their own requests; pinAccountMode / syncAgent
///    once per MODE_PIN_INTERVAL (vault roles at any time, HL-PROXY)
library VaultGovernance {
    using Math for uint256;
    using VaultMath for VaultStorage;

    bytes4 internal constant SEL_SET_MANAGER = bytes4(keccak256("setManager(address)"));
    bytes4 internal constant SEL_SET_FEES = bytes4(keccak256("setFees(uint16,uint16)"));
    bytes4 internal constant SEL_SET_FEE_RECIPIENT = bytes4(keccak256("setFeeRecipient(address)"));
    bytes4 internal constant SEL_SET_TIMELOCK = bytes4(keccak256("setTimelockDelay(uint256)"));
    bytes4 internal constant SEL_SET_AGENT = bytes4(keccak256("setAgent(address)"));
    bytes4 internal constant SEL_CLEAR_BREACH = bytes4(keccak256("clearBreach()"));

    // ==================================================================
    // Initialization (the vault runs the ERC-20 / Ownable initializers itself)
    // ==================================================================
    function initialize(VaultStorage storage $, InitParams calldata p, uint256 value) external {
        if (p.manager == address(0) || p.feeRecipient == address(0) || address(p.policy) == address(0) || address(p.coreDepositWallet) == address(0)) {
            revert E.ZeroAddress();
        }
        if (p.factory == address(0) && p.guardian == address(0)) revert E.ZeroAddress();
        if (IERC20Metadata(address(p.asset)).decimals() != 6) revert E.UnsupportedAsset();
        if (p.managementFeeBps > MAX_MANAGEMENT_FEE_BPS || p.performanceFeeBps > MAX_PERFORMANCE_FEE_BPS) revert E.InvalidFee();
        if (p.timelockDelay < MIN_TIMELOCK || p.timelockDelay > MAX_TIMELOCK) revert E.InvalidTimelock();
        if (p.protocolShareBps > MAX_PROTOCOL_SHARE_BPS || p.baseShareBps > MAX_PROTOCOL_SHARE_BPS) revert E.InvalidShare();

        $.asset = p.asset;
        $.policy = p.policy;
        $.coreDepositWallet = p.coreDepositWallet;
        $.factory = p.factory;
        $.protocolShareBps = p.protocolShareBps;
        $.baseShareBps = p.baseShareBps;
        $.hosted = p.hosted;
        $.manager = p.manager;
        $.guardian = p.guardian;
        $.feeRecipient = p.feeRecipient;
        $.managementFeeBps = p.managementFeeBps;
        $.performanceFeeBps = p.performanceFeeBps;
        $.timelockDelay = p.timelockDelay;
        _setDepositCap($, p.depositCap);

        $.highWaterMark = 10 ** 6; // 1 USDC per share at an empty vault
        $.peakSharePrice = 10 ** 6;
        $.epochStartedAt = uint64(block.timestamp);
        $.epochDeadline = uint64(block.timestamp + p.policy.maxEpochDuration());
        $.lastFeeAccrual = uint64(block.timestamp);
        $.riskDay = block.timestamp / 1 days;

        // The USDC deposit creates the Core account in this transaction; HyperCore drops any action sent before the
        // account exists (A-13), so the agent is only recorded here (HL-PROXY: it is never approved on HyperCore; the
        // first settle or pinAccountMode() pins the account mode once the account exists).
        if (p.seedUsdc > 0) VaultLogic.seedCore($, p.seedUsdc);
        if (value > 0) VaultLogic.fundCoreGas($, value);
        if (p.agent != address(0)) {
            VaultLogic.initAgent($, p.agent);
            // HLO-07: the binding is inert for AGENT_WARMUP (no deposit, no HyperCore approval): a leaked registrar
            // or owner key cannot bind a self-held agent and take deposits before the platform can veto it.
            if (p.factory != address(0)) $.agentActiveAt = uint64(block.timestamp + AGENT_WARMUP);
        }
        if (p.operator != address(0)) {
            $.operator = p.operator;
            emit Ev.OperatorSet(p.operator);
        }
    }

    // ==================================================================
    // Treasury operator: settle, bridgeToCore, bridgeToEvm and moveUsd only (no trading, policy, fees or roles)
    // ==================================================================
    /// @notice Owner grants (or replaces) the operator; zero revokes.
    function setOperator(VaultStorage storage $, address operator) external {
        if (msg.sender != VaultMath.owner()) revert E.Unauthorized();
        $.operator = operator;
        emit Ev.OperatorSet(operator);
    }

    /// @notice Owner, guardian or sentinel: removes the operator at once.
    function revokeOperator(VaultStorage storage $, address guardian, address sentinel) external {
        if (msg.sender != VaultMath.owner() && msg.sender != guardian && msg.sender != sentinel) revert E.Unauthorized();
        $.operator = address(0);
        emit Ev.OperatorSet(address(0));
    }

    // ==================================================================
    // Risk (round 4: breach = derisk, not shutdown; every loss measured on the share price, R-01)
    // ==================================================================
    /// @notice Permissionless risk check. Leverage, daily loss and drawdown over the policy limits put the vault in
    ///         reduce only mode WITHOUT revoking the agent (the platform executor holds it and honours the mode):
    ///         - leverage: until clearLeverageBreach() finds every limit met again (anyone, after a cooldown);
    ///         - daily loss: until the next UTC day, cleared by the first check of that day;
    ///         - drawdown: until the owner calls resume().
    ///         Only the guardian / sentinel / owner (triggerBreach) and emergency revoke the agent.
    /// @dev Daily loss compares the share price with the share price at the day's first check; drawdown compares it
    ///      with the lifetime peak. Deposits and redemptions settle at the share price and fee mints rescale both
    ///      references, so no flow moves either metric (R-01). Inside a bridge window the equity is
    ///      min(snapshot, live + amount in flight) (audit N-01b); the day does not roll and the peak does not move in
    ///      flight. Also ratchets the NAV checkpoint settle() is bounded against.
    function checkRisk(VaultStorage storage $) external returns (uint256 leverageBps, uint256 dailyLossBps, uint256 drawdownBps) {
        (leverageBps, dailyLossBps, drawdownBps) = _check($);
    }

    /// @notice Anyone: lifts a leverage breach once leverage, daily loss and drawdown are all within the policy,
    ///         outside a bridge window and LEVERAGE_CLEAR_COOLDOWN after the breach. The agent was never revoked.
    function clearLeverageBreach(VaultStorage storage $) external {
        if (!$.breached || $.breachReason != BreachReason.LEVERAGE) revert E.NotClearable();
        if ($.emergency) revert E.InEmergency();
        if ($.bridgePending()) revert E.BridgeInFlight();
        if (block.timestamp < uint256($.breachedAt) + LEVERAGE_CLEAR_COOLDOWN) revert E.NotReady();
        (uint256 lev, uint256 daily, uint256 dd) = _check($);
        (uint256 maxLev, uint256 maxDaily, uint256 maxDd) = $.policy.riskLimits();
        // _check may have escalated the breach (a daily loss or drawdown appeared): that one is not cleared here.
        if ($.breachReason != BreachReason.LEVERAGE || lev > maxLev || daily > maxDaily || dd > maxDd) revert E.NotClearable();
        _clear($);
    }

    /// @notice Owner: ends a drawdown breach, at the earliest RESUME_COOLDOWN after it fired. The peak is reset to
    ///         the current share price so the vault does not breach again at the same NAV; leverage and the daily
    ///         loss must be within the policy. Emits Resumed and records lastResumeAt for depositors.
    function resume(VaultStorage storage $) external {
        if (msg.sender != VaultMath.owner()) revert E.Unauthorized();
        if (!$.breached || $.breachReason != BreachReason.DRAWDOWN) revert E.NotClearable();
        if ($.emergency) revert E.InEmergency();
        if (block.timestamp < uint256($.breachedAt) + RESUME_COOLDOWN) revert E.NotReady();
        if ($.bridgePending()) revert E.BridgeInFlight();
        (uint256 lev, uint256 daily,) = _check($);
        (uint256 maxLev, uint256 maxDaily,) = $.policy.riskLimits();
        if ($.breachReason != BreachReason.DRAWDOWN || lev > maxLev || daily > maxDaily) revert E.NotClearable();
        uint256 before = $.peakSharePrice;
        uint256 price = $.sharePrice();
        $.peakSharePrice = price;
        $.lastResumeAt = uint64(block.timestamp);
        emit Ev.Resumed(before, price);
        _clear($);
    }

    function _check(VaultStorage storage $) internal returns (uint256 leverageBps, uint256 dailyLossBps, uint256 drawdownBps) {
        // HL-PROXY: under a non-Standard account mode the precompiles do not show the vault's equity (CONTEXT evidence
        // 3): no checkpoint, peak, day start or breach decision is taken from them. pinAccountMode() re-pins the mode.
        if (VaultMath.modeSuspect()) revert E.AccountModeMismatch();
        VaultLogic.syncBridge($);
        // In flight or late (R3-01 residual): the bridged amount counts as in transit, never as a loss.
        bool inFlight = $.bridgePending();
        uint256 equity = $.idleAssets() + VaultMath.coreEquity();
        if (inFlight) {
            uint256 visible = equity + $.bridgeAmount;
            equity = visible < $.equityAtBridge ? visible : $.equityAtBridge;
        }
        uint256 supply = VaultMath.totalSupply();
        uint256 price = VaultMath.priceAt(equity, supply);

        uint256 day = block.timestamp / 1 days;
        if (day != $.riskDay && !inFlight) {
            $.riskDay = day;
            $.dayStartSharePrice = price;
            // A daily loss breach lasts until the daily reset.
            if ($.breached && $.breachReason == BreachReason.DAILY_LOSS && !$.emergency) _clear($);
        }
        if (!inFlight && price > $.peakSharePrice) $.peakSharePrice = price;

        if (HyperCore.coreUserExists(address(this))) {
            HyperCore.AccountMarginSummary memory m = HyperCore.accountMarginSummary(address(this));
            if (m.ntlPos > 0) {
                leverageBps = m.accountValue > 0 ? uint256(m.ntlPos).mulDiv(BPS, uint256(uint64(m.accountValue))) : type(uint256).max;
            }
        }
        if (supply > 0 && equity >= MIN_RISK_NAV) {
            uint256 start = $.dayStartSharePrice;
            if (start > price) dailyLossBps = (start - price).mulDiv(BPS, start);
            if ($.peakSharePrice > price) drawdownBps = ($.peakSharePrice - price).mulDiv(BPS, $.peakSharePrice);
        }

        VaultLogic.checkpoint($, equity);
        VaultLogic.pinModeIfDue($);
        emit Ev.RiskChecked(leverageBps, dailyLossBps, drawdownBps, equity);

        (uint256 maxLev, uint256 maxDaily, uint256 maxDd) = $.policy.riskLimits();
        BreachReason r = drawdownBps > maxDd
            ? BreachReason.DRAWDOWN
            : dailyLossBps > maxDaily ? BreachReason.DAILY_LOSS : leverageBps > maxLev ? BreachReason.LEVERAGE : BreachReason.NONE;
        // A breach only escalates, and a full stop (guardian, emergency) is never touched here.
        if (r != BreachReason.NONE && (!$.breached || $.breachReason < r)) _derisk($, r);
    }

    /// @dev Reduce only, agent kept. An escalation restarts breachedAt: the new reason's rules apply from now.
    function _derisk(VaultStorage storage $, BreachReason r) internal {
        $.breached = true;
        $.breachReason = r;
        $.breachedAt = uint64(block.timestamp);
        emit Ev.Breached(r == BreachReason.LEVERAGE ? "leverage" : r == BreachReason.DAILY_LOSS ? "daily loss" : "drawdown", msg.sender);
    }

    function _clear(VaultStorage storage $) internal {
        $.breached = false;
        $.breachReason = BreachReason.NONE;
        $.platformHold = false;
        emit Ev.BreachCleared();
    }

    /// @notice Owner, guardian or sentinel: full stop (reduce only and the agent revoked).
    function triggerBreach(VaultStorage storage $, address guardian, address sentinel) external {
        if (msg.sender != VaultMath.owner() && msg.sender != guardian && msg.sender != sentinel) revert E.Unauthorized();
        // Escalates a risk breach to a full stop; an emergency stays an emergency. Every call restarts breachedAt,
        // so an owner clear queued before it no longer counts (audit N-04).
        _stop($, $.breachReason > BreachReason.GUARDIAN ? $.breachReason : BreachReason.GUARDIAN, "guardian");
        // HLR2-E06: only a platform stop freezes the settles; the owner's settles redemption-only. Never downgraded
        // by a later owner call, reset by any clear.
        if (msg.sender == guardian || msg.sender == sentinel) $.platformHold = true;
    }

    function _stop(VaultStorage storage $, BreachReason r, string memory reason) internal {
        $.breached = true;
        $.breachReason = r;
        $.breachedAt = uint64(block.timestamp);
        VaultLogic.revokeAgent($);
        emit Ev.Breached(reason, msg.sender);
    }

    /// @notice Owner or guardian at any time. Anyone if the epoch is overdue with redemptions waiting.
    /// @dev Entering emergency stamps `emergencyAt`; the guardian's exit looks at the settles made since then.
    function triggerEmergency(VaultStorage storage $, address guardian) external {
        bool privileged = msg.sender == guardian || msg.sender == VaultMath.owner();
        if (!privileged && !($.epochOverdue() && $.pendingRedeemShares > 0)) revert E.NotOverdue();
        if (!$.emergency) {
            $.emergency = true;
            $.emergencyAt = uint64(block.timestamp);
        }
        // Every trigger restarts breachedAt, so an owner clearBreach queued before it never counts (R3-03, N-04).
        _stop($, BreachReason.EMERGENCY, "emergency");
        emit Ev.EmergencyTriggered(msg.sender);
    }

    /// @notice The cold guardian instantly, or the owner through a queue item created after the breach (the
    ///         timelock then runs from the breach, audit N-04). Clears any breach outside emergency. The day's share
    ///         price reference restarts from now; the drawdown peak is only ever reset by the owner's resume().
    function clearBreach(VaultStorage storage $, address guardian) external {
        if (msg.sender != address(this) && msg.sender != guardian) revert E.Unauthorized();
        if ($.emergency) revert E.InEmergency();
        $.dayStartSharePrice = $.sharePrice();
        $.riskDay = block.timestamp / 1 days;
        // HLR2-XA01: only the guardian lifts a revoke's deposit hold (never the owner's queued clear).
        if (msg.sender == guardian && $.depositHold) {
            $.depositHold = false;
            emit Ev.DepositHold(false);
        }
        _clear($);
    }

    /// @notice Guardian only (HLR2-A02 / A08): accepts that the latest transfer, missing past MAX_UNLANDED_BLOCKS,
    ///         is lost (or will be handled off chain), which ends the settle hold before UNRESOLVED_WAIT_BLOCKS.
    ///         From then on settles price at the visible NAV, as after the wait.
    function writeOffBridge(VaultStorage storage $, address guardian) external {
        if (msg.sender != guardian) revert E.Unauthorized();
        VaultLogic.syncBridge($);
        if (!$.bridgeUnresolved()) revert E.NotUnresolved();
        $.bridgeWrittenOff = true;
        emit Ev.BridgeWrittenOff($.bridgeAmount);
    }

    /// @notice Only the cold guardian ends an emergency (audit W-01 / W-01b: the owner has no path, queued or
    ///         direct). Not while redemptions are pending, and not while the last settle of this emergency was a
    ///         partial fill whose returned shares may still be waiting to be re-requested. Operational rule: exit
    ///         only after every redeemer is fully paid or has declined.
    function exitEmergency(VaultStorage storage $, address guardian) external {
        if (msg.sender != guardian) revert E.Unauthorized();
        if ($.pendingRedeemShares > 0) revert E.RedemptionsPending();
        uint256 epoch = $.currentEpoch;
        if (epoch > 0) {
            EpochResult storage last = $.epochs[epoch - 1];
            if (last.settledAt >= $.emergencyAt && last.redeemBurned < last.redeemShares) revert E.RedemptionsPending();
        }
        $.emergency = false;
        emit Ev.EmergencyExited();
    }

    // ==================================================================
    // Switches
    // ==================================================================
    /// @dev Pausing: owner, guardian or sentinel. Unpausing: owner or guardian.
    function setDepositsPaused(VaultStorage storage $, bool paused, address guardian, address sentinel) external {
        _switchAuth(paused, guardian, sentinel);
        $.depositsPaused = paused;
        emit Ev.DepositsPaused(paused);
    }

    function setTradingPaused(VaultStorage storage $, bool paused, address guardian, address sentinel) external {
        _switchAuth(paused, guardian, sentinel);
        $.tradingPaused = paused;
        emit Ev.TradingPaused(paused);
    }

    function _switchAuth(bool paused, address guardian, address sentinel) internal view {
        if (msg.sender == VaultMath.owner() || msg.sender == guardian) return;
        if (paused && msg.sender == sentinel) return;
        revert E.Unauthorized();
    }

    /// @notice Deposit cap on NAV plus pending deposits. Factory vaults must stay within the platform maximum.
    function setDepositCap(VaultStorage storage $, uint256 cap) external {
        if (msg.sender != VaultMath.owner()) revert E.Unauthorized();
        _setDepositCap($, cap);
    }

    function _setDepositCap(VaultStorage storage $, uint256 cap) internal {
        if ($.factory != address(0) && (cap == 0 || cap > IVaultFactory($.factory).maxDepositCap())) revert E.CapExceeded();
        $.depositCap = cap;
        emit Ev.DepositCapUpdated(cap);
    }

    /// @notice Lowering at least one fee is immediate (neither may go up) and drops any scheduled performance
    ///         fee raise. Raising goes through the timelock.
    function lowerFees(VaultStorage storage $, uint16 mgmtBps, uint16 perfBps) external {
        if (msg.sender != VaultMath.owner()) revert E.Unauthorized();
        if (mgmtBps > $.managementFeeBps || perfBps > $.performanceFeeBps) revert E.InvalidFee();
        if (mgmtBps == $.managementFeeBps && perfBps == $.performanceFeeBps && $.pendingPerformanceFeeBps == 0) {
            revert E.InvalidFee();
        }
        _setFees($, mgmtBps, perfBps);
    }

    // ==================================================================
    // Timelocked admin (owner queues, anyone executes after the delay, within the grace period)
    // ==================================================================
    /// @dev Exact calldata length per selector: no padding can create duplicate ids for one call (audit N-04).
    function queue(VaultStorage storage $, bytes calldata data) external returns (bytes32 id) {
        if (msg.sender != VaultMath.owner()) revert E.Unauthorized();
        if (data.length < 4) revert E.NotQueued();
        bytes4 sel = bytes4(data[:4]);
        uint256 expected;
        if (sel == SEL_SET_MANAGER || sel == SEL_SET_FEE_RECIPIENT || sel == SEL_SET_TIMELOCK || sel == SEL_SET_AGENT) expected = 36;
        else if (sel == SEL_SET_FEES) expected = 68;
        else if (sel == SEL_CLEAR_BREACH) expected = 4;
        else revert E.Unauthorized();
        if (data.length != expected) revert E.Unauthorized();
        id = keccak256(data);
        // Exit before effect (hl-r2 H01): every queued item (agent, manager, fee recipient, fee raise, delay, breach
        // clear) waits until a redeemer who is waiting now has reached a forced exit with EXIT_MARGIN to spare.
        uint256 eta = block.timestamp + $.timelockDelay;
        uint256 notice = $.policy.noticeEta();
        if (notice > eta) eta = notice;
        notice = uint256($.epochDeadline) + EXIT_MARGIN;
        if (notice > eta) eta = notice;
        $.queuedEta[id] = eta;
        $.queuedAt[id] = block.timestamp;
        emit Ev.Queued(id, data, eta);
    }

    function execute(VaultStorage storage $, bytes calldata data) external {
        bytes32 id = keccak256(data);
        uint256 eta = $.queuedEta[id];
        if (eta == 0) revert E.NotQueued();
        if (block.timestamp < eta) revert E.NotReady();
        if (block.timestamp > eta + GRACE_PERIOD) revert E.Expired();
        // A breach clear only counts when it was queued after the breach it clears (audit N-04).
        if (bytes4(data[:4]) == SEL_CLEAR_BREACH && $.queuedAt[id] <= $.breachedAt) revert E.NotReady();
        delete $.queuedEta[id];
        delete $.queuedAt[id];
        (bool ok, bytes memory ret) = address(this).call(data);
        if (!ok) revert E.CallFailed(ret);
        emit Ev.Executed(id);
    }

    /// @notice Owner or guardian.
    function cancel(VaultStorage storage $, bytes32 id, address guardian) external {
        if (msg.sender != VaultMath.owner() && msg.sender != guardian) revert E.Unauthorized();
        if ($.queuedEta[id] == 0) revert E.NotQueued();
        delete $.queuedEta[id];
        delete $.queuedAt[id];
        emit Ev.Cancelled(id);
    }

    function setManager(VaultStorage storage $, address newManager) external {
        if (newManager == address(0)) revert E.ZeroAddress();
        $.manager = newManager;
        emit Ev.ManagerUpdated(newManager);
    }

    /// @dev Never inside a bridge window: the old rate must crystallise on a reliable NAV first (audit M-02).
    function setFees(VaultStorage storage $, uint16 mgmtBps, uint16 perfBps) external {
        if ($.bridgePending()) revert E.BridgeInFlight();
        _setFees($, mgmtBps, perfBps);
    }

    function setFeeRecipient(VaultStorage storage $, address recipient) external {
        if (recipient == address(0)) revert E.ZeroAddress();
        $.feeRecipient = recipient;
        emit Ev.FeeRecipientUpdated(recipient);
    }

    function setTimelockDelay(VaultStorage storage $, uint256 delay) external {
        if (delay < MIN_TIMELOCK || delay > MAX_TIMELOCK) revert E.InvalidTimelock();
        $.timelockDelay = delay;
        emit Ev.TimelockUpdated(delay);
    }

    /// @dev Crystallises the management fee at the old rate when NAV is reliable. The performance fee only
    ///      crystallises in settle(), at the rate in force then (audit N-05). A performance fee raise is only
    ///      scheduled: settle() charges the running epoch at the old rate, then switches (audit N2-02). A
    ///      performance fee that is lowered (or unchanged) applies at once and clears any scheduled raise.
    function _setFees(VaultStorage storage $, uint16 mgmtBps, uint16 perfBps) internal {
        if (mgmtBps > MAX_MANAGEMENT_FEE_BPS || perfBps > MAX_PERFORMANCE_FEE_BPS) revert E.InvalidFee();
        if (!$.bridgePending()) VaultLogic.accrueFees($);
        $.managementFeeBps = mgmtBps;
        if (perfBps > $.performanceFeeBps) {
            $.pendingPerformanceFeeBps = perfBps;
            emit Ev.FeesUpdated(mgmtBps, $.performanceFeeBps);
            emit Ev.FeesScheduled(perfBps);
        } else {
            $.performanceFeeBps = perfBps;
            $.pendingPerformanceFeeBps = 0;
            emit Ev.FeesUpdated(mgmtBps, perfBps);
        }
    }
}
