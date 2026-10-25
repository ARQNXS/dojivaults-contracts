// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import "./NavForkBase.sol";

/// @notice Round 1 review (3.1, NAV): economic PoCs on the real diamond (Arbitrum One fork, real fees, real spread and
///         skew impact). The test_GR1_* tests are the fix round's regressions of the round 1 PoCs (each names the PoC
///         it was); the others pass while the behaviour they are named after exists.
contract NavEconForkTest is NavForkBase {
    // ------------------------------------------------------------------ helpers
    /// @dev Redeems everything `who` holds, settles (keeper), claims; returns the USDC received.
    function _exitAll(address who) internal returns (uint256 got) {
        uint256 sh = v.balanceOf(who);
        vm.prank(who);
        v.requestRedeem(sh, who, who);
        _settleK(v);
        uint256 b = USDC.balanceOf(who);
        v.claim(who);
        got = USDC.balanceOf(who) - b;
    }

    struct Cycle {
        uint256 navBeforeOpen;
        uint256 navOpen;
        uint256 paid;
        uint256 bobIn;
        uint256 bobOut;
        uint256 aliceIn;
        uint256 aliceOut;
        uint256 notional;
    }

    /// @dev alice holds the vault; the manager opens one market trade (fill at C), bob deposits while it is open, the
    ///      trade closes at the unchanged Chainlink price, both leave. Fees on (2% management, 20% performance).
    ///      bobIn = 0: the same timeline without bob (the control alice is compared with).
    function _biasCycle(uint32 maxLevBps, uint16 pair, bool long, uint120 coll, uint24 lev, uint256 bobIn)
        internal
        returns (Cycle memory c)
    {
        // GR2-KEY-01b (WP5 port): the cycles' 270k to 900k notional is above 1 % of the pair's skew depth (ETH: about
        // 142k at 517,076,707); they measure deposit pricing, not the pair cap, so the cap is raised to the 10 % maximum.
        _raisePairCapToMax(pair);
        (v, pol) = _create(bytes32(uint256(maxLevBps) + lev), _risk(maxLevBps), 200, 2_000);
        c.aliceIn = 100_000e6;
        c.bobIn = bobIn;
        _depositSettle(v, alice, c.aliceIn);
        c.navBeforeOpen = v.totalAssets();
        (uint32 idx, bool ok) = _open(v, pair, long, coll, lev, _c(pair));
        assertTrue(ok, "opened");
        c.navOpen = v.totalAssets();
        c.notional = v.venue().notional;

        if (bobIn > 0) {
            vm.prank(bob);
            v.requestDeposit(bobIn, bob);
        }
        _settleK(v);
        if (bobIn > 0) v.claim(bob);

        _rollFresh(10);
        c.paid = _closeAt(v, idx, _c(pair)); // Gains' oracle at Chainlink: no price move at all
        if (bobIn > 0) c.bobOut = _exitAll(bob);
        c.aliceOut = _exitAll(alice);
        console2.log("notional (USDC)", c.notional / 1e6);
        console2.log("NAV before open / with the trade open", c.navBeforeOpen, c.navOpen);
        console2.log("NAV drop at open, bps of notional", ((c.navBeforeOpen - c.navOpen) * 10_000) / c.notional);
        console2.log("close paid", c.paid);
        console2.log("bob  in / out", c.bobIn, c.bobOut);
        console2.log("alice in / out", c.aliceIn, c.aliceOut);
    }

    // ------------------------------------------------------------------ NAVBIAS on the fork, real fees
    /// @dev The cycle with bob and the same cycle without him, from the same state: what alice receives in each.
    function _biasPair(uint32 maxLevBps, uint120 coll, uint24 lev, uint256 bobIn) internal returns (Cycle memory c, Cycle memory c0) {
        uint256 snap = vm.snapshotState();
        c = _biasCycle(maxLevBps, ETH, true, coll, lev, bobIn);
        vm.revertToState(snap);
        c0 = _biasCycle(maxLevBps, ETH, true, coll, lev, 0);
        console2.log("alice out with bob / without bob", c.aliceOut, c0.aliceOut);
    }

    /// @notice Was the GR1-02 PoC `test_NAVBIAS_fork_realFees_3x` (bob, entering while an ETH long 45k x 6 was open and
    ///         leaving after it closed at C, took about B x notional x his share from alice). Deposits now mint at the
    ///         favourable band edge: bob ends with no more than he put in, and alice receives at least what she would
    ///         have received without him (1 USDC rounding), real Gains fees included.
    function test_GR1_02_fork_realFees_3x_depositInWhileOpenGainsNothing() public {
        (Cycle memory c, Cycle memory c0) = _biasPair(30_000, 45_000e6, 6_000, 100_000e6);
        assertLe(c.bobOut, c.bobIn, "GR1-02: bob gains nothing with no price move");
        console2.log("bob pays (USDC 1e6)", c.bobIn - c.bobOut);
        assertGe(c.aliceOut + 1e6, c0.aliceOut, "GR1-02: alice loses nothing to bob beyond rounding");
    }

    /// @notice Was the GR1-02 PoC `test_NAVBIAS_fork_realFees_10x` (bob took ~1% of his deposit per cycle at 10x).
    function test_GR1_02_fork_realFees_10x_depositInWhileOpenGainsNothing() public {
        (Cycle memory c, Cycle memory c0) = _biasPair(100_000, 90_000e6, 10_000, 100_000e6);
        assertLe(c.bobOut, c.bobIn, "GR1-02: bob gains nothing at 10x either");
        console2.log("bob pays (USDC 1e6)", c.bobIn - c.bobOut);
        assertGe(c.aliceOut + 1e6, c0.aliceOut, "GR1-02: alice loses nothing to bob beyond rounding");
    }

    // ------------------------------------------------------------------ near-liquidation cliff
    /// @dev Lowest Chainlink move (in 1 bp steps, against the trade) at which GainsNav values the vault's only trade
    ///      at 0 while Gains would still pay for a close at C. Returns the move in bps (0 = already 0 at open).
    function _walkToCliff(uint16 pair, bool long) internal returns (uint256 movedBps) {
        uint64 c0 = _c(pair);
        while (v.venue().value != 0) {
            movedBps++;
            require(movedBps < 2_000, "no cliff");
            uint256 px = long ? (uint256(c0) * (10_000 - movedBps)) / 10_000 : (uint256(c0) * (10_000 + movedBps)) / 10_000;
            _setPx(pair, uint64(px));
        }
    }

    /// @notice Was the GR1-03 PoC `test_NAVCLIFF_fork_highLeverageTradeValuedZeroButPays` (the near-liquidation rule
    ///         counted the band twice: a trade at Gains' maximum pair leverage was worth 0 in NAV from the open while a
    ///         close at C paid back a large part of its collateral). Now the trade is valued at the open, at about what
    ///         Gains pays for a close at the valuation price (the adverse band edge), and the cliff sits further out.
    function test_GR1_03_fork_highLeverageTradeValuedAtWhatGainsPays() public {
        // GR2-KEY-01b (WP5 port): the 270k ETH notional is above 1 % of ETH's skew depth (about 142k at 517,076,707);
        // this test is about NAV at the cliff, not the pair cap, so ETH's cap is raised to the 10 % maximum.
        _raisePairCapToMax(ETH);
        (v, pol) = _create(bytes32(uint256(901)), _risk(30_000), 0, 0);
        _depositSettle(v, alice, 100_000e6);
        uint256 maxLev = X.pairMaxLeverage(ETH);
        console2.log("Gains pairMaxLeverage ETH (1e3)", maxLev);
        uint120 coll = uint120((270_000e6 * 1e3) / maxLev); // vault leverage 3x
        (uint32 idx,) = _open(v, ETH, true, coll, uint24(maxLev), _c(ETH));
        uint256 value0 = v.venue().value;
        console2.log("collateral / NAV value of the trade at the open", coll, value0);
        assertGt(value0, uint256(coll) / 10, "GR1-03: valued at the open, not 0");
        uint256 snap = vm.snapshotState();
        uint256 moved = _walkToCliff(ETH, true);
        console2.log("Chainlink move against the trade to the zero value, bps", moved);
        assertGt(moved, 0, "the cliff is not at the open");
        vm.revertToState(snap);
        _passHold(); // GR2-KEY-01b (WP5 port): was _rollFresh(1); the manager's close waits the 10-minute minimum hold
        uint64 p = _adverseP(ETH, true);
        uint256 navValue = v.venue().value;
        uint256 paid = _closeAt(v, idx, p);
        console2.log("NAV value / Gains pays at the adverse edge", navValue, paid);
        assertApproxEqAbs(paid, navValue, uint256(coll) / 100, "valued within 1% of collateral of what Gains pays at P");
    }

    /// @notice Was the GR1-03 PoC `test_NAVCLIFF_fork_confederateExtractsFromHolders` (a non-insider confederate
    ///         deposited while NAV called the max-leverage trade worthless and left with alice's money after the close
    ///         at C). At the cliff the trade is now zero only at the adverse edge; deposits mint at the favourable edge
    ///         (GR1-02), so the confederate ends with no more than he put in.
    function test_GR1_03_fork_confederateCannotExtractAtTheCliff() public {
        // GR2-KEY-01b (WP5 port): the 270k ETH notional is above 1 % of ETH's skew depth (about 142k at 517,076,707);
        // this test is about NAV at the cliff, not the pair cap, so ETH's cap is raised to the 10 % maximum.
        _raisePairCapToMax(ETH);
        (v, pol) = _create(bytes32(uint256(902)), _risk(30_000), 200, 2_000);
        _depositSettle(v, alice, 100_000e6);
        uint256 maxLev = X.pairMaxLeverage(ETH);
        uint120 coll = uint120((270_000e6 * 1e3) / maxLev);
        (uint32 idx,) = _open(v, ETH, true, coll, uint24(maxLev), _c(ETH));
        _walkToCliff(ETH, true);
        uint256 navCliff = v.totalAssets();

        uint256 bobIn = 1_000_000e6;
        vm.prank(bob);
        v.requestDeposit(bobIn, bob);
        _settleK(v);
        v.claim(bob);
        _rollFresh(1);
        uint256 paid = _closeAt(v, idx, _c(ETH));
        uint256 bobOut = _exitAll(bob);
        uint256 aliceOut = _exitAll(alice);
        console2.log("collateral / NAV at the cliff / close paid", coll, navCliff, paid);
        console2.log("bob in / out", bobIn, bobOut);
        console2.log("alice in 100000e6, out", aliceOut);
        assertLe(bobOut, bobIn, "GR1-03: the confederate gains nothing");
    }

    /// @notice Was the NAVCLIFF control `test_NAVCLIFF_fork_controlSameNotionalAt6x` (the same 270k notional at 6x let
    ///         bob gain through NAVBIAS alone). With two-sided pricing (GR1-02) the 1M confederate gains nothing.
    function test_GR1_02_fork_controlSameNotionalAt6x_gainsNothing() public {
        Cycle memory c = _biasCycle(30_000, ETH, true, 45_000e6, 6_000, 1_000_000e6);
        console2.log("control: bob pays at 6x", c.bobIn - c.bobOut);
        assertLe(c.bobOut, c.bobIn);
    }

    // ------------------------------------------------------------------ pending partial open: gov fee of pair 0
    /// @notice Was the GR1-28 PoC `test_GOVFEEPAIR_fork_pendingSolIncreaseUsesPair0Fee` (a pending SOL partial open
    ///         was netted with pair 0's gov fee, because Gains leaves pairIndex 0 in the order). It is now netted with
    ///         SOL's own fee; pair 0's fee is made different (mocked x10) so the two cannot coincide.
    function test_GR1_28_fork_pendingSolIncreaseUsesTradesOwnPairFee() public {
        (v, pol) = _create(bytes32(uint256(903)), _risk(30_000), 0, 0);
        _depositSettle(v, alice, 100_000e6);
        uint256 f33 = harness.minGovFee(D, 3, SOL);
        (uint32 idx,) = _open(v, SOL, true, 1_000e6, 5_000, _c(SOL));
        uint256 before = v.venue().value;
        _call(v, mgr, abi.encodeCall(GainsVault.increaseTrade, (idx, uint120(500e6), uint24(5_000), _c(SOL), uint16(1_000))));
        IGainsDiamond.PendingOrder[] memory o = D.getPendingOrders(address(v));
        assertEq(o.length, 1);
        assertEq(o[0].orderType, 8, "MARKET_PARTIAL_OPEN");
        assertEq(o[0].trade.pairIndex, 0, "Gains leaves pairIndex 0 on a partial open");
        IGainsDiamond.GlobalTradeFeeParams memory fp = D.getTradeFeeParams(3, SOL);
        fp.govFeeP *= 10;
        vm.mockCall(address(D), abi.encodeCall(IGainsDiamond.getTradeFeeParams, (uint8(3), uint16(0))), abi.encode(fp));
        uint256 f0 = harness.minGovFee(D, 3, BTC);
        console2.log("minGovFee pair 0 (mocked) / SOL", f0, f33);
        assertTrue(f0 != f33, "pair 0's fee differs");
        uint256 pendingValue = v.venue().value - before;
        assertEq(pendingValue, 500e6 - f33, "GR1-28: valued with SOL's gov fee");
    }

    // ------------------------------------------------------------------ band + fees vs the daily loss limit
    /// @notice NAV drop at open in bps of notional (opening fee realized + closing fee + spread / impact + band): a
    ///         vault that opens up to its leverage limit books it as a loss of drop x vault leverage at once.
    function test_DAILYLOSS_fork_navDropAtOpenPerNotional() public {
        // GR2-KEY-01b (WP5 port): 100k of SOL is above 1 % of SOL's skew depth at 517,076,707 (BTC and ETH fit); this
        // test measures the NAV drop at open, not the pair cap, so SOL's cap is raised to the 10 % maximum.
        _raisePairCapToMax(SOL);
        (v, pol) = _create(bytes32(uint256(904)), _risk(100_000), 0, 0);
        _depositSettle(v, alice, 100_000e6);
        uint16[3] memory pairs = [BTC, ETH, SOL];
        for (uint256 i; i < 3; i++) {
            uint256 n0 = v.totalAssets();
            (, bool ok) = _open(v, pairs[i], true, 10_000e6, 10_000, _c(pairs[i]));
            assertTrue(ok);
            uint256 n1 = v.totalAssets();
            console2.log("pair / NAV drop at open in bps of the 100k notional", pairs[i], ((n0 - n1) * 10_000) / 100_000e6);
        }
        uint256 nav = v.totalAssets();
        (, uint256 dl,) = v.checkRisk();
        console2.log("daily loss after opening 3x vault leverage (bps)", dl, "NAV", nav);
        assertGt(dl, 0);
    }
}
