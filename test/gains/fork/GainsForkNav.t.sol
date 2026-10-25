// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import "./GainsForkBase.sol";
import {NavCalc} from "../spike/NavCalc.sol";

/// @notice Stage 0 C on the Arbitrum One fork: NavCalc (PLAN.md 4.3 step 4) evaluated in the fill block at the fill's
///         oracle price, against the USDC actually received by the trader contract. Real v10 pair parameters, fees,
///         price impact, funding and borrowing at FORK_BLOCK; only the oracle answer is ours.
contract GainsForkNavTest is GainsForkBase {
    address internal constant BTC_USD = 0x6ce185860a4963106506C203335A2910413708e9;
    address internal constant ETH_USD = 0x639Fe6ab55C921f74e7fac1ee960C0B6293ba612;
    address internal constant SOL_USD = 0x24ceA4b8ce57cdA5058b924B9B9987992450590c;

    uint256 internal constant DAY_BLOCKS = 345_600; // 4 blocks/s

    function test_C_fullClose_profitLong_afterProtectionWindow() public {
        uint64 p = _chainlink1e10(ETH_USD);
        uint32 idx = _openFilled(ETH, true, 10e6, 10_000, p);
        _roll(1_000);
        _closeAndCompare("ETH long 10x +1% after 1000 blocks", idx, p * 101 / 100);
    }

    function test_C_fullClose_profitLong_insideProtectionWindow() public {
        uint64 p = _chainlink1e10(ETH_USD);
        uint32 idx = _openFilled(ETH, true, 10e6, 10_000, p);
        _roll(10);
        _closeAndCompare("ETH long 10x +1% after 10 blocks (protection close factor)", idx, p * 101 / 100);
    }

    function test_C_fullClose_lossLong() public {
        uint64 p = _chainlink1e10(ETH_USD);
        uint32 idx = _openFilled(ETH, true, 10e6, 10_000, p);
        _roll(1_000);
        _closeAndCompare("ETH long 10x -1%", idx, p * 99 / 100);
    }

    function test_C_fullClose_profitShort_btc_oneDay() public {
        uint64 p = _chainlink1e10(BTC_USD);
        uint32 idx = _openFilled(BTC, false, 10e6, 20_000, p);
        _roll(DAY_BLOCKS);
        _closeAndCompare("BTC short 20x -0.5% price after 1 day", idx, p * 995 / 1000);
    }

    function test_C_fullClose_sol_sevenDays() public {
        uint64 p = _chainlink1e10(SOL_USD);
        uint32 idx = _openFilled(SOL, true, 10e6, 5_000, p);
        _roll(7 * DAY_BLOCKS);
        _closeAndCompare("SOL long 5x -2% after 7 days", idx, p * 98 / 100);
    }

    function test_C_partialThenFull_holdingFeesAndRealizedPnl() public {
        uint64 p = _chainlink1e10(ETH_USD);
        uint32 idx = _openFilled(ETH, true, 20e6, 10_000, p);
        _roll(DAY_BLOCKS);
        _reduceAndCompare("ETH long 10x: -8 of 20 USDC at +0.5% after 1 day", idx, 8e6, p * 1005 / 1000);

        G.TradeFeesData memory fd = DIAMOND.getTradeFeesData(address(trader), idx);
        console2.log("after partial: realizedTradingFees", fd.realizedTradingFeesCollateral);
        console2.logInt(fd.realizedPnlCollateral);
        console2.log("after partial: virtualAvailableCollateralInDiamond", fd.virtualAvailableCollateralInDiamond);

        _roll(DAY_BLOCKS);
        _closeAndCompare("ETH long 10x: close remaining 12 USDC at -0.5% after 2 days", idx, p * 995 / 1000);
    }

    function test_C_fullClose_pastLiquidationPaysZero() public {
        uint64 p = _chainlink1e10(ETH_USD);
        uint32 idx = _openFilled(ETH, true, 2e6, 100_000, p);
        _roll(100);
        NavCalc.Breakdown memory b = _closeAndCompare("ETH long 100x at -1.5%: past liquidation", idx, p * 985 / 1000);
        assertTrue(b.liquidated);
        assertEq(b.value, 0);
    }

    // ---------------- harness ----------------

    function _closeAndCompare(string memory label, uint32 idx, uint64 price)
        internal
        returns (NavCalc.Breakdown memory b)
    {
        vm.recordLogs();
        trader.closeTradeMarket(idx, price);
        Vm.Log[] memory req = vm.getRecordedLogs();
        _roll(1);
        b = NavCalc.value(DIAMOND, address(trader), idx, price); // same block as the fill, same price
        uint256 before = USDC.balanceOf(address(trader));
        Vm.Log[] memory fill = _fill(req, price);
        uint256 paid = USDC.balanceOf(address(trader)) - before;

        (,, uint256 oraclePrice, uint256 marketPrice, uint256 sent) =
            _decodeMarketExecuted(_find(fill, G.MarketExecuted.selector));
        assertEq(oraclePrice, price);
        assertEq(paid, sent, "USDC received == MarketExecuted.amountSentToTrader");
        _report(label, b, paid);
        assertEq(uint256(b.priceAfterImpact), marketPrice, "NavCalc priceAfterImpact == MarketExecuted.marketPrice");
        assertEq(b.value, int256(paid), "NavCalc exact at the fill price");
    }

    function _reduceAndCompare(string memory label, uint32 idx, uint120 collateralDelta, uint64 price) internal {
        vm.recordLogs();
        trader.decreasePositionSize(idx, collateralDelta, 0, price);
        Vm.Log[] memory req = vm.getRecordedLogs();
        _roll(1);
        NavCalc.Breakdown memory b = NavCalc.partialClose(DIAMOND, address(trader), idx, price, collateralDelta);
        NavCalc.Breakdown memory full = NavCalc.value(DIAMOND, address(trader), idx, price);
        uint256 before = USDC.balanceOf(address(trader));
        Vm.Log[] memory fill = _fill(req, price);
        uint256 paid = USDC.balanceOf(address(trader)) - before;
        assertEq(_count(fill, G.PositionSizeDecreaseExecuted.selector), 1);
        _report(label, b, paid);
        console2.log("  full-trade NavCalc value just before (USDC 1e6)");
        console2.logInt(full.value);
        assertEq(b.value, int256(paid), "NavCalc.partialClose exact at the fill price");
    }

    function _report(string memory label, NavCalc.Breakdown memory b, uint256 paid) internal pure {
        console2.log(label);
        console2.log("  collateral, positionSize, price", b.collateral, b.positionSizeCollateral, b.price);
        console2.log("  priceAfterImpact, closingFee, closingFeeNoTier", b.priceAfterImpact, b.closingFee, b.closingFeeNoTier);
        console2.log("  spreadP, cumulVolP, skewP (1e10 %):");
        console2.logInt(b.fixedSpreadP);
        console2.logInt(b.cumulVolPriceImpactP);
        console2.logInt(b.skewPriceImpactP);
        console2.log("  rawPnl, impactHaircut, holdingFees, totalRealizedPnl (USDC 1e6):");
        console2.logInt(b.rawPnl);
        console2.logInt(b.impactHaircut);
        console2.logInt(b.holdingFees);
        console2.logInt(b.totalRealizedPnl);
        console2.log("  liqPrice, liquidated", b.liqPrice, b.liquidated);
        console2.log("  NavCalc value vs USDC paid:");
        console2.logInt(b.value);
        console2.log("  paid", paid);
    }
}
