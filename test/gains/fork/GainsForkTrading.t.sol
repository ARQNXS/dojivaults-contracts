// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import "./GainsForkBase.sol";

/// @notice Stage 0 A1-A5 on an Arbitrum One fork (PLAN.md 9 items: contract caller, collateral at request,
///         timeout, USDC index, min size / leverage / max TP / gas). Run: forge test --match-path "test/gains/**"
contract GainsForkTradingTest is GainsForkBase {
    address internal constant ETH_USD = 0x639Fe6ab55C921f74e7fac1ee960C0B6293ba612;

    // ---------------- A1: a contract can call every trading function ----------------

    function test_A1_contractCallsEveryTradingFunction() public {
        uint64 p = _chainlink1e10(ETH_USD);
        uint256 bal0 = USDC.balanceOf(address(trader));

        // openTrade (market) + fill
        uint32 idx = _openFilled(ETH, true, 10e6, 10_000, p);
        _logGas("last oracle fulfill (callback stores the trade, paid by the node)");
        G.Trade memory t = DIAMOND.getTrade(address(trader), idx);
        assertEq(t.user, address(trader), "trade.user is the contract");
        assertTrue(t.isOpen);
        assertEq(t.collateralAmount, 10e6);

        // updateSl / updateTp (synchronous, no oracle)
        uint64 sl = p * 95 / 100;
        uint64 tp = p * 110 / 100;
        vm.recordLogs();
        trader.updateSl(idx, sl);
        _logGas("updateSl");
        trader.updateTp(idx, tp);
        _logGas("updateTp");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(_count(logs, G.TradeSlUpdated.selector), 1);
        assertEq(_count(logs, G.TradeTpUpdated.selector), 1);
        t = DIAMOND.getTrade(address(trader), idx);
        assertEq(t.sl, sl);
        assertEq(t.tp, tp);

        // increasePositionSize: +5 USDC at 10x, request + fill
        vm.recordLogs();
        trader.increasePositionSize(idx, 5e6, 10_000, p, 1000);
        _logGas("increasePositionSize (request)");
        logs = vm.getRecordedLogs();
        assertEq(_count(logs, G.PositionSizeUpdateInitiated.selector), 1);
        _roll(1);
        logs = _fill(logs, p);
        assertEq(_count(logs, G.PositionSizeIncreaseExecuted.selector), 1);
        assertEq(DIAMOND.getTrade(address(trader), idx).collateralAmount, 15e6);

        // updateLeverage down 10x -> 5x at constant size: the diamond pulls 15 USDC more collateral
        vm.recordLogs();
        trader.updateLeverage(idx, 5_000, 15e6);
        _logGas("updateLeverage (request, lower)");
        logs = vm.getRecordedLogs();
        assertEq(_count(logs, G.LeverageUpdateInitiated.selector), 1);
        _roll(1);
        logs = _fill(logs, p);
        assertEq(_count(logs, G.LeverageUpdateExecuted.selector), 1);
        t = DIAMOND.getTrade(address(trader), idx);
        assertEq(t.leverage, 5_000);
        assertEq(t.collateralAmount, 30e6);

        // decreasePositionSize: -10 USDC collateral, request + fill, payout to the contract
        uint256 balBefore = USDC.balanceOf(address(trader));
        vm.recordLogs();
        trader.decreasePositionSize(idx, 10e6, 0, p);
        _logGas("decreasePositionSize (request)");
        logs = vm.getRecordedLogs();
        _roll(1);
        logs = _fill(logs, p);
        assertEq(_count(logs, G.PositionSizeDecreaseExecuted.selector), 1);
        assertEq(DIAMOND.getTrade(address(trader), idx).collateralAmount, 20e6);
        assertGt(USDC.balanceOf(address(trader)), balBefore, "partial close paid the contract");

        // closeTradeMarket: request + fill, payout to the contract
        balBefore = USDC.balanceOf(address(trader));
        vm.recordLogs();
        trader.closeTradeMarket(idx, p);
        _logGas("closeTradeMarket (request)");
        logs = vm.getRecordedLogs();
        _roll(1);
        logs = _fill(logs, p);
        (, bool open,,, uint256 sent) = _decodeMarketExecuted(_find(logs, G.MarketExecuted.selector));
        assertFalse(open);
        assertEq(USDC.balanceOf(address(trader)) - balBefore, sent, "close payout == amountSentToTrader");
        assertEq(_openTrades().length, 0);

        // limit order: openTrade(tradeType 1) stores immediately, cancelOpenOrder returns the collateral
        balBefore = USDC.balanceOf(address(trader));
        vm.recordLogs();
        trader.openTrade(_trade(ETH, true, 10e6, 10_000, p * 90 / 100, 1), 1000);
        _logGas("openTrade (limit)");
        logs = vm.getRecordedLogs();
        assertEq(_count(logs, G.OpenOrderPlaced.selector), 1);
        G.Trade[] memory ts = _openTrades();
        assertEq(ts.length, 1);
        assertEq(ts[0].tradeType, 1);
        assertEq(USDC.balanceOf(address(trader)), balBefore - 10e6);
        trader.cancelOpenOrder(ts[0].index);
        _logGas("cancelOpenOrder");
        assertEq(USDC.balanceOf(address(trader)), balBefore);
        assertEq(_openTrades().length, 0);

        console2.log("A1 round trip cost (USDC 1e6, fees + spread):", bal0 - USDC.balanceOf(address(trader)));
    }

    function test_withdrawReturnsAllUsdcAfterTrading() public {
        uint64 p = _chainlink1e10(ETH_USD);
        uint32 idx = _openFilled(ETH, true, 1e6, 5_000, p);
        Vm.Log[] memory req = _recordClose(idx, p);
        _roll(1);
        _fill(req, p);
        uint256 held = USDC.balanceOf(address(trader));
        uint256 ownerBefore = USDC.balanceOf(address(this));
        trader.withdraw(USDC);
        assertEq(USDC.balanceOf(address(trader)), 0);
        assertEq(USDC.balanceOf(address(this)) - ownerBefore, held, "everything back to the owner");
    }

    function _recordClose(uint32 idx, uint64 p) internal returns (Vm.Log[] memory) {
        vm.recordLogs();
        trader.closeTradeMarket(idx, p);
        return vm.getRecordedLogs();
    }

    // ---------------- A2: USDC leaves the contract at request time ----------------

    function test_A2_collateralPulledAtRequestAndPending() public {
        uint64 p = _chainlink1e10(ETH_USD);
        uint256 traderBefore = USDC.balanceOf(address(trader));
        uint256 diamondBefore = USDC.balanceOf(address(DIAMOND));

        Vm.Log[] memory logs = _requestOpen(ETH, true, 10e6, 10_000, p);

        assertEq(traderBefore - USDC.balanceOf(address(trader)), 10e6, "pulled at request");
        assertEq(USDC.balanceOf(address(DIAMOND)) - diamondBefore, 10e6, "held by the diamond while pending");
        assertEq(_openTrades().length, 0, "no trade before the fill");

        G.PendingOrder[] memory po = DIAMOND.getPendingOrders(address(trader));
        assertEq(po.length, 1);
        assertEq(po[0].user, address(trader));
        assertTrue(po[0].isOpen);
        assertEq(po[0].orderType, MARKET_OPEN);
        assertEq(po[0].trade.collateralAmount, 10e6);
        assertEq(po[0].trade.user, address(trader));
        assertEq(po[0].createdBlock, _arbBlock(), "createdBlock is the L2 block");
        assertEq(DIAMOND.getCounters(address(trader), 1).openCount, 1, "pending order counter");

        // MarketOrderInitiated(orderId, trader indexed, pairIndex indexed, open)
        Vm.Log memory l = _find(logs, G.MarketOrderInitiated.selector);
        assertEq(address(uint160(uint256(l.topics[1]))), address(trader));
        (G.Id memory orderId, bool open) = abi.decode(l.data, (G.Id, bool));
        assertEq(orderId.user, address(trader));
        assertEq(orderId.index, po[0].index);
        assertTrue(open);
        console2.log("oracle requests (nodes paid):", _countOracleRequests(logs));
    }

    function test_A2_cancelledOpenReturnsCollateralMinusGovFee() public {
        uint64 p = _chainlink1e10(ETH_USD);
        uint256 before = USDC.balanceOf(address(trader));
        Vm.Log[] memory req = _requestOpen(ETH, true, 10e6, 10_000, p); // 1% max slippage
        _roll(1);
        Vm.Log[] memory logs = _fill(req, p * 102 / 100); // fill 2% above the expected price

        Vm.Log memory l = _find(logs, G.MarketOpenCanceled.selector);
        (G.Id memory orderId, uint8 cancelReason, uint256 returned) = abi.decode(l.data, (G.Id, uint8, uint256));
        assertEq(orderId.user, address(trader));
        assertEq(cancelReason, 3, "CancelReason.SLIPPAGE");
        assertEq(USDC.balanceOf(address(trader)), before - 10e6 + returned, "returned to the contract in the callback");
        assertEq(_openTrades().length, 0);
        assertEq(DIAMOND.getPendingOrders(address(trader)).length, 0);
        console2.log("cancelled open: collateral 10e6, returned", returned, "kept as gov fee", 10e6 - returned);
    }

    // ---------------- A3: timeout and cancelOrderAfterTimeout ----------------

    function test_A3_timeoutReturnsCollateralAfterExactly200Blocks() public {
        uint16 timeoutBlocks = DIAMOND.getMarketOrdersTimeoutBlocks();
        assertEq(timeoutBlocks, 200);

        uint64 p = _chainlink1e10(ETH_USD);
        uint256 before = USDC.balanceOf(address(trader));
        _requestOpen(ETH, true, 10e6, 10_000, p);
        G.PendingOrder memory po = DIAMOND.getPendingOrders(address(trader))[0];

        _roll(timeoutBlocks - 1);
        vm.expectRevert(bytes4(keccak256("WaitTimeout()")));
        trader.cancelOrderAfterTimeout(po.index);

        _roll(1); // createdBlock + 200
        assertEq(_arbBlock(), po.createdBlock + timeoutBlocks);
        vm.recordLogs();
        vm.prank(address(0xBEEF)); // the spike forwards for anyone; the diamond sees msg.sender == trader
        trader.cancelOrderAfterTimeout(po.index);
        _logGas("cancelOrderAfterTimeout");
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(USDC.balanceOf(address(trader)), before, "full collateral back");
        assertEq(DIAMOND.getPendingOrders(address(trader)).length, 0);
        assertEq(_count(logs, G.CollateralReturnedAfterTimeout.selector), 1);
        assertEq(_count(logs, G.ChainlinkCallbackTimeout.selector), 1);
    }

    function test_A3_lateAnswersAfterCancelDoNothing() public {
        uint64 p = _chainlink1e10(ETH_USD);
        uint256 before = USDC.balanceOf(address(trader));
        Vm.Log[] memory req = _requestOpen(ETH, true, 10e6, 10_000, p);
        G.PendingOrder memory po = DIAMOND.getPendingOrders(address(trader))[0];
        _roll(200);
        trader.cancelOrderAfterTimeout(po.index);

        Vm.Log[] memory logs = _fill(req, p); // nodes answer after the cancel
        assertEq(_count(logs, G.MarketExecuted.selector), 0, "no trade opened");
        assertEq(_openTrades().length, 0);
        assertEq(USDC.balanceOf(address(trader)), before, "nothing pulled twice");
    }

    function test_A3_fillAfterTimeoutWithoutCancelStillExecutes() public {
        uint64 p = _chainlink1e10(ETH_USD);
        Vm.Log[] memory req = _requestOpen(ETH, true, 10e6, 10_000, p);
        _roll(250);
        Vm.Log[] memory logs = _fill(req, p);
        // Records what the diamond does with an answer that arrives after the 200 block window when nobody cancelled.
        console2.log("MarketExecuted after 250 blocks:", _count(logs, G.MarketExecuted.selector));
        console2.log("MarketOpenCanceled after 250 blocks:", _count(logs, G.MarketOpenCanceled.selector));
        console2.log("open trades:", _openTrades().length);
    }

    function test_A3_closeTimeoutKeepsTradeOpenAndMovesNoUsdc() public {
        uint64 p = _chainlink1e10(ETH_USD);
        uint32 idx = _openFilled(ETH, true, 10e6, 10_000, p);
        uint256 before = USDC.balanceOf(address(trader));

        trader.closeTradeMarket(idx, p);
        G.PendingOrder memory po = DIAMOND.getPendingOrders(address(trader))[0];
        assertEq(po.orderType, MARKET_CLOSE);
        _roll(200);
        vm.recordLogs();
        trader.cancelOrderAfterTimeout(po.index);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(USDC.balanceOf(address(trader)), before);
        assertTrue(DIAMOND.getTrade(address(trader), idx).isOpen, "trade stays open, close can be retried");
        assertEq(_count(logs, G.CollateralReturnedAfterTimeout.selector), 0);
        assertEq(_count(logs, G.ChainlinkCallbackTimeout.selector), 1);
    }

    // ---------------- A4: USDC collateral index and precision ----------------

    function test_A4_usdcCollateralIndex3() public view {
        assertEq(DIAMOND.getCollateralIndex(address(USDC)), USDC_INDEX);
        G.Collateral memory c = DIAMOND.getCollateral(USDC_INDEX);
        assertEq(c.collateral, address(USDC));
        assertTrue(c.isActive);
        assertEq(c.precision, 1e6);
        assertEq(c.precisionDelta, 1e12);
    }

    // ---------------- A5: min size, leverage bounds, max TP ----------------

    function test_A5_pairLimits() public view {
        uint16[3] memory pairs_ = [BTC, ETH, SOL];
        for (uint256 i; i < 3; i++) {
            uint256 pi = pairs_[i];
            uint256 minPosUsd = DIAMOND.pairMinPositionSizeUsd(pi); // 1e18
            uint256 minFeeUsd = DIAMOND.pairMinFeeUsd(pi); // 1e18
            uint256 minFeeUsdc = DIAMOND.getCollateralFromUsdNormalizedValue(USDC_INDEX, minFeeUsd);
            console2.log("pair", pi);
            console2.log("  pairMinPositionSizeUsd (1e18)", minPosUsd);
            console2.log("  pairMinFeeUsd (1e18)", minFeeUsd);
            console2.log("  min opening collateral = 5 x min fee (USDC 1e6)", 5 * minFeeUsdc);
            console2.log("  pairMinLeverage (1e3)", DIAMOND.pairMinLeverage(pi));
            console2.log("  pairMaxLeverage (1e3)", DIAMOND.pairMaxLeverage(pi));
            console2.log("  pairTotalPositionSizeFeeP (1e10 %)", DIAMOND.pairTotalPositionSizeFeeP(pi));
            console2.log("  pairSpreadP (1e10 %)", DIAMOND.pairSpreadP(address(trader), pi));
            console2.log("  getPairMaxOi USDC (1e10)", DIAMOND.getPairMaxOi(USDC_INDEX, uint16(pi)));
        }
        assertEq(DIAMOND.pairMaxLeverage(BTC), 200_000);
        assertEq(DIAMOND.pairMaxLeverage(ETH), 200_000);
        assertEq(DIAMOND.pairMaxLeverage(SOL), 150_000);
        assertEq(DIAMOND.pairMinLeverage(ETH), 1_100);
    }

    function test_A5_minCollateralIsFiveMinFeesNotPositionSize() public {
        uint64 p = _chainlink1e10(ETH_USD);
        uint256 minCollateral =
            5 * DIAMOND.getCollateralFromUsdNormalizedValue(USDC_INDEX, DIAMOND.pairMinFeeUsd(ETH));
        // 5 x 0.10 USD min fee, converted with the diamond's USDC/USD price: 0.500075 USDC at block 515,219,884
        assertApproxEqRel(minCollateral, 0.5e6, 0.001e18, "about 0.50 USDC");
        console2.log("min opening collateral (USDC 1e6)", minCollateral);

        vm.expectRevert(bytes4(keccak256("InsufficientCollateral()")));
        trader.openTrade(_trade(ETH, true, uint120(minCollateral - 1), 1_100, p, 0), 1000);

        // 0.50 USDC at 1.1x = 0.55 USD position opens: there is no hard minimum position size
        uint32 idx = _openFilled(ETH, true, uint120(minCollateral), 1_100, p);
        assertEq(DIAMOND.getTrade(address(trader), idx).collateralAmount, minCollateral);
    }

    function test_A5_leverageBounds() public {
        uint64 p = _chainlink1e10(ETH_USD);
        vm.expectRevert(bytes4(keccak256("WrongLeverage()")));
        trader.openTrade(_trade(ETH, true, 10e6, 200_001, p, 0), 1000);
        vm.expectRevert(bytes4(keccak256("WrongLeverage()")));
        trader.openTrade(_trade(ETH, true, 10e6, 1_099, p, 0), 1000);
        _requestOpen(ETH, true, 1e6, 200_000, p); // 200x accepted at request

        uint64 sol = _chainlink1e10(0x24ceA4b8ce57cdA5058b924B9B9987992450590c);
        vm.expectRevert(bytes4(keccak256("WrongLeverage()")));
        trader.openTrade(_trade(SOL, true, 10e6, 150_001, sol, 0), 1000);
    }

    function test_A5_noMaxTpAndSlDistanceIsClamped() public {
        uint64 p = _chainlink1e10(ETH_USD);
        uint32 idx = _openFilled(ETH, true, 10e6, 10_000, p);

        uint64 farTp = p * 100; // +9900% price move, 99000% pnl at 10x
        trader.updateTp(idx, farTp);
        assertEq(DIAMOND.getTrade(address(trader), idx).tp, farTp, "TP stored as sent, no cap");

        uint64 farSl = p / 10; // beyond liquidation
        trader.updateSl(idx, farSl);
        uint64 storedSl = DIAMOND.getTrade(address(trader), idx).sl;
        console2.log("SL sent", farSl, "SL stored (clamped to liq distance)", storedSl);
        assertGt(storedSl, farSl, "SL clamped above liquidation");
    }

    // ---------------- helpers ----------------

    function _countOracleRequests(Vm.Log[] memory logs) internal pure returns (uint256 n) {
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == ORACLE_REQUEST) n++;
        }
    }

    function _logGas(string memory what) internal view {
        Vm.Gas memory g = vm.lastFrameGas();
        console2.log(string.concat("gas ", what), g.gasTotalUsed);
    }
}
