// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IGainsDiamond, GTrade} from "./IGainsDiamond.sol";
import {GainsNav} from "./GainsNav.sol";
import {GainsVaultLogic} from "./GainsVaultLogic.sol";
import {GainsVaultMath} from "./GainsVaultMath.sol";
import {GainsPrice} from "./GainsPrice.sol";
import {IGainsCuration} from "./GainsVaultPolicy.sol";
import {EXIT_MARGIN, IGainsVaultErrors as E, IGainsVaultEvents as Ev, InitParams, VaultStorage} from "./GainsTypes.sol";
import {
    BPS,
    BreachReason,
    EpochResult,
    GRACE_PERIOD,
    IVaultFactory,
    LEVERAGE_CLEAR_COOLDOWN,
    MAX_MANAGEMENT_FEE_BPS,
    RESUME_COOLDOWN,
    MIN_DEPOSIT,
    MIN_RISK_NAV,
    MAX_PERFORMANCE_FEE_BPS,
    MAX_PROTOCOL_SHARE_BPS,
    MAX_TIMELOCK,
    MIN_TIMELOCK,
    Request
} from "../VaultTypes.sol";

/// @title GainsVaultGovernance
/// @notice Initialization, the depositor requests, risk checks, breach and emergency state, safety switches and the owner timelock of
///         GainsVault. Linked as an external library: every function runs by delegatecall on the vault's storage.
/// @dev Round 4 VaultGovernance copied 1:1 except: initialize (diamond and collateral index instead of the Core
///      deposit wallet, seed bridge and Core gas), _check (equity and vault leverage from GainsNav, no bridge window)
///      and the bridge-window guards, which have no Gains counterpart.
///
/// Roles on a factory vault (read live from the factory, rotatable by the factory owner, audit N-06):
///  - sentinel (hot, the executor's monitor): revokeAgent, revokeOperator, pause deposits, pause trading,
///    triggerBreach, cancelOrder, SL tightening while breached, breach / emergency close and flatten, settle
///  - guardian (cold): clearBreach, exitEmergency, cancel queued items, triggerEmergency, unpause, revokeOperator,
///    close and flatten at any time (custom slippage in emergency), settle
///  - owner: everything sensitive through queue + execute after the timelock, plus the switches above, setOperator,
///    resume() after a drawdown breach
///  - operator (granted by the owner, the platform keeper by default): settle, reduceTrade (frees USDC for
///    redemptions) and the breach / emergency close and flatten
///  - agent (bound by the factory): trades through the vault like the manager (decision D1)
///  - anyone: checkRisk, clearLeverageBreach, accrueFees, cancelTimedOut, claims and their own requests
library GainsVaultGovernance {
    using SafeERC20 for IERC20;
    using Math for uint256;
    using GainsVaultMath for VaultStorage;

    bytes4 internal constant SEL_SET_MANAGER = bytes4(keccak256("setManager(address)"));
    bytes4 internal constant SEL_SET_FEES = bytes4(keccak256("setFees(uint16,uint16)"));
    bytes4 internal constant SEL_SET_FEE_RECIPIENT = bytes4(keccak256("setFeeRecipient(address)"));
    bytes4 internal constant SEL_SET_TIMELOCK = bytes4(keccak256("setTimelockDelay(uint256)"));
    bytes4 internal constant SEL_SET_AGENT = bytes4(keccak256("setAgent(address)"));
    bytes4 internal constant SEL_CLEAR_BREACH = bytes4(keccak256("clearBreach()"));
    bytes4 internal constant SEL_SET_PAIR_FEED = bytes4(keccak256("setPairFeed(uint16,address,uint32,uint16)"));
    bytes4 internal constant SEL_SET_SEQUENCER_FEED = bytes4(keccak256("setSequencerFeed(address,uint256)"));

    // ==================================================================
    // Initialization (the vault runs the ERC-20 / Ownable initializers itself)
    // ==================================================================
    function initialize(VaultStorage storage $, InitParams calldata p) external {
        if (p.manager == address(0) || p.feeRecipient == address(0) || address(p.policy) == address(0) || address(p.diamond) == address(0)) {
            revert E.ZeroAddress();
        }
        if (p.factory == address(0) && p.guardian == address(0)) revert E.ZeroAddress();
        if (IERC20Metadata(address(p.asset)).decimals() != 6) revert E.UnsupportedAsset();
        if (p.managementFeeBps > MAX_MANAGEMENT_FEE_BPS || p.performanceFeeBps > MAX_PERFORMANCE_FEE_BPS) revert E.InvalidFee();
        if (p.timelockDelay < MIN_TIMELOCK || p.timelockDelay > MAX_TIMELOCK) revert E.InvalidTimelock();
        if (p.protocolShareBps > MAX_PROTOCOL_SHARE_BPS || p.baseShareBps > MAX_PROTOCOL_SHARE_BPS) revert E.InvalidShare();
        // The asset must be an active collateral on the diamond (USDC: index 3 on Arbitrum, STAGE0.md A4).
        uint8 ci = p.diamond.getCollateralIndex(address(p.asset));
        IGainsDiamond.Collateral memory c = p.diamond.getCollateral(ci);
        if (ci == 0 || c.collateral != address(p.asset) || !c.isActive) revert E.UnsupportedAsset();
        // The policy names this vault as the only caller of its feed rotation (setPairFeed).
        if (p.policy.vault() != address(this)) revert E.PolicyMismatch();

        $.asset = p.asset;
        $.policy = p.policy;
        $.diamond = p.diamond;
        $.collateralIndex = ci;
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
        $.startEpoch();
        $.lastFeeAccrual = uint64(block.timestamp);
        $.riskDay = block.timestamp / 1 days;

        // The seed USDC (if any) is already here as idle; there is no Core account to open. The agent is a vault
        // caller, so storing it is all the binding there is.
        if (p.agent != address(0)) GainsVaultLogic.setAgent($, p.agent);
        if (p.operator != address(0)) {
            $.operator = p.operator;
            emit Ev.OperatorSet(p.operator);
        }
    }

    // ==================================================================
    // Depositor flow (moved from GainsVaultLogic unchanged, for size)
    // ==================================================================
    /// @dev A deposit by the manager, the owner or the fee recipient (as sender or controller) is priced at the NEXT
    ///      epoch's settlement, never in the epoch whose timing and NAV the insider can influence. Such a request
    ///      belongs to epoch currentEpoch + 1 and its USDC is held apart (deferredDepositAssets) until then. A
    ///      controller has one request at a time: mixing a current-epoch request with a next-epoch one reverts.
    function requestDeposit(VaultStorage storage $, uint256 assets, address controller) external returns (uint256 epoch) {
        GainsVaultLogic._enter($);
        if (assets == 0) revert E.ZeroAmount();
        if (assets < MIN_DEPOSIT) revert E.DepositTooSmall();
        if (controller == address(0)) revert E.ZeroAddress();
        if ($.depositsPaused || $.breached || $.emergency) revert E.DepositsClosed();
        if ($.depositCap != 0 && $.totalAssets() + $.pendingDepositAssets + $.deferredDepositAssets + assets > $.depositCap) {
            revert E.CapExceeded();
        }

        _claimIfSettled($, controller);
        _rejoinCarry($, controller);
        bool insider = _isInsider($, msg.sender) || _isInsider($, controller);
        epoch = insider ? $.currentEpoch + 1 : $.currentEpoch;
        Request storage r = $.requests[controller];
        if ((r.depositAssets > 0 || r.redeemShares > 0) && r.epoch != epoch) revert E.RequestPending();

        // GR2-FF-02: the request is booked before the asset moves, so a transfer callback never sees the incoming USDC
        // as NAV (and _check refuses to run inside the lock, for a callback before the balance moves).
        r.epoch = epoch;
        r.depositAssets += assets;
        if (insider) $.deferredDepositAssets += assets;
        else $.pendingDepositAssets += assets;
        $.asset.safeTransferFrom(msg.sender, address(this), assets);

        emit Ev.DepositRequested(controller, msg.sender, epoch, assets);
        GainsVaultLogic._exit($);
    }

    /// @dev Always allowed, including during breach or emergency: exits are never gated.
    function requestRedeem(VaultStorage storage $, uint256 shares, address controller, address owner_)
        external
        returns (uint256 epoch)
    {
        GainsVaultLogic._enter($);
        if (shares == 0) revert E.ZeroAmount();
        if (controller == address(0)) revert E.ZeroAddress();
        if (msg.sender != owner_) GainsVaultMath.spendAllowance(owner_, msg.sender, shares);

        _claimIfSettled($, controller);
        _rejoinCarry($, controller);
        Request storage r = $.requests[controller];
        // A deposit waiting for the next epoch must settle first: one request per controller. (A carried deposit
        // has just rejoined the current epoch, so exits are never gated by it.)
        if (r.epoch > $.currentEpoch) revert E.RequestPending();
        GainsVaultMath.transfer(owner_, address(this), shares);

        r.epoch = $.currentEpoch;
        r.redeemShares += shares;
        $.pendingRedeemShares += shares;

        emit Ev.RedeemRequested(controller, owner_, $.currentEpoch, shares);
        GainsVaultLogic._exit($);
        return $.currentEpoch;
    }

    function cancelDepositRequest(VaultStorage storage $) external {
        Request storage r = $.requests[msg.sender];
        if (r.depositAssets == 0) revert E.NothingToCancel();
        if (r.epoch < $.currentEpoch) {
            // only a deposit still carried by a redemption-only epoch is cancellable once its epoch has passed
            (,, bool carried) = $.claimableWithCarry(msg.sender);
            if (!carried) revert E.NothingToCancel();
        }
        uint256 assets = r.depositAssets;
        r.depositAssets = 0;
        if (r.epoch > $.currentEpoch) {
            $.deferredDepositAssets -= assets;
            // The request is empty now: it belongs to the current epoch again, so a redemption is not refused as
            // RequestPending until the next settle (GR1-32; a deferred deposit never coexists with a redemption).
            r.epoch = $.currentEpoch;
        } else {
            $.pendingDepositAssets -= assets;
        }
        $.asset.safeTransfer(msg.sender, assets);
        emit Ev.DepositCancelled(msg.sender, assets);
    }

    /// @dev Cancels what is still pending in the current epoch (a settled request is claimed first).
    function cancelRedeemRequest(VaultStorage storage $) external {
        _claimIfSettled($, msg.sender);
        Request storage r = $.requests[msg.sender];
        if (r.epoch != $.currentEpoch || r.redeemShares == 0) revert E.NothingToCancel();
        uint256 shares = r.redeemShares;
        r.redeemShares = 0;
        $.pendingRedeemShares -= shares;
        GainsVaultMath.transfer(address(this), msg.sender, shares);
        emit Ev.RedeemCancelled(msg.sender, shares);
    }

    /// @dev Delivers settled shares and USDC to `controller`. Callable by anyone.
    function claim(VaultStorage storage $, address controller) external {
        Request storage r = $.requests[controller];
        if (r.epoch >= $.currentEpoch) revert E.RequestNotSettled();
        (,, bool carried) = $.claimableWithCarry(controller);
        if (carried && r.redeemShares == 0) revert E.RequestNotSettled();
        _claimIfSettled($, controller);
    }

    /// @dev Delivers the epoch's result: minted shares and refunds for deposits, the pro rata payout for
    ///      redemptions plus the shares the epoch could not pay for (partial fill + return, audit V-01).
    function _claimIfSettled(VaultStorage storage $, address controller) internal {
        Request storage r = $.requests[controller];
        if (r.epoch >= $.currentEpoch) return;
        if (r.depositAssets == 0 && r.redeemShares == 0) return;
        (uint256 shares, uint256 assets, bool carried) = $.claimableWithCarry(controller);
        uint256 epoch = r.epoch;
        // A carried deposit stays queued (with its epoch pointer); only the redemption part is delivered.
        if (!carried) r.depositAssets = 0;
        r.redeemShares = 0;
        if (shares > 0) GainsVaultMath.transfer(address(this), controller, shares);
        if (assets > 0) {
            // Pro rata rounding can leave a few wei short of the reserve; never pay out of other users' money.
            if (assets > $.claimableRedeemAssets) assets = $.claimableRedeemAssets;
            $.claimableRedeemAssets -= assets;
            $.asset.safeTransfer(controller, assets);
        }
        emit Ev.Claimed(controller, epoch, shares, assets);
    }

    /// @dev A deposit still carried by a redemption-only epoch moves to the current epoch. Sound because the carried
    ///      USDC is in the shared queue (pendingDepositAssets) and the current epoch either continues the same carry
    ///      run (another redemption-only settle) or prices it; either way the request resolves to the same result.
    function _rejoinCarry(VaultStorage storage $, address controller) internal {
        Request storage r = $.requests[controller];
        if (r.depositAssets == 0 || r.epoch >= $.currentEpoch) return;
        (,, bool carried) = $.claimableWithCarry(controller);
        if (carried) r.epoch = $.currentEpoch;
    }

    function _isInsider(VaultStorage storage $, address a) internal view returns (bool) {
        return a == $.manager || a == GainsVaultMath.owner() || a == $.feeRecipient;
    }

    // ==================================================================
    // Treasury operator: settle, reduceTrade and the breach / emergency unwind only (no new risk, policy, fees or roles)
    // ==================================================================
    /// @notice Owner grants (or replaces) the operator; zero revokes.
    function setOperator(VaultStorage storage $, address operator) external {
        if (msg.sender != GainsVaultMath.owner()) revert E.Unauthorized();
        $.operator = operator;
        emit Ev.OperatorSet(operator);
    }

    /// @notice Owner, guardian or sentinel: removes the operator at once.
    function revokeOperator(VaultStorage storage $, address guardian, address sentinel) external {
        if (msg.sender != GainsVaultMath.owner() && msg.sender != guardian && msg.sender != sentinel) revert E.Unauthorized();
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
    ///      references, so no flow moves either metric (R-01). Leverage is vault leverage: open notional / NAV
    ///      (PLAN.md 4.5). Collateral in a pending order is valued by GainsNav, so there is no in-flight case.
    ///      Also ratchets the NAV checkpoint settle() is bounded against.
    function checkRisk(VaultStorage storage $) external returns (uint256 leverageBps, uint256 dailyLossBps, uint256 drawdownBps) {
        (leverageBps, dailyLossBps, drawdownBps) = _check($);
    }

    /// @notice Anyone: lifts a leverage breach once leverage, daily loss and drawdown are all within the policy,
    ///         LEVERAGE_CLEAR_COOLDOWN after the breach. The agent was never revoked.
    function clearLeverageBreach(VaultStorage storage $) external {
        if (!$.breached || $.breachReason != BreachReason.LEVERAGE) revert E.NotClearable();
        if ($.emergency) revert E.InEmergency();
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
        if (msg.sender != GainsVaultMath.owner()) revert E.Unauthorized();
        if (!$.breached || $.breachReason != BreachReason.DRAWDOWN) revert E.NotClearable();
        if ($.emergency) revert E.InEmergency();
        if (block.timestamp < uint256($.breachedAt) + RESUME_COOLDOWN) revert E.NotReady();
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
        // GR2-FF-02: never from inside a request or settle (a transfer callback reads half-moved books).
        if ($.lock == 1) revert E.Reentrancy();
        GainsNav.Snapshot memory v = $.venue();
        uint256 equity = $.idleAssets() + v.value;
        uint256 supply = GainsVaultMath.totalSupply();
        uint256 price = GainsVaultMath.priceAt(equity, supply);

        uint256 day = block.timestamp / 1 days;
        if (day != $.riskDay) {
            $.riskDay = day;
            $.dayStartSharePrice = price;
            // A daily loss breach lasts until the daily reset.
            if ($.breached && $.breachReason == BreachReason.DAILY_LOSS && !$.emergency) _clear($);
        }
        if (price > $.peakSharePrice) $.peakSharePrice = price;

        if (v.notional > 0) leverageBps = equity > 0 ? v.notional.mulDiv(BPS, equity) : type(uint256).max;
        if (supply > 0 && equity >= MIN_RISK_NAV) {
            uint256 start = $.dayStartSharePrice;
            if (start > price) dailyLossBps = (start - price).mulDiv(BPS, start);
            if ($.peakSharePrice > price) drawdownBps = ($.peakSharePrice - price).mulDiv(BPS, $.peakSharePrice);
        }

        GainsVaultLogic.checkpoint($, equity);
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
        emit Ev.BreachCleared();
    }

    /// @notice Owner, guardian or sentinel: full stop (reduce only and the agent revoked).
    function triggerBreach(VaultStorage storage $, address guardian, address sentinel) external {
        if (msg.sender != GainsVaultMath.owner() && msg.sender != guardian && msg.sender != sentinel) revert E.Unauthorized();
        // Escalates a risk breach to a full stop; an emergency stays an emergency. Every call restarts breachedAt,
        // so an owner clear queued before it no longer counts (audit N-04).
        _stop($, $.breachReason > BreachReason.GUARDIAN ? $.breachReason : BreachReason.GUARDIAN, "guardian");
    }

    function _stop(VaultStorage storage $, BreachReason r, string memory reason) internal {
        $.breached = true;
        $.breachReason = r;
        $.breachedAt = uint64(block.timestamp);
        GainsVaultLogic.revokeAgent($);
        _cancelResting($);
        emit Ev.Breached(reason, msg.sender);
    }

    /// @dev A full stop cancels the vault's resting limit / stop opens, which Gains' bots would otherwise still open
    ///      (GR1-16). Best effort: an unreadable trade list or a refused cancel never blocks the stop (the sentinel's
    ///      cancelOrder and flatten remain).
    function _cancelResting(VaultStorage storage $) internal {
        IGainsDiamond d = $.diamond;
        (bool ok, IGainsDiamond.Trade[] memory trades) = GainsNav.tryReadTrades(d, address(this));
        if (!ok) return;
        for (uint256 i; i < trades.length; ++i) {
            if (!trades[i].isOpen || trades[i].tradeType == GTrade.TRADE) continue;
            try d.cancelOpenOrder(trades[i].index) {
                emit Ev.OrderCancelled(trades[i].index, msg.sender);
            } catch {}
        }
    }

    /// @notice Owner or guardian at any time. Anyone if the epoch is overdue with redemptions waiting.
    /// @dev Entering emergency stamps `emergencyAt`; the guardian's exit looks at the settles made since then.
    function triggerEmergency(VaultStorage storage $, address guardian) external {
        bool privileged = msg.sender == guardian || msg.sender == GainsVaultMath.owner();
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
        _clear($);
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
        if (msg.sender == GainsVaultMath.owner() || msg.sender == guardian) return;
        if (paused && msg.sender == sentinel) return;
        revert E.Unauthorized();
    }

    /// @notice Deposit cap on NAV plus pending deposits. Factory vaults must stay within the platform maximum.
    function setDepositCap(VaultStorage storage $, uint256 cap) external {
        if (msg.sender != GainsVaultMath.owner()) revert E.Unauthorized();
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
        if (msg.sender != GainsVaultMath.owner()) revert E.Unauthorized();
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
        if (msg.sender != GainsVaultMath.owner()) revert E.Unauthorized();
        if (data.length < 4) revert E.NotQueued();
        bytes4 sel = bytes4(data[:4]);
        uint256 expected;
        if (sel == SEL_SET_MANAGER || sel == SEL_SET_FEE_RECIPIENT || sel == SEL_SET_TIMELOCK || sel == SEL_SET_AGENT) expected = 36;
        else if (sel == SEL_SET_FEES) expected = 68;
        else if (sel == SEL_CLEAR_BREACH) expected = 4;
        else if (sel == SEL_SET_SEQUENCER_FEED) expected = 68;
        else if (sel == SEL_SET_PAIR_FEED) expected = 132;
        else revert E.Unauthorized();
        if (data.length != expected) revert E.Unauthorized();
        // The sequencer rotation is snapshotted at queue time (GV-03): the queued feed and grace period must be the
        // factory's current ones, so what the owner reviews is what executes, whatever the factory holds later.
        if (sel == SEL_SET_SEQUENCER_FEED) {
            (address feed, uint256 grace) = abi.decode(data[4:], (address, uint256));
            IGainsCuration f = IGainsCuration($.policy.factory());
            if (feed != f.sequencerFeed() || grace != f.sequencerGracePeriod()) revert GainsPrice.SequencerFeedNotCurrent();
            GainsPrice.checkSequencerGrace(grace);
        }
        id = keccak256(data);
        // Exit before effect (GR2-CFG-01): every queued item (agent, manager, fee recipient, fee raise, delay, breach
        // clear, feed rotations) waits until a redeemer who is waiting now has reached an overdue epoch with
        // EXIT_MARGIN to spare.
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
        if (msg.sender != GainsVaultMath.owner() && msg.sender != guardian) revert E.Unauthorized();
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

    /// @dev The old rate crystallises on the current NAV first (audit M-02); a stale feed reverts it.
    function setFees(VaultStorage storage $, uint16 mgmtBps, uint16 perfBps) external {
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
        GainsVaultLogic.accrueFees($);
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
