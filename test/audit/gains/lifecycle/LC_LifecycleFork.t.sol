// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import "./LifecycleForkBase.sol";
import {NavCalc} from "../../../gains/spike/NavCalc.sol";

/// @notice Task 2: collateral in flight, timeouts and late fills, double cancels, Gains-side executions while a
///         vault order is pending, index bookkeeping. All on the real diamond.
contract LC_LifecycleForkTest is LifecycleForkBase {
    /// @dev An oracle answer that may revert (late answer to a closed order). Returns whether every answer went in.
    function _tryFill(Vm.Log[] memory requestLogs, uint64 price) internal returns (uint256 ok, uint256 failed) {
        for (uint256 i; i < requestLogs.length; i++) {
            Vm.Log memory l = requestLogs[i];
            if (l.topics[0] != ORACLE_REQUEST) continue;
            (address requester, bytes32 requestId) = abi.decode(l.data, (address, bytes32));
            if (requester != address(DIAMOND)) continue;
            vm.prank(l.emitter);
            try DIAMOND.fulfill(requestId, _packAnswer(price)) {
                ok++;
            } catch {
                failed++;
            }
        }
    }

    // ------------------------------------------------------------------ fill after the timeout, before any cancel
    function test_lc_fillAfterTimeoutBeforeCancel_executes_thenCancelReverts() public {
        _depositSettle(alice, 10_000e6);
        uint256 navBefore = _nav();
        Vm.Log[] memory req = _req(mgr, abi.encodeCall(GainsVault.openTrade, (_openParams(ETH, true, 1_000e6, 5_000))));
        uint32 orderIndex = _lastPending().index;
        _rollFresh(250);
        assertEq(lens.timedOutOrders(v).length, 1, "timed out");
        uint256 navPending = _nav();
        assertApproxEqAbs(navPending, navBefore, 1e5, "held collateral counted (minus the gov fee) while timed out");
        Vm.Log[] memory fill = _fill(req, cl[ETH_USD]);
        assertEq(_count(fill, G.MarketExecuted.selector), 1, "a late answer still opens the trade");
        assertFalse(v.ordersPending());
        vm.prank(stranger);
        vm.expectRevert(); // Gains: NoOrder
        v.cancelTimedOut(orderIndex);
        assertEq(D.getTrades(address(v)).length, 1);
    }

    // ------------------------------------------------------------------ double cancel, cancel after fill, late answer after cancel
    function test_lc_timedOutCancel_twice_andLateAnswerAfterCancel() public {
        _depositSettle(alice, 10_000e6);
        uint256 usdc0 = _usdc();
        Vm.Log[] memory req = _req(mgr, abi.encodeCall(GainsVault.openTrade, (_openParams(ETH, true, 1_000e6, 5_000))));
        uint32 orderIndex = _lastPending().index;
        _rollFresh(200);
        vm.prank(stranger);
        v.cancelTimedOut(orderIndex);
        assertEq(_usdc(), usdc0, "full refund, no fee on the timeout path");
        vm.prank(stranger);
        vm.expectRevert(); // NoOrder
        v.cancelTimedOut(orderIndex);
        // the oracle answers after the cancel: nothing happens to the vault
        (uint256 ok, uint256 failed) = _tryFill(req, cl[ETH_USD]);
        console2.log("late answers after cancel: accepted / reverted", ok, failed);
        assertEq(_usdc(), usdc0, "a late answer to a cancelled order moves no USDC");
        assertEq(D.getTrades(address(v)).length, 0, "and opens no trade");
        assertFalse(v.ordersPending());
    }

    function test_lc_cancelOfFilledOrder_reverts() public {
        _depositSettle(alice, 10_000e6);
        Vm.Log[] memory req = _req(mgr, abi.encodeCall(GainsVault.openTrade, (_openParams(ETH, true, 1_000e6, 5_000))));
        uint32 orderIndex = _lastPending().index;
        _rollFresh(1);
        _fill(req, cl[ETH_USD]);
        _rollFresh(200);
        uint256 usdc0 = _usdc();
        vm.prank(stranger);
        vm.expectRevert();
        v.cancelTimedOut(orderIndex);
        assertEq(_usdc(), usdc0);
    }

    function test_lc_limitCancelledTwice_secondReverts() public {
        _depositSettle(alice, 10_000e6);
        OpenParams memory p = _openParams(ETH, true, 1_000e6, 5_000);
        p.tradeType = 1;
        p.expectedPrice = cl[ETH_USD] * 95 / 100;
        uint256 usdc0 = _usdc();
        vm.prank(mgr);
        v.openTrade(p);
        uint32 idx = D.getTrades(address(v))[0].index;
        vm.prank(fSentinel);
        v.cancelOrder(idx);
        assertEq(_usdc(), usdc0, "limit collateral back in full");
        vm.prank(mgr);
        vm.expectRevert();
        v.cancelOrder(idx);
        assertEq(_usdc(), usdc0);
    }

    // ------------------------------------------------------------------ timed-out close
    /// @dev A timed-out MARKET_CLOSE keeps tradePendingOrderBlock: a new close reverts at Gains, flatten skips the trade
    ///      and reports remaining = 0 although the trade is still open. Only cancelTimedOut (anyone) unblocks it.
    function test_lc_timedOutClose_blocksNewCloseAndFlattenReportsZeroRemaining() public {
        _depositSettle(alice, 10_000e6);
        uint32 idx = _openFilledV(ETH, true, 1_000e6, 5_000);
        _passHold(); // GR2-KEY-01b (WP5 port): the manager's exit waits the 10-minute minimum hold
        _req(mgr, abi.encodeCall(GainsVault.closeTrade, (idx, cl[ETH_USD])));
        uint32 orderIndex = _lastPending().index;
        _rollFresh(200);
        vm.prank(mgr);
        vm.expectRevert(); // Gains ConflictingPendingOrder(MARKET_CLOSE)
        v.closeTrade(idx, cl[ETH_USD]);
        vm.prank(fGuardian);
        (uint256 sent, uint256 remaining) = v.flatten(ETH, 0, cl[ETH_USD], type(uint256).max);
        assertEq(sent, 0);
        assertEq(remaining, 0, "flatten reports nothing left while the trade is open behind a dead close");
        assertTrue(_trade(idx).isOpen);
        vm.prank(stranger);
        v.cancelTimedOut(orderIndex);
        Vm.Log[] memory req = _req(fGuardian, abi.encodeCall(GainsVault.flatten, (ETH, uint256(0), cl[ETH_USD], type(uint256).max)));
        _rollFresh(1);
        _fill(req, cl[ETH_USD]);
        assertFalse(_trade(idx).isOpen, "closed after the cancel");
    }

    // ------------------------------------------------------------------ Gains-side executions while a vault order is pending
    /// @dev A bot's SL closes the trade while the vault's reduce is pending. The reduce later fills as NO_TRADE (no fee,
    ///      no payout). In between, redemptionShortfall still counts the dead reduce's delta as USDC on its way.
    function test_lc_stopLossWhileReducePending() public {
        _depositSettle(alice, 10_000e6);
        uint32 idx = _openFilledV(BTC, false, 1_000e6, 5_000);
        uint64 sl = cl[BTC_USD] * 102 / 100;
        vm.prank(mgr);
        v.setSlTp(idx, sl, 0);
        // a redemption of about 1,500 USDC on a vault that holds about 9,000 idle: no shortfall yet
        uint256 shares = v.balanceOf(alice) / 2;
        vm.prank(alice);
        v.requestRedeem(shares, alice, alice);
        _passHold(); // GR2-KEY-01b (WP5 port): the manager's exit waits the 10-minute minimum hold
        Vm.Log[] memory reduceReq = _req(mgr, abi.encodeCall(GainsVault.reduceTrade, (idx, uint120(300e6), uint24(0), cl[BTC_USD])));
        _rollFresh(100);
        _setCl(BTC_USD, _round(sl));
        Vm.Log[] memory slReq = _trigger(bot, T_SL, idx);
        _rollFresh(1);
        uint256 b0 = _usdc();
        Vm.Log[] memory fill = _fillRange(slReq, sl * 1001 / 1000, sl * 1001 / 1000, sl * 999 / 1000);
        (, uint8 ot,,, uint256 sent,) = _limitExecuted(fill);
        assertEq(ot, T_SL);
        assertEq(_usdc() - b0, sent, "SL paid to the vault, unknown to the vault");
        assertFalse(_trade(idx).isOpen);
        assertEq(_pending().length, 1, "the vault's reduce is still pending on a closed trade");
        assertFalse(v.ordersPending(), "fix round (GR1-04): a pending reduce holds nothing and does not hold settle");
        uint256 navMid = _nav();
        assertEq(navMid, v.idleAssets(), "NAV = idle: the closed trade and the dead reduce are worth 0");
        // the reduce of the closed trade fills as a no-op
        uint256 b1 = _usdc();
        Vm.Log[] memory rf = _fill(reduceReq, sl);
        assertEq(_usdc(), b1, "no payout, no fee");
        console2.log("reduce on a closed trade: PositionSizeDecreaseExecuted events", _count(rf, G.PositionSizeDecreaseExecuted.selector));
        assertFalse(v.ordersPending());
        assertEq(_nav(), navMid);
    }

    /// @dev Liquidation while an UPDATE_LEVERAGE decrease is pending: Gains keeps the closed trade's fields, so the
    ///      callback (NO_TRADE) and the timeout path both return the margin that was pulled; GainsNav counts it.
    function test_lc_liquidationWhileLeverageDecreasePending_marginRefunded() public {
        _leverageDecreaseThenLiquidate(false);
    }

    function test_lc_liquidationWhileLeverageDecreasePending_timeoutRefund() public {
        _leverageDecreaseThenLiquidate(true);
    }

    function _leverageDecreaseThenLiquidate(bool viaTimeout) internal {
        _depositSettle(alice, 10_000e6);
        uint32 idx = _openFilledV(ETH, true, 100e6, 50_000);
        uint256 liq = NavCalc.liquidationPrice(DIAMOND, DIAMOND.getTrade(address(v), idx), cl[ETH_USD]);
        Vm.Log[] memory levReq = _req(mgr, abi.encodeCall(GainsVault.updateLeverage, (idx, uint24(25_000))));
        IGainsDiamond.PendingOrder memory o = _lastPending();
        assertEq(o.trade.collateralAmount, 100e6, "margin pulled: 100 x 50 / 25 - 100");
        uint32 levOrder = o.index;
        uint64 crash = uint64(liq * 99 / 100);
        _setCl(ETH_USD, _round(crash));
        Vm.Log[] memory liqReq = _trigger(bot, T_LIQ, idx);
        _rollFresh(1);
        _fill(liqReq, crash);
        assertFalse(_trade(idx).isOpen, "liquidated");
        assertEq(_trade(idx).leverage, 50_000, "closed trade keeps its fields");
        uint256 navMid = _nav();
        uint256 idleMid = v.idleAssets();
        console2.log("after liquidation, pending margin counted in NAV", navMid - idleMid);
        assertGt(navMid - idleMid, 99e6, "held margin (minus the gov fee) still counted");
        uint256 b0 = _usdc();
        if (viaTimeout) {
            _rollFresh(200);
            vm.prank(stranger);
            v.cancelTimedOut(levOrder);
        } else {
            _fill(levReq, crash);
        }
        assertEq(_usdc() - b0, 100e6, "margin returned in full");
        assertFalse(v.ordersPending());
        assertGe(_nav() + 1, navMid, "NAV never above what came back");
    }

    function test_lc_liquidationWhileIncreasePending_collateralRefunded() public {
        _depositSettle(alice, 10_000e6);
        uint32 idx = _openFilledV(ETH, true, 100e6, 50_000);
        uint256 liq = NavCalc.liquidationPrice(DIAMOND, DIAMOND.getTrade(address(v), idx), cl[ETH_USD]);
        Vm.Log[] memory incReq = _req(mgr, abi.encodeCall(GainsVault.increaseTrade, (idx, uint120(200e6), uint24(10_000), cl[ETH_USD], uint16(1_000))));
        uint64 crash = uint64(liq * 99 / 100);
        _setCl(ETH_USD, _round(crash));
        Vm.Log[] memory liqReq = _trigger(bot, T_LIQ, idx);
        _rollFresh(1);
        _fill(liqReq, crash);
        assertFalse(_trade(idx).isOpen);
        uint256 b0 = _usdc();
        _fill(incReq, crash);
        assertEq(_usdc() - b0, 200e6, "the increase's collateral comes back in full (NO_TRADE, no gov fee)");
        assertFalse(v.ordersPending());
    }

    // ------------------------------------------------------------------ index bookkeeping
    /// @dev Gains trade and pending-order indexes are counters: never reused after a close. A pending MARKET_OPEN
    ///      carries trade.index = 0, which flatten's _hasPending excludes, so trade 0 is still flattened.
    function test_lc_indexesNeverReused_andPendingOpenDoesNotShieldTradeZero() public {
        _depositSettle(alice, 10_000e6);
        uint32 i0 = _openFilledV(ETH, true, 500e6, 5_000);
        uint32 i1 = _openFilledV(ETH, false, 500e6, 5_000);
        _passHold(); // GR2-KEY-01b (WP5 port): the manager's exit waits the 10-minute minimum hold
        Vm.Log[] memory req = _req(mgr, abi.encodeCall(GainsVault.closeTrade, (i0, cl[ETH_USD])));
        _rollFresh(1);
        _fill(req, cl[ETH_USD]);
        uint32 i2 = _openFilledV(ETH, true, 500e6, 5_000);
        console2.log("trade indexes", i0, i1, i2);
        assertGt(i2, i1, "a closed index is never reused");
        // pending MARKET_OPEN (trade.index 0 in the pending order) next to an open trade with index i2 / i1
        _req(mgr, abi.encodeCall(GainsVault.openTrade, (_openParams(ETH, true, 500e6, 5_000))));
        IGainsDiamond.PendingOrder memory po = _lastPending();
        assertEq(po.orderType, 0);
        assertEq(po.trade.index, 0, "pending open has trade.index 0");
        vm.prank(fGuardian);
        (uint256 sent,) = v.flatten(ETH, 0, cl[ETH_USD], type(uint256).max);
        assertEq(sent, 2, "both open trades flattened, the pending open does not shield anything");
    }

    function test_lc_indexZeroTradeNotSkippedByPendingOpen() public {
        // Fresh vault, so the first trade gets index 0.
        _depositSettle(alice, 10_000e6);
        uint32 i0 = _openFilledV(BTC, true, 500e6, 5_000);
        assertEq(i0, 0, "first trade of the vault has index 0");
        _req(mgr, abi.encodeCall(GainsVault.openTrade, (_openParams(BTC, false, 500e6, 5_000))));
        vm.prank(fGuardian);
        (uint256 sent,) = v.flatten(BTC, 0, cl[BTC_USD], type(uint256).max);
        assertEq(sent, 1, "trade 0 flattened despite the pending open with trade.index 0");
    }

    /// @dev Gains fills at its oracle price, not the expected price: the size in tokens follows the fill price and
    ///      GainsNav's notional (positionSizeToken x Chainlink) follows it.
    function test_lc_fillAtDifferentPrice_sizeInTokensFollowsFill() public {
        _depositSettle(alice, 10_000e6);
        Vm.Log[] memory req = _req(mgr, abi.encodeCall(GainsVault.openTrade, (_openParams(ETH, true, 1_000e6, 5_000))));
        uint256 pendingNotional = v.venue().notional;
        assertEq(pendingNotional, 5_000e6, "pending: collateral x leverage");
        _rollFresh(1);
        uint64 fillPx = cl[ETH_USD] * 9_950 / 10_000; // 0.5% better than expected
        _fill(req, fillPx);
        uint256 n = v.venue().notional;
        console2.log("notional at C after a fill 0.5% below C", n);
        assertGt(n, pendingNotional, "more tokens bought at the lower fill, valued at C");
        assertApproxEqRel(n, uint256(5_000e6) * 10_000 / 9_950, 0.003e18);
    }
}

