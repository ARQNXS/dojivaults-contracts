// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import "./LifecycleForkBase.sol";

/// @notice Task 3: the policy applies no price band to limit / stop triggers (AUDIT-DIFF deviation 8). Can a
///         compromised agent place a limit / stop (or a TP / SL) on the wrong side of the market to transfer value to
///         Gains LPs? Measured on the real diamond with the bot trigger path.
contract LC_LimitStopForkTest is LifecycleForkBase {
    bytes32 internal constant TRIGGER_CANCELED = keccak256("TriggerOrderCanceled((address,uint32),address,uint8,uint8)");
    uint8 internal constant CANCEL_SLIPPAGE = 3;

    struct Outcome {
        bool executed;
        uint64 execPrice; // open price Gains stored (after spread / impact)
        uint256 oraclePrice;
        bool exact;
        uint8 cancelReason;
        uint32 idx;
    }

    /// @dev Places a resting order at `trigger`, triggers it with the bot, answers with a tight range around C
    ///      (+-5 bps) and returns what Gains did.
    function _placeAndTrigger(uint16 pair, bool long, uint8 tradeType, uint64 trigger) internal returns (Outcome memory r) {
        OpenParams memory p = _openParams(pair, long, 1_000e6, 5_000);
        p.tradeType = tradeType;
        p.expectedPrice = trigger;
        vm.prank(mgr); // the agent has the same power
        v.openTrade(p);
        IGainsDiamond.Trade[] memory ts = D.getTrades(address(v));
        r.idx = ts[ts.length - 1].index;
        assertEq(ts[ts.length - 1].tradeType, tradeType, "resting");
        _rollFresh(10);
        Vm.Log[] memory req = _trigger(bot, tradeType == 1 ? T_LIMIT_OPEN : T_STOP_OPEN, r.idx);
        _rollFresh(1);
        uint64 c = cl[_feed(pair)];
        Vm.Log[] memory fill = _fillRange(req, c, c * 10_005 / 10_000, c * 9_995 / 10_000);
        if (_count(fill, G.LimitExecuted.selector) > 0) {
            G.Trade memory t;
            (t,, r.oraclePrice,,, r.exact) = _limitExecuted(fill);
            r.execPrice = t.openPrice;
            r.executed = true;
        } else {
            Vm.Log memory l = _find(fill, TRIGGER_CANCELED);
            (,, r.cancelReason) = abi.decode(l.data, (G.Id, uint8, uint8));
        }
    }

    function _bps(uint256 a, uint256 b) internal pure returns (int256) {
        return (int256(a) - int256(b)) * 10_000 / int256(b);
    }

    /// @dev A LIMIT long far ABOVE the market (better-than-market trigger) is not an exact execution: Gains executes
    ///      it at the oracle's current price, so the 2C trigger transfers nothing.
    function test_lc_limitLongFarAboveMarket_executesAtMarket() public {
        _depositSettle(alice, 10_000e6);
        uint64 c = cl[ETH_USD];
        Outcome memory r = _placeAndTrigger(ETH, true, 1, c * 2);
        console2.log("LIMIT long @2C: exec price", r.execPrice, "C", c);
        assertTrue(r.executed);
        assertFalse(r.exact, "not an exact execution");
        assertEq(r.oraclePrice, c, "executed at the oracle's current price, not at the 2C trigger");
        assertLt(r.execPrice, c * 1_001 / 1_000, "within the spread of C");
    }

    function test_lc_limitShortFarBelowMarket_executesAtMarket() public {
        _depositSettle(alice, 10_000e6);
        uint64 c = cl[BTC_USD];
        Outcome memory r = _placeAndTrigger(BTC, false, 1, c / 2);
        console2.log("LIMIT short @C/2: exec price", r.execPrice, "C", c);
        assertTrue(r.executed);
        assertFalse(r.exact);
        assertEq(r.oraclePrice, c);
        assertGt(r.execPrice, c * 999 / 1_000);
    }

    /// @dev A STOP on the wrong side (long stop far BELOW the market) is hit at once, but the market price is far
    ///      above the stored open price + the order's slippage: Gains cancels the trigger (SLIPPAGE). Nothing executes;
    ///      the bot loses its LINK, the order keeps resting.
    function test_lc_stopLongFarBelowMarket_cancelledBySlippage() public {
        _depositSettle(alice, 10_000e6);
        uint64 c = cl[ETH_USD];
        uint256 usdc0 = _usdc();
        Outcome memory r = _placeAndTrigger(ETH, true, 2, c / 2);
        assertFalse(r.executed, "not executed");
        assertEq(r.cancelReason, CANCEL_SLIPPAGE);
        assertTrue(_trade(r.idx).isOpen && _trade(r.idx).tradeType == 2, "still resting");
        assertEq(_usdc(), usdc0 - 1_000e6, "collateral still resting, nothing lost");
    }

    function test_lc_stopShortFarAboveMarket_cancelledBySlippage() public {
        _depositSettle(alice, 10_000e6);
        uint64 c = cl[BTC_USD];
        Outcome memory r = _placeAndTrigger(BTC, false, 2, c * 2);
        assertFalse(r.executed);
        assertEq(r.cancelReason, CANCEL_SLIPPAGE);
    }

    /// @dev The worst case: a LIMIT long whose trigger sits inside the oracle's lookback range above the current
    ///      price executes EXACTLY at the trigger (Gains' guaranteed execution). The loss is bounded by the range the
    ///      price really travelled since the order was placed, not by the agent.
    function test_lc_limitLongInsideRange_exactExecutionCostBoundedByRange() public {
        _depositSettle(alice, 10_000e6);
        uint64 c = cl[ETH_USD];
        uint64 trigger = c * 10_004 / 10_000; // +4 bps, inside the +5 bps range high
        Outcome memory r = _placeAndTrigger(ETH, true, 1, trigger);
        console2.log("LIMIT long inside range: exec", r.execPrice, "oracle", r.oraclePrice);
        console2.logInt(_bps(r.execPrice, c));
        assertTrue(r.executed && r.exact, "exact execution at the trigger");
        assertLe(r.oraclePrice, c * 10_005 / 10_000, "never beyond the range high");
    }

    /// @dev TP / SL on the wrong side of the market (long TP below C, long SL above C): Gains stores them unchecked
    ///      (updateTradeTp has no validation; updateTradeSl only clamps the loss side) and a bot can trigger them at
    ///      once. They execute at the oracle's current price (not exact: the trigger is outside the range), i.e. a
    ///      market close, not a transfer.
    function test_lc_wrongSideTakeProfit_executesAsMarketClose() public {
        _depositSettle(alice, 10_000e6);
        uint32 idx = _openFilledV(ETH, true, 1_000e6, 5_000);
        uint64 c = cl[ETH_USD];
        vm.prank(mgr);
        v.setSlTp(idx, 0, c * 90 / 100); // TP 10% BELOW the market for a long
        assertEq(_trade(idx).tp, c * 90 / 100, "accepted by Gains");
        _rollFresh(10);
        uint256 navBefore = _nav();
        Vm.Log[] memory req = _trigger(bot, T_TP, idx);
        _rollFresh(1);
        uint256 b0 = _usdc();
        Vm.Log[] memory fill = _fillRange(req, c, c * 10_005 / 10_000, c * 9_995 / 10_000);
        (, uint8 ot, uint256 oracle,, uint256 sent, bool exact) = _limitExecuted(fill);
        assertEq(ot, T_TP);
        assertFalse(exact, "TP outside the range: not exact");
        assertEq(oracle, c, "closed at the current oracle price");
        assertEq(_usdc() - b0, sent);
        console2.log("wrong-side TP: paid", sent, "NAV before (at P)", navBefore);
        assertGe(_nav() + 1, navBefore, "closing at C is never below the NAV at the adverse edge P");
    }

    function test_lc_wrongSideStopLoss_executesAsMarketClose() public {
        _depositSettle(alice, 10_000e6);
        uint32 idx = _openFilledV(ETH, true, 1_000e6, 5_000);
        uint64 c = cl[ETH_USD];
        vm.prank(mgr);
        v.setSlTp(idx, c * 110 / 100, 0); // SL 10% ABOVE the market for a long
        assertEq(_trade(idx).sl, c * 110 / 100);
        _rollFresh(10);
        uint256 navBefore = _nav();
        Vm.Log[] memory req = _trigger(bot, T_SL, idx);
        _rollFresh(1);
        Vm.Log[] memory fill = _fillRange(req, c, c * 10_005 / 10_000, c * 9_995 / 10_000);
        if (_count(fill, G.LimitExecuted.selector) > 0) {
            (, uint8 ot, uint256 oracle,,, bool exact) = _limitExecuted(fill);
            assertEq(ot, T_SL);
            assertFalse(exact);
            assertEq(oracle, c);
            assertGe(_nav() + 1, navBefore, "a market close at C");
            console2.log("wrong-side SL: executed as a market close at C");
        } else {
            // Gains: execution price (C) below sl - closing slippage -> SLIPPAGE cancel, the trade stays open
            (,, uint8 reason) = abi.decode(_find(fill, TRIGGER_CANCELED).data, (G.Id, uint8, uint8));
            assertEq(reason, CANCEL_SLIPPAGE);
            assertTrue(_trade(idx).isOpen, "nothing executed");
            console2.log("wrong-side SL: trigger cancelled (SLIPPAGE), trade still open");
        }
    }
}
