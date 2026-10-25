// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import "./GainsSideForkBase.sol";

interface IGToken {
    function sendAssets(uint256 assets, address receiver) external;
}

interface IFiatTokenR2 {
    function blacklister() external view returns (address);
    function blacklist(address account) external;
    function pauser() external view returns (address);
    function pause() external;
}

/// @notice Round 2, domain GNS (contracts/audit/gains/r2/GAINS-SIDE.md). Real gTrade v10 diamond on an Arbitrum One
///         fork at a block >= 516,000,000 (GainsSideForkBase). Skips without ARBITRUM_RPC_URL.
contract GainsSideForkTest is GainsSideForkBase {
    uint8 internal constant CANCEL_REASON_SLIPPAGE = 3;

    function _venueValue() internal view returns (uint256) {
        return v.venue().value;
    }

    function _assetsOf(address who) internal view returns (uint256) {
        return v.convertToAssets(v.balanceOf(who));
    }

    // ==================================================================
    // GR2-GNS-01: a trade past its take profit is valued at the market; Gains pays the TP
    // ==================================================================
    struct TpRun {
        uint256 bobGot;
        uint256 aliceAfter;
        uint256 navAtSettle;
        uint256 tpPaid;
    }

    /// @dev Gains executes a TP whose trigger lies inside the oracle range since the TP was set EXACTLY at the TP
    ///      (TradingCallbacksUtils._validateTriggerCloseOrderCallback, exactExecution), however far the market went
    ///      past it before the bot's trigger lands. GainsNav values the open trade at Chainlink -+ band and ignores
    ///      t.tp, so between the crossing and the trigger NAV is above what the vault will receive. A settle in that
    ///      window pays redeemers out of the remaining holders' share.
    function _tpScenario(bool settleFirst, uint32 idx, uint64 c, uint64 c2) internal returns (TpRun memory r) {
        if (settleFirst) {
            r.navAtSettle = v.totalAssets();
            uint256 b0 = USDC.balanceOf(bob);
            vm.prank(keeper);
            v.settle();
            v.claim(bob);
            r.bobGot = USDC.balanceOf(bob) - b0;
        }
        Vm.Log[] memory req = _trigger(bot, T_TP, idx);
        _rollFresh(1);
        uint256 u0 = _usdc();
        Vm.Log[] memory fill = _fillRange(req, c2, c2, c);
        (, uint8 ot,,,, bool exact) = _limitExecuted(fill);
        assertEq(ot, T_TP, "a TP execution");
        assertTrue(exact, "the TP lies inside the oracle range: exact execution at the TP");
        r.tpPaid = _usdc() - u0;
        if (!settleFirst) {
            r.navAtSettle = v.totalAssets();
            uint256 b0 = USDC.balanceOf(bob);
            vm.prank(keeper);
            v.settle();
            v.claim(bob);
            r.bobGot = USDC.balanceOf(bob) - b0;
        }
        r.aliceAfter = _assetsOf(alice);
    }

    function test_GR2_GNS_01_takeProfitPastTheMarket_navAboveWhatGainsPays_redeemerOverpaid() public {
        // GR2-KEY-01b (WP5 port): the 500k ETH trade is above 1 % of ETH's skew depth (about 142k at 517,076,707); this test is not
        // about the pair cap, so ETH's cap is raised to the 10 % maximum (the guardian's 31-day raise).
        _raisePairCapToMax(ETH);
        _twoHolders(100_000e6, 100_000e6);
        // 5,000 USDC at 100x: 500,000 USDC of ETH (2.5x vault leverage, inside the live 5x policy)
        uint32 idx = _openFilledV(ETH, true, 5_000e6, 100_000);
        uint64 c = cl[ETH_USD];
        uint64 tp = uint64((uint256(c) * 10_100) / 10_000); // TP +1% (+100% on the trade)
        vm.prank(mgr);
        v.setSlTp(idx, 0, tp);
        // the market runs through the TP to +2% before Gains' trigger bot lands
        uint64 c2 = uint64((uint256(c) * 10_200) / 10_000);
        _setCl(ETH_USD, c2);
        _rollFresh(2);
        uint256 bobShares = v.balanceOf(bob);
        vm.prank(bob);
        v.requestRedeem(bobShares, bob, bob);

        uint256 snap = vm.snapshotState();
        TpRun memory a = _tpScenario(true, idx, c, c2); // settle in the window, then the TP fills
        vm.revertToState(snap);
        TpRun memory b = _tpScenario(false, idx, c, c2); // the TP fills, then settle

        uint256 overpaid = a.bobGot - b.bobGot;
        console2.log("NAV at the settle in the window / after the TP fill", a.navAtSettle, b.navAtSettle);
        console2.log("Gains paid at the TP", a.tpPaid);
        console2.log("bob (50%) paid: settle in window / after fill", a.bobGot, b.bobGot);
        console2.log("bob overpaid / alice short", overpaid, b.aliceAfter - a.aliceAfter);
        assertEq(a.tpPaid, b.tpPaid, "Gains pays the same TP either way");
        assertGt(a.navAtSettle, b.navAtSettle + 3_000e6, "NAV in the window is > 3,000 USDC above what the vault realizes");
        assertGt(overpaid, 1_500e6, "the redeemer is overpaid by about half the overstatement");
        assertGt(b.aliceAfter, a.aliceAfter + 1_500e6, "the holder who stays pays it");
    }

    // ==================================================================
    // Q2(a): no positive PnL cap in v10 (market close)
    // ==================================================================
    function test_GNS_noPositivePnlCap_marketClosePaysBeyond900Percent() public {
        // GR2-KEY-01b (WP5 port): the 300k ETH trade is above 1 % of ETH's skew depth (about 142k at 517,076,707); this test is not
        // about the pair cap, so ETH's cap is raised to the 10 % maximum (the guardian's 31-day raise).
        _raisePairCapToMax(ETH);
        _twoHolders(100_000e6, 100_000e6);
        uint32 idx = _openFilledV(ETH, true, 2_000e6, 150_000); // 300,000 notional
        _passHold(); // GR2-KEY-01b (WP5 port): the manager's close below waits the 10-minute minimum hold
        uint64 c = cl[ETH_USD];
        _setCl(ETH_USD, uint64((uint256(c) * 10_800) / 10_000)); // +8% = +1,200% on the trade
        _rollFresh(1);
        uint256 navTrade = _venueValue();
        uint256 got = _closeV(idx, ETH);
        console2.log("trade valued (adverse edge) / Gains paid", navTrade, got);
        assertGt(got, 11 * 2_000e6, "paid more than +1,000% on 2,000 USDC: no +900% cap");
        assertGe(got, navTrade, "NAV never above the payout");
        assertLe(got - navTrade, 700e6, "the gap is the 20 bps band on 324,000 of notional (648 USDC)");
    }

    // ==================================================================
    // Q3: third-party skew. NAV change per 1M of outside skew, the outsider's round trip, the break-even
    // ==================================================================
    struct SkewRow {
        uint256 dNav;
        uint256 predicted;
        uint256 cost;
        uint256 breakEven;
    }

    function _skewRow(uint16 pair, uint256 n, uint256 x) internal returns (SkewRow memory r) {
        uint256 snap = vm.snapshotState();
        _twoHolders(100_000e6, 100_000e6);
        uint256 lev = 20_000; // 20x
        _openFilledV(pair, true, uint120((n * 1_000) / lev), uint24(lev));
        _rollFresh(1);
        uint256 nav0 = _venueValue();
        GainsSpikeTrader o = _outsider(200_000e6);
        uint120 oc = uint120(x / 100);
        uint32 oi = _openOutside(o, pair, true, oc, 100_000); // x of long skew at 100x
        uint256 nav1 = _venueValue();
        r.dNav = nav1 > nav0 ? nav1 - nav0 : 0;
        uint64 px = cl[_feed(pair)];
        uint256 depthUsd = (GOV.getPairSkewDepth(USDC_INDEX, pair) * px) / 1e22; // tokens 1e18 x price 1e10 -> 1e6
        r.predicted = (n * x) / (200 * depthUsd);
        uint256 sent = _closeOutside(o, pair, oi);
        r.cost = oc - sent;
        r.breakEven = r.dNav == 0 ? type(uint256).max : (r.cost * n) / r.dNav;
        vm.revertToState(snap);
    }

    function test_GNS_skew_outsideSkewMovesNav_unprofitableBelowBreakEven() public {
        uint16[3] memory pairs = [BTC, ETH, SOL];
        uint256 n = 500_000e6; // the vault's long notional (2.5x of 200k)
        uint256 x = 1_000_000e6; // the outsider's long
        // GR2-KEY-01b (WP5 port): the vault's 500k long is above 1 % of the pair's skew depth on ETH and SOL at
        // 517,076,707; this test measures outside skew, not the pair cap, so the three caps go to the 10 % maximum.
        _raisePairCapToMax(BTC);
        _raisePairCapToMax(ETH);
        _raisePairCapToMax(SOL);
        for (uint256 i; i < 3; ++i) {
            // GR2-KEY-01b (WP5 port): even at the 10 % maximum SOL takes about 418k at 517,076,707 (1 % skew depth
            // 4.18M), so its vault size is 400k; the break-even (cost x 200 x depth / X) does not depend on N
            SkewRow memory r = _skewRow(pairs[i], pairs[i] == SOL ? 400_000e6 : n, x);
            console2.log("pair", pairs[i]);
            console2.log("  vault NAV change for 1M of outside long skew on 500k long / predicted (N x X / 200 D)", r.dNav, r.predicted);
            console2.log("  outsider round trip cost on 1M", r.cost);
            console2.log("  break-even redeemer notional f x N (USDC)", r.breakEven);
            assertGt(r.dNav, 0, "outside skew moves the vault's NAV (no revert, no detection)");
            assertApproxEqRel(r.dNav, r.predicted, 0.25e18, "the move is Gains' skew impact on the vault's size");
            assertGt(r.breakEven, 1_000_000e6, "a redeemer needs > 1M of pro-rata notional on one pair to break even");
        }
    }

    // ==================================================================
    // Q1: a Gains MANAGER (EOA) halves the ETH skew depth: NAV steps without a revert and still equals the payout
    // ==================================================================
    function test_GNS_managerSkewDepthChange_navStepsSilently_matchesPayout() public {
        // GR2-KEY-01b (WP5 port): the 500k ETH trade is above 1 % of ETH's skew depth (about 142k at 517,076,707); this test is not
        // about the pair cap, so ETH's cap is raised to the 10 % maximum (the guardian's 31-day raise).
        _raisePairCapToMax(ETH);
        assertTrue(GOV.hasRole(GAINS_MANAGER, ROLE_MANAGER), "MANAGER role holder");
        _twoHolders(100_000e6, 100_000e6);
        uint32 idx = _openFilledV(ETH, true, 25_000e6, 20_000); // 500k
        _passHold(); // GR2-KEY-01b (WP5 port): the manager's close below waits the 10-minute minimum hold
        GainsSpikeTrader o = _outsider(100_000e6);
        _openOutside(o, ETH, true, 40_000e6, 100_000); // 4M of long skew so the depth matters
        uint256 nav0 = _venueValue();
        uint8[] memory ci = new uint8[](1);
        ci[0] = USDC_INDEX;
        uint16[] memory pi = new uint16[](1);
        pi[0] = ETH;
        uint256[] memory dep = new uint256[](1);
        dep[0] = GOV.getPairSkewDepth(USDC_INDEX, ETH) / 4;
        vm.prank(GAINS_MANAGER);
        GOV.setPairSkewDepths(ci, pi, dep);
        uint256 nav1 = _venueValue();
        console2.log("vault trade value before / after the MANAGER cuts the depth to 1/4", nav0, nav1);
        assertGt(nav1, nav0 + 1_000e6, "a single MANAGER call moves NAV by > 1,000 USDC, no timelock, no revert");
        uint256 got = _closeV(idx, ETH);
        assertGe(got, nav1, "NAV still never above the payout");
        assertLe(got - nav1, 1_100e6, "within the band (20 bps of 500k)");
    }

    // ==================================================================
    // Q2(d): Gains' MANAGER realizes negative PnL and holding fees on the vault's trade: NAV unchanged
    // ==================================================================
    function test_GNS_managerManualRealizations_navNeutral() public {
        _twoHolders(100_000e6, 100_000e6);
        uint32 idx = _openFilledV(ETH, true, 10_000e6, 5_000);
        _rollFresh(4 * 3_600); // some holding fees
        uint64 c = cl[ETH_USD];
        _setCl(ETH_USD, uint64((uint256(c) * 9_800) / 10_000)); // -2%: negative PnL
        _rollFresh(1);
        uint256 nav0 = _venueValue();
        uint256 usdc0 = _usdc();
        for (uint256 k; k < 2; ++k) {
            vm.recordLogs();
            vm.prank(GAINS_MANAGER);
            GOV.initiateManualNegativePnlRealization(address(v), idx, k == 1);
            Vm.Log[] memory req = vm.getRecordedLogs();
            _rollFresh(1);
            _fill(req, cl[ETH_USD]);
        }
        uint256 nav1 = _venueValue();
        console2.log("vault trade value before / after both manual realizations", nav0, nav1);
        assertEq(_usdc(), usdc0, "no USDC moved to or from the vault");
        assertApproxEqAbs(nav1, nav0, 2e6, "value unchanged (2 blocks of holding fees)");
        uint256 got = _closeV(idx, ETH);
        assertGe(got, nav1);
        assertLe(got - nav1, 110e6, "the band: 20 bps on 49k of notional (98 USDC)");
    }

    // ==================================================================
    // Q2(e): the gToken refuses a payout (NotEnoughAssets / MaxDailyPnl): the profitable close does not fill
    // ==================================================================
    function test_GNS_gTokenRefusesPayout_closeDoesNotFill_navUnchanged() public {
        // GR2-KEY-01b (WP5 port): the 250k ETH trade is above 1 % of ETH's skew depth (about 142k at 517,076,707); this test is not
        // about the pair cap, so ETH's cap is raised to the 10 % maximum (the guardian's 31-day raise).
        _raisePairCapToMax(ETH);
        _twoHolders(100_000e6, 100_000e6);
        uint32 idx = _openFilledV(ETH, true, 5_000e6, 50_000);
        _passHold(); // GR2-KEY-01b (WP5 port): the manager's close below waits the 10-minute minimum hold
        uint64 c = cl[ETH_USD];
        _setCl(ETH_USD, uint64((uint256(c) * 10_300) / 10_000)); // +3%: +150%, paid partly by gUSDC
        _rollFresh(1);
        uint256 nav0 = v.totalAssets();
        vm.mockCallRevert(GUSDC, abi.encodeWithSelector(IGToken.sendAssets.selector), abi.encodeWithSignature("MaxDailyPnl()"));
        Vm.Log[] memory req = _req(mgr, abi.encodeCall(GainsVault.closeTrade, (idx, cl[ETH_USD])));
        _rollFresh(1);
        uint256 reverted;
        for (uint256 i; i < req.length; i++) {
            Vm.Log memory l = req[i];
            if (l.topics[0] != ORACLE_REQUEST) continue;
            (address requester, bytes32 requestId) = abi.decode(l.data, (address, bytes32));
            if (requester != address(DIAMOND)) continue;
            vm.prank(l.emitter);
            try DIAMOND.fulfill(requestId, _packAnswer(cl[ETH_USD])) {} catch {
                ++reverted;
            }
        }
        vm.clearMockedCalls(); // also drops the ArbSys and Chainlink mocks: put them back
        _mockArbBlock();
        _refreshCl();
        console2.log("oracle answers that reverted", reverted);
        assertGt(reverted, 0, "the callback reverts with the gToken refusal: the node's answer fails");
        assertTrue(_trade(idx).isOpen, "the trade stays open");
        assertApproxEqAbs(v.totalAssets(), nav0, 1e6, "NAV still counts the full profit");
        assertFalse(v.ordersPending(), "a close in flight does not hold settle (GR1-04)");
    }

    // ==================================================================
    // Q4: Circle blacklists the diamond, then pauses USDC
    // ==================================================================
    function test_GNS_usdcBlacklistDiamondAndPause_failClosed_noMisvalue() public {
        _twoHolders(100_000e6, 100_000e6);
        uint32 idx = _openFilledV(ETH, true, 5_000e6, 20_000);
        _passHold(); // GR2-KEY-01b (WP5 port): the manager's close below waits the 10-minute minimum hold
        IFiatTokenR2 fiat = IFiatTokenR2(address(USDC));
        vm.prank(fiat.blacklister());
        fiat.blacklist(address(D));
        uint256 nav0 = v.totalAssets();
        // a close request still goes out; its fill cannot pay the vault
        Vm.Log[] memory req = _req(mgr, abi.encodeCall(GainsVault.closeTrade, (idx, cl[ETH_USD])));
        _rollFresh(1);
        bool anyFilled;
        for (uint256 i; i < req.length; i++) {
            Vm.Log memory l = req[i];
            if (l.topics[0] != ORACLE_REQUEST) continue;
            (address requester, bytes32 requestId) = abi.decode(l.data, (address, bytes32));
            if (requester != address(DIAMOND)) continue;
            vm.prank(l.emitter);
            try DIAMOND.fulfill(requestId, _packAnswer(cl[ETH_USD])) {
                anyFilled = true;
            } catch {}
        }
        assertTrue(_trade(idx).isOpen, "diamond blacklisted: the close cannot fill");
        assertApproxEqAbs(v.totalAssets(), nav0, 1e6, "NAV unchanged: the trade is still valued");
        // redemptions are paid from idle: settle moves no USDC, claim moves vault -> redeemer
        uint256 half = v.balanceOf(bob) / 2;
        vm.prank(bob);
        v.requestRedeem(half, bob, bob);
        vm.prank(keeper);
        v.settle();
        uint256 b0 = USDC.balanceOf(bob);
        v.claim(bob);
        assertGt(USDC.balanceOf(bob), b0, "a redemption from idle is paid while the diamond is blacklisted");
        // USDC paused: settle still books, claims revert until unpaused
        uint256 aliceHalf = v.balanceOf(alice) / 2;
        vm.prank(alice);
        v.requestRedeem(aliceHalf, alice, alice);
        _rollFresh(4 * 3_600);
        vm.prank(fiat.pauser());
        fiat.pause();
        vm.prank(keeper);
        v.settle();
        vm.expectRevert();
        v.claim(alice);
        console2.log("blacklisted diamond: fill succeeded?", anyFilled);
    }
}
