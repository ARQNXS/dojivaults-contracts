// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import "./liveness/LiveLifecycleBase.sol";

/// @notice GR2-LIVE-01 on the Arbitrum One fork (real gTrade v10 diamond, LiveForkBase pin; run of record 516,380,000).
///         Gains' getTrades(trader) walks EVERY trade index the trader ever used (TradingStorageGetters.getTrades:
///         `for (i; i < counter.currentIndex; ++i) if (trades[trader][i].isOpen) ...`, early exit only once all open
///         trades are found, none when there are none). getPendingOrders does the same over every pending-order index
///         when at least one is open. GainsNav reads both on every NAV path, so settle (every mode, emergency included),
///         totalAssets, checkRisk, flatten, openTrade and requestDeposit cost one cold SLOAD per index the vault has
///         EVER used, and Gains never reuses an index. MAX_POSITIONS bounds open items, not this.
///
///         The vault's trade counter is moved with vm.store (TradingStorage at slot 301, userCounters at +8,
///         CounterType.TRADE = 0, PENDING_ORDER = 1; checked against getCounters first). The scanned slots are
///         empty, exactly like the slot of an index Gains filled and closed later: a cold SLOAD costs the same.
///         Every scanned slot is an RPC fetch on the public endpoint, so N is an env knob (LIVE_N, default 2,000);
///         the per-index cost is linear and is extrapolated to the 32M Arbitrum limit in LIVENESS.md.
contract LivenessHistoryForkTest is LiveLifecycleBase {
    uint256 internal constant ARB_LIMIT = 32_000_000;
    uint256 internal constant TS_SLOT = 301;
    uint256 internal constant TRADES_SLOT = TS_SLOT + 4;
    uint256 internal constant COUNTERS_SLOT = TS_SLOT + 8;

    function _counterSlot(address trader, uint8 kind) internal pure returns (bytes32) {
        return keccak256(abi.encode(uint256(kind), keccak256(abi.encode(trader, COUNTERS_SLOT))));
    }

    function _counter(address trader, uint8 kind) internal view returns (uint32 current, uint32 open) {
        G.Counter memory c = DIAMOND.getCounters(trader, kind);
        return (c.currentIndex, c.openCount);
    }

    /// @dev Sets the trader's counter as if it had used `current` indexes, `open` of them still open.
    function _setCounter(address trader, uint8 kind, uint32 current, uint32 open) internal {
        bytes32 slot = _counterSlot(trader, kind);
        uint256 word = uint256(vm.load(address(DIAMOND), slot));
        word = (word & ~uint256(type(uint64).max)) | uint256(current) | (uint256(open) << 32);
        vm.store(address(DIAMOND), slot, bytes32(word));
        (uint32 c, uint32 o) = _counter(trader, kind);
        assertEq(c, current, "counter slot: currentIndex");
        assertEq(o, open, "counter slot: openCount");
    }

    function _n() internal view returns (uint32) {
        return uint32(vm.envOr("LIVE_N", uint256(2_000)));
    }

    /// @dev The slot layout the PoC relies on, read back through Gains' own getters.
    function test_GR2_LIVE_01_layout_countersAndTradesSlots() public {
        _depositSettle(alice, 10_000e6);
        uint32 idx = _openFilledV(ETH, true, 1_000e6, 3_000);
        (uint32 c, uint32 o) = _counter(address(v), 0);
        assertEq(c, idx + 1);
        assertEq(o, 1);
        bytes32 tslot = keccak256(abi.encode(uint256(idx), keccak256(abi.encode(address(v), TRADES_SLOT))));
        uint256 w = uint256(vm.load(address(DIAMOND), tslot));
        assertEq(address(uint160(w)), address(v), "trades[vault][idx].user");
        // packed: user 160 | index 32 | pairIndex 16 | leverage 24 | long 8 | isOpen 8 | collateralIndex 8
        assertEq((w >> 160) & type(uint32).max, idx, "index");
        assertEq((w >> 240) & 0xff, 1, "isOpen");
        assertEq(w >> 248, 3, "collateralIndex (USDC)");
    }

    /// @dev Organic growth: every resting limit order placed and cancelled consumes a trade index for good; the vault
    ///      pays no Gains fee for it (the collateral comes back in full). A manager or the agent can therefore grow the
    ///      counter at gas cost only.
    function test_GR2_LIVE_01_limitPlaceAndCancelBurnsOneIndexEach_noFee() public {
        _depositSettle(alice, 10_000e6);
        (uint32 c0,) = _counter(address(v), 0);
        uint256 usdc0 = _usdc();
        uint256 gasPlace;
        uint256 gasCancel;
        for (uint256 i; i < 5; ++i) {
            OpenParams memory p = _openParams(ETH, true, 100e6, 3_000);
            p.tradeType = 1;
            p.expectedPrice = cl[ETH_USD] * 80 / 100;
            (uint256 g,) = _gas(mgr, abi.encodeCall(GainsVault.openTrade, (p)));
            gasPlace += g;
            IGainsDiamond.Trade[] memory ts = D.getTrades(address(v));
            (g,) = _gas(mgr, abi.encodeCall(GainsVault.cancelOrder, (ts[0].index)));
            gasCancel += g;
        }
        (uint32 c1, uint32 o1) = _counter(address(v), 0);
        assertEq(c1, c0 + 5, "5 indexes consumed");
        assertEq(o1, 0, "nothing open");
        assertEq(_usdc(), usdc0, "no Gains fee on a placed + cancelled limit");
        console2.log("GAS place limit (avg) / cancel (avg)", gasPlace / 5, gasCancel / 5);
    }

    /// @dev The core measurement: a flat vault (no trade, no order) whose counter says N indexes were used. Pre-fix,
    ///      settle, totalAssets and checkRisk grew linearly in N through getTrades (run of record 516,380,000, LIVENESS.md).
    ///      On the fixed vault this PoC (`test_GR2_LIVE_01_navAndSettleCostGrowWithLifetimeIndexes`) still PASSED at
    ///      517,076,707 (WP5 fork2 log: settle 416,506 at N = 0 and 64,595,906 at N = 2,000, 32,089 gas per index), but
    ///      only because vm.store moves Gains' counter past the vault's cursor: the N indexes are UNSEEN, and the vault
    ///      reads [cursor, counter) one getTrade each. A real vault cannot get there (every call that takes an index
    ///      syncs first). Re-scoped as the fix assertion: the unseen walk is what a recovery costs per index, the
    ///      permissionless syncIndexes pulls it in bounded batches, and after it settle and totalAssets cost what they
    ///      cost at N = 0 (lifetime indexes are free).
    function test_GR2_LIVE_01_fix_lifetimeIndexesCostNothingOnceSynced() public {
        _depositSettle(alice, 20_000e6);
        uint256 shares = v.balanceOf(alice) / 10;
        vm.prank(alice);
        v.requestRedeem(shares, alice, alice);
        _rollFresh(10);
        v.checkRisk();
        uint256 snap = vm.snapshotState();

        (uint256 gS0,) = _gas(keeper, abi.encodeCall(GainsVault.settle, ()));
        vm.revertToState(snap);
        (uint256 gT0,) = _gas(address(this), abi.encodeCall(GainsVault.totalAssets, ()));
        vm.revertToState(snap);

        uint32 n = _n();
        (uint32 c0,) = _counter(address(v), 0);
        _setCounter(address(v), 0, c0 + n, 0);
        snap = vm.snapshotState();
        (uint256 gTn,) = _gas(address(this), abi.encodeCall(GainsVault.totalAssets, ()));
        vm.revertToState(snap);
        (uint256 gCn,) = _gas(keeper, abi.encodeCall(GainsVault.checkRisk, ()));
        vm.revertToState(snap);
        (uint256 gSn,) = _gas(keeper, abi.encodeCall(GainsVault.settle, ()));
        vm.revertToState(snap);
        (uint256 gRaw,) = _rawGetTrades(address(v));

        uint256 perIdx = (gSn - gS0) / n;
        console2.log("lifetime indexes N", n);
        console2.log("GAS settle: N = 0 / N", gS0, gSn);
        console2.log("GAS totalAssets: N = 0 / N", gT0, gTn);
        console2.log("GAS checkRisk at N", gCn);
        console2.log("GAS diamond.getTrades alone at N", gRaw);
        console2.log("settle gas per lifetime index", perIdx);
        console2.log("N at which a flat vault's settle passes 32M", (ARB_LIMIT - gS0) / perIdx);
        console2.log("N at which it passes 26M (20% headroom)", (26_000_000 - gS0) / perIdx);
        assertGt(perIdx, 2_000, "an UNSEEN index costs one read");
        assertGt(gSn, gS0 + uint256(n) * 2_000);

        // the fix: once the unseen range is pulled (bounded batches, anyone), settle and totalAssets are back at N = 0
        uint256 worst = _syncInBatches(n);
        console2.log("syncIndexes(500) worst batch gas", worst);
        snap = vm.snapshotState();
        (uint256 gSs,) = _gas(keeper, abi.encodeCall(GainsVault.settle, ()));
        vm.revertToState(snap);
        (uint256 gTs,) = _gas(address(this), abi.encodeCall(GainsVault.totalAssets, ()));
        vm.revertToState(snap);
        console2.log("GAS settle / totalAssets at N after the sync", gSs, gTs);
        assertLt(gSs, gS0 + 50_000, "settle at N lifetime indexes costs what it cost at N = 0");
        assertLt(gTs, gT0 + 50_000, "and totalAssets too");

        // exits that read no list are flat in N
        uint256 g;
        (g,) = _gas(alice, abi.encodeCall(GainsVault.cancelRedeemRequest, ()));
        console2.log("GAS cancelRedeemRequest at N", g);
        vm.prank(alice);
        v.requestRedeem(shares, alice, alice);
        assertLt(g, 200_000);
    }

    /// @dev GR2-LIVE-01 fix, inverted from the PoC `test_GR2_LIVE_01_twentyOpenTradesAfterNIndexes_settleAndFlatten`
    ///      ("with trades open the walk stops at the newest open index, which on a vault that keeps trading is close to
    ///      the counter: same cost"; it asserted settle > 8M + N x 2,000). On the fixed vault the PoC FAILED at
    ///      517,076,707 (WP5 fork2 log, fork2-all-fork.txt): "the walk adds to the 20-trade settle: 8327813 <= 12000000",
    ///      with settle 8,327,813 and totalAssets 7,814,400 at N = 2,000, flattenIndices (20) 24,205,983. The vault now
    ///      reads its own index set: the first open after the jump pulls the unseen range once, then settle reads the
    ///      20 open trades only and the cursor sits at Gains' counter. 20 open trades at indexes N .. N+19.
    function test_GR2_LIVE_01_fix_twentyOpenTradesAfterNIndexes_settleAndFlatten() public {
        _depositSettle(alice, 100_000e6);
        uint32 n = _n();
        (uint32 c0,) = _counter(address(v), 0);
        _setCounter(address(v), 0, c0 + n, 0);
        uint16[3] memory pairs = [BTC, ETH, SOL];
        for (uint256 i; i < 20; ++i) {
            _openFilledV(pairs[i % 3], i % 2 == 0, 400e6, 3_000);
        }
        (uint32 c1, uint32 o1) = _counter(address(v), 0);
        assertEq(o1, 20);
        assertEq(c1, c0 + n + 20);
        uint256 shares = v.balanceOf(alice) / 100;
        vm.prank(alice);
        v.requestRedeem(shares, alice, alice);
        _rollFresh(4 * 3_600);
        v.checkRisk();
        uint256 snap = vm.snapshotState();
        (uint256 gS,) = _gas(keeper, abi.encodeCall(GainsVault.settle, ()));
        vm.revertToState(snap);
        (uint256 gT,) = _gas(address(this), abi.encodeCall(GainsVault.totalAssets, ()));
        vm.revertToState(snap);
        console2.log("N + 20 open trades: GAS settle (redemption) / totalAssets", gS, gT);
        // flattenIndices decodes nothing: it does not walk the list
        IGainsDiamond.Trade[] memory ts = D.getTrades(address(v));
        uint32[] memory ix = new uint32[](ts.length);
        for (uint256 i; i < ts.length; ++i) {
            ix[i] = ts[i].index;
        }
        uint256 g0 = gasleft();
        (bool ok,) = _try(fGuardian, abi.encodeCall(GainsVault.flattenIndices, (ix, uint256(0), cl[ETH_USD])));
        console2.log("N + 20 open trades: flattenIndices (20) ok / gas (incl. prank)", ok, g0 - gasleft());
        assertTrue(ok, "flattenIndices of the 20 trades");
        (uint32 tc,, uint32[] memory tracked,) = v.indexSet();
        assertEq(tc, c1, "the trade cursor is at Gains' counter: nothing unseen");
        assertEq(tracked.length, 20, "the index set holds the 20 open trades only");
        assertLt(gS, 8_000_000 + uint256(n) * 2_000, "the lifetime indexes no longer add to the 20-trade settle");
    }

    /// @dev GR2-LIVE-01 fix, inverted from the PoC `test_GR2_LIVE_01_pendingWalkWithACloseInFlight` (getPendingOrders
    ///      returns early with nothing open and otherwise walks every pending index up to the newest open one, so a close
    ///      in flight on a vault with M lifetime market orders cost M SLOADs in ordersPending, the NAV read and
    ///      redemptionShortfall; it asserted settle with the close > settle without + M x 2,000). On the fixed vault,
    ///      with the minimum hold waited (WP5 port), the PoC FAILED at 517,076,707 (wp5-logs/fork-poc-proof.txt):
    ///      "assertion failed: 1109198 <= 4996432" (settle 996,432 with no order in flight, 1,109,198 with the close in
    ///      flight): the close no longer adds a walk over the M pending indexes. Inverted: once the unseen range is synced (the vault's own calls keep it so; syncIndexes recovers a
    ///      jump in batches), a close in flight costs one tracked order, not M reads.
    function test_GR2_LIVE_01_fix_pendingWalkWithACloseInFlight() public {
        _depositSettle(alice, 20_000e6);
        uint32 a = _openFilledV(ETH, true, 1_000e6, 3_000);
        uint32 n = _n();
        (uint32 p0,) = _counter(address(v), 1);
        _setCounter(address(v), 1, p0 + n, 0);
        _syncInBatches(n); // the fix: the vault's index set is caught up (no unseen pending range)
        uint256 shares = v.balanceOf(alice) / 2;
        vm.prank(alice);
        v.requestRedeem(shares, alice, alice);
        _passHold(); // GR2-KEY-01b (WP5 port): was _rollFresh(10); the manager's close below waits the minimum hold
        v.checkRisk();
        uint256 snap = vm.snapshotState();
        (uint256 gNo,) = _gas(keeper, abi.encodeCall(GainsVault.settle, ()));
        vm.revertToState(snap);
        _req(mgr, abi.encodeCall(GainsVault.closeTrade, (a, cl[ETH_USD]))); // pending index p0 + n
        snap = vm.snapshotState();
        (uint256 gYes,) = _gas(keeper, abi.encodeCall(GainsVault.settle, ()));
        vm.revertToState(snap);
        (uint256 gSf,) = _gas(address(this), abi.encodeCall(GainsVault.redemptionShortfall, ()));
        vm.revertToState(snap);
        (uint256 gOp,) = _gas(address(this), abi.encodeCall(GainsVault.ordersPending, ()));
        console2.log("M lifetime pending indexes", n);
        console2.log("GAS settle: no order in flight / a close in flight", gNo, gYes);
        console2.log("GAS redemptionShortfall / ordersPending with the close in flight", gSf, gOp);
        assertLt(gYes, gNo + 200_000, "a close in flight adds one tracked order, not a walk over M pending indexes");
        assertLt(gSf, 1_000_000, "redemptionShortfall reads the tracked orders only");
        assertLt(gOp, 1_000_000, "ordersPending too");
    }

    /// @dev End to end at a size the public RPC can serve in one run: a settle sent with Arbitrum's whole 32M fails
    ///      once N passes the threshold. Only runs with LIVE_N_E2E set (each index is one RPC fetch).
    function test_GR2_LIVE_01_settleOutOfGasAt32M_e2e() public {
        uint256 n = vm.envOr("LIVE_N_E2E", uint256(0));
        if (n == 0) {
            vm.skip(true);
            return;
        }
        _depositSettle(alice, 20_000e6);
        uint256 shares = v.balanceOf(alice) / 10;
        vm.prank(alice);
        v.requestRedeem(shares, alice, alice);
        _rollFresh(10);
        v.checkRisk();
        (uint32 c0,) = _counter(address(v), 0);
        _setCounter(address(v), 0, c0 + uint32(n), 0);
        vm.prank(keeper);
        (bool ok,) = address(v).call{gas: ARB_LIMIT}(abi.encodeCall(GainsVault.settle, ()));
        assertFalse(ok, "settle cannot run inside Arbitrum's 32M");
        vm.prank(fGuardian);
        v.triggerEmergency();
        vm.prank(fGuardian);
        (ok,) = address(v).call{gas: ARB_LIMIT}(abi.encodeCall(GainsVault.settle, ()));
        assertFalse(ok, "nor the guardian's emergency exit-only settle");
        // the redemption stays pending: nothing else pays it
        assertEq(v.pendingRedeemShares(), shares);
    }

    function _rawGetTrades(address trader) internal returns (uint256 g, uint256 len) {
        g = gasleft();
        IGainsDiamond.Trade[] memory t = D.getTrades(trader);
        g -= gasleft();
        len = t.length;
    }
}
