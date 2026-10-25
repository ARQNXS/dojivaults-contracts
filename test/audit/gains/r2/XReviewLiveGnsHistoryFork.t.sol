// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import "./liveness/LiveLifecycleBase.sol";

/// @notice Cross-review of GR2-LIVE-01 (XREVIEW-LIVE-GNS.md). Real gTrade v10 diamond on an Arbitrum One fork
///         (LIVE_FORK_BLOCK or GAINS_FORK_BLOCK = tip - ~40). The lifetime trade counter is moved with vm.store exactly as in
///         LivenessHistoryFork.t.sol (TradingStorage slot 301, userCounters at +8), checked through getCounters.
///
///         The question these tests answer: LIVENESS.md jumps the counter to N with vm.store, but a real vault can only
///         consume a trade index through its own openTrade (no trading delegate, Gains files every trade under
///         msg.sender), and openTrade itself runs the full GainsNav snapshot, i.e. the same getTrades walk. So the
///         largest counter a vault can ever reach is bounded by openTrade's own gas, and the cheapest exit settle (flat
///         vault, emergency exit-only) must be compared against THAT, not against an arbitrary N.
contract XReviewLiveGnsHistoryForkTest is LiveLifecycleBase {
    uint256 internal constant TS_SLOT = 301;
    uint256 internal constant COUNTERS_SLOT = TS_SLOT + 8;

    function _counterSlot(address t, uint8 kind) internal pure returns (bytes32) {
        return keccak256(abi.encode(uint256(kind), keccak256(abi.encode(t, COUNTERS_SLOT))));
    }

    function _counter(address t, uint8 kind) internal view returns (uint32 current, uint32 open) {
        G.Counter memory c = DIAMOND.getCounters(t, kind);
        return (c.currentIndex, c.openCount);
    }

    function _setCounter(address t, uint8 kind, uint32 current, uint32 open) internal {
        bytes32 slot = _counterSlot(t, kind);
        uint256 word = uint256(vm.load(address(DIAMOND), slot));
        word = (word & ~uint256(type(uint64).max)) | uint256(current) | (uint256(open) << 32);
        vm.store(address(DIAMOND), slot, bytes32(word));
        (uint32 c, uint32 o) = _counter(t, kind);
        assertEq(c, current, "getCounters.currentIndex follows the slot");
        assertEq(o, open, "getCounters.openCount follows the slot");
    }

    /// @dev Smallest gas limit (to 1,000 gas) at which `caller` -> vault.call(data) succeeds. Every attempt runs from
    ///      the same snapshot, so storage the walk reads is cold on each attempt (forge 1.8: each top-level call
    ///      starts cold; the first attempt's cost is logged against a repeat to show it).
    function _minGas(address caller, bytes memory data, uint256 lo, uint256 hi) internal returns (uint256) {
        uint256 snap = vm.snapshotState();
        vm.prank(caller);
        (bool okHi,) = address(v).call{gas: hi}(data);
        vm.revertToState(snap);
        require(okHi, "succeeds at hi");
        while (hi - lo > 1_000) {
            uint256 mid = (lo + hi) / 2;
            vm.prank(caller);
            (bool ok,) = address(v).call{gas: mid}(data);
            vm.revertToState(snap);
            if (ok) hi = mid;
            else lo = mid;
        }
        return hi;
    }

    function _restingLimit() internal view returns (OpenParams memory p) {
        p = _openParams(ETH, true, 100e6, 3_000);
        p.tradeType = 1; // LIMIT, far below the market: rests, consumes one trade index, no Gains fee
        p.expectedPrice = (cl[ETH_USD] * 80) / 100;
    }

    struct Row {
        uint256 n;
        uint256 open; // min gas: the grinder's openTrade at counter n (flat vault, cheapest possible open)
        uint256 settleExit; // min gas: guardian exit-only settle in emergency, flat vault, counter n + 21
        uint256 settleNormal; // min gas: keeper normal settle, flat vault, counter n + 21
        uint256 emergency; // min gas: guardian triggerEmergency, counter n + 21
    }

    function _row(uint32 c0, uint32 n) internal returns (Row memory r) {
        r.n = n;
        uint256 base = vm.snapshotState();
        _setCounter(address(v), 0, c0 + n, 0);
        bytes memory open = abi.encodeCall(GainsVault.openTrade, (_restingLimit()));
        r.open = _minGas(mgr, open, 100_000, 30_000_000);

        // The grinder's last open fitted at counter n. Worst case after it: up to 20 market opens requested at n (each
        // request walks n, the trade index is assigned at Gains' fill, which walks nothing) fill, plus this limit:
        // counter n + 21, all closed again (closes read no list). The vault is flat.
        // GR2-LIVE-01 fix (WP5): the open that fitted RAN, so (unlike the pre-fix vault, which kept no state about what
        // it had read) its sync left the vault's cursor at n; the probe above reverted it, so it is sent once for real
        // and the limit cancelled (flat again). The 21 indexes after it are the only unseen ones.
        vm.prank(mgr);
        v.openTrade(_restingLimit());
        IGainsDiamond.Trade[] memory rest = D.getTrades(address(v));
        vm.prank(mgr);
        v.cancelOrder(rest[0].index);
        _setCounter(address(v), 0, c0 + n + 21, 0);
        uint256 flat = vm.snapshotState();

        // End to end at the grinder's own budget: the guardian's emergency and exit-only settle each fit in r.open.
        vm.prank(fGuardian);
        (bool okE,) = address(v).call{gas: r.open}(abi.encodeCall(GainsVault.triggerEmergency, ()));
        assertTrue(okE, "triggerEmergency fits in the gas of the last open that fitted");
        vm.prank(fGuardian);
        (bool okS,) = address(v).call{gas: r.open}(abi.encodeCall(GainsVault.settle, ()));
        assertTrue(okS, "the exit-only settle of the flat vault fits in the gas of the last open that fitted");
        assertEq(v.pendingRedeemShares(), 0, "the redemption was settled");
        vm.revertToState(flat);

        r.settleNormal = _minGas(keeper, abi.encodeCall(GainsVault.settle, ()), 100_000, 30_000_000);
        r.emergency = _minGas(fGuardian, abi.encodeCall(GainsVault.triggerEmergency, ()), 50_000, 30_000_000);
        vm.prank(fGuardian);
        v.triggerEmergency();
        r.settleExit = _minGas(fGuardian, abi.encodeCall(GainsVault.settle, ()), 100_000, 30_000_000);
        vm.revertToState(base);

        console2.log("counter n", n);
        console2.log("  min gas openTrade(limit) at n          ", r.open);
        console2.log("  min gas exit-only settle (flat) at n+21", r.settleExit);
        console2.log("  min gas normal settle (flat) at n+21   ", r.settleNormal);
        console2.log("  min gas triggerEmergency at n+21       ", r.emergency);
        assertGt(r.open, r.settleExit, "open needs more than the flat exit-only settle 21 indexes later");
        assertGt(r.open, r.settleNormal, "and more than the flat normal settle");
    }

    /// @dev GR2-LIVE-01 fix, inverted from the cross-review PoC
    ///      `test_GR2_XR_LIVE01_openTradeWalksTheSameList_lockOnlyInANarrowBandBelowTheOpenCeiling`: how far can a vault's
    ///      counter get, and where does the flat exit settle stop fitting? Pre-fix (block 516,425,211, XREVIEW-LIVE-GNS.md
    ///      1.3) the open and the flat exit settle both walked every lifetime index: open 1,906,701 / 4,366,734 and exit
    ///      settle 1,648,470 / 4,142,265 at counters 500 / 1,500, slopes 2,460 / 2,493 per index, so a narrow lock band
    ///      opened just under the open's 32M ceiling (open stops at ~12,732, exit settle at ~12,670). On the fixed vault
    ///      the PoC FAILED at 517,076,707 (WP5 fork2 log, fork2-all-fork.txt): "triggerEmergency fits in the gas of the
    ///      last open that fitted" (its min-gas probe left the cursor at the start, so every exit pulled the whole jump).
    ///      With the open sent (the vault's cursor follows it) the exits 21 indexes later pull those 21 only: they are
    ///      flat in the counter, so the margin to the open grows and no lock band exists.
    ///      XR_N1 / XR_N2 set the sizes (each index is one RPC fetch on the public node).
    function test_GR2_XR_LIVE01_fix_openTradeWalksTheSameList_noLockBandBelowTheOpenCeiling() public {
        _depositSettle(alice, 20_000e6);
        uint256 shares = v.balanceOf(alice) / 10;
        vm.prank(alice);
        v.requestRedeem(shares, alice, alice);
        _rollFresh(10);
        v.checkRisk();
        (uint32 c0,) = _counter(address(v), 0);

        // WP5: 200 / 600 (were 500 / 1,500): the fixed vault's open pulls each unseen index with one getTrade (about
        // 32,000 gas cold, LivenessHistoryFork), so an open after a 1,500 jump no longer fits _minGas's 30M ceiling
        Row memory a = _row(c0, uint32(vm.envOr("XR_N1", uint256(200))));
        Row memory b = _row(c0, uint32(vm.envOr("XR_N2", uint256(600))));

        uint256 dn = b.n - a.n;
        uint256 slopeOpen = (b.open - a.open) / dn;
        int256 dExit = int256(b.settleExit) - int256(a.settleExit);
        int256 dNormal = int256(b.settleNormal) - int256(a.settleNormal);
        console2.log("min-gas slope per index: open", slopeOpen);
        console2.log("exit settle / normal settle change from n1 to n2 (gas)");
        console2.logInt(dExit);
        console2.logInt(dNormal);
        int256 mA = int256(a.open) - int256(a.settleExit);
        int256 mB = int256(b.open) - int256(b.settleExit);
        console2.log("margin open - exit settle at n1 / n2");
        console2.logInt(mA);
        console2.logInt(mB);
        // The unseen range is walked by the open (it grows with the counter), the exits 21 indexes later pull 21 only.
        assertGt(slopeOpen, 2_000, "the open after a counter jump still pulls the unseen range");
        assertLt(dExit, int256(dn) * 100, "the flat exit-only settle no longer grows with the counter (< 100 gas per index)");
        assertLt(dNormal, int256(dn) * 100, "nor the flat normal settle");
        assertGt(mB, mA, "the margin to the open grows with the counter: no lock band below the open's ceiling");
        assertLt(b.settleExit, 4_000_000, "the flat exit-only settle after 21 unseen indexes stays far below 32M");
    }

    /// @dev GR2-LIVE-01 fix, inverted from the cross-review PoC `test_GR2_XR_LIVE01_getTradesStopsAtTheLastOpenTrade`
    ///      (Gains' getTrades stops at the last open trade: a vault whose only open trade is old did not pay for 50,000
    ///      later indexes, settle 956,869 at counter idx+1 and 961,369 at idx+50,001, block 516,425,211). The fixed vault
    ///      no longer calls getTrades: it reads its own index set plus the unseen range [cursor, counter). On it the PoC
    ///      FAILED at 517,076,707 (WP5 fork2 log, fork2-all-fork.txt): "EvmError: Revert" after 1,024,526,535 gas, the
    ///      settle pulling all 50,000 jumped indexes. A real vault cannot jump its counter (every call that takes an index
    ///      syncs), and anyone can pull an unseen range in bounded batches with syncIndexes(maxSteps). Asserted: after a
    ///      jump of LIVE_N indexes (default 2,000; each one RPC fetch), batches of 500 each fit far below 32M, and settle
    ///      then costs what it cost before the jump.
    function test_GR2_XR_LIVE01_fix_oldOpenTrade_settleFlatOnceTheUnseenRangeIsSynced() public {
        _depositSettle(alice, 20_000e6);
        uint32 idx = _openFilledV(ETH, true, 1_000e6, 3_000);
        uint256 shares = v.balanceOf(alice) / 10;
        vm.prank(alice);
        v.requestRedeem(shares, alice, alice);
        _rollFresh(10);
        v.checkRisk();
        uint256 snap = vm.snapshotState();
        (uint256 g0,) = _gas(keeper, abi.encodeCall(GainsVault.settle, ()));
        vm.revertToState(snap);
        (uint32 c,) = _counter(address(v), 0);
        assertEq(c, idx + 1);
        uint32 n = uint32(vm.envOr("LIVE_N", uint256(2_000)));
        _setCounter(address(v), 0, c + n, 1); // n later indexes, all closed; the open trade is the old one
        uint256 worst = _syncInBatches(n);
        console2.log("syncIndexes(500) worst batch gas, n", worst, n);
        (uint32 tc,, uint32[] memory tracked,) = v.indexSet();
        assertEq(tc, c + n, "cursor at Gains' counter");
        assertEq(tracked.length, 1, "the old open trade is the one tracked index");
        (uint256 g1,) = _gas(keeper, abi.encodeCall(GainsVault.settle, ()));
        console2.log("settle, one open trade at a low index: counter idx+1 / idx+1+n after the sync", g0, g1);
        assertLt(g1, g0 + 50_000, "no walk past what the vault has seen");
    }


    /// @dev GR2-LIVE-01 fix, inverted from the cross-review PoC `test_GR2_XR_LIVE01_pendingCounterIsFreeOnceNothingIsPending`
    ///      (Gains' getPendingOrders returns at once when nothing is pending: the pending counter raised by 1,000,000
    ///      moved settle from 387,064 to 391,564, block 516,425,211). The fixed vault reads pending orders by index from
    ///      its cursor, not getPendingOrders; on it the PoC FAILED at 517,076,707 (WP5 fork2 log): "EvmError: Revert"
    ///      after 1,024,276,545 gas, the settle pulling the whole jumped range. Closes and reduces sync MAX_POSITIONS
    ///      steps each (XF-03), so their own pending indexes never pile up; a jumped range is pulled by syncIndexes in
    ///      bounded batches, after which settle costs what it cost before. LIVE_N (default 2,000) sets the jump.
    function test_GR2_XR_LIVE01_fix_pendingCounter_settleFlatOnceTheUnseenRangeIsSynced() public {
        _depositSettle(alice, 20_000e6);
        uint256 shares = v.balanceOf(alice) / 10;
        vm.prank(alice);
        v.requestRedeem(shares, alice, alice);
        _rollFresh(10);
        v.checkRisk();
        uint256 snap = vm.snapshotState();
        (uint256 g0,) = _gas(keeper, abi.encodeCall(GainsVault.settle, ()));
        vm.revertToState(snap);
        (uint32 p,) = _counter(address(v), 1);
        uint32 n = uint32(vm.envOr("LIVE_N", uint256(2_000)));
        _setCounter(address(v), 1, p + n, 0);
        uint256 worst = _syncInBatches(n);
        console2.log("syncIndexes(500) worst batch gas, n", worst, n);
        (, uint32 oc,, uint32[] memory orders) = v.indexSet();
        assertEq(oc, p + n, "order cursor at Gains' counter");
        assertEq(orders.length, 0, "nothing pending, nothing tracked");
        (uint256 g1,) = _gas(keeper, abi.encodeCall(GainsVault.settle, ()));
        console2.log("settle, flat: pending counter +0 / +n after the sync (none open)", g0, g1);
        assertLt(g1, g0 + 20_000);
    }

    /// @dev Who can consume the vault's indexes: Gains files a trade under msg.sender (or a trading delegate the trader
    ///      set). The vault never sets one, and only the manager / agent reach vault.openTrade.
    function test_GR2_XR_LIVE01_onlyManagerOrAgentConsumeIndexes() public {
        _depositSettle(alice, 20_000e6);
        assertEq(DIAMOND.getTradingDelegate(address(v)), address(0), "no trading delegate");
        (uint32 c0,) = _counter(address(v), 0);
        OpenParams memory p = _restingLimit();
        address[4] memory who = [stranger, keeper, fSentinel, alice];
        for (uint256 i; i < who.length; ++i) {
            (bool ok,) = _try(who[i], abi.encodeCall(GainsVault.openTrade, (p)));
            assertFalse(ok, "only the manager or the agent opens");
        }
        // a stranger trading on Gains directly uses its own counter
        (uint32 t0,) = _counter(address(trader), 0);
        trader.openTrade(_traderLimit(), 1000);
        (uint32 t1,) = _counter(address(trader), 0);
        (uint32 c1,) = _counter(address(v), 0);
        assertEq(t1, t0 + 1);
        assertEq(c1, c0, "the vault's counter did not move");
    }

    function _traderLimit() internal view returns (G.Trade memory t) {
        t.user = address(trader);
        t.pairIndex = ETH;
        t.leverage = 3_000;
        t.long = true;
        t.isOpen = true;
        t.collateralIndex = USDC_INDEX;
        t.tradeType = 1; // LIMIT
        t.collateralAmount = 100e6;
        t.openPrice = (cl[ETH_USD] * 80) / 100;
    }
}
