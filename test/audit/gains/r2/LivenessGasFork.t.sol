// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import "./liveness/LiveLifecycleBase.sol";
import {MockChainlinkFeed} from "../../../gains/mocks/GainsMocks.sol";

interface IPairsListedLive {
    function isPairIndexListed(uint256 pairIndex) external view returns (bool);
    function pairsCount() external view returns (uint256);
}

/// @notice Round 2, domain LIVE (3.7): gas of every exit and settle path at the MAX_POSITIONS ceiling on the Arbitrum One
///         fork (real gTrade v10 diamond, LiveForkBase pin; run of record 516,380,000), in the worst mixes the ceiling allows:
///         - 20 open trades + 20 pending orders that hold nothing (leverage-only increases: GR1-04 lets settle run
///           beside them, and GainsNav reads the trade for each), settle in every mode, deposits included (both
///           band edges);
///         - 20 resting limit orders for triggerBreach / triggerEmergency (_cancelResting);
///         - 20 trades + 10 / 19 pending closes for redemptionShortfall and the operator's reduce;
///         - flatten / flattenIndices of 20 trades with a slippage update on every trade;
///         - 20 trades on 20 different pairs (one Chainlink read per pair).
///         Chainlink feeds are vm.mockCall'ed (as in every fork test of this repo), so a real feed read is measured
///         separately (test_GR2_LIVE_gas_realFeedReadCost) and added per distinct pair in LIVENESS.md.
///         Every figure is the execution gas of one top-level vault call (forge starts each one cold); add 21,000 +
///         calldata for the transaction.
contract LivenessGasForkTest is LiveLifecycleBase {
    uint256 internal constant ARB_LIMIT = 32_000_000;
    uint256 internal constant HEADROOM_LINE = 26_000_000;

    function _h(string memory what, uint256 g) internal pure {
        console2.log(what, g, ((ARB_LIMIT - g) * 100) / ARB_LIMIT);
        assertLt(g, ARB_LIMIT, what);
    }

    function _fill20Mixed(uint120 coll) internal {
        _depositSettle(alice, 100_000e6);
        uint16[3] memory pairs = [BTC, ETH, SOL];
        uint256 n = v.venue().orders;
        while (n < 20) {
            _openFilledV(pairs[n % 3], n % 2 == 0, coll, 3_000);
            n = v.venue().orders;
        }
    }

    /// @dev A leverage increase on every trade: 20 pending UPDATE_LEVERAGE increases (non-holding; GainsNav reads the trade
    ///      for each). increaseTrade cannot be used at the ceiling (TooManyPositions), updateLeverage has no ceiling check.
    function _twentyNonHolding() internal {
        IGainsDiamond.Trade[] memory ts = D.getTrades(address(v));
        for (uint256 i; i < ts.length; ++i) {
            vm.prank(mgr);
            v.updateLeverage(ts[i].index, ts[i].leverage + 1_000); // UPDATE_LEVERAGE increase: no ceiling check, holds nothing
        }
        GainsNavSnapshotLike memory s = _snap();
        assertEq(s.pending, 20);
        assertEq(s.orders, 40);
        assertFalse(v.ordersPending(), "leverage-only increases hold nothing (GR1-04)");
    }

    struct GainsNavSnapshotLike {
        uint256 orders;
        uint256 pending;
    }

    function _snap() internal view returns (GainsNavSnapshotLike memory s) {
        s.orders = v.venue().orders;
        s.pending = v.venue().pending;
    }

    // ------------------------------------------------------------------ settle in every mode, worst NAV state
    function test_GR2_LIVE_gas_settleEveryMode_20Trades20NonHoldingPending() public {
        _fill20Mixed(400e6);
        _twentyNonHolding();
        uint256 g;
        (g,) = _gas(address(this), abi.encodeCall(GainsVault.totalAssets, ()));
        _h("totalAssets (20T + 20 non-holding pending) / % headroom", g);
        (g,) = _gas(address(this), abi.encodeCall(GainsVault.venue, ()));
        _h("venue() both edges (20T + 20P)", g);

        vm.prank(bob);
        v.requestDeposit(1_000e6, bob);
        uint256 shares = v.balanceOf(alice) / 100;
        vm.prank(alice);
        v.requestRedeem(shares, alice, alice);
        _rollFresh(4 * 3_600);
        (g,) = _gas(keeper, abi.encodeCall(GainsVault.checkRisk, ()));
        _h("checkRisk (20T + 20P)", g);
        uint256 snap = vm.snapshotState();

        (g,) = _gas(keeper, abi.encodeCall(GainsVault.settle, ()));
        _h("settle normal, deposits + redemption, favourable edge (20T + 20P)", g);
        assertEq(v.pendingDepositAssets(), 0);
        vm.revertToState(snap);

        vm.prank(bob);
        v.cancelDepositRequest();
        (g,) = _gas(keeper, abi.encodeCall(GainsVault.settle, ()));
        _h("settle normal, redemption only (20T + 20P)", g);
        vm.revertToState(snap);

        (g,) = _gas(fGuardian, abi.encodeCall(GainsVault.triggerEmergency, ()));
        _h("triggerEmergency (20T + 20P, no resting order)", g);
        (g,) = _gas(fGuardian, abi.encodeCall(GainsVault.settle, ()));
        _h("settle exit-only (emergency), deposits refunded (20T + 20P)", g);
        vm.revertToState(snap);

        // overdue exit-only settle by the sentinel (no emergency): idle covers the 1% redemption
        _rollFresh(4 * 7 days); // _roll advances 1 s per 4 blocks
        v.checkRisk();
        (g,) = _gas(fSentinel, abi.encodeCall(GainsVault.settle, ()));
        _h("settle exit-only (overdue, sentinel) (20T + 20P)", g);
    }

    // ------------------------------------------------------------------ emergency partial fill and the depositor calls
    function test_GR2_LIVE_gas_emergencyPartialFill_depositorCalls_20Trades() public {
        _fill20Mixed(2_000e6); // 40k on the diamond, ~61k idle
        uint256 shares = v.balanceOf(alice) * 95 / 100;
        uint256 g;
        (g,) = _gas(alice, abi.encodeCall(GainsVault.requestRedeem, (shares, alice, alice)));
        _h("requestRedeem (20 positions)", g);
        _rollFresh(10);
        v.checkRisk();
        (g,) = _gas(fGuardian, abi.encodeCall(GainsVault.triggerEmergency, ()));
        _h("triggerEmergency (20 trades)", g);
        // the guardian flattens every pair; 20 closes in flight do not hold the settle
        Vm.Log[] memory r1 = _req(fGuardian, abi.encodeCall(GainsVault.flatten, (BTC, uint256(0), cl[BTC_USD], type(uint256).max)));
        Vm.Log[] memory r2 = _req(fGuardian, abi.encodeCall(GainsVault.flatten, (ETH, uint256(0), cl[ETH_USD], type(uint256).max)));
        Vm.Log[] memory r3 = _req(fGuardian, abi.encodeCall(GainsVault.flatten, (SOL, uint256(0), cl[SOL_USD], type(uint256).max)));
        assertEq(_pending().length, 20);
        (g,) = _gas(fSentinel, abi.encodeCall(GainsVault.settle, ()));
        _h("settle exit-only, partial fill, 20 closes in flight", g);
        (uint256 epoch,,) = v.requests(alice);
        (,, uint256 rs, uint256 ra, uint256 rb,,,) = v.epochs(epoch);
        console2.log("round 1: shares / paid / burned", rs, ra, rb);
        assertLt(rb, rs, "partial fill");
        (g,) = _gas(stranger, abi.encodeCall(GainsVault.claim, (alice)));
        _h("claim (partial fill: USDC + returned shares)", g);
        uint256 back = v.balanceOf(alice);
        (g,) = _gas(alice, abi.encodeCall(GainsVault.requestRedeem, (back, alice, alice)));
        _h("requestRedeem (round 2)", g);
        (g,) = _gas(alice, abi.encodeCall(GainsVault.cancelRedeemRequest, ()));
        _h("cancelRedeemRequest", g);
        vm.prank(alice);
        v.requestRedeem(back, alice, alice);
        // the closes fill (Gains' own oracle, independent of the Chainlink feeds), then round 2 pays in full
        _rollFresh(1);
        _fill(r1, cl[BTC_USD]);
        _fill(r2, cl[ETH_USD]);
        _fill(r3, cl[SOL_USD]);
        assertEq(D.getTrades(address(v)).length, 0);
        (g,) = _gas(fSentinel, abi.encodeCall(GainsVault.settle, ()));
        _h("settle exit-only, flat vault (round 2)", g);
        (epoch,,) = v.requests(alice);
        (,, rs, ra, rb,,,) = v.epochs(epoch);
        assertEq(rb, rs, "round 2 fills in full");
        v.claim(alice);
        console2.log("rounds for a 95% redeemer with the trades closed between: 2 settles, 4 depositor txs");
    }

    // ------------------------------------------------------------------ full stop with 20 resting orders
    function test_GR2_LIVE_gas_triggerBreachAndEmergency_20RestingOrders() public {
        _depositSettle(alice, 100_000e6);
        uint16[3] memory pairs = [BTC, ETH, SOL];
        for (uint256 i; i < 20; ++i) {
            uint16 pair = pairs[i % 3];
            OpenParams memory p = _openParams(pair, true, 400e6, 3_000);
            p.tradeType = 1;
            p.expectedPrice = cl[_feed(pair)] * 80 / 100;
            vm.prank(mgr);
            v.openTrade(p);
        }
        assertEq(D.getTrades(address(v)).length, 20);
        uint256 snap = vm.snapshotState();
        (uint256 g,) = _gas(fSentinel, abi.encodeCall(GainsVault.triggerBreach, ()));
        _h("triggerBreach (sentinel), 20 resting orders cancelled", g);
        assertEq(D.getTrades(address(v)).length, 0, "every resting order cancelled");
        vm.revertToState(snap);
        (g,) = _gas(fGuardian, abi.encodeCall(GainsVault.triggerEmergency, ()));
        _h("triggerEmergency (guardian), 20 resting orders cancelled", g);
        assertEq(D.getTrades(address(v)).length, 0);
        vm.revertToState(snap);
        // the same state with the owner as caller (owner may full-stop too)
        (g,) = _gas(creator, abi.encodeCall(GainsVault.triggerBreach, ()));
        _h("triggerBreach (owner), 20 resting orders", g);
    }

    // ------------------------------------------------------------------ redemptionShortfall and the operator's reduce
    function test_GR2_LIVE_gas_redemptionShortfall_operatorReduce_pendingCloses() public {
        _fill20Mixed(2_000e6);
        uint256 shares = v.balanceOf(alice) * 95 / 100;
        vm.prank(alice);
        v.requestRedeem(shares, alice, alice);
        _passHold(); // GR2-KEY-01b (WP5 port): was _rollFresh(10); the manager's closes wait the 10-minute minimum hold
        v.checkRisk();
        IGainsDiamond.Trade[] memory ts = D.getTrades(address(v));
        for (uint256 i; i < 10; ++i) {
            vm.prank(mgr);
            v.closeTrade(ts[i].index, cl[_feed(ts[i].pairIndex)]);
        }
        uint256 g;
        (g,) = _gas(address(this), abi.encodeCall(GainsVault.redemptionShortfall, ()));
        _h("redemptionShortfall view (20 trades, 10 pending closes)", g);
        uint256 sf = v.redemptionShortfall();
        assertGt(sf, 1_000e6);
        (g,) = _gas(keeper, abi.encodeCall(GainsVault.reduceTrade, (ts[10].index, uint120(1_000e6), uint24(0), cl[_feed(ts[10].pairIndex)])));
        _h("reduceTrade by the operator (shortfall path, 20 trades + 10 pending closes)", g);
        for (uint256 i = 11; i < 20; ++i) {
            vm.prank(mgr);
            v.closeTrade(ts[i].index, cl[_feed(ts[i].pairIndex)]);
        }
        assertEq(_pending().length, 20);
        (g,) = _gas(address(this), abi.encodeCall(GainsVault.redemptionShortfall, ()));
        _h("redemptionShortfall view (20 trades, 20 pending: 19 closes + 1 partial close)", g);
    }

    // ------------------------------------------------------------------ flatten with a slippage update on every trade
    function test_GR2_LIVE_gas_flattenAndFlattenIndices_20OnOnePair_slippageUpdated() public {
        _depositSettle(alice, 100_000e6);
        for (uint256 i; i < 20; ++i) {
            OpenParams memory p = _openParams(ETH, i % 2 == 0, 400e6, 3_000);
            p.maxSlippageP = 500; // flatten's policy band is 1,000: every trade gets updateMaxClosingSlippageP
            Vm.Log[] memory req = _req(mgr, abi.encodeCall(GainsVault.openTrade, (p)));
            _rollFresh(1);
            _fill(req, cl[ETH_USD]);
        }
        IGainsDiamond.Trade[] memory ts = D.getTrades(address(v));
        assertEq(ts.length, 20);
        console2.log("stored maxSlippageP of a market trade (flatten updates when != policy band)", D.getTradeInfo(address(v), ts[0].index).maxSlippageP);
        uint32[] memory ix = new uint32[](20);
        for (uint256 i; i < 20; ++i) {
            ix[i] = ts[i].index;
        }
        uint256 snap = vm.snapshotState();
        (uint256 g,) = _gas(fGuardian, abi.encodeCall(GainsVault.flatten, (ETH, uint256(0), cl[ETH_USD], type(uint256).max)));
        _h("flatten 20 ETH trades, slippage updated on each (one call)", g);
        assertEq(_pending().length, 20);
        if (g > HEADROOM_LINE) console2.log("ABOVE 26M: less than 20% headroom");
        vm.revertToState(snap);
        (g,) = _gas(fGuardian, abi.encodeCall(GainsVault.flattenIndices, (ix, uint256(0), cl[ETH_USD])));
        _h("flattenIndices 20 ETH trades (one call)", g);
        if (g > HEADROOM_LINE) console2.log("ABOVE 26M: less than 20% headroom");
        vm.revertToState(snap);
        // batches of 7 still work
        uint256 total;
        for (uint256 i; i < 3; ++i) {
            (g,) = _gas(fGuardian, abi.encodeCall(GainsVault.flatten, (ETH, uint256(0), cl[ETH_USD], uint256(7))));
            total += g;
            _h("flatten batch of <= 7 (slippage updated)", g);
        }
        assertEq(_pending().length, 20);
        console2.log("flatten 3 batches total", total);
    }

    // ------------------------------------------------------------------ single exits at 20 positions
    function test_GR2_LIVE_gas_singleExitsAt20Positions() public {
        _depositSettle(alice, 100_000e6);
        uint16[3] memory pairs = [BTC, ETH, SOL];
        while (v.venue().orders < 19) {
            uint256 n = v.venue().orders;
            _openFilledV(pairs[n % 3], n % 2 == 0, 400e6, 3_000);
        }
        _req(mgr, abi.encodeCall(GainsVault.openTrade, (_openParams(SOL, true, 400e6, 3_000))));
        uint32 pendingOpen = _lastPending().index;
        assertEq(v.venue().orders, 20);
        assertTrue(v.ordersPending());
        uint256 timeoutBlocks = DIAMOND.getMarketOrdersTimeoutBlocks();
        console2.log("Gains marketOrdersTimeoutBlocks (L2 blocks)", timeoutBlocks);
        _rollFresh(timeoutBlocks);
        uint256 g;
        (g,) = _gas(stranger, abi.encodeCall(GainsVault.cancelTimedOut, (pendingOpen)));
        _h("cancelTimedOut (anyone), 20 positions", g);
        assertFalse(v.ordersPending());
        IGainsDiamond.Trade[] memory ts = D.getTrades(address(v));
        (g,) = _gas(fGuardian, abi.encodeCall(GainsVault.closeTrade, (ts[0].index, cl[_feed(ts[0].pairIndex)])));
        _h("closeTrade (guardian), 19 trades", g);
        _passHold(); // GR2-KEY-01b (WP5 port): the manager's reduce waits the 10-minute minimum hold (the guardian's is not held)
        (g,) = _gas(mgr, abi.encodeCall(GainsVault.reduceTrade, (ts[1].index, uint120(100e6), uint24(0), cl[_feed(ts[1].pairIndex)])));
        _h("reduceTrade (manager)", g);
        (g,) = _gas(fGuardian, abi.encodeCall(GainsVault.reduceTrade, (ts[2].index, uint120(0), uint24(1_000), cl[_feed(ts[2].pairIndex)])));
        _h("reduceTrade (guardian, leverage)", g);
    }

    // ------------------------------------------------------------------ real Chainlink read cost (feeds are mocked above)
    function test_GR2_LIVE_gas_realFeedReadCost() public {
        vm.clearMockedCalls();
        _mockArbBlock();
        uint256 g = gasleft();
        ILiveChainlinkFeed(SEQ).latestRoundData();
        g = g - gasleft();
        console2.log("real sequencer uptime feed latestRoundData (cold)", g);
        address[3] memory feeds = [BTC_USD, ETH_USD, SOL_USD];
        for (uint256 i; i < 3; ++i) {
            g = gasleft();
            ILiveChainlinkFeed(feeds[i]).latestRoundData();
            ILiveChainlinkFeed(feeds[i]).decimals();
            g = g - gasleft();
            console2.log("real pair feed latestRoundData + decimals (cold)", g);
        }
        // the same through the policy: sequencer + feed + decimals, as GainsNav pays per distinct pair
        _refreshCl();
        g = gasleft();
        try pol.navPrice(ETH) {} catch {}
        g = g - gasleft();
        console2.log("policy.navPrice with mocked feeds (what the tables above pay per pair)", g);
    }

    // ------------------------------------------------------------------ 20 different pairs
    mapping(uint16 => uint64) internal px;
    mapping(uint16 => address) internal feedOf;

    /// @dev Listed crypto pairs with a plain (DEFAULT) Gains feed whose answer reads, besides the three of the base.
    function _discoverPairs(uint256 want) internal returns (uint16[] memory out) {
        out = new uint16[](want);
        uint256 k;
        out[k++] = BTC;
        out[k++] = ETH;
        out[k++] = SOL;
        px[BTC] = cl[BTC_USD];
        px[ETH] = cl[ETH_USD];
        px[SOL] = cl[SOL_USD];
        feedOf[BTC] = BTC_USD;
        feedOf[ETH] = ETH_USD;
        feedOf[SOL] = SOL_USD;
        for (uint16 i = 2; i < 120 && k < want; ++i) {
            if (i == SOL) continue;
            try IPairsListedLive(address(D)).isPairIndexListed(i) returns (bool listed) {
                if (!listed) continue;
            } catch {
                continue;
            }
            if (DIAMOND.pairMaxLeverage(i) < 10_000) continue;
            // GR2-KEY-01b (WP5 port): a pair without a skew depth takes no new exposure ("no skew depth", fail closed),
            // e.g. the forex pairs at this block
            uint256 depth = D.getPairSkewDepth(USDC_INDEX, i);
            if (depth == 0) continue;
            // Gains v10 keeps no Chainlink feed per pair (pairs(i).feed is zero): each pair gets its own feed contract
            // at 1 USD; Gains takes the test's oracle answer as is. Real feed cost: test_GR2_LIVE_gas_realFeedReadCost.
            // GR2-KEY-01b (WP5 port): the pair cap is the guardian's launch cap, 1 % of the skew depth (tokens) at that
            // price, so the price is raised where 1 USD would make 1 % of the depth smaller than 12,000 USDC (4x the
            // 3,000 opened on each pair, room for the leverage increase below). The test measures gas per distinct
            // pair; the price level is immaterial to it.
            uint256 p1 = (12_000e6 * 1e22 * 10_000) / (depth * 100) + 1;
            px[i] = uint64(p1 > 1e10 ? p1 : 1e10);
            MockChainlinkFeed f = new MockChainlinkFeed(8, 1e8);
            feedOf[i] = address(f);
            out[k++] = i;
        }
        require(k == want, "not enough pairs");
    }

    function _mockFeed(address feed, uint64 price) internal {
        uint256 t = vm.getBlockTimestamp();
        uint8 dec = ILiveChainlinkFeed(feed).decimals();
        int256 ans = int256(uint256(price) * (10 ** dec) / 1e10);
        vm.mockCall(feed, abi.encodeWithSelector(ILiveChainlinkFeed.latestRoundData.selector), abi.encode(uint80(1), ans, t, t, uint80(1)));
    }

    function _refreshAll(uint16[] memory pairs) internal {
        for (uint256 i; i < pairs.length; ++i) {
            _mockFeed(feedOf[pairs[i]], px[pairs[i]]);
        }
    }

    function _createMulti(uint16[] memory pairs) internal returns (GainsVault vault) {
        uint32[] memory assets = new uint32[](pairs.length);
        vm.startPrank(fOwner);
        for (uint256 i; i < pairs.length; ++i) {
            assets[i] = pairs[i];
            if (pairs[i] != BTC && pairs[i] != ETH && pairs[i] != SOL) factory.setAssetCurated(pairs[i], true, feedOf[pairs[i]], 90_000, 20);
        }
        vm.stopPrank();
        vm.prank(creator);
        USDC.approve(address(factory), 1e6);
        vm.prank(creator);
        (address va,) = factory.create(
            GainsVaultFactory.CreateParams({
                name: "Gains LIVE 20 pairs",
                symbol: "gL20",
                owner: creator,
                manager: mgr,
                feeRecipient: creator,
                managementFeeBps: 0,
                performanceFeeBps: 0,
                timelockDelay: 2 days,
                depositCap: 1_000_000e6,
                risk: GainsVaultPolicy.RiskConfig({
                    maxLeverageBps: 30_000,
                    maxDailyLossBps: 500,
                    maxDrawdownBps: 1_500,
                    maxSlippageBps: 100,
                    maxOrderNotional: 1_000_000e6,
                    maxEpochDuration: 7 days,
                    maxNavMoveBps: 2_000,
                    maxFlattenSlippageBps: 300
                }),
                assets: assets,
                agent: address(0),
                agentSig: "",
                agentDeadline: 0,
                operator: keeper,
                hosted: false,
                seedUsdc: 1e6,
                salt: bytes32(uint256(20))
            }),
            GainsVaultFactory.PermitData(0, 0, 0, bytes32(0), bytes32(0))
        );
        vault = GainsVault(va);
    }

    /// @dev Leverage-only increase on every open trade of `v` (any pair).
    function _twentyNonHolding_any() internal {
        IGainsDiamond.Trade[] memory ts = D.getTrades(address(v));
        for (uint256 i; i < ts.length; ++i) {
            vm.prank(mgr);
            v.updateLeverage(ts[i].index, ts[i].leverage + 1_000);
        }
        assertFalse(v.ordersPending());
    }

    /// @dev 20 distinct pairs, flattenIndices on a clean set (no order in flight): the close of each pair is cold.
    function test_GR2_LIVE_gas_twentyDistinctPairs_flattenIndicesClean() public {
        uint16[] memory pairs = _discoverPairs(20);
        _refreshAll(pairs);
        // GR2-KEY-01b (WP5 port): the guardian's launch cap on every pair the vault trades (BTC, ETH and SOL are set by
        // the base); a pair never set takes no new exposure ("pair cap")
        vm.startPrank(factory.guardian());
        for (uint256 i; i < pairs.length; ++i) {
            if (factory.pairSkewCapBps(pairs[i]) == 0) factory.setPairSkewCap(pairs[i], 100);
        }
        vm.stopPrank();
        v = _createMulti(pairs);
        vm.prank(alice);
        USDC.approve(address(v), type(uint256).max);
        vm.prank(alice);
        v.requestDeposit(100_000e6, alice);
        _roll(4 * 3_600);
        _refreshAll(pairs);
        v.checkRisk();
        vm.prank(keeper);
        v.settle();
        v.claim(alice);
        uint256 opened = _openEach(pairs);
        console2.log("distinct pairs with an open trade", opened);
        assertGe(opened, 15);
        _roll(1);
        _refreshAll(pairs);
        uint256 g;
        (g,) = _gas(address(this), abi.encodeCall(GainsVault.totalAssets, ()));
        _h("totalAssets, distinct pairs (trades only)", g);
        IGainsDiamond.Trade[] memory ts = D.getTrades(address(v));
        uint32[] memory ix = new uint32[](ts.length);
        for (uint256 i; i < ts.length; ++i) {
            ix[i] = ts[i].index;
        }
        uint256 snap = vm.snapshotState();
        (g,) = _gas(fGuardian, abi.encodeCall(GainsVault.flattenIndices, (ix, uint256(0), uint64(1))));
        _h("flattenIndices, every trade on a different pair (one call)", g);
        console2.log("closes sent", _pending().length);
        if (g > HEADROOM_LINE) console2.log("ABOVE 26M: less than 20% headroom");
        vm.revertToState(snap);
        _twentyNonHolding_any();
        vm.prank(bob);
        USDC.approve(address(v), type(uint256).max);
        vm.prank(bob);
        v.requestDeposit(1_000e6, bob);
        uint256 shares = v.balanceOf(alice) / 100;
        vm.prank(alice);
        v.requestRedeem(shares, alice, alice);
        _roll(4 * 3_600);
        _refreshAll(pairs);
        v.checkRisk();
        snap = vm.snapshotState();
        (g,) = _gas(keeper, abi.encodeCall(GainsVault.settle, ()));
        _h("settle normal with deposits, distinct pairs + 1 non-holding pending each", g);
        vm.revertToState(snap);
        (g,) = _gas(fGuardian, abi.encodeCall(GainsVault.triggerEmergency, ()));
        _h("triggerEmergency, distinct pairs", g);
        (g,) = _gas(fGuardian, abi.encodeCall(GainsVault.settle, ()));
        _h("settle exit-only (emergency), distinct pairs + non-holding pending", g);
    }

    /// @dev Opens and fills one trade per pair; returns how many Gains accepted.
    function _openEach(uint16[] memory pairs) internal returns (uint256 opened) {
        for (uint256 i; i < pairs.length; ++i) {
            uint16 pair = pairs[i];
            OpenParams memory p = OpenParams(pair, i % 2 == 0, 600e6, 5_000, px[pair], 1_000, 0, 0, 0);
            vm.recordLogs();
            vm.prank(mgr);
            (bool ok,) = address(v).call(abi.encodeCall(GainsVault.openTrade, (p)));
            Vm.Log[] memory req = vm.getRecordedLogs();
            if (!ok) {
                console2.log("open refused on pair", pair);
                continue;
            }
            _roll(1);
            _refreshAll(pairs);
            uint256 before = D.getTrades(address(v)).length;
            _fill(req, px[pair]);
            if (D.getTrades(address(v)).length > before) {
                ++opened;
            } else {
                console2.log("open cancelled by Gains on pair", pair);
            }
        }
    }
}
