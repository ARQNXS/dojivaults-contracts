// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import "./LifecycleForkBase.sol";

/// @notice Task 4: OrdersPending griefing and trigger griefing, measured on the real diamond.
contract LC_GriefForkTest is LifecycleForkBase {
    uint8 internal constant CANCEL_SLIPPAGE = 3;

    function _setupEmergencyWithRedemptions() internal returns (uint32 e1, uint32 e2) {
        _depositSettle(alice, 10_000e6);
        e1 = _openFilledV(ETH, true, 1_000e6, 3_000);
        e2 = _openFilledV(ETH, true, 1_000e6, 3_000);
        uint256 shares = v.balanceOf(alice);
        vm.prank(alice);
        v.requestRedeem(shares, alice, alice);
        vm.prank(fGuardian);
        v.triggerEmergency();
        assertTrue(v.emergency());
    }

    function _totalRealized(uint32 idx) internal view returns (int256 r) {
        (,, r) = D.getTradeRealizedPnlCollateral(address(v), idx);
    }

    function _closeCancelReason(Vm.Log[] memory fill) internal pure returns (uint8 reason) {
        (, reason) = abi.decode(_find(fill, G.MarketCloseCanceled.selector).data, (G.Id, uint8));
    }

    function _settleReverts(address who) internal {
        vm.prank(who);
        vm.expectRevert(IGainsVaultErrors.OrdersPending.selector);
        v.settle();
    }

    // ------------------------------------------------------------------ LC-02: decoy closes keep emergency settle blocked
    /// @notice Was the GR1-04 PoC `test_lc_LC02_staggeredDecoyClosesBlockEmergencySettle` (in emergency the manager
    ///         kept one slippage-cancelled close per trade in flight, staggered, and settle reverted OrdersPending in
    ///         every mode). A pending close holds no collateral: it no longer holds settle, so the guardian's
    ///         exit-only settle goes through with a decoy in flight. flatten still skips a trade with a close in flight
    ///         and reports 0 remaining (GR1-27, unchanged).
    function test_GR1_04_decoyClosesDoNotHoldEmergencySettle() public {
        (uint32 e1, uint32 e2) = _setupEmergencyWithRedemptions();
        uint64 decoy = cl[ETH_USD] * 2; // a long's close is cancelled if the fill is below expected - 1%

        (uint256 g1, Vm.Log[] memory d1) = _gas(mgr, abi.encodeCall(GainsVault.closeTrade, (e1, decoy)));
        console2.log("gas of one decoy close request (manager)", g1);
        _rollFresh(2);
        _req(mgr, abi.encodeCall(GainsVault.closeTrade, (e2, decoy)));
        assertEq(_pending().length, 2, "two decoys in flight");
        assertFalse(v.ordersPending(), "GR1-04: closes do not count as orders that hold settle");
        vm.prank(fGuardian);
        (uint256 sent, uint256 remaining) = v.flatten(ETH, 0, cl[ETH_USD], type(uint256).max);
        assertEq(sent, 0, "flatten skips every trade with a decoy in flight");
        assertEq(remaining, 0, "and reports nothing left (GR1-27)");
        uint256 epoch = v.currentEpoch();
        vm.prank(fGuardian);
        v.settle(); // the emergency exit-only settle, decoys still in flight
        assertEq(v.currentEpoch(), epoch + 1, "GR1-04: settled with the decoys in flight");
        uint256 b = USDC.balanceOf(alice);
        v.claim(alice);
        assertGt(USDC.balanceOf(alice) - b, 0, "alice is paid from the idle USDC");
        // a decoy answered after the settle is harmless
        _rollFresh(2);
        Vm.Log[] memory f = _fill(d1, cl[ETH_USD]);
        assertEq(_closeCancelReason(f), CANCEL_SLIPPAGE, "decoy cancelled, trade stays open");
    }

    /// @dev The guardian / sentinel wins a race (its flatten lands after a decoy's fill and before the re-send):
    ///      that trade closes and the manager loses a decoy slot; once every trade is closed no decoy is possible
    ///      (Gains: close of a closed index reverts DoesntExist; opens, increases and leverage changes are refused in
    ///      emergency) and the exit-only settle goes through.
    function test_lc_LC02_guardianWinsTheRace_thenSettle() public {
        (uint32 e1, uint32 e2) = _setupEmergencyWithRedemptions();
        uint64 decoy = cl[ETH_USD] * 2;
        Vm.Log[] memory d1 = _req(mgr, abi.encodeCall(GainsVault.closeTrade, (e1, decoy)));
        _rollFresh(2);
        _fill(d1, cl[ETH_USD]);
        // race lost by the manager: the sentinel's flatten (hot key, allowed in emergency) closes both
        Vm.Log[] memory fl = _req(fSentinel, abi.encodeCall(GainsVault.flatten, (ETH, uint256(0), cl[ETH_USD], type(uint256).max)));
        vm.prank(mgr);
        vm.expectRevert(); // ConflictingPendingOrder: the trade already has the sentinel's close in flight
        v.closeTrade(e1, decoy);
        _rollFresh(2);
        _fill(fl, cl[ETH_USD]);
        assertFalse(_trade(e1).isOpen || _trade(e2).isOpen);
        vm.prank(mgr);
        vm.expectRevert(); // DoesntExist
        v.closeTrade(e1, decoy);
        vm.prank(mgr);
        vm.expectRevert(IGainsVaultErrors.ReduceOnlyMode.selector);
        v.openTrade(_openParams(ETH, true, 100e6, 2_000));
        vm.prank(fGuardian);
        v.settle();
        v.claim(alice);
        assertGt(USDC.balanceOf(alice), 190_000e6, "alice paid");
    }

    /// @notice Was `test_lc_LC02_everyExitRoleCanHoldSettle` (GR1-04: the owner's close and the operator's collateral
    ///         reduce each held the emergency settle). Neither holds collateral, so neither holds settle now; the
    ///         operator is still revocable at once.
    function test_GR1_04_exitRoleClosesAndReducesDoNotHoldSettle() public {
        (uint32 e1, uint32 e2) = _setupEmergencyWithRedemptions();
        uint64 decoy = cl[ETH_USD] * 2;
        _req(creator, abi.encodeCall(GainsVault.closeTrade, (e1, decoy))); // vault owner
        _req(keeper, abi.encodeCall(GainsVault.reduceTrade, (e2, uint120(1e6), uint24(0), decoy))); // operator
        assertEq(_pending().length, 2);
        assertFalse(v.ordersPending(), "a close and a collateral reduce hold nothing");
        uint256 epoch = v.currentEpoch();
        vm.prank(fGuardian);
        v.settle();
        assertEq(v.currentEpoch(), epoch + 1, "GR1-04: the exit-only settle runs");
        vm.prank(fSentinel);
        v.revokeOperator();
        vm.prank(keeper);
        vm.expectRevert(IGainsVaultErrors.Unauthorized.selector);
        v.closeTrade(e1, decoy);
    }

    /// @dev Cost of the cheapest decoy that does not cancel: a 1 USDC collateral reduce at a sane expected price fills
    ///      and pays Gains' closing fee on the min position basis.
    function test_lc_LC02_decoyCosts_reduceThatFills() public {
        (uint32 e1,) = _setupEmergencyWithRedemptions();
        uint256 b0 = _usdc();
        int256 r0 = _totalRealized(e1);
        Vm.Log[] memory d = _req(mgr, abi.encodeCall(GainsVault.reduceTrade, (e1, uint120(1e6), uint24(0), cl[ETH_USD])));
        _rollFresh(2);
        _fill(d, cl[ETH_USD]);
        console2.log("1 USDC reduce decoy: USDC back", _usdc() - b0);
        console2.log("  cost of the decoy (1 USDC - USDC back)", 1e6 - (_usdc() - b0));
        console2.logInt(_totalRealized(e1) - r0);
    }

    // ------------------------------------------------------------------ overdue epoch + emergency
    /// @notice Was `test_lc_overdueEmergencyStillBlockedByPendingClose` (GR1-04: a pending close held the overdue
    ///         emergency settle). It does not any more.
    function test_GR1_04_overdueEmergencyNotBlockedByPendingClose() public {
        _depositSettle(alice, 10_000e6);
        uint32 e1 = _openFilledV(ETH, true, 1_000e6, 3_000);
        uint256 shares = v.balanceOf(alice);
        vm.prank(alice);
        v.requestRedeem(shares, alice, alice);
        _rollFresh(7 days * 4 + 10); // past maxEpochDuration (7 days, 4 blocks per second)
        _req(mgr, abi.encodeCall(GainsVault.closeTrade, (e1, cl[ETH_USD] * 2)));
        vm.prank(stranger);
        v.triggerEmergency(); // anyone: overdue with redemptions pending
        assertTrue(v.emergency());
        uint256 epoch = v.currentEpoch();
        vm.prank(fSentinel);
        v.settle();
        assertEq(v.currentEpoch(), epoch + 1, "GR1-04: settled with the close in flight");
    }

    /// @notice GR1-04, the orders that still hold settle (they hold collateral): an open in flight holds the overdue
    ///         settle for at most one Gains timeout. Once the epoch is overdue no new collateral-holding order can be
    ///         sent (EpochOverdue: open, increase, leverage raise and decrease), and after the timeout anyone cancels
    ///         the stuck open (cancelTimedOut is permissionless) and the settle runs.
    function test_GR1_04_openInFlightHoldsSettleAtMostOneTimeout() public {
        _depositSettle(alice, 10_000e6);
        uint32 e1 = _openFilledV(ETH, true, 1_000e6, 3_000);
        uint256 shares = v.balanceOf(alice);
        vm.prank(alice);
        v.requestRedeem(shares, alice, alice);
        _req(mgr, abi.encodeCall(GainsVault.openTrade, (_openParams(ETH, true, 500e6, 2_000)))); // never answered
        assertTrue(v.ordersPending(), "a market open holds collateral");
        _rollFresh(7 days * 4 + 10);
        bytes[] memory calls = new bytes[](4);
        calls[0] = abi.encodeCall(GainsVault.openTrade, (_openParams(ETH, true, 100e6, 2_000)));
        calls[1] = abi.encodeCall(GainsVault.increaseTrade, (e1, uint120(100e6), uint24(1_000), cl[ETH_USD], uint16(1_000)));
        calls[2] = abi.encodeCall(GainsVault.updateLeverage, (e1, uint24(4_000)));
        calls[3] = abi.encodeCall(GainsVault.updateLeverage, (e1, uint24(2_000)));
        for (uint256 i; i < calls.length; ++i) {
            (bool ok, bytes memory ret) = _try(mgr, calls[i]);
            assertFalse(ok);
            assertEq(_sel(ret), IGainsVaultErrors.EpochOverdue.selector, "GR1-04: no new order once overdue");
        }
        vm.prank(stranger);
        v.triggerEmergency();
        _settleReverts(fGuardian);
        uint32 orderIndex = _lastPending().index;
        vm.prank(stranger);
        v.cancelTimedOut(orderIndex); // anyone, after Gains' timeout
        assertFalse(v.ordersPending());
        uint256 epoch = v.currentEpoch();
        vm.prank(fGuardian);
        v.settle();
        assertEq(v.currentEpoch(), epoch + 1, "settled once the stuck open is cancelled");
    }

    // ------------------------------------------------------------------ nobody else can create a vault-owned pending order
    function test_lc_strangerCannotCreateVaultPendingOrders() public {
        _depositSettle(alice, 10_000e6);
        uint32 e1 = _openFilledV(ETH, true, 1_000e6, 3_000);
        bytes[] memory calls = new bytes[](6);
        calls[0] = abi.encodeCall(GainsVault.closeTrade, (e1, cl[ETH_USD]));
        calls[1] = abi.encodeCall(GainsVault.reduceTrade, (e1, uint120(1e6), uint24(0), cl[ETH_USD]));
        calls[2] = abi.encodeCall(GainsVault.flatten, (ETH, uint256(0), cl[ETH_USD], type(uint256).max));
        calls[3] = abi.encodeCall(GainsVault.openTrade, (_openParams(ETH, true, 100e6, 2_000)));
        calls[4] = abi.encodeCall(GainsVault.increaseTrade, (e1, uint120(10e6), uint24(1_000), cl[ETH_USD], uint16(1_000)));
        calls[5] = abi.encodeCall(GainsVault.updateLeverage, (e1, uint24(2_000)));
        for (uint256 i; i < calls.length; ++i) {
            (bool ok, bytes memory ret) = _try(stranger, calls[i]);
            assertFalse(ok);
            assertEq(_sel(ret), IGainsVaultErrors.Unauthorized.selector);
        }
        // a bot's trigger is filed under the bot, never under the vault: settle is not blocked by it
        vm.prank(mgr);
        v.setSlTp(e1, cl[ETH_USD] * 90 / 100, 0);
        _trigger(stranger, T_SL, e1);
        assertFalse(v.ordersPending(), "trigger orders are not the vault's pending orders");
        assertEq(_pending().length, 0);
    }

    // ------------------------------------------------------------------ LC-03: 1 LINK trigger blocks setSlTp / cancelOrder
    /// @dev Anyone can file a trigger order on the vault's trade for 1 LINK (no price check at request). While it is
    ///      active (until the oracle answers, at most triggerTimeoutBlocks = 20), Gains refuses updateSl / updateTp /
    ///      cancelOpenOrder (PendingTrigger). GainsVaultLogic.setSlTp and cancelOrder have no fallback: the sentinel's
    ///      SL tightening in a breach and a resting-order cancel revert. Closes and flatten are unaffected.
    function test_lc_LC03_strangerTriggerBlocksSlTighteningAndLimitCancel() public {
        _depositSettle(alice, 10_000e6);
        uint32 idx = _openFilledV(ETH, true, 1_000e6, 5_000);
        uint64 c = cl[ETH_USD];
        vm.prank(mgr);
        v.setSlTp(idx, c * 90 / 100, c * 120 / 100);
        // resting limit far from the market (not hit)
        OpenParams memory p = _openParams(ETH, true, 500e6, 5_000);
        p.tradeType = 1;
        p.expectedPrice = c * 80 / 100;
        vm.prank(mgr);
        v.openTrade(p);
        IGainsDiamond.Trade[] memory ts = D.getTrades(address(v));
        uint32 lim = ts[ts.length - 1].index;
        _rollFresh(30);

        address link = IGainsTriggerLC(address(D)).getChainlinkToken();
        uint256 linkBefore = IERC20(link).balanceOf(address(D));
        Vm.Log[] memory slReq = _trigger(stranger, T_SL, idx); // 1 LINK, NOT_HIT at the answer
        _trigger(stranger, T_LIMIT_OPEN, lim); // 1 LINK
        console2.log("LINK paid by the griefer (1e18)", IERC20(link).balanceOf(address(D)) - linkBefore);
        // fix round: the breach now cancels resting opens (GR1-16); with the trigger filed first that cancel is refused
        // (PendingTrigger, best effort) and the limit survives the breach
        vm.prank(fSentinel);
        v.triggerBreach();
        assertTrue(_trade(lim).isOpen, "the breach's resting-order cancel was refused while the trigger is active");

        vm.prank(fSentinel);
        vm.expectRevert(); // Gains PendingTrigger
        v.setSlTp(idx, c * 95 / 100, c * 120 / 100); // the sentinel's breach-time SL tightening
        vm.prank(fSentinel);
        vm.expectRevert(); // PendingTrigger
        v.cancelOrder(lim);
        // exits still go out
        vm.prank(fSentinel);
        (uint256 sent,) = v.flatten(ETH, 0, c, type(uint256).max);
        assertEq(sent, 2, "flatten: the close goes out, the refused limit cancel counts as sent");
        assertTrue(_trade(lim).isOpen, "the resting limit survived the flatten");

        // once the oracle answers the SL trigger (NOT_HIT) the block lifts for that trade
        _rollFresh(1);
        _fill(slReq, c);
        assertEq(IGainsTriggerLC(address(D)).getTradePendingOrderBlock(IGainsDiamond.Id(address(v), idx), T_SL), 0, "cleared at the answer");
    }

    /// @dev Without an answer the trigger stays active for triggerTimeoutBlocks; measure it.
    function test_lc_LC03_triggerWindowWithoutAnswer() public {
        _depositSettle(alice, 10_000e6);
        uint32 idx = _openFilledV(ETH, true, 1_000e6, 5_000);
        uint64 c = cl[ETH_USD];
        vm.prank(mgr);
        v.setSlTp(idx, c * 90 / 100, 0);
        _rollFresh(30);
        _trigger(stranger, T_SL, idx);
        uint256 blocked;
        for (uint256 i; i < 40; ++i) {
            (bool ok,) = _try(mgr, abi.encodeCall(GainsVault.setSlTp, (idx, c * 91 / 100, uint64(0))));
            if (ok) break;
            ++blocked;
            _rollFresh(1);
        }
        console2.log("blocks setSlTp stayed blocked without an oracle answer", blocked);
        assertGt(blocked, 0);
        assertLe(blocked, 20);
    }

    /// @dev An SL trigger needs an SL on the trade (Gains NoSl); a LIQ trigger is always possible but does not block
    ///      SL / TP updates.
    function test_lc_LC03_preconditions() public {
        _depositSettle(alice, 10_000e6);
        uint32 idx = _openFilledV(ETH, true, 1_000e6, 5_000);
        address link = IGainsTriggerLC(address(D)).getChainlinkToken();
        deal(link, stranger, 10e18);
        vm.prank(stranger);
        IERC20(link).approve(address(D), type(uint256).max);
        uint256 packed = uint256(T_SL) | (uint256(uint160(address(v))) << 8) | (uint256(idx) << 168);
        vm.prank(stranger);
        vm.expectRevert(); // NoSl
        IGainsTriggerLC(address(D)).triggerOrder(packed);
        _trigger(stranger, T_LIQ, idx);
        vm.prank(mgr);
        v.setSlTp(idx, cl[ETH_USD] * 90 / 100, 0); // not blocked by a LIQ trigger
    }
    // ------------------------------------------------------------------ GR2-LIVE-01 follow-up (WP5)
    /// @dev Can anyone but the vault's own calls grow its unseen index range? A stranger's Gains triggers on the vault's
    ///      trade and resting limit (SL, LIMIT_OPEN, then TP and LIQ once the SL is answered), each paid in LINK: the
    ///      vault's TRADE and PENDING_ORDER counters must not move. The stranger's own pending counter is logged, to show
    ///      where Gains files a trigger.
    function test_GR2_LIVE_01_strangerTriggersDoNotConsumeTheVaultsIndexes() public {
        _depositSettle(alice, 10_000e6);
        uint32 idx = _openFilledV(ETH, true, 1_000e6, 5_000);
        uint64 c = cl[ETH_USD];
        vm.prank(mgr);
        v.setSlTp(idx, c * 90 / 100, c * 120 / 100);
        OpenParams memory p = _openParams(ETH, true, 500e6, 5_000);
        p.tradeType = 1;
        p.expectedPrice = c * 80 / 100;
        vm.prank(mgr);
        v.openTrade(p);
        IGainsDiamond.Trade[] memory ts = D.getTrades(address(v));
        uint32 lim = ts[ts.length - 1].index;
        _rollFresh(30);

        IGainsDiamond.Counter memory t0 = D.getCounters(address(v), 0);
        IGainsDiamond.Counter memory o0 = D.getCounters(address(v), 1);
        uint32 s0 = D.getCounters(stranger, 1).currentIndex;
        Vm.Log[] memory slReq = _trigger(stranger, T_SL, idx);
        _trigger(stranger, T_LIMIT_OPEN, lim);
        uint32 s1 = D.getCounters(stranger, 1).currentIndex;
        console2.log("vault TRADE counter / PENDING_ORDER counter before the triggers", t0.currentIndex, o0.currentIndex);
        console2.log("stranger PENDING_ORDER counter before / with two triggers in flight", s0, s1);
        assertEq(D.getCounters(address(v), 0).currentIndex, t0.currentIndex, "triggers file no trade under the vault");
        assertEq(D.getCounters(address(v), 1).currentIndex, o0.currentIndex, "triggers file no pending order under the vault");

        _rollFresh(1);
        _fill(slReq, c); // NOT_HIT
        _rollFresh(30);
        _trigger(stranger, T_TP, idx);
        _trigger(stranger, T_LIQ, idx);
        console2.log("stranger PENDING_ORDER counter after TP and LIQ triggers", D.getCounters(stranger, 1).currentIndex);
        assertEq(D.getCounters(address(v), 0).currentIndex, t0.currentIndex, "still no trade index consumed");
        assertEq(D.getCounters(address(v), 1).currentIndex, o0.currentIndex, "still no pending index consumed");
    }
}
