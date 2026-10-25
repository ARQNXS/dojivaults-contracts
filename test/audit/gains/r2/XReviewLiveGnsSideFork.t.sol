// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import "./GainsSideForkBase.sol";

/// @notice Cross-review of GR2-GNS-01 (XREVIEW-LIVE-GNS.md): the sibling case for resting LIMIT opens. Real gTrade v10
///         diamond (GNS_FORK_BLOCK or GAINS_FORK_BLOCK = tip - ~40), oracle answers emulated by pranking Gains' nodes, Chainlink frozen.
///
///         Gains executes a LIMIT / STOP open EXACTLY at its trigger when the trigger lies inside the oracle range since
///         the order was placed (TradingCallbacksUtils._validateTriggerOpenOrderCallback, exactExecution). A LIMIT long
///         whose trigger the market has run through therefore opens at the limit, above the market: the new trade is
///         immediately worth less than its collateral. GainsNav values a resting order at its collateral until Gains'
///         bot fills it (GainsNav.sol:89-94), so a settle in that window pays redeemers out of the holders who stay.
///         A STOP long run through opens at the stop, below the market: NAV understates (conservative).
contract XReviewLiveGnsSideForkTest is GainsSideForkBase {
    struct Run {
        uint256 navAtSettle;
        uint256 bobGot;
        uint256 aliceAfter;
    }

    function _lastIndex() internal view returns (uint32) {
        IGainsDiamond.Trade[] memory ts = D.getTrades(address(v));
        return ts[ts.length - 1].index;
    }

    function _fillLimit(uint32 idx, uint64 open, uint64 high, uint64 low) internal returns (uint64 execOpenPrice) {
        Vm.Log[] memory req = _trigger(bot, T_LIMIT_OPEN, idx);
        _rollFresh(1);
        Vm.Log[] memory fill = _fillRange(req, open, high, low);
        (G.Trade memory t, uint8 ot,,,, bool exact) = _limitExecuted(fill);
        assertEq(ot, T_LIMIT_OPEN, "a LIMIT_OPEN execution");
        assertTrue(exact, "the limit lies inside the oracle range: exact execution at the limit");
        execOpenPrice = t.openPrice;
    }

    function _settleBob() internal returns (uint256 navAtSettle, uint256 got) {
        navAtSettle = v.totalAssets();
        uint256 b0 = USDC.balanceOf(bob);
        vm.prank(keeper);
        v.settle();
        v.claim(bob);
        got = USDC.balanceOf(bob) - b0;
    }

    function test_GR2_XR_GNS01_crossedLimitOpen_valuedAtCollateral_opensBelowIt_redeemerOverpaid() public {
        // GR2-KEY-01b (WP5 port): the 500k ETH order is above 1 % of ETH's skew depth (about 142k at 517,076,707); this
        // test is about NAV while the order rests, not the pair cap, so ETH's cap is raised to the 10 % maximum.
        _raisePairCapToMax(ETH);
        _twoHolders(100_000e6, 100_000e6);
        uint64 c = cl[ETH_USD];
        // LIMIT long 0.5% below the market: 25,000 USDC at 20x = 500,000 of ETH (2.5x vault leverage, policy 5x)
        OpenParams memory p = _openParams(ETH, true, 25_000e6, 20_000);
        p.tradeType = 1;
        p.expectedPrice = uint64((uint256(c) * 9_950) / 10_000);
        vm.prank(mgr);
        v.openTrade(p);
        uint32 idx = _lastIndex();
        // the market falls through the limit to -1.5% (1% below the limit) before the bot's trigger lands
        uint64 c2 = uint64((uint256(c) * 9_850) / 10_000);
        _setCl(ETH_USD, c2);
        _rollFresh(2);
        uint256 bobShares = v.balanceOf(bob);
        vm.prank(bob);
        v.requestRedeem(bobShares, bob, bob);

        uint256 snap = vm.snapshotState();
        // A: settle in the window (resting order at collateral), then the limit fills
        Run memory a;
        (a.navAtSettle, a.bobGot) = _settleBob();
        uint64 execA = _fillLimit(idx, c2, c, c2);
        a.aliceAfter = v.convertToAssets(v.balanceOf(alice));
        vm.revertToState(snap);
        // B: the limit fills, then settle
        Run memory b;
        uint64 execB = _fillLimit(idx, c2, c, c2);
        (b.navAtSettle, b.bobGot) = _settleBob();
        b.aliceAfter = v.convertToAssets(v.balanceOf(alice));

        console2.log("limit / market at the fill / Gains open price", p.expectedPrice, c2, execB);
        console2.log("NAV at settle: in the window / after the fill", a.navAtSettle, b.navAtSettle);
        console2.log("bob (50%) paid: window / after fill", a.bobGot, b.bobGot);
        console2.log("bob overpaid / alice short", a.bobGot - b.bobGot, b.aliceAfter - a.aliceAfter);
        assertEq(execA, execB, "same fill either way");
        assertGt(execB, c2, "opened above the market (at the limit, plus spread / impact)");
        // 1% of 500,000 = 5,000 USDC below collateral at once, plus the opening fee and the band edge
        assertGt(a.navAtSettle, b.navAtSettle + 4_500e6, "NAV in the window is > 4,500 USDC above the post-fill NAV");
        assertGt(a.bobGot, b.bobGot + 2_000e6, "the redeemer is overpaid by about half of it");
        assertGt(b.aliceAfter, a.aliceAfter + 2_000e6, "the holder who stays pays it");
    }

    /// @dev Control: a STOP long the market ran through opens at the stop, below the market, so its post-fill value is
    ///      ABOVE the collateral GainsNav counted while it rested (NAV conservative).
    function test_GR2_XR_GNS01_crossedStopOpen_conservative() public {
        // GR2-KEY-01b (WP5 port): the 500k ETH order is above 1 % of ETH's skew depth (about 142k at 517,076,707); this
        // test is about NAV while the order rests, not the pair cap, so ETH's cap is raised to the 10 % maximum.
        _raisePairCapToMax(ETH);
        _twoHolders(100_000e6, 100_000e6);
        uint64 c = cl[ETH_USD];
        OpenParams memory p = _openParams(ETH, true, 25_000e6, 20_000);
        p.tradeType = 2; // STOP long 0.5% above the market
        p.expectedPrice = uint64((uint256(c) * 10_050) / 10_000);
        vm.prank(mgr);
        v.openTrade(p);
        uint32 idx = _lastIndex();
        uint64 c2 = uint64((uint256(c) * 10_150) / 10_000);
        _setCl(ETH_USD, c2);
        _rollFresh(2);
        uint256 navResting = v.totalAssets();
        Vm.Log[] memory req = _trigger(bot, T_STOP_OPEN, idx);
        _rollFresh(1);
        Vm.Log[] memory fill = _fillRange(req, c2, c2, c);
        (,,,,, bool exact) = _limitExecuted(fill);
        assertTrue(exact, "exact at the stop");
        uint256 navFilled = v.totalAssets();
        console2.log("STOP run through: NAV resting / filled", navResting, navFilled);
        assertGt(navFilled, navResting, "NAV understated while resting: conservative");
    }
}
