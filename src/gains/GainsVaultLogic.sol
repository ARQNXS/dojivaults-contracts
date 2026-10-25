// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {GainsVaultMath} from "./GainsVaultMath.sol";
import {GainsNav} from "./GainsNav.sol";
import {GainsVaultPolicy} from "./GainsVaultPolicy.sol";
import {IGainsDiamond, GTrade} from "./IGainsDiamond.sol";
import {
    IGainsVaultErrors as E,
    IGainsVaultEvents as Ev,
    DEFAULT_PAIR_SKEW_CAP_BPS,
    IGainsPairCaps,
    MAX_POSITIONS,
    MIN_COLLATERAL_FEE_MULTIPLE,
    OpenParams,
    operatorReduceCap,
    VaultStorage
} from "./GainsTypes.sol";
import {
    BPS,
    BreachReason,
    INSIDER_MIN_EPOCH_AGE,
    DECIMALS_OFFSET,
    EpochResult,
    IVaultFactory,
    MIN_RISK_NAV,
    ONE_SHARE,
    YEAR
} from "../VaultTypes.sol";

/// @title GainsVaultLogic
/// @notice Settlement, fees, Gains trading and the agent slot of GainsVault (the depositor requests are in
///         GainsVaultGovernance, for size). Linked as an
///         external library: every function runs by delegatecall on the vault's own storage.
/// @dev Round 4 VaultLogic with bridging, Core gas, moveUsd and the HyperCore agent approval removed and Gains
///      trading added (PLAN.md 4.2). Depositor flow, settle and fees are copied 1:1 apart from the bridge window,
///      which becomes "no settle while an order is pending on the diamond".
library GainsVaultLogic {
    using SafeERC20 for IERC20;
    using Math for uint256;
    using GainsVaultMath for VaultStorage;

    /// @dev A daily loss or drawdown breach outside emergency (redemption-only settles, no added margin).
    function _lossBreach(VaultStorage storage $) internal view returns (bool) {
        return !$.emergency && $.breached && ($.breachReason == BreachReason.DAILY_LOSS || $.breachReason == BreachReason.DRAWDOWN);
    }

    /// @dev Treasury actions: the manager or the operator.
    function _treasury(VaultStorage storage $) internal view returns (bool) {
        return msg.sender == $.manager || (msg.sender == $.operator && $.operator != address(0));
    }

    /// @dev Platform and owner roles that may unwind a vault in breach or emergency.
    function _platform(VaultStorage storage $, address guardian, address sentinel) internal view returns (bool) {
        return msg.sender == GainsVaultMath.owner() || msg.sender == guardian || msg.sender == sentinel || msg.sender == $.manager;
    }

    // ==================================================================
    // Settlement and fees
    // ==================================================================
    /// @notice Prices the epoch at NAV, mints shares for deposits and reserves USDC for redemptions.
    /// @dev Three modes, for the owner, manager, operator, sentinel and guardian only.
    ///      Normal (the manager or the operator, outside emergency and outside any breach except a leverage one):
    ///      deposits are minted, redemptions paid in full or the call reverts, NAV must be within
    ///      policy.maxNavMoveBps of the keeper's checkpoint.
    ///      Redemption-only (any listed role, in a daily loss or drawdown breach): redemptions are paid in full at
    ///      the current NAV under the same checkpoint bound; nothing is minted and the deposit queue is carried to
    ///      the epoch that prices it once the breach clears (claims follow it in O(1); a carried deposit can be
    ///      cancelled). Audit C-01 stays closed: no share is ever minted at a NAV that may be deflated.
    ///      Exit only (emergency, or once the epoch is overdue; by the owner, manager, operator, sentinel or
    ///      guardian, never by anyone else): queued deposits are refunded, never minted; redemptions are priced at
    ///      min(NAV, checkpoint) and, in emergency, filled pro rata to the liquidity on hand: only the shares that
    ///      were paid for are burned, the rest go back to the redeemers on claim (partial fill + return, audit
    ///      V-01). Nothing rolls into a later epoch except the insiders' next-epoch deposits. The NAV bound never
    ///      blocks an exit. Never while an order that holds collateral is pending on the diamond, timed out or not
    ///      (PLAN.md 4.3 step 3): collateral in flight is never priced (the Gains analog of the bridge window).
    ///      Pending closes, partial closes and leverage increases hold nothing and do not block (GR1-04).
    ///      Two prices (GR1-02): deposits mint at the NAV with every trade at the favourable band edge (the most
    ///      the vault could be worth), redemptions are paid at the adverse edge. Without open trades both are equal.
    function settle(VaultStorage storage $, address guardian, address sentinel) external {
        _enter($);
        bool treasury = msg.sender == $.manager || (msg.sender == $.operator && $.operator != address(0));
        bool platform = msg.sender == GainsVaultMath.owner() || msg.sender == guardian || msg.sender == sentinel;
        if (!treasury && !platform) revert E.Unauthorized();
        if ($.hardStop() && !$.emergency) revert E.ReduceOnlyMode();
        // A daily loss or drawdown breach may be the visible side of a deflated NAV (audit C-01): such a settle is
        // redemption-only (pays redemptions at the current NAV within the checkpoint bound, mints nothing, carries
        // the deposit queue). A leverage breach says nothing about the NAV and settles normally.
        bool redemptionOnly = _lossBreach($);
        bool exitOnly = $.emergency || (!treasury && !redemptionOnly);
        if (exitOnly && !$.emergency && !$.epochOverdue()) revert E.Unauthorized();
        // R3-02, GR1-02: a settle that would PRICE deposits (any depositor, not only insiders) runs at least
        // INSIDER_MIN_EPOCH_AGE into the epoch, so settles cannot be cycled every few minutes around the vault's open
        // trades or Chainlink's lag. Exits are never delayed by it: redemption-only and exit-only settles price no
        // deposit.
        if (
            !exitOnly && !redemptionOnly && ($.insiderInQueue || $.pendingDepositAssets > 0)
                && block.timestamp < uint256($.epochStartedAt) + INSIDER_MIN_EPOCH_AGE
        ) revert E.EpochTooYoung();
        if ($.ordersPending()) revert E.OrdersPending();
        // Nothing below touches the diamond, so the venue is valued once: NAV = idle + venue at every step (round 4
        // read totalAssets() three times; each read is a full GainsNav pass). The favourable edge is only valued when
        // this settle prices deposits.
        GainsNav.Snapshot memory v = $.venue(!exitOnly && !redemptionOnly && $.pendingDepositAssets > 0);
        uint256 venue = v.value;

        // The performance fee crystallises in every settle that prices deposits (GR2-ECON-03): a normal settle and a
        // leverage-breach settle, which mints like a normal one, so a new depositor never buys into an uncharged gain
        // and pays the fee on it later. No performance fee in a loss breach (redemption-only: the NAV may be deflated,
        // audit C-01) or in any exit-only settle (emergency, R3-06, or overdue: redeemers are paid at the capped NAV,
        // so a fee on the uncapped one would charge them for a gain they are not paid, GR2 XF-01): only the
        // management fee accrues there, and the high water mark does not move.
        bool withPerformance = !exitOnly && !redemptionOnly;
        _accrueFees($, withPerformance, venue);
        // A scheduled performance fee raise starts with the next epoch: the running one was just charged at the
        // old rate (audit N2-02).
        uint16 pendingPerf = $.pendingPerformanceFeeBps;
        // Only a settle that charged the running epoch at the old rate switches the raise on (N2-02): the same
        // condition as the charge above. A loss-breach or exit-only settle charges no performance fee, so the raise
        // waits for the next settle that does (R3-06); a leverage-breach settle charges it, so the raise switches.
        if (pendingPerf != 0 && withPerformance) {
            $.performanceFeeBps = pendingPerf;
            $.pendingPerformanceFeeBps = 0;
            emit Ev.FeesUpdated($.managementFeeBps, pendingPerf);
        }

        uint256 nav = $.idleAssets() + venue;
        uint256 priceNav = nav;
        if (exitOnly) {
            priceNav = $.redemptionCap(nav);
        } else {
            // A redemption-only settle pays at min(live NAV, cap), the cap read before the ratchet: a NAV pushed up
            // inside the per-settle bound is never paid out in a loss breach (REAUDIT3 question a), and a checkpoint
            // taken at a dip does not price redemptions at the dip after a rebound (GR2-KEY-06, redemptionCap).
            if (redemptionOnly) priceNav = $.redemptionCap(nav);
            _checkpoint($, nav, true);
        }

        uint256 depAssets = redemptionOnly ? 0 : $.pendingDepositAssets;
        uint256 depIn = exitOnly ? 0 : depAssets;
        uint256 redShares = $.pendingRedeemShares;
        uint256 supply = GainsVaultMath.totalSupply();
        uint256 redAssets = GainsVaultMath.toAssets(redShares, priceNav, supply, Math.Rounding.Floor);
        // Deposits buy at the favourable edge, never below the redemption NAV (GR1-02).
        uint256 depShares = GainsVaultMath.toShares(depIn, Math.max(nav, $.idleAssets() + v.valueHigh), supply, Math.Rounding.Floor);
        if (depShares == 0) depIn = 0; // nothing to mint: refund instead of swallowing the deposit (N-11)

        uint256 available = $.idleAssets() + depIn;
        uint256 paid = redAssets;
        uint256 burned = redShares;
        if (available < redAssets) {
            if (!$.emergency) revert E.InsufficientLiquidity(available, redAssets);
            // Partial fill: burn only the shares the payout covers (rounded down, so the vault never over-burns);
            // the remaining shares are returned to the redeemers when they claim.
            paid = available;
            burned = redShares.mulDiv(paid, redAssets, Math.Rounding.Floor);
        }

        if (burned > 0) GainsVaultMath.burn(address(this), burned);
        if (depShares > 0) GainsVaultMath.mint(address(this), depShares);

        $.claimableRedeemAssets += paid + depAssets - depIn;
        uint256 epoch = $.currentEpoch;
        uint256 carriedFrom;
        if (redemptionOnly) {
            // The deposit queue is carried, not priced: it stays reserved and joins (or opens) the carry run.
            if ($.pendingDepositAssets > 0) {
                if ($.carryOrigin == 0) $.carryOrigin = epoch + 1;
                carriedFrom = $.carryOrigin;
            }
            if ($.deferredDepositAssets > 0) $.insiderInQueue = true;
            $.pendingDepositAssets += $.deferredDepositAssets;
        } else {
            // This settle priced (or refunded) the queue, carried deposits included.
            if ($.carryOrigin != 0) {
                $.carryPricedIn[$.carryOrigin - 1] = epoch + 1;
                $.carryOrigin = 0;
            }
            $.pendingDepositAssets = $.deferredDepositAssets;
            $.insiderInQueue = $.deferredDepositAssets > 0;
        }
        // The insiders' deposits for the next epoch become that epoch's queue.
        $.deferredDepositAssets = 0;
        $.pendingRedeemShares = 0;

        // Flows settle at the share price, so the risk references (day start price, peak) need no adjustment
        // (R-01). A first mint into an empty vault starts them from the new price.
        uint256 navAfter = $.idleAssets() + venue;
        uint256 price = GainsVaultMath.toAssets(ONE_SHARE, navAfter, GainsVaultMath.totalSupply(), Math.Rounding.Floor);
        if (supply == 0 && depShares > 0) {
            $.highWaterMark = price;
            $.peakSharePrice = price;
            $.dayStartSharePrice = price;
        }
        if (price > $.peakSharePrice) $.peakSharePrice = price;

        // Field by field (round 4 used one struct literal): the same record, without holding all nine values on the
        // stack at once, so the library also compiles without the optimizer (coverage builds).
        EpochResult storage er = $.epochs[epoch];
        er.depositAssets = depAssets;
        er.depositShares = depShares;
        er.redeemShares = redShares;
        er.redeemAssets = paid;
        er.redeemBurned = burned;
        er.nav = navAfter;
        er.sharePrice = price;
        er.settledAt = uint64(block.timestamp);
        er.carriedFrom = carriedFrom;
        $.currentEpoch = epoch + 1;
        $.startEpoch();
        // Flows are applied now, so the next bound starts from the post settlement NAV.
        _setCheckpoint($, navAfter);

        emit Ev.EpochSettled(epoch, nav, depAssets, depShares, redShares, paid);
        _exit($);
    }

    /// @notice Accrues the management fee by minting shares. The performance fee only crystallises in settle()
    ///         and the high water mark only moves there (audit M-05 / N-05 / N-08).
    function accrueFees(VaultStorage storage $) external {
        _accrueFees($, false, $.venue().value);
    }

    /// @param venue the GainsNav value of the diamond side, read once by the caller (NAV = idle + venue)
    function _accrueFees(VaultStorage storage $, bool withPerformance, uint256 venue) internal {
        uint256 supply = GainsVaultMath.totalSupply();
        uint256 assets = $.idleAssets() + venue;
        uint256 elapsed = block.timestamp - $.lastFeeAccrual;
        $.lastFeeAccrual = uint64(block.timestamp);
        if (supply == 0 || assets == 0) return;

        uint256 feeAssets = assets.mulDiv(uint256($.managementFeeBps) * elapsed, BPS * YEAR);
        // sharePrice() at the NAV just read (minting moves no assets): one GainsNav pass instead of three.
        uint256 price = GainsVaultMath.priceAt(assets, supply);
        if (withPerformance && price > $.highWaterMark && $.performanceFeeBps > 0) {
            uint256 gain = (price - $.highWaterMark).mulDiv(supply, ONE_SHARE);
            feeAssets += gain.mulDiv($.performanceFeeBps, BPS);
        }

        uint256 feeShares;
        uint256 protocolShares;
        if (feeAssets > 0 && feeAssets < assets) {
            feeShares = feeAssets.mulDiv(supply + 10 ** DECIMALS_OFFSET, assets - feeAssets);
            if ($.factory != address(0) && $.protocolShareBps > 0) {
                address protocolRecipient = IVaultFactory($.factory).protocolFeeRecipient();
                if (protocolRecipient != address(0)) {
                    protocolShares = feeShares.mulDiv($.protocolShareBps, BPS);
                    if (protocolShares > 0) GainsVaultMath.mint(protocolRecipient, protocolShares);
                }
            }
            if (feeShares > protocolShares) GainsVaultMath.mint($.feeRecipient, feeShares - protocolShares);
        }

        uint256 newPrice = GainsVaultMath.priceAt(assets, GainsVaultMath.totalSupply());
        if (withPerformance && newPrice > $.highWaterMark) $.highWaterMark = newPrice;
        // Fee dilution is not a loss: scale both risk references by the same factor (audit L-03, R-01).
        if (feeShares > 0 && newPrice < price) {
            $.peakSharePrice = $.peakSharePrice.mulDiv(newPrice, price);
            $.dayStartSharePrice = $.dayStartSharePrice.mulDiv(newPrice, price);
        }
        emit Ev.FeesAccrued(feeShares, protocolShares, newPrice);
    }

    // ------------------------------------------------------------------
    // NAV checkpoint (rule in GainsVaultPolicy.nextCheckpoint, audit C-01 / N-03 / N-12)
    // ------------------------------------------------------------------
    /// @dev A ratchet keeps the value it replaces as priorCheckpointNav for one interval (GR2-KEY-06, redemptionCap).
    function _checkpoint(VaultStorage storage $, uint256 nav, bool settling) internal {
        uint192 prev = $.checkpointNav;
        (uint256 next, bool update) = $.policy.nextCheckpoint(prev, $.checkpointAt, nav, settling);
        if (update) {
            $.checkpointNav = SafeCast.toUint192(next);
            $.checkpointAt = uint64(block.timestamp);
            $.priorCheckpointNav = prev;
        }
    }

    /// @dev A settle's checkpoint: the post-flow NAV, on a new scale, so the prior value restarts from it too.
    function _setCheckpoint(VaultStorage storage $, uint256 nav) internal {
        $.checkpointNav = SafeCast.toUint192(nav);
        $.checkpointAt = uint64(block.timestamp);
        $.priorCheckpointNav = $.checkpointNav;
    }

    /// @dev Exposed for GainsVaultGovernance.checkRisk (same delegatecall context).
    function checkpoint(VaultStorage storage $, uint256 nav) external {
        _checkpoint($, nav, false);
    }

    // ==================================================================
    // Hosting and protocol share
    // ==================================================================
    /// @notice Leaves the hosted strategy: drops the protocol share to the base rate and revokes the agent. One way.
    function leaveHosted(VaultStorage storage $) external {
        if (msg.sender != GainsVaultMath.owner()) revert E.Unauthorized();
        if (!$.hosted) revert E.NotHosted();
        $.hosted = false;
        if ($.baseShareBps < $.protocolShareBps) $.protocolShareBps = $.baseShareBps;
        _revokeAgent($);
        emit Ev.LeftHosted($.protocolShareBps);
    }

    /// @notice Factory only. Lowers this vault's protocol share. Raising is impossible by construction.
    function lowerProtocolShare(VaultStorage storage $, uint16 newBps) external {
        if (msg.sender != $.factory) revert E.Unauthorized();
        if (newBps >= $.protocolShareBps) revert E.InvalidShare();
        $.protocolShareBps = newBps;
        if (newBps < $.baseShareBps) $.baseShareBps = newBps;
        emit Ev.ProtocolShareLowered(newBps);
    }

    // ==================================================================
    // Trading (PLAN.md 4.2). The manager and the platform agent trade through the vault (decision D1): every new
    // exposure runs policy.checkOrder against Chainlink and GainsNav. Exits (closeTrade, reduceTrade, cancelOrder,
    // cancelTimedOut, flatten) read neither: a stale feed or a down sequencer can never block them.
    // ==================================================================
    /// @notice Opens a market trade (request, filled by Gains' oracle) or places a limit / stop order.
    function openTrade(VaultStorage storage $, OpenParams calldata o) external {
        _newRisk($);
        if (o.collateral == 0 || o.leverage == 0 || o.expectedPrice == 0) revert E.ZeroAmount();
        if (o.tradeType > GTrade.STOP) revert E.OrderRejected("trade type");
        IGainsDiamond d = $.diamond;
        GainsNav.Snapshot memory s = $.venueFor(o.pairIndex);
        if (s.orders >= MAX_POSITIONS) revert E.TooManyPositions(s.orders, MAX_POSITIONS);
        uint256 idle = $.idleAssets();
        if (o.collateral > idle) revert E.InsufficientIdle(idle, o.collateral);
        _lossGate($, idle + s.value);
        uint8 ci = $.collateralIndex;
        _checkOrder(
            $,
            GainsVaultPolicy.Order({
                pair: o.pairIndex,
                long: o.long,
                market: o.tradeType == GTrade.TRADE,
                expectedPrice: o.expectedPrice,
                maxSlippageP: o.maxSlippageP,
                collateral: o.collateral,
                notional: GTrade.positionSize(o.collateral, o.leverage),
                minCollateral: MIN_COLLATERAL_FEE_MULTIPLE * d.getCollateralFromUsdNormalizedValue(ci, d.pairMinFeeUsd(o.pairIndex)),
                nav: idle + s.value,
                openNotional: s.notional
            })
        );
        _checkPairDepth($, o.pairIndex, s.pairNotional + GTrade.positionSize(o.collateral, o.leverage));
        _spendTurnover($, o.pairIndex, idle + s.value, GTrade.positionSize(o.collateral, o.leverage));
        IGainsDiamond.Trade memory t;
        t.user = address(this);
        t.pairIndex = o.pairIndex;
        t.leverage = o.leverage;
        t.long = o.long;
        t.isOpen = true;
        t.collateralIndex = ci;
        t.tradeType = o.tradeType;
        t.collateralAmount = o.collateral;
        t.openPrice = o.expectedPrice;
        t.tp = o.tp;
        t.sl = o.sl;
        _approve($, o.collateral);
        // Referrer: none until Gains confirms how a contract trader is attributed (PLAN.md 4.2).
        d.openTrade(t, o.maxSlippageP, address(0));
        _clearApproval($);
        emit Ev.TradeRequested(o.pairIndex, o.long, o.collateral, o.leverage, o.expectedPrice, o.tradeType, msg.sender);
    }

    /// @notice Adds collateral and / or size to an open trade (request). Same checks as openTrade.
    /// @param collateralDelta 0 = a pure leverage increase on the existing collateral (Gains semantics)
    function increaseTrade(
        VaultStorage storage $,
        uint32 index,
        uint120 collateralDelta,
        uint24 leverageDelta,
        uint64 expectedPrice,
        uint16 maxSlippageP
    ) external {
        _newRisk($);
        if (leverageDelta == 0 || expectedPrice == 0) revert E.ZeroAmount();
        IGainsDiamond.Trade memory t = $.diamond.getTrade(address(this), index);
        _onePending($, index);
        GainsNav.Snapshot memory s = $.venueFor(t.pairIndex);
        if (s.orders >= MAX_POSITIONS) revert E.TooManyPositions(s.orders, MAX_POSITIONS);
        uint256 idle = $.idleAssets();
        if (collateralDelta > idle) revert E.InsufficientIdle(idle, collateralDelta);
        _lossGate($, idle + s.value);
        uint256 added = GTrade.positionSize(collateralDelta == 0 ? t.collateralAmount : collateralDelta, leverageDelta);
        _checkOrder(
            $,
            GainsVaultPolicy.Order({
                pair: t.pairIndex,
                long: t.long,
                market: true,
                expectedPrice: expectedPrice,
                maxSlippageP: maxSlippageP,
                collateral: collateralDelta,
                notional: added,
                minCollateral: 0,
                nav: idle + s.value,
                openNotional: s.notional
            })
        );
        _checkPairDepth($, t.pairIndex, s.pairNotional + added);
        _spendTurnover($, t.pairIndex, idle + s.value, added);
        if (collateralDelta > 0) _approve($, collateralDelta);
        $.diamond.increasePositionSize(index, collateralDelta, leverageDelta, expectedPrice, maxSlippageP);
        if (collateralDelta > 0) _clearApproval($);
        emit Ev.IncreaseRequested(index, collateralDelta, leverageDelta, expectedPrice, msg.sender);
    }

    /// @notice Changes a trade's leverage at constant size (request). Lowering pulls the extra collateral from the
    ///         vault's idle USDC and is allowed in a leverage breach (more margin lowers risk, like bridgeToCore in
    ///         round 4); raising returns collateral and runs the leverage check like a new exposure.
    function updateLeverage(VaultStorage storage $, uint32 index, uint24 newLeverage) external {
        if (!_trader($)) revert E.Unauthorized();
        IGainsDiamond.Trade memory t = $.diamond.getTrade(address(this), index);
        _onePending($, index);
        uint256 delta;
        if (newLeverage < t.leverage) {
            if ($.hardStop() || _lossBreach($)) revert E.ReduceOnlyMode();
            // It holds collateral on the diamond until filled: never once the epoch is overdue (GR1-04).
            if ($.epochOverdue()) revert E.EpochOverdue();
            if (newLeverage == 0) revert E.ZeroAmount();
            // Gains: newCollateral = collateral x leverage / newLeverage (UpdateLeverageLifecycles)
            delta = (uint256(t.collateralAmount) * t.leverage) / newLeverage - t.collateralAmount;
            uint256 idle = $.idleAssets();
            if (delta > idle) revert E.InsufficientIdle(idle, delta);
            _approve($, delta);
            $.diamond.updateLeverage(index, newLeverage);
            _clearApproval($);
        } else {
            _newRisk($);
            GainsNav.Snapshot memory s = $.venue();
            _lossGate($, $.idleAssets() + s.value);
            _checkOrder(
                $,
                GainsVaultPolicy.Order({
                    pair: t.pairIndex,
                    long: t.long,
                    market: false,
                    expectedPrice: t.openPrice,
                    maxSlippageP: 0,
                    collateral: 0,
                    notional: 0,
                    minCollateral: 0,
                    nav: $.idleAssets() + s.value,
                    openNotional: s.notional
                })
            );
            $.diamond.updateLeverage(index, newLeverage);
        }
        emit Ev.LeverageUpdateRequested(index, newLeverage, delta, msg.sender);
    }

    /// @notice Market close of one trade (request). Reduce-only by nature; no NAV or price read.
    /// @param expectedPrice slippage reference for Gains (the trade's closing slippage applies around it)
    function closeTrade(VaultStorage storage $, uint32 index, uint64 expectedPrice, address guardian, address sentinel) external {
        if (!_mayExit($, guardian, sentinel)) revert E.Unauthorized();
        if (_held($, guardian)) _holdTrade($, index);
        $.diamond.closeTradeMarket(index, expectedPrice);
        emit Ev.CloseRequested(index, expectedPrice, msg.sender);
    }

    /// @notice Partial close (request). Reduce-only; no NAV or price read. Outside a breach or emergency the operator
    ///         may reduce only to fund the redemptions (the analog of bridgeToEvm, PLAN.md 5.3): a collateral
    ///         reduce, only while the vault is short of USDC for them, and only up to that shortfall plus the fee
    ///         allowance (computed here, at the request). It still cannot closeTrade outside a breach.
    function reduceTrade(
        VaultStorage storage $,
        uint32 index,
        uint120 collateralDelta,
        uint24 leverageDelta,
        uint64 expectedPrice,
        address guardian,
        address sentinel
    ) external {
        if (!_mayExit($, guardian, sentinel)) {
            if (msg.sender != $.operator || $.operator == address(0)) revert E.Unauthorized();
            uint256 shortfall = GainsVaultMath.redemptionShortfall($);
            // Gains keeps its closing fee from what the reduce returns: the cap carries an allowance for it, only
            // while there is a shortfall at all
            if (leverageDelta != 0 || collateralDelta > operatorReduceCap(shortfall)) revert E.ReduceAboveShortfall(shortfall, collateralDelta);
        } else if (_held($, guardian)) {
            _holdTrade($, index);
        }
        $.diamond.decreasePositionSize(index, collateralDelta, leverageDelta, expectedPrice);
        emit Ev.ReduceRequested(index, collateralDelta, leverageDelta, expectedPrice, msg.sender);
    }

    /// @notice Sets SL and TP (synchronous). The manager and the agent at any time; the sentinel while breached.
    ///         While breached or in emergency a stop loss may only tighten (never removed or widened); the sentinel
    ///         may not touch the take profit.
    function setSlTp(VaultStorage storage $, uint32 index, uint64 sl, uint64 tp, address sentinel) external {
        bool trader = _trader($);
        bool stopped = $.breached || $.emergency;
        if (!trader && !(msg.sender == sentinel && stopped)) revert E.Unauthorized();
        IGainsDiamond.Trade memory t = $.diamond.getTrade(address(this), index);
        if (sl != t.sl) {
            if (stopped && (sl == 0 || (t.sl != 0 && (t.long ? sl < t.sl : sl > t.sl)))) revert E.SlNotTighter();
            $.diamond.updateSl(index, sl);
        }
        if (tp != t.tp) {
            if (!trader) revert E.Unauthorized();
            $.diamond.updateTp(index, tp);
        }
        emit Ev.SlTpUpdated(index, sl, tp, msg.sender);
    }

    /// @notice Cancels a resting limit / stop order; its collateral comes back. Manager, agent or sentinel.
    function cancelOrder(VaultStorage storage $, uint32 index, address sentinel) external {
        if (!_trader($) && msg.sender != sentinel) revert E.Unauthorized();
        $.diamond.cancelOpenOrder(index);
        emit Ev.OrderCancelled(index, msg.sender);
    }

    /// @notice Anyone (the keeper, a depositor): cancels a market order Gains did not fill within its timeout. Only the
    ///         trader can call cancelOrderAfterTimeout, so the vault exposes it (STAGE0.md A3); collateral of an open
    ///         comes back. Permissionless, so no role can hold a settle behind a timed-out order (GR1-04).
    function cancelTimedOut(VaultStorage storage $, uint32 orderIndex) external {
        $.diamond.cancelOrderAfterTimeout(orderIndex);
        emit Ev.TimeoutCancelled(orderIndex, msg.sender);
    }

    /// @notice Closes the open trades of a pair (market close requests) and cancels its resting orders, at most
    ///         `maxTrades` of them per call, so a flatten of many trades can be split across transactions (each close
    ///         request costs about 1.4M gas). No NAV or price read: the caller passes the expected price, and the
    ///         closing slippage around it comes from the policy (audit M-04).
    /// @param slippageBps 0 uses the policy band. A custom bound (at most policy.maxFlattenSlippageBps, itself capped
    ///        at 3%) is the manager's, or the guardian's in emergency (audit N2-03). The manager and the guardian
    ///        flatten at any time; the owner, operator and sentinel while breached or in emergency. Nobody else,
    ///        depositors included: a stranger must not crystallise a temporary loss at the worst moment.
    /// @param maxTrades closes plus resting-order cancels this call may send (> 0); type(uint256).max = all
    /// @return sent closes and cancels sent by this call
    /// @return remaining trades and resting orders of the pair this call left for the next one (not counting those
    ///         with a market order in flight): the next batch, 0 once everything of the pair is closing or cancelled
    /// @dev A trade with a market order already pending on the diamond (a close in flight) is skipped: Gains would
    ///      revert, and one stuck trade must not block the others. That is also what makes batches continue where the
    ///      last one stopped: the trades it closed are in flight. Gains files TP / SL / limit triggers under the bot
    ///      that sent them, so the vault cannot see them; while one is in flight Gains refuses a slippage update or a
    ///      limit cancel for that trade. Both are side steps here (try / catch): the close goes out regardless, at
    ///      the trade's stored slippage, and the resting order stays until the next flatten or cancel (a refused
    ///      cancel still counts as sent, so a stuck order cannot hold a batch forever).
    function flatten(
        VaultStorage storage $,
        uint16 pairIndex,
        uint256 slippageBps,
        uint64 expectedPrice,
        uint256 maxTrades,
        address guardian,
        address sentinel
    ) external returns (uint256 sent, uint256 remaining) {
        _flattenAuth($, slippageBps, guardian, sentinel);
        if (expectedPrice == 0 || maxTrades == 0) revert E.ZeroAmount();
        uint16 slippage = $.policy.flattenSlippage(slippageBps);
        IGainsDiamond d = $.diamond;
        // GR2-KEY-01b: the manager's flatten outside a breach waits out the pair's hold and every trade's own
        if (_held($, guardian)) GainsNav.holdPair($, pairIndex);
        IGainsDiamond.Trade[] memory trades = GainsNav.readTrades(d, address(this));
        IGainsDiamond.PendingOrder[] memory orders = GainsNav.readPendingOrders(d, address(this));
        for (uint256 i; i < trades.length; ++i) {
            IGainsDiamond.Trade memory t = trades[i];
            if (!t.isOpen || t.pairIndex != pairIndex || _hasPending(orders, t.index)) continue;
            if (sent == maxTrades) {
                ++remaining;
                continue;
            }
            ++sent;
            if (t.tradeType != GTrade.TRADE) {
                try d.cancelOpenOrder(t.index) {
                    emit Ev.OrderCancelled(t.index, msg.sender);
                } catch {}
                continue;
            }
            if (d.getTradeInfo(address(this), t.index).maxSlippageP != slippage) {
                try d.updateMaxClosingSlippageP(t.index, slippage) {} catch {}
            }
            d.closeTradeMarket(t.index, expectedPrice);
            emit Ev.Flattened(pairIndex, t.index, expectedPrice, msg.sender);
        }
    }

    /// @notice flatten by trade index, for when Gains' trade list cannot be decoded (a facet upgrade changed its
    ///         layout, GR1-08): decodes nothing. Each index is closed at the market (a resting limit / stop order is
    ///         cancelled instead); an index that is not open, already has an order in flight or is refused by Gains
    ///         is skipped. Same callers and slippage rules as flatten. Indexes come from getTrade / Gains' events.
    /// @return sent closes and cancels Gains accepted
    function flattenIndices(
        VaultStorage storage $,
        uint32[] calldata indices,
        uint256 slippageBps,
        uint64 expectedPrice,
        address guardian,
        address sentinel
    ) external returns (uint256 sent) {
        _flattenAuth($, slippageBps, guardian, sentinel);
        if (expectedPrice == 0 || indices.length == 0) revert E.ZeroAmount();
        // decodes nothing (GR1-08), so the manager's hold here is the vault-wide one (request time)
        if (_held($, guardian)) _checkHold($.lastRiskAt, 0);
        uint16 slippage = $.policy.flattenSlippage(slippageBps);
        IGainsDiamond d = $.diamond;
        for (uint256 i; i < indices.length; ++i) {
            uint32 index = indices[i];
            try d.updateMaxClosingSlippageP(index, slippage) {} catch {}
            try d.closeTradeMarket(index, expectedPrice) {
                ++sent;
                emit Ev.CloseRequested(index, expectedPrice, msg.sender);
            } catch {
                try d.cancelOpenOrder(index) {
                    ++sent;
                    emit Ev.OrderCancelled(index, msg.sender);
                } catch {}
            }
        }
    }

    /// @dev The manager and the guardian flatten at any time; the owner, operator and sentinel while breached or in
    ///      emergency. A custom slippage is the manager's, or the guardian's in emergency (audit N2-03).
    function _flattenAuth(VaultStorage storage $, uint256 slippageBps, address guardian, address sentinel) private view {
        bool isManager = msg.sender == $.manager;
        bool isGuardian = msg.sender == guardian;
        if (!isManager && !_platform($, guardian, sentinel) && !(msg.sender == $.operator && $.operator != address(0))) {
            revert E.Unauthorized();
        }
        if (slippageBps != 0) {
            if (!isManager && !(isGuardian && $.emergency)) revert E.Unauthorized();
        } else if (!isManager && !isGuardian && !$.breached && !$.emergency) {
            revert E.Unauthorized();
        }
    }

    /// @dev Gains allows one pending market order per trade; the vault refuses a second one itself, so no check ever
    ///      runs against a trade whose earlier request has not filled yet (GR1-01).
    function _onePending(VaultStorage storage $, uint32 index) private view {
        if (GainsNav.hasPendingOrder($.diamond, address(this), index)) revert E.PendingOrderExists(index);
    }

    function _hasPending(IGainsDiamond.PendingOrder[] memory orders, uint32 index) private pure returns (bool) {
        for (uint256 i; i < orders.length; ++i) {
            if (orders[i].isOpen && orders[i].orderType != GTrade.MARKET_OPEN && orders[i].trade.index == index) return true;
        }
        return false;
    }

    /// @dev The manager or the platform agent.
    function _trader(VaultStorage storage $) internal view returns (bool) {
        return msg.sender == $.manager || (msg.sender == $.agent && $.agent != address(0));
    }

    /// @dev New exposure: the manager or the agent, not paused, not in any breach or emergency, and not once the epoch
    ///      is overdue (GR1-04): from then on an exit-only settle may run, and no new order may hold collateral in
    ///      flight in front of it.
    function _newRisk(VaultStorage storage $) internal view {
        if (!_trader($)) revert E.Unauthorized();
        if ($.breached || $.emergency) revert E.ReduceOnlyMode();
        if ($.tradingPaused) revert E.TradingIsPaused();
        if ($.epochOverdue()) revert E.EpochOverdue();
    }

    /// @dev Exit callers (the round 4 flatten rule): the manager, the agent and the guardian at any time; the owner,
    ///      operator and sentinel while breached or in emergency.
    function _mayExit(VaultStorage storage $, address guardian, address sentinel) internal view returns (bool) {
        if (_trader($) || msg.sender == guardian) return true;
        bool isOperator = msg.sender == $.operator && $.operator != address(0);
        return (msg.sender == GainsVaultMath.owner() || msg.sender == sentinel || isOperator) && ($.breached || $.emergency);
    }

    function _checkOrder(VaultStorage storage $, GainsVaultPolicy.Order memory o) internal view {
        (bool ok, string memory reason) = $.policy.checkOrder(o);
        if (!ok) revert E.OrderRejected(reason);
    }

    /// @dev GR2-KEY-01: the vault's notional on `pair` after this order (open + resting + pending + new, USD at the
    ///      Chainlink price) within the pair's cap of its 1 % skew depth: the factory's per-pair cap (GR2-KEY-01b),
    ///      DEFAULT_PAIR_SKEW_CAP_BPS on a standalone vault. A pair with a zero cap or without skew depth takes no new
    ///      risk: fail closed.
    function _checkPairDepth(VaultStorage storage $, uint16 pair, uint256 pairNotional) internal view {
        uint256 capBps = $.factory == address(0) ? DEFAULT_PAIR_SKEW_CAP_BPS : IGainsPairCaps($.factory).pairSkewCapBps(pair);
        if (capBps == 0) revert E.OrderRejected("pair cap");
        uint256 depth = $.diamond.getPairSkewDepth($.collateralIndex, pair);
        if (depth == 0) revert E.OrderRejected("no skew depth");
        // depth tokens (1e18) x Chainlink price (1e10) -> USD in collateral units (1e6), like GainsNav's notional
        uint256 cap = Math.mulDiv(depth, $.policy.price(pair), 1e22) * capBps / BPS;
        // GR2 XF-04: Gains' own open-interest cap of the pair (collateral precision) bounds a depth read in the wrong
        // units (from the HL review's GAINS-OPENTRADE ceiling); 0 = none set.
        uint256 maxOi = $.diamond.getPairMaxOiCollateral($.collateralIndex, pair);
        if (maxOi != 0 && cap > maxOi) cap = maxOi;
        if (pairNotional > cap) revert E.OrderRejected("pair depth");
    }

    /// @dev GR2-KEY-01: the daily loss and drawdown limits are enforced before new risk, at the NAV this order was
    ///      checked against (no second NAV read): the same metrics as GainsVaultGovernance._check (R-01), a new UTC day
    ///      counting from the current price. Refuses only; the breach itself is recorded by the next checkRisk.
    function _lossGate(VaultStorage storage $, uint256 equity) internal view {
        uint256 supply = GainsVaultMath.totalSupply();
        if (supply == 0 || equity < MIN_RISK_NAV) return;
        uint256 price = GainsVaultMath.priceAt(equity, supply);
        (, uint256 maxDaily, uint256 maxDd) = $.policy.riskLimits();
        uint256 start = block.timestamp / 1 days == $.riskDay ? $.dayStartSharePrice : price;
        if (start > price && (start - price).mulDiv(BPS, start) > maxDaily) revert E.ReduceOnlyMode();
        uint256 peak = $.peakSharePrice;
        if (peak > price && (peak - price).mulDiv(BPS, peak) > maxDd) revert E.ReduceOnlyMode();
    }

    /// @dev GR2-KEY-01b turnover budget and hold stamps (GainsNav.spendTurnover, kept out of this library for size).
    function _spendTurnover(VaultStorage storage $, uint16 pair, uint256 nav, uint256 notional) internal {
        GainsNav.spendTurnover($, pair, nav, notional);
    }

    /// @dev GR2-KEY-01b: an exit by the manager or the agent outside a breach or emergency (never the guardian's, the
    ///      operator's or any exit in a breach or emergency) waits out the minimum hold.
    function _held(VaultStorage storage $, address guardian) internal view returns (bool) {
        return msg.sender != guardian && !$.breached && !$.emergency && _trader($);
    }

    function _holdTrade(VaultStorage storage $, uint32 index) internal view {
        GainsNav.holdTrade($, index);
    }

    function _checkHold(uint256 riskAt, uint256 increaseBlock) internal view {
        GainsNav.checkHold(riskAt, increaseBlock);
    }

    /// @dev Exactly the collateral of one request, never unlimited (PLAN.md 4.2); cleared after the call.
    function _approve(VaultStorage storage $, uint256 amount) internal {
        $.asset.forceApprove(address($.diamond), amount);
    }

    function _clearApproval(VaultStorage storage $) internal {
        if ($.asset.allowance(address(this), address($.diamond)) != 0) $.asset.forceApprove(address($.diamond), 0);
    }

    // ==================================================================
    // Agent (platform trading wallet, decision D1: it calls the vault, never a Gains delegate)
    // ==================================================================
    /// @dev Factory vaults accept only the platform agent the factory bound to this vault (audit N-07).
    function setAgent(VaultStorage storage $, address newAgent) external {
        _storeAgent($, newAgent);
    }

    function _storeAgent(VaultStorage storage $, address newAgent) internal {
        if (newAgent == address(0)) revert E.ZeroAddress();
        if ($.factory != address(0) && IVaultFactory($.factory).platformAgentFor(newAgent) != address(this)) {
            revert E.NotPlatformAgent();
        }
        $.agent = newAgent;
        emit Ev.AgentSet(newAgent);
    }

    function revokeAgent(VaultStorage storage $) external {
        _revokeAgent($);
    }

    /// @dev The agent is a vault caller only, so clearing the slot revokes it.
    function _revokeAgent(VaultStorage storage $) internal {
        address old = $.agent;
        if (old == address(0)) return;
        $.agent = address(0);
        emit Ev.AgentRevoked(old);
    }

    // ------------------------------------------------------------------
    // Reentrancy guard. The asset is a trusted token and every other call goes to the gTrade diamond, the factory
    // or the policy clone; the guard covers the entry points that move shares and settle.
    // ------------------------------------------------------------------
    function _enter(VaultStorage storage $) internal {
        if ($.lock == 1) revert E.Reentrancy();
        $.lock = 1;
    }

    function _exit(VaultStorage storage $) internal {
        $.lock = 0;
    }
}
