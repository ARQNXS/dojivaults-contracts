// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import "./GainsForkBase.sol";
import {NavCalc} from "../spike/NavCalc.sol";

/// @notice Stage 0 A6 (fee, liquidation and holding fee views on a real v10 trade) and A7 (Chainlink on Arbitrum).
contract GainsForkReadsTest is GainsForkBase {
    /// @dev Busy USDC trader from backend-arbitrum.gains.trade/open-trades (19 open BTC market trades at READS_BLOCK).
    address internal constant BUSY = 0xa6287941fD8f70194ec253722dff1519946F368F;
    /// @dev A6 asserts BUSY's open trades at this block (the old Stage 0 pin): needs an archive RPC.
    uint256 internal constant READS_BLOCK = 515_219_884;

    // data.chain.link, Arbitrum One (reference-data-directory feeds-ethereum-mainnet-arbitrum-1.json)
    address internal constant BTC_USD = 0x6ce185860a4963106506C203335A2910413708e9;
    address internal constant ETH_USD = 0x639Fe6ab55C921f74e7fac1ee960C0B6293ba612;
    address internal constant SOL_USD = 0x24ceA4b8ce57cdA5058b924B9B9987992450590c;
    address internal constant SEQUENCER = 0xFdB631F5EE196F0ed6FAa767959853A9F217697D;

    // ---------------- A6 ----------------

    function test_A6_viewsOnARealOpenTrade() public {
        _forkAt(READS_BLOCK);
        G.Trade[] memory ts = DIAMOND.getTrades(BUSY);
        G.TradeInfo[] memory infos = DIAMOND.getTradeInfos(BUSY);
        G.GroupLiquidationParams[] memory liqs = DIAMOND.getTradesLiquidationParams(BUSY);
        assertGt(ts.length, 0);
        assertEq(infos.length, ts.length, "getTradeInfos parallel to getTrades");
        assertEq(liqs.length, ts.length, "getTradesLiquidationParams parallel to getTrades");
        console2.log("open trades", ts.length);
        console2.log("pending orders", DIAMOND.getPendingOrders(BUSY).length);
        console2.log("counter TRADE openCount", DIAMOND.getCounters(BUSY, 0).openCount);
        console2.log("trading delegate", DIAMOND.getTradingDelegate(BUSY));

        uint256 k = type(uint256).max;
        for (uint256 i; i < ts.length; i++) {
            if (ts[i].isOpen && ts[i].tradeType == 0 && ts[i].collateralIndex == USDC_INDEX && infos[i].contractsVersion == 2) {
                k = i;
                break;
            }
        }
        require(k != type(uint256).max, "no open v10 USDC market trade");
        G.Trade memory t = ts[k];
        uint64 price = _chainlink1e10(BTC_USD);
        _logTrade(t, infos[k], liqs[k]);

        G.TradeHoldingFees memory hf = DIAMOND.getTradePendingHoldingFeesCollateral(BUSY, t.index, price);
        console2.log("holding fees at Chainlink BTC (USDC 1e6):");
        console2.logInt(hf.fundingFeeCollateral);
        console2.log(hf.borrowingFeeCollateral, hf.borrowingFeeCollateral_old);
        console2.logInt(hf.totalFeeCollateral);
        assertEq(
            hf.totalFeeCollateral,
            hf.fundingFeeCollateral + int256(hf.borrowingFeeCollateral) + int256(hf.borrowingFeeCollateral_old),
            "total = funding + borrowing v2 + borrowing v1"
        );

        G.TradeFeesData memory fd = DIAMOND.getTradeFeesData(BUSY, t.index);
        console2.log("TradeFeesData realizedTradingFeesCollateral", fd.realizedTradingFeesCollateral);
        console2.logInt(fd.realizedPnlCollateral);
        console2.log("manuallyRealizedNegativePnl / alreadyTransferredNegativePnl",
            fd.manuallyRealizedNegativePnlCollateral, fd.alreadyTransferredNegativePnlCollateral);
        console2.log("virtualAvailableCollateralInDiamond", fd.virtualAvailableCollateralInDiamond);
        console2.logInt(fd.initialAccFundingFeeP);
        console2.log("initialAccBorrowingFeeP", fd.initialAccBorrowingFeeP);

        (int256 rp, uint256 rf, int256 rt) = DIAMOND.getTradeRealizedPnlCollateral(BUSY, t.index);
        assertEq(rp, int256(fd.realizedPnlCollateral), "realizedPnl view = TradeFeesData.realizedPnlCollateral");
        assertEq(rf, fd.realizedTradingFeesCollateral, "realizedFees view = TradeFeesData.realizedTradingFeesCollateral");
        assertEq(rt, rp - int256(rf), "total = realizedPnl - realizedTradingFees");

        uint256 liq = NavCalc.liquidationPrice(DIAMOND, t, price);
        console2.log("getTradeLiquidationPrice (1e10)", liq);
        assertGt(liq, 0);
        if (t.long) assertLt(liq, t.openPrice);
        else assertGt(liq, t.openPrice);

        NavCalc.Breakdown memory b = NavCalc.value(DIAMOND, BUSY, t.index, price);
        console2.log("NavCalc value at Chainlink BTC (USDC 1e6)");
        console2.logInt(b.value);
        console2.log("closingFee", b.closingFee, "closingFeeNoTier", b.closingFeeNoTier);
        console2.logInt(b.impactHaircut);
    }

    // ---------------- A7 ----------------

    function test_A7_chainlinkFeedsAndSequencer() public view {
        _feed("BTC / USD", BTC_USD);
        _feed("ETH / USD", ETH_USD);
        _feed("SOL / USD", SOL_USD);

        (uint80 rid, int256 answer, uint256 startedAt, uint256 updatedAt,) =
            IChainlinkFeed(SEQUENCER).latestRoundData();
        console2.log("sequencer uptime feed: answer (0 = up), startedAt, updatedAt, roundId");
        console2.logInt(answer);
        console2.log(startedAt, updatedAt, rid);
        console2.log("sequencer up for (s)", vm.getBlockTimestamp() - startedAt);
        assertEq(answer, 0, "sequencer up at the fork block");
        assertEq(IChainlinkFeed(SEQUENCER).decimals(), 0);
    }

    function _feed(string memory name, address f) internal view {
        IChainlinkFeed feed = IChainlinkFeed(f);
        (uint80 rid, int256 answer,, uint256 updatedAt,) = feed.latestRoundData();
        assertEq(feed.decimals(), 8, name);
        assertEq(keccak256(bytes(feed.description())), keccak256(bytes(name)), "description");
        assertGt(answer, 0);
        console2.log(name, f);
        console2.log("  decimals 8, answer (1e8), age (s):", uint256(answer), vm.getBlockTimestamp() - updatedAt);

        // observed update intervals over the last 20 rounds (heartbeat bound and deviation pushes)
        uint256 maxGap;
        uint256 minGap = type(uint256).max;
        uint256 maxMoveBps;
        uint256 prevTs = updatedAt;
        int256 prevAns = answer;
        for (uint80 i = 1; i <= 20; i++) {
            (, int256 a,, uint256 u,) = feed.getRoundData(rid - i);
            if (u == 0) break;
            uint256 gap = prevTs - u;
            if (gap > maxGap) maxGap = gap;
            if (gap < minGap) minGap = gap;
            uint256 move = uint256(prevAns > a ? prevAns - a : a - prevAns) * 10_000 / uint256(a);
            if (move > maxMoveBps) maxMoveBps = move;
            prevTs = u;
            prevAns = a;
        }
        console2.log("  last 20 rounds: min gap (s), max gap (s), max move (bps):", minGap, maxGap, maxMoveBps);
    }

    function _logTrade(G.Trade memory t, G.TradeInfo memory i, G.GroupLiquidationParams memory l) internal pure {
        console2.log("trade index, pair, leverage", t.index, t.pairIndex, t.leverage);
        console2.log("long, collateral, openPrice", t.long, t.collateralAmount, t.openPrice);
        console2.log("tp, sl, positionSizeToken", t.tp, t.sl, t.positionSizeToken);
        console2.log("info createdBlock, contractsVersion, lastPosIncreaseBlock", i.createdBlock, i.contractsVersion, i.lastPosIncreaseBlock);
        console2.log("liq params maxLiqSpreadP, startLiqThresholdP, endLiqThresholdP", l.maxLiqSpreadP, l.startLiqThresholdP, l.endLiqThresholdP);
        console2.log("liq params startLeverage, endLeverage", l.startLeverage, l.endLeverage);
    }
}
