// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import "../lifecycle/LifecycleForkBase.sol";

interface IDiamondLoupeINT {
    function facetAddress(bytes4 selector) external view returns (address);
}

interface IGainsReferralsINT {
    function getTraderActiveReferrer(address trader) external view returns (address);
}

/// @notice Round 1, section 3.5 on the Arbitrum One fork (real gTrade v10 diamond, oracle emulation of
///         LifecycleForkBase): every selector the vault uses exists, every struct the vault decodes has exactly the
///         word count of IGainsDiamond, and the vault's requests carry Gains units with exact approvals.
///         Skips without ARBITRUM_RPC_URL.
contract IntegrationForkTest is LifecycleForkBase {
    function _selectors() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](36);
        s[0] = IGainsDiamond.openTrade.selector;
        s[1] = IGainsDiamond.closeTradeMarket.selector;
        s[2] = IGainsDiamond.decreasePositionSize.selector;
        s[3] = IGainsDiamond.increasePositionSize.selector;
        s[4] = IGainsDiamond.updateSl.selector;
        s[5] = IGainsDiamond.updateTp.selector;
        s[6] = IGainsDiamond.updateLeverage.selector;
        s[7] = IGainsDiamond.updateMaxClosingSlippageP.selector;
        s[8] = IGainsDiamond.cancelOpenOrder.selector;
        s[9] = IGainsDiamond.cancelOrderAfterTimeout.selector;
        s[10] = IGainsDiamond.getTrades.selector;
        s[11] = IGainsDiamond.getTrade.selector;
        s[12] = IGainsDiamond.getTradeInfo.selector;
        s[13] = IGainsDiamond.getPendingOrders.selector;
        s[14] = IGainsDiamond.getTradeLiquidationParams.selector;
        s[15] = IGainsDiamond.getTradePendingHoldingFeesCollateral.selector;
        s[16] = IGainsDiamond.getTradeRealizedPnlCollateral.selector;
        s[17] = IGainsDiamond.getTradeLiquidationPrice.selector;
        s[18] = IGainsDiamond.getTradeSkewPriceImpactP.selector;
        s[19] = IGainsDiamond.getTradeCumulVolPriceImpactP.selector;
        s[20] = IGainsDiamond.pairSpreadP.selector;
        s[21] = IGainsDiamond.pairMinPositionSizeUsd.selector;
        s[22] = IGainsDiamond.pairMinFeeUsd.selector;
        s[23] = IGainsDiamond.pairTotalPositionSizeFeeP.selector;
        s[24] = IGainsDiamond.pairMaxLeverage.selector;
        s[25] = IGainsDiamond.getPairFlags.selector;
        s[26] = IGainsDiamond.getTradeFeeParams.selector;
        s[27] = IGainsDiamond.calculateFeeAmount.selector;
        s[28] = IGainsDiamond.getUsdNormalizedValue.selector;
        s[29] = IGainsDiamond.getCollateralFromUsdNormalizedValue.selector;
        s[30] = IGainsDiamond.getCollateral.selector;
        s[31] = IGainsDiamond.getCollateralIndex.selector;
        s[32] = IGainsDiamond.getTradingDelegate.selector;
        s[33] = IGainsDiamond.getMarketOrdersTimeoutBlocks.selector;
        s[34] = IGainsDiamond.getPendingOrders.selector;
        s[35] = IGainsDiamond.getTrades.selector;
    }

    /// @notice Every selector of IGainsDiamond is routed to a facet of the live diamond.
    function test_INT_fork_everySelectorHasAFacet() public view {
        bytes4[] memory s = _selectors();
        for (uint256 i; i < s.length; ++i) {
            address f = IDiamondLoupeINT(address(D)).facetAddress(s[i]);
            assertTrue(f != address(0), "selector without facet");
        }
    }

    function _raw(bytes memory data) internal view returns (uint256 len) {
        (bool ok, bytes memory ret) = address(D).staticcall(data);
        require(ok, "read reverted");
        return ret.length;
    }

    /// @notice Exact ABI word counts of every struct the vault decodes, on live data: Trade 15, PendingOrder 21,
    ///         TradeInfo 9, Collateral 5, GroupLiquidationParams 5, TradeHoldingFees 4, realized pnl 3, PairFlags 4,
    ///         GlobalTradeFeeParams 7. Any facet upgrade that changes one of these counts breaks the decoder (INT-01).
    function test_INT_fork_returnLayoutsMatchIGainsDiamond() public {
        _depositSettle(alice, 100_000e6);
        uint32 a = _openFilledV(ETH, true, 1_000e6, 5_000);
        uint32 b = _openFilledV(BTC, false, 1_000e6, 5_000);
        _passHold(); // GR2-KEY-01b (WP5 port): the manager's exit waits the 10-minute minimum hold
        _req(mgr, abi.encodeCall(GainsVault.closeTrade, (b, cl[BTC_USD])));
        address va = address(v);
        assertEq(_raw(abi.encodeCall(IGainsDiamond.getTrades, (va))), 64 + 2 * 15 * 32, "Trade[]: 15 words each");
        assertEq(_raw(abi.encodeCall(IGainsDiamond.getPendingOrders, (va))), 64 + 1 * 21 * 32, "PendingOrder[]: 21 words");
        assertEq(_raw(abi.encodeCall(IGainsDiamond.getTrade, (va, a))), 15 * 32);
        assertEq(_raw(abi.encodeCall(IGainsDiamond.getTradeInfo, (va, a))), 9 * 32);
        assertEq(_raw(abi.encodeCall(IGainsDiamond.getCollateral, (USDC_INDEX))), 5 * 32);
        assertEq(_raw(abi.encodeCall(IGainsDiamond.getTradeLiquidationParams, (va, a))), 5 * 32);
        assertEq(_raw(abi.encodeCall(IGainsDiamond.getTradePendingHoldingFeesCollateral, (va, a, cl[ETH_USD]))), 4 * 32);
        assertEq(_raw(abi.encodeCall(IGainsDiamond.getTradeRealizedPnlCollateral, (va, a))), 3 * 32);
        assertEq(_raw(abi.encodeCall(IGainsDiamond.getPairFlags, (USDC_INDEX, ETH))), 4 * 32);
        assertEq(_raw(abi.encodeCall(IGainsDiamond.getTradeFeeParams, (USDC_INDEX, ETH))), 7 * 32);
        assertEq(D.getCollateralIndex(address(USDC)), 3, "USDC is collateral index 3");
        assertEq(v.collateralIndex(), 3);
        IGainsDiamond.Collateral memory c = D.getCollateral(3);
        assertEq(c.collateral, address(USDC));
        assertEq(uint256(c.precisionDelta), 1e12);
        // decoded values are sane (no misalignment): the vault's own trades, open, USDC
        IGainsDiamond.Trade[] memory t = D.getTrades(va);
        for (uint256 i; i < t.length; ++i) {
            assertEq(t[i].user, va);
            assertEq(t[i].collateralIndex, 3);
            assertEq(uint256(t[i].leverage), 5_000);
        }
        IGainsDiamond.PendingOrder memory o = _lastPending();
        assertEq(o.user, va);
        assertEq(uint256(o.orderType), 1, "MARKET_CLOSE");
        assertEq(uint256(o.trade.index), b);
    }

    /// @notice Market open: trade.user = vault, collateral index 3, leverage 1e3, price 1e10, slippage 1e3; exactly
    ///         the collateral is pulled; no allowance left; no referrer recorded; no trading delegate.
    function test_INT_fork_openTradeEncodingAndExactApproval() public {
        _depositSettle(alice, 100_000e6);
        uint120 coll = 1_000e6 + 7;
        uint256 bal = _usdc();
        Vm.Log[] memory req = _req(mgr, abi.encodeCall(GainsVault.openTrade, (_openParams(ETH, true, coll, 5_000))));
        assertEq(bal - _usdc(), coll, "pulled exactly the collateral");
        assertEq(USDC.allowance(address(v), address(D)), 0, "no standing allowance");
        IGainsDiamond.PendingOrder memory o = _lastPending();
        assertEq(o.trade.user, address(v));
        assertEq(uint256(o.trade.collateralIndex), 3);
        assertEq(uint256(o.trade.leverage), 5_000, "1e3 leverage");
        assertEq(uint256(o.trade.openPrice), cl[ETH_USD], "1e10 price");
        assertEq(uint256(o.maxSlippageP), 1_000, "1e3 percent slippage");
        assertEq(uint256(o.trade.collateralAmount), coll);
        assertEq(D.getTradingDelegate(address(v)), address(0), "never a delegate");
        try IGainsReferralsINT(address(D)).getTraderActiveReferrer(address(v)) returns (address r) {
            assertEq(r, address(0), "no referrer");
        } catch {}
        _rollFresh(1);
        Vm.Log[] memory fill = _fill(req, cl[ETH_USD]);
        uint32 idx = uint32(uint256(_find(fill, G.MarketExecuted.selector).topics[2]));
        IGainsDiamond.Trade memory t = _trade(idx);
        assertEq(uint256(t.leverage), 5_000);
        emit log_named_uint("collateral after fill (Gains v10 keeps opening fees as realized)", t.collateralAmount);
    }

    /// @notice A resting limit order: the trigger is the 1e10 openPrice, the collateral is pulled exactly, and the
    ///         cancel returns it to the wei.
    function test_INT_fork_limitOrderExactPullAndRefund() public {
        _depositSettle(alice, 100_000e6);
        uint120 coll = 500e6 + 3;
        uint64 trig = _round((cl[ETH_USD] * 9) / 10);
        uint256 bal = _usdc();
        _req(mgr, abi.encodeCall(GainsVault.openTrade, (OpenParams(ETH, true, coll, 5_000, trig, 1_000, 0, 0, 1))));
        assertEq(bal - _usdc(), coll);
        assertEq(USDC.allowance(address(v), address(D)), 0);
        IGainsDiamond.Trade[] memory ts = D.getTrades(address(v));
        IGainsDiamond.Trade memory t = ts[ts.length - 1];
        assertEq(uint256(t.tradeType), 1, "LIMIT");
        assertEq(uint256(t.openPrice), trig);
        _req(mgr, abi.encodeCall(GainsVault.cancelOrder, (t.index)));
        assertEq(_usdc(), bal, "refunded to the wei");
    }

    /// @notice Leverage decrease with odd numbers: the vault approves floor(c x lev / newLev) - c, which is exactly what
    ///         the live UpdateLeverage facet pulls (allowance back to 0); increase pulls exactly its collateral.
    function test_INT_fork_leverageDecreaseAndIncreaseExactPull() public {
        _depositSettle(alice, 100_000e6);
        uint32 idx = _openFilledV(ETH, true, 1_000e6 + 7, 7_000);
        IGainsDiamond.Trade memory t = _trade(idx);
        uint256 c = t.collateralAmount;
        uint256 delta = (c * 7_000) / 3_000 - c;
        uint256 bal = _usdc();
        Vm.Log[] memory req = _req(mgr, abi.encodeCall(GainsVault.updateLeverage, (idx, uint24(3_000))));
        assertEq(bal - _usdc(), delta, "pulled exactly Gains' delta");
        assertEq(USDC.allowance(address(v), address(D)), 0);
        IGainsDiamond.PendingOrder memory o = _lastPending();
        assertEq(uint256(o.orderType), 7, "UPDATE_LEVERAGE");
        assertEq(uint256(o.trade.collateralAmount), delta);
        assertEq(uint256(o.trade.leverage), 3_000);
        _rollFresh(1);
        _fill(req, cl[ETH_USD]);
        t = _trade(idx);
        emit log_named_uint("collateral after decrease", t.collateralAmount);
        emit log_named_uint("c + delta", c + delta);
        assertEq(uint256(t.leverage), 3_000);

        uint120 add = 300e6 + 1;
        bal = _usdc();
        _req(mgr, abi.encodeCall(GainsVault.increaseTrade, (idx, add, uint24(2_000), cl[ETH_USD], uint16(1_000))));
        assertEq(bal - _usdc(), add, "increase pulled exactly");
        assertEq(USDC.allowance(address(v), address(D)), 0);
        o = _lastPending();
        assertEq(uint256(o.orderType), 8, "MARKET_PARTIAL_OPEN");
        assertEq(uint256(o.trade.collateralAmount), add);
        assertEq(uint256(o.trade.leverage), 2_000);
    }

    /// @notice SL / TP are stored in 1e10 as sent; the flatten slippage reaches Gains as bps x 10 (1e3 percent).
    function test_INT_fork_slTpAndFlattenSlippageUnits() public {
        _depositSettle(alice, 100_000e6);
        uint32 idx = _openFilledV(ETH, true, 1_000e6, 5_000);
        uint64 sl = _round((cl[ETH_USD] * 92) / 100);
        uint64 tp = _round((cl[ETH_USD] * 120) / 100);
        _req(mgr, abi.encodeCall(GainsVault.setSlTp, (idx, sl, tp)));
        IGainsDiamond.Trade memory t = _trade(idx);
        assertEq(uint256(t.sl), sl);
        assertEq(uint256(t.tp), tp);
        _passHold(); // GR2-KEY-01b (WP5 port): the manager's exit waits the 10-minute minimum hold
        _req(mgr, abi.encodeCall(GainsVault.flatten, (ETH, uint256(250), cl[ETH_USD], type(uint256).max)));
        assertEq(uint256(D.getTradeInfo(address(v), idx).maxSlippageP), 2_500, "250 bps = 2,500 in 1e3 percent");
        assertEq(uint256(_lastPending().orderType), 1, "close in flight");
    }
}
