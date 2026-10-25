// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import "./LifecycleForkBase.sol";

interface IFiatToken {
    function blacklister() external view returns (address);
    function blacklist(address account) external;
    function isBlacklisted(address account) external view returns (bool);
}

interface IPairsListed {
    function isPairIndexListed(uint256 pairIndex) external view returns (bool);
}

/// @notice Task 5: exits never read NAV or prices (dynamic proof), MAX_POSITIONS never blocks an exit, flatten's
///         expectedPrice, Gains CLOSE_ONLY / PAUSED, a pair Gains no longer serves, Circle blacklisting the vault.
contract LC_LivenessForkTest is LifecycleForkBase {
    uint8 internal constant CANCEL_SLIPPAGE = 3;

    // ------------------------------------------------------------------ X1: exits read no price
    function _exitFixture() internal returns (uint32 a, uint32 b, uint32 c, uint32 lim, uint32 timedOut) {
        _depositSettle(alice, 20_000e6);
        a = _openFilledV(ETH, true, 1_000e6, 5_000);
        b = _openFilledV(ETH, false, 1_000e6, 3_000);
        c = _openFilledV(BTC, true, 1_000e6, 5_000);
        OpenParams memory p = _openParams(SOL, true, 500e6, 3_000);
        p.tradeType = 1;
        p.expectedPrice = cl[SOL_USD] * 80 / 100;
        vm.prank(mgr);
        v.openTrade(p);
        IGainsDiamond.Trade[] memory ts = D.getTrades(address(v));
        lim = ts[ts.length - 1].index;
        _req(mgr, abi.encodeCall(GainsVault.openTrade, (_openParams(BTC, false, 500e6, 3_000))));
        timedOut = _lastPending().index;
        // GR2-KEY-01b (WP5 port): was _rollFresh(200) (the open times out after 200 blocks); the manager's close in the
        // tests waits the 10-minute minimum hold, which is longer, so the open is timed out all the same
        _passHold();
        // a redemption larger than idle, so the operator's shortfall path is live outside a breach
        uint256 shares = v.balanceOf(alice) * 95 / 100;
        vm.prank(alice);
        v.requestRedeem(shares, alice, alice);
        assertGt(v.redemptionShortfall(), 0);
    }

    /// @dev vm.expectCall(..., 0): no call to the policy's price surface (price, navPrice, checkOrder) during any exit,
    ///      by every caller that may send it.
    function test_lc_exitsNeverCallPolicyPrices() public {
        (uint32 a, uint32 b, uint32 c, uint32 lim, uint32 timedOut) = _exitFixture();
        vm.expectCall(address(pol), abi.encodeWithSelector(GainsVaultPolicy.price.selector), 0);
        vm.expectCall(address(pol), abi.encodeWithSelector(GainsVaultPolicy.navPrice.selector), 0);
        vm.expectCall(address(pol), abi.encodeWithSelector(GainsVaultPolicy.checkOrder.selector), 0);
        vm.prank(stranger);
        v.cancelTimedOut(timedOut);
        vm.prank(keeper); // operator outside a breach: shortfall-capped collateral reduce
        v.reduceTrade(c, uint120(100e6), 0, cl[BTC_USD]);
        vm.prank(mgr);
        v.closeTrade(a, cl[ETH_USD]);
        vm.prank(fSentinel);
        v.cancelOrder(lim);
        vm.prank(fGuardian);
        v.flatten(ETH, 0, cl[ETH_USD], type(uint256).max); // closes b (a is in flight)
        assertEq(_pending().length, 3, "close a, close b, reduce c in flight");
        b;
    }

    /// @dev Same exits with every Chainlink feed reverting and the sequencer reported down: nothing the vault calls
    ///      on an exit depends on a price. (NAV readers revert SequencerDown at the same time.)
    function test_lc_exitsWorkWithEveryPriceSourceDown() public {
        (uint32 a, uint32 b, uint32 c, uint32 lim, uint32 timedOut) = _exitFixture();
        vm.mockCall(SEQ, abi.encodeWithSelector(IChainlinkFeed.latestRoundData.selector), abi.encode(uint80(1), int256(1), uint256(1), uint256(1), uint80(1)));
        vm.mockCallRevert(ETH_USD, abi.encodeWithSelector(IChainlinkFeed.latestRoundData.selector), "down");
        vm.mockCallRevert(BTC_USD, abi.encodeWithSelector(IChainlinkFeed.latestRoundData.selector), "down");
        vm.mockCallRevert(SOL_USD, abi.encodeWithSelector(IChainlinkFeed.latestRoundData.selector), "down");
        vm.expectRevert(GainsPrice.SequencerDown.selector);
        v.totalAssets();
        vm.prank(stranger);
        v.cancelTimedOut(timedOut);
        vm.prank(keeper);
        v.reduceTrade(c, uint120(100e6), 0, cl[BTC_USD]);
        vm.prank(mgr);
        v.closeTrade(a, cl[ETH_USD]);
        vm.prank(fSentinel);
        v.cancelOrder(lim);
        vm.prank(fSentinel);
        v.triggerBreach();
        vm.prank(creator); // owner in a breach
        v.reduceTrade(b, uint120(0), uint24(1_000), cl[ETH_USD]);
        vm.prank(fSentinel); // sentinel in a breach: flatten at the policy band
        v.flatten(BTC, 0, cl[BTC_USD], type(uint256).max);
        assertEq(_pending().length, 3, "close a, reduce b, reduce c (BTC flatten skips c, in flight)");
    }

    // ------------------------------------------------------------------ X2 / T2: MAX_POSITIONS never blocks an exit
    function test_lc_maxPositionsNeverBlocksExits() public {
        _depositSettle(alice, 100_000e6);
        uint16[3] memory pairs = [BTC, ETH, SOL];
        while (v.venue().orders < 19) {
            uint256 n = v.venue().orders;
            _openFilledV(pairs[n % 3], n % 2 == 0, 400e6, 3_000);
        }
        OpenParams memory p = _openParams(ETH, true, 400e6, 3_000);
        p.tradeType = 1;
        p.expectedPrice = cl[ETH_USD] * 80 / 100;
        vm.prank(mgr);
        v.openTrade(p); // 20th position: a resting limit
        assertEq(v.venue().orders, 20);
        vm.prank(mgr);
        vm.expectRevert(abi.encodeWithSelector(IGainsVaultErrors.TooManyPositions.selector, 20, 20));
        v.openTrade(_openParams(ETH, true, 400e6, 3_000));
        _passHold(); // GR2-KEY-01b (WP5 port): the manager's exits below wait the 10-minute minimum hold
        IGainsDiamond.Trade[] memory ts = D.getTrades(address(v));
        vm.startPrank(mgr);
        v.closeTrade(ts[0].index, cl[_feed(ts[0].pairIndex)]);
        v.reduceTrade(ts[1].index, uint120(100e6), 0, cl[_feed(ts[1].pairIndex)]);
        v.reduceTrade(ts[2].index, 0, uint24(1_000), cl[_feed(ts[2].pairIndex)]);
        v.cancelOrder(ts[ts.length - 1].index);
        vm.stopPrank();
        assertEq(v.venue().orders, 22, "19 trades + 3 pending exits: above the ceiling, exits still go out");
        vm.prank(fGuardian);
        (uint256 sent,) = v.flatten(BTC, 0, cl[BTC_USD], type(uint256).max);
        assertGt(sent, 0, "flatten above the ceiling");
    }

    // ------------------------------------------------------------------ X3: gas at 20 positions
    function _twentyMixed() internal returns (uint32 lim, uint32 pendingOpen) {
        _depositSettle(alice, 100_000e6);
        uint16[3] memory pairs = [BTC, ETH, SOL];
        while (v.venue().orders < 18) {
            uint256 n = v.venue().orders;
            _openFilledV(pairs[n % 3], n % 2 == 0, 400e6, 3_000);
        }
        OpenParams memory p = _openParams(ETH, true, 400e6, 3_000);
        p.tradeType = 1;
        p.expectedPrice = cl[ETH_USD] * 80 / 100;
        vm.prank(mgr);
        v.openTrade(p);
        IGainsDiamond.Trade[] memory ts = D.getTrades(address(v));
        lim = ts[ts.length - 1].index;
        _req(mgr, abi.encodeCall(GainsVault.openTrade, (_openParams(SOL, true, 400e6, 3_000))));
        pendingOpen = _lastPending().index;
        assertEq(v.venue().orders, 20);
    }

    function test_lc_gas_everyExitAndNavReaderAtTwentyPositions() public {
        (uint32 lim, uint32 pendingOpen) = _twentyMixed();
        _rollFresh(200);
        uint256 g;
        (g,) = _gas(address(this), abi.encodeCall(GainsVault.totalAssets, ()));
        console2.log("GAS totalAssets (18 trades + 1 limit + 1 pending open)", g);
        (g,) = _gas(keeper, abi.encodeCall(GainsVault.checkRisk, ()));
        console2.log("GAS checkRisk (same)", g);
        (g,) = _gas(stranger, abi.encodeCall(GainsVault.cancelTimedOut, (pendingOpen)));
        console2.log("GAS cancelTimedOut (20 positions)", g);
        (g,) = _gas(fSentinel, abi.encodeCall(GainsVault.cancelOrder, (lim)));
        console2.log("GAS cancelOrder (limit, 19 positions)", g);
        // back to 20: openTrade at 18 + 1 -> measured, filled
        Vm.Log[] memory req;
        (g, req) = _gas(mgr, abi.encodeCall(GainsVault.openTrade, (_openParams(BTC, true, 400e6, 3_000))));
        console2.log("GAS openTrade (18 trades -> 19th)", g);
        _rollFresh(1);
        _fill(req, cl[BTC_USD]);
        (g, req) = _gas(mgr, abi.encodeCall(GainsVault.openTrade, (_openParams(ETH, false, 400e6, 3_000))));
        console2.log("GAS openTrade (19 trades -> 20th)", g);
        _rollFresh(1);
        _fill(req, cl[ETH_USD]);
        assertEq(v.venue().orders, 20);
        IGainsDiamond.Trade[] memory ts = D.getTrades(address(v));
        (g,) = _gas(address(this), abi.encodeCall(GainsVault.totalAssets, ()));
        console2.log("GAS totalAssets (20 open trades)", g);
        _rollFresh(4 * 3_600);
        (g,) = _gas(keeper, abi.encodeCall(GainsVault.checkRisk, ()));
        console2.log("GAS checkRisk (20 open trades)", g);
        (g,) = _gas(mgr, abi.encodeCall(GainsVault.setSlTp, (ts[0].index, uint64(0), uint64(cl[_feed(ts[0].pairIndex)] * 3))));
        console2.log("GAS setSlTp (TP only, 20 trades)", g);
        uint256 shares = v.balanceOf(alice) / 10;
        vm.prank(alice);
        v.requestRedeem(shares, alice, alice);
        (g,) = _gas(keeper, abi.encodeCall(GainsVault.settle, ()));
        console2.log("GAS settle (20 open trades, a redemption)", g);
        // a redemption above idle: the operator's shortfall reduce
        shares = v.balanceOf(alice) * 95 / 100;
        vm.prank(alice);
        v.requestRedeem(shares, alice, alice);
        uint256 sf = v.redemptionShortfall();
        (g,) = _gas(keeper, abi.encodeCall(GainsVault.reduceTrade, (ts[1].index, uint120(100e6), uint24(0), cl[_feed(ts[1].pairIndex)])));
        console2.log("GAS reduceTrade (operator, shortfall path, 20 trades)", g, "shortfall", sf);
        (g,) = _gas(mgr, abi.encodeCall(GainsVault.reduceTrade, (ts[2].index, uint120(100e6), uint24(0), cl[_feed(ts[2].pairIndex)])));
        console2.log("GAS reduceTrade (manager)", g);
        (g,) = _gas(mgr, abi.encodeCall(GainsVault.closeTrade, (ts[3].index, cl[_feed(ts[3].pairIndex)])));
        console2.log("GAS closeTrade", g);
        (g,) = _gas(address(this), abi.encodeCall(GainsVault.redemptionShortfall, ()));
        console2.log("GAS redemptionShortfall view (3 pending)", g);
        (g,) = _gas(fGuardian, abi.encodeCall(GainsVault.flatten, (SOL, uint256(0), cl[SOL_USD], type(uint256).max)));
        console2.log("GAS flatten (all SOL trades, mixed 20)", g);
        (g,) = _gas(address(this), abi.encodeCall(GainsVault.totalAssets, ()));
        console2.log("GAS totalAssets (20 trades + pending closes)", g);
    }

    /// @dev The heaviest NAV state: 20 open trades, each with a pending UPDATE_LEVERAGE decrease (GainsNav does a
    ///      getTrade and a min gov fee read per pending order). Then flatten skips every trade.
    function test_lc_gas_navWorstCase_twentyTradesTwentyPendingLeverageDecreases() public {
        _depositSettle(alice, 100_000e6);
        uint16[3] memory pairs = [BTC, ETH, SOL];
        while (v.venue().orders < 20) {
            uint256 n = v.venue().orders;
            _openFilledV(pairs[n % 3], n % 2 == 0, 400e6, 3_000);
        }
        IGainsDiamond.Trade[] memory ts = D.getTrades(address(v));
        for (uint256 i; i < ts.length; ++i) {
            vm.prank(mgr);
            v.updateLeverage(ts[i].index, 2_000);
        }
        assertEq(v.venue().pending, 20);
        assertEq(v.venue().orders, 40);
        uint256 g;
        (g,) = _gas(address(this), abi.encodeCall(GainsVault.totalAssets, ()));
        console2.log("GAS totalAssets (20 trades + 20 pending leverage decreases)", g);
        _rollFresh(4 * 3_600);
        (g,) = _gas(keeper, abi.encodeCall(GainsVault.checkRisk, ()));
        console2.log("GAS checkRisk (20 trades + 20 pending leverage decreases)", g);
        assertLt(g, 32_000_000);
        (g,) = _gas(address(this), abi.encodeCall(GainsVault.redemptionShortfall, ()));
        console2.log("GAS redemptionShortfall (20 pending)", g);
        uint256 sent;
        uint256 remaining;
        vm.prank(fGuardian);
        (sent, remaining) = v.flatten(ETH, 0, cl[ETH_USD], type(uint256).max);
        assertEq(sent + remaining, 0, "every trade has a market order in flight: flatten skips all");
    }

    // ------------------------------------------------------------------ flatten, maxTrades and expectedPrice
    function _twentyOnEth() internal {
        _depositSettle(alice, 100_000e6);
        while (v.venue().orders < 20) {
            uint256 n = v.venue().orders;
            _openFilledV(ETH, n % 2 == 0, 400e6, 3_000);
        }
    }

    function test_lc_gas_flattenTwentyOnOnePair_oneCallAndBatches() public {
        _twentyOnEth();
        (uint256 g, Vm.Log[] memory req) = _gas(fGuardian, abi.encodeCall(GainsVault.flatten, (ETH, uint256(0), cl[ETH_USD], type(uint256).max)));
        console2.log("GAS flatten (20 ETH trades, one call)", g);
        assertLt(g, 32_000_000);
        _rollFresh(1);
        Vm.Log[] memory fill = _fill(req, cl[ETH_USD]);
        assertEq(_count(fill, G.MarketExecuted.selector), 20, "expectedPrice = C protects longs and shorts alike");
        assertEq(lens.openPositions(v), 0);
    }

    function test_lc_gas_flattenBatches_7_7_6() public {
        _twentyOnEth();
        uint256 g;
        uint256 total;
        for (uint256 i; i < 3; ++i) {
            (g,) = _gas(fGuardian, abi.encodeCall(GainsVault.flatten, (ETH, uint256(0), cl[ETH_USD], uint256(7))));
            console2.log("GAS flatten batch of <=7", g);
            total += g;
        }
        assertEq(_pending().length, 20);
        vm.prank(fGuardian);
        (uint256 sent, uint256 rem) = v.flatten(ETH, 0, cl[ETH_USD], 7);
        assertEq(sent + rem, 0);
        console2.log("GAS flatten 3 batches total", total);
    }

    /// @dev One expectedPrice for both sides: a hot role in a breach (sentinel, operator, owner) can pass a price that
    ///      guarantees every short's close is cancelled (Gains: fill > expected + slippage) while the longs go out with
    ///      no effective bound. Gains books its min gov fee on each cancelled trade; the trades stay open; settle is
    ///      blocked until the answers. The fills themselves are always at the oracle price.
    function test_lc_flattenExpectedPrice_guaranteedFailureCostsGovFees() public {
        _twentyOnEth();
        vm.prank(fSentinel);
        v.triggerBreach();
        uint256 navBefore = _nav();
        Vm.Log[] memory req = _req(fSentinel, abi.encodeCall(GainsVault.flatten, (ETH, uint256(0), cl[ETH_USD] / 2, type(uint256).max)));
        _rollFresh(1);
        Vm.Log[] memory fill = _fill(req, cl[ETH_USD]);
        uint256 executed = _count(fill, G.MarketExecuted.selector);
        uint256 cancelled = _count(fill, G.MarketCloseCanceled.selector);
        console2.log("flatten at C/2: longs executed / shorts cancelled", executed, cancelled);
        assertEq(executed, 10);
        assertEq(cancelled, 10);
        uint256 navAfter = _nav();
        console2.log("NAV before (at P) / after (10 closed at C, 10 cancelled)", navBefore, navAfter);
        // the 10 shorts each carry a realized gov fee now
        IGainsDiamond.Trade[] memory ts = D.getTrades(address(v));
        (, uint256 fee,) = D.getTradeRealizedPnlCollateral(address(v), ts[0].index);
        console2.log("realized trading fees on one cancelled short (opening fee + gov fee)", fee);
    }

    function test_lc_flattenZeroArgsRevert() public {
        _depositSettle(alice, 10_000e6);
        vm.prank(fGuardian);
        vm.expectRevert(IGainsVaultErrors.ZeroAmount.selector);
        v.flatten(ETH, 0, 0, 1);
        vm.prank(fGuardian);
        vm.expectRevert(IGainsVaultErrors.ZeroAmount.selector);
        v.flatten(ETH, 0, cl[ETH_USD], 0);
    }

    // ------------------------------------------------------------------ Gains CLOSE_ONLY / PAUSED
    /// @dev Finds the byte of diamond storage behind getTradingActivated() (record its reads, flip each byte, keep the
    ///      one that makes the getter return the new state) and sets it.
    function _setTradingActivated(uint8 state) internal {
        IGainsTriggerLC g = IGainsTriggerLC(address(D));
        vm.record();
        g.getTradingActivated();
        (bytes32[] memory reads,) = vm.accesses(address(D));
        for (uint256 i; i < reads.length; ++i) {
            bytes32 slot = reads[i];
            uint256 val = uint256(vm.load(address(D), slot));
            for (uint256 k; k < 32; ++k) {
                uint256 mask = uint256(0xff) << (8 * k);
                if (val & mask != 0) continue; // the live state is ACTIVATED (0)
                // double check with both non-zero states, then set the requested one
                bool hit = _getterReads(slot, val | (uint256(1) << (8 * k)), 1) && _getterReads(slot, val | (uint256(2) << (8 * k)), 2);
                if (hit) {
                    vm.store(address(D), slot, bytes32(val | (uint256(state) << (8 * k))));
                    _taSlot = slot;
                    _taOrig = val;
                    console2.log("tradingActivated slot / byte", uint256(slot), k);
                    return;
                }
                vm.store(address(D), slot, bytes32(val));
            }
        }
        revert("tradingActivated slot not found");
    }

    function test_lc_gainsCloseOnly_whatStillWorks() public {
        _depositSettle(alice, 20_000e6);
        uint32 a = _openFilledV(ETH, true, 1_000e6, 5_000);
        uint32 b = _openFilledV(BTC, true, 1_000e6, 5_000);
        // GR2-KEY-01b (WP5 port): the manager's close of `a` below waits the 10-minute minimum hold, which also runs from
        // a pending open's request on the same pair. The hold is waited here, and the pending open goes to SOL (was an
        // ETH short) so it stays inside Gains' 200-block timeout when CLOSE_ONLY lands and its answer is tried.
        _passHold();
        Vm.Log[] memory openReq = _req(mgr, abi.encodeCall(GainsVault.openTrade, (_openParams(SOL, false, 500e6, 3_000))));
        uint32 pendingOpen = _lastPending().index;
        _setTradingActivated(1); // CLOSE_ONLY
        assertEq(IGainsTriggerLC(address(D)).getTradingActivated(), 1);

        (bool ok,) = _try(mgr, abi.encodeCall(GainsVault.openTrade, (_openParams(ETH, true, 500e6, 3_000))));
        assertFalse(ok, "open refused by Gains");
        (ok,) = _try(mgr, abi.encodeCall(GainsVault.setSlTp, (a, uint64(cl[ETH_USD] * 90 / 100), uint64(0))));
        assertFalse(ok, "setSlTp refused (updateSl is tradingActivated): no SL tightening in CLOSE_ONLY");
        (ok,) = _try(mgr, abi.encodeCall(GainsVault.updateLeverage, (a, uint24(3_000))));
        assertFalse(ok, "adding margin refused");
        // the pending open cannot be filled (callback tradingActivated): the answer reverts or is dropped
        _rollFresh(1);
        uint256 answered;
        for (uint256 i; i < openReq.length; i++) {
            if (openReq[i].topics[0] != ORACLE_REQUEST) continue;
            (address requester, bytes32 requestId) = abi.decode(openReq[i].data, (address, bytes32));
            if (requester != address(DIAMOND)) continue;
            vm.prank(openReq[i].emitter);
            try DIAMOND.fulfill(requestId, _packAnswer(cl[SOL_USD])) {
                answered++;
            } catch {}
        }
        console2.log("CLOSE_ONLY: oracle answers accepted for a pending open", answered);
        assertTrue(v.ordersPending(), "the open is still pending");
        // exits work
        Vm.Log[] memory closeReq = _req(mgr, abi.encodeCall(GainsVault.closeTrade, (a, cl[ETH_USD])));
        _req(fGuardian, abi.encodeCall(GainsVault.flatten, (BTC, uint256(0), cl[BTC_USD], type(uint256).max)));
        _rollFresh(1);
        _fill(closeReq, cl[ETH_USD]);
        assertFalse(_trade(a).isOpen, "close filled in CLOSE_ONLY");
        _rollFresh(200);
        vm.prank(stranger);
        v.cancelTimedOut(pendingOpen);
        b;
    }

    /// @dev Fix round (GR1-04): a stuck close holds no collateral and no longer holds settle; the settle runs while
    ///      Gains is PAUSED (was: OrdersPending until Gains resumes).
    function test_lc_gainsPaused_exitsRevert_stuckCloseNoLongerHoldsSettle() public {
        _depositSettle(alice, 20_000e6);
        uint32 a = _openFilledV(ETH, true, 1_000e6, 5_000);
        uint32 b = _openFilledV(BTC, true, 1_000e6, 5_000);
        // GR2-KEY-01b (WP5 port): waited first, so the refusals below are Gains' pause, not the minimum hold
        _passHold();
        // a close in flight when Gains pauses
        _req(mgr, abi.encodeCall(GainsVault.closeTrade, (b, cl[BTC_USD])));
        uint32 pendingClose = _lastPending().index;
        _setTradingActivated(2); // PAUSED
        (bool ok,) = _try(mgr, abi.encodeCall(GainsVault.closeTrade, (a, cl[ETH_USD])));
        assertFalse(ok, "close refused");
        (ok,) = _try(mgr, abi.encodeCall(GainsVault.reduceTrade, (a, uint120(100e6), uint24(0), cl[ETH_USD])));
        assertFalse(ok, "reduce refused");
        (ok,) = _try(fGuardian, abi.encodeCall(GainsVault.flatten, (ETH, uint256(0), cl[ETH_USD], type(uint256).max)));
        assertFalse(ok, "flatten reverts as a whole (closeTradeMarket is not try/caught)");
        _rollFresh(200);
        (ok,) = _try(stranger, abi.encodeCall(GainsVault.cancelTimedOut, (pendingClose)));
        assertFalse(ok, "timed-out cancel refused while PAUSED");
        // NAV still reads, redemptions can be requested, and the stuck close does not hold the settle (GR1-04)
        uint256 nav = _nav();
        assertGt(nav, 0);
        uint256 shares = v.balanceOf(alice) / 10;
        vm.prank(alice);
        v.requestRedeem(shares, alice, alice);
        v.checkRisk();
        assertFalse(v.ordersPending(), "a stuck close holds nothing");
        uint256 epoch = v.currentEpoch();
        vm.prank(keeper);
        v.settle();
        assertEq(v.currentEpoch(), epoch + 1, "settled while PAUSED with the close stuck");
        // back to ACTIVATED: the stuck close can be cancelled
        _setTradingActivatedBack();
        vm.prank(stranger);
        v.cancelTimedOut(pendingClose);
    }

    function test_lc_gainsPaused_noPendingOrder_settleStillRuns() public {
        _depositSettle(alice, 20_000e6);
        _openFilledV(ETH, true, 1_000e6, 5_000);
        _setTradingActivated(2);
        uint256 shares = v.balanceOf(alice) / 10;
        vm.prank(alice);
        v.requestRedeem(shares, alice, alice);
        _rollFresh(10);
        v.checkRisk();
        vm.prank(keeper);
        v.settle();
        v.claim(alice);
    }

    bytes32 internal _taSlot;
    uint256 internal _taOrig;

    function _getterReads(bytes32 slot, uint256 value, uint8 expected) internal returns (bool hit) {
        vm.store(address(D), slot, bytes32(value));
        try IGainsTriggerLC(address(D)).getTradingActivated() returns (uint8 s) {
            hit = s == expected;
        } catch {}
    }

    function _setTradingActivatedBack() internal {
        vm.store(address(D), _taSlot, bytes32(_taOrig));
        assertEq(IGainsTriggerLC(address(D)).getTradingActivated(), 0);
    }

    // ------------------------------------------------------------------ a pair Gains no longer serves
    /// @dev Emulated delisting: Gains reports the pair as not listed (no new trade) and its oracle stops answering
    ///      for it. Opens are refused; closes go out but time out; anyone cancels; the trade's value stays locked but
    ///      valued (Chainlink still prices it), settle runs between attempts and pays redemptions from idle only.
    function test_lc_pairNoLongerServed_valueLockedButSettleRuns() public {
        _depositSettle(alice, 10_000e6);
        uint32 a = _openFilledV(ETH, true, 5_000e6, 2_000);
        _passHold(); // GR2-KEY-01b (WP5 port): the manager's close below waits the 10-minute minimum hold
        vm.mockCall(address(D), abi.encodeWithSelector(IPairsListed.isPairIndexListed.selector, uint256(ETH)), abi.encode(false));
        (bool ok,) = _try(mgr, abi.encodeCall(GainsVault.openTrade, (_openParams(ETH, true, 500e6, 3_000))));
        assertFalse(ok, "Gains refuses new ETH trades");
        _req(mgr, abi.encodeCall(GainsVault.closeTrade, (a, cl[ETH_USD])));
        uint32 o = _lastPending().index;
        _rollFresh(200); // never answered
        vm.prank(stranger);
        v.cancelTimedOut(o);
        assertTrue(_trade(a).isOpen, "value locked in the trade");
        // everyone redeems: idle (~5,000) < owed (~10,000)
        uint256 shares = v.balanceOf(alice);
        vm.prank(alice);
        v.requestRedeem(shares, alice, alice);
        _rollFresh(10);
        v.checkRisk();
        vm.prank(keeper);
        vm.expectRevert(); // InsufficientLiquidity: a normal settle pays in full or not at all
        v.settle();
        vm.prank(fGuardian);
        v.triggerEmergency();
        vm.prank(fGuardian);
        v.settle(); // exit-only: partial fill from idle
        v.claim(alice);
        console2.log("emergency fill with the ETH trade unclosable: USDC paid", USDC.balanceOf(alice) - 190_000e6);
    }

    // ------------------------------------------------------------------ Circle blacklists the vault
    function test_lc_usdcBlacklistsVault_whatStillWorks() public {
        _depositSettle(alice, 10_000e6);
        uint32 a = _openFilledV(ETH, true, 1_000e6, 5_000);
        // a pending open when the blacklist lands
        _req(mgr, abi.encodeCall(GainsVault.openTrade, (_openParams(ETH, false, 500e6, 3_000))));
        uint32 pendingOpen = _lastPending().index;
        IFiatToken usdc = IFiatToken(address(USDC));
        vm.prank(usdc.blacklister());
        usdc.blacklist(address(v));
        assertTrue(usdc.isBlacklisted(address(v)));

        vm.prank(bob);
        vm.expectRevert();
        v.requestDeposit(100e6, bob);
        uint256 shares = v.balanceOf(alice) / 10;
        vm.prank(alice);
        v.requestRedeem(shares, alice, alice); // no USDC moves
        // GR2-KEY-01b (WP5 port): the manager's close waits the 10-minute minimum hold (from the pending ETH open's
        // request); the pending open times out meanwhile, which changes nothing below (its cancel is tried after a timeout)
        _passHold();
        Vm.Log[] memory closeReq = _req(mgr, abi.encodeCall(GainsVault.closeTrade, (a, cl[ETH_USD]))); // request moves no USDC
        _rollFresh(1);
        uint256 ok;
        uint256 failed;
        for (uint256 i; i < closeReq.length; i++) {
            if (closeReq[i].topics[0] != ORACLE_REQUEST) continue;
            (address requester, bytes32 requestId) = abi.decode(closeReq[i].data, (address, bytes32));
            if (requester != address(DIAMOND)) continue;
            vm.prank(closeReq[i].emitter);
            try DIAMOND.fulfill(requestId, _packAnswer(cl[ETH_USD])) {
                ok++;
            } catch {
                failed++;
            }
        }
        console2.log("blacklisted vault: close answers accepted / reverted", ok, failed);
        console2.log("  trade still open after the answer", _trade(a).isOpen);
        _rollFresh(200);
        (bool s,) = _try(stranger, abi.encodeCall(GainsVault.cancelTimedOut, (pendingOpen)));
        assertFalse(s, "timed-out open cannot be cancelled: the refund transfer to the vault reverts");
        assertTrue(v.ordersPending());
        v.checkRisk();
        vm.prank(keeper);
        vm.expectRevert(IGainsVaultErrors.OrdersPending.selector);
        v.settle(); // blocked for as long as the blacklist lasts
    }
}
