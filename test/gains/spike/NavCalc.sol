// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {IGainsDiamondSpike as G} from "./IGainsDiamondSpike.sol";

/// @notice Stage 0 spike only (test code). PLAN.md 4.3 step 4 for one open trade, written against the gTrade v10
///         close path as deployed (GNSTradingCallbacks closeTradeMarketCallback / _unregisterTrade and
///         DecreasePositionSizeUtils.prepareCallbackValues, source verified on Sourcify for Arbitrum 42161):
///
///         value = max(0, collateral + rawPnl(priceAfterImpact) - pendingHoldingFees.total - closingFee
///                        + totalRealizedPnl)                                  (0 if the oracle price is past liq)
///         priceAfterImpact = P * (1 + fixedSpreadP + cumulVolPriceImpactP + skewPriceImpactP)
///         impactHaircut    = rawPnl(P) - rawPnl(priceAfterImpact)
///         totalRealizedPnl = getTradeRealizedPnlCollateral().totalRealizedPnlCollateral
///                          = TradeFeesData.realizedPnlCollateral - TradeFeesData.realizedTradingFeesCollateral
///
///         With P = the oracle price of the fill this is the exact payout; with P = Chainlink it is the NAV estimate.
/// @dev Counter trades are not modelled (the vault never sends them); `value` reverts on one.
library NavCalc {
    uint256 internal constant P_10 = 1e10;
    uint8 internal constant V9_2 = 1;
    uint8 internal constant V10 = 2;

    error CounterTradeNotModelled();

    struct Breakdown {
        uint256 collateral; // collateral precision
        uint256 positionSizeCollateral; // collateral being closed (full or delta) x leverage
        uint64 price; // P, 1e10
        uint64 priceAfterImpact; // 1e10
        int256 fixedSpreadP; // 1e10 %
        int256 cumulVolPriceImpactP; // 1e10 %
        int256 skewPriceImpactP; // 1e10 %
        int256 pnlPercent; // 1e10 %, at priceAfterImpact, floored at -100%
        int256 rawPnl; // collateral, at priceAfterImpact
        int256 impactHaircut; // collateral, rawPnl(P) - rawPnl(priceAfterImpact)
        int256 holdingFees; // getTradePendingHoldingFeesCollateral(P).totalFeeCollateral
        uint256 closingFee; // fee-tier adjusted, as charged
        uint256 closingFeeNoTier; // without fee tier discount (conservative NAV per PLAN.md 4.3)
        int256 totalRealizedPnl; // getTradeRealizedPnlCollateral total (realized pnl - realized fees)
        uint256 liqPrice; // 1e10
        bool liquidated;
        int256 value; // full close: payout; partial close: collateralSentToTrader
    }

    /// @notice Full close value of `index` of `trader` at pair price `price` (PLAN.md 4.3 step 4).
    function value(G d, address trader, uint32 index, uint64 price) internal view returns (Breakdown memory b) {
        G.Trade memory t = d.getTrade(trader, index);
        if (t.isCounterTrade) revert CounterTradeNotModelled();
        G.TradeInfo memory info = d.getTradeInfo(trader, index);

        b.collateral = t.collateralAmount;
        b.price = price;
        b.positionSizeCollateral = positionSize(t.collateralAmount, t.leverage);
        _impact(d, t, info, price, b);
        _fees(d, t, price, b);

        b.closingFeeNoTier = totalTradeFeesRaw(d, t, b.positionSizeCollateral);
        b.closingFee = totalTradeFees(d, t, b.positionSizeCollateral);

        uint128 precisionDelta = d.getCollateral(t.collateralIndex).precisionDelta;
        b.value = int256(
            tradeValuePure(
                t.collateralAmount,
                b.pnlPercent,
                int256(b.closingFee) + b.holdingFees - b.totalRealizedPnl,
                precisionDelta
            )
        );

        _liq(d, t, price, b);
        if (b.liquidated) b.value = 0;
    }

    /// @notice USDC sent to the trader by decreasePositionSize(index, collateralDelta, 0, ...) filled at `price`.
    function partialClose(G d, address trader, uint32 index, uint64 price, uint120 collateralDelta)
        internal
        view
        returns (Breakdown memory b)
    {
        G.Trade memory t = d.getTrade(trader, index);
        if (t.isCounterTrade) revert CounterTradeNotModelled();
        G.TradeInfo memory info = d.getTradeInfo(trader, index);

        uint256 existingSize = positionSize(t.collateralAmount, t.leverage);
        b.collateral = collateralDelta;
        b.price = price;
        b.positionSizeCollateral = positionSize(collateralDelta, t.leverage);
        _impact(d, t, info, price, b);
        _fees(d, t, price, b);

        uint128 precisionDelta = d.getCollateral(t.collateralIndex).precisionDelta;
        // getTradeValueCollateral(existing, pnl, closingFee = 0): holding fees and realized pnl of the whole trade
        int256 valueNoClosingFee = int256(
            tradeValuePure(t.collateralAmount, b.pnlPercent, b.holdingFees - b.totalRealizedPnl, precisionDelta)
        );
        int256 partialNetPnl =
            ((valueNoClosingFee - int256(uint256(t.collateralAmount))) * int256(b.positionSizeCollateral)) /
            int256(existingSize);

        b.closingFeeNoTier = totalTradeFeesRaw(d, t, b.positionSizeCollateral);
        b.closingFee = totalTradeFees(d, t, b.positionSizeCollateral);
        b.value = int256(uint256(collateralDelta)) + partialNetPnl - int256(b.closingFee);

        _liq(d, t, price, b);
    }

    /// @dev Liquidation price and flag (a helper so value() also compiles without the optimizer, for coverage).
    function _liq(G d, G.Trade memory t, uint64 price, Breakdown memory b) private view {
        b.liqPrice = liquidationPrice(d, t, price);
        b.liquidated = t.long ? price <= b.liqPrice : price >= b.liqPrice;
    }

    // ---- pieces, each mirroring one TradingCommonUtils function ----

    function _fees(G d, G.Trade memory t, uint64 price, Breakdown memory b) private view {
        b.holdingFees = d.getTradePendingHoldingFeesCollateral(t.user, t.index, price).totalFeeCollateral;
        (,, b.totalRealizedPnl) = d.getTradeRealizedPnlCollateral(t.user, t.index);
    }

    /// @dev TradingCommonUtils.getTradeClosingPriceImpact with useCumulativeVolPriceImpact = true (market close).
    function _impact(G d, G.Trade memory t, G.TradeInfo memory info, uint64 price, Breakdown memory b)
        private
        view
    {
        if (info.contractsVersion < V9_2) {
            b.priceAfterImpact = price;
        } else {
            uint256 posUsd = d.getUsdNormalizedValue(t.collateralIndex, b.positionSizeCollateral);
            uint256 posToken =
                (b.positionSizeCollateral * t.positionSizeToken) / positionSize(t.collateralAmount, t.leverage);

            b.fixedSpreadP = fixedSpreadP(d.pairSpreadP(t.user, uint256(t.pairIndex)), t.long, false);
            b.skewPriceImpactP = info.contractsVersion < V10
                ? int256(0)
                : d.getTradeSkewPriceImpactP(t.collateralIndex, t.pairIndex, t.long, posToken, false);

            // pass 1: cumulative vol impact assuming negative pnl, to decide whether the protection factor applies
            int256 cumul0 = d.getTradeCumulVolPriceImpactP(
                t.user, t.pairIndex, t.long, posUsd, false, false, info.lastPosIncreaseBlock
            );
            uint256 valueNoFactor = tradeValueCollateral(
                d,
                t,
                pnlPercent(
                    t.openPrice,
                    priceAfterImpact(price, b.fixedSpreadP + cumul0 + b.skewPriceImpactP),
                    t.long,
                    t.leverage
                ),
                totalTradeFees(d, t, positionSize(t.collateralAmount, t.leverage)),
                price
            );
            b.cumulVolPriceImpactP = d.getTradeCumulVolPriceImpactP(
                t.user,
                t.pairIndex,
                t.long,
                posUsd,
                valueNoFactor > t.collateralAmount,
                false,
                info.lastPosIncreaseBlock
            );
            b.priceAfterImpact =
                priceAfterImpact(price, b.fixedSpreadP + b.cumulVolPriceImpactP + b.skewPriceImpactP);
        }

        b.pnlPercent = pnlPercent(t.openPrice, b.priceAfterImpact, t.long, t.leverage);
        b.rawPnl = (b.pnlPercent * int256(b.collateral)) / 100 / int256(P_10);
        b.impactHaircut =
            (pnlPercent(t.openPrice, price, t.long, t.leverage) * int256(b.collateral)) / 100 / int256(P_10) - b.rawPnl;
    }

    function tradeValueCollateral(G d, G.Trade memory t, int256 pnlP, uint256 closingFee, uint64 price)
        internal
        view
        returns (uint256)
    {
        int256 holding = d.getTradePendingHoldingFeesCollateral(t.user, t.index, price).totalFeeCollateral;
        (,, int256 realized) = d.getTradeRealizedPnlCollateral(t.user, t.index);
        return tradeValuePure(
            t.collateralAmount,
            pnlP,
            int256(closingFee) + holding - realized,
            d.getCollateral(t.collateralIndex).precisionDelta
        );
    }

    /// @dev TradingCommonUtils.getTotalTradeFeesCollateral (non counter trade), fee tier applied unless skipped.
    function totalTradeFees(G d, G.Trade memory t, uint256 positionSizeCollateral) internal view returns (uint256) {
        uint256 raw = totalTradeFeesRaw(d, t, positionSizeCollateral);
        G.PairFlags memory flags = d.getPairFlags(t.collateralIndex, t.pairIndex);
        return flags.skipFeeTierMultiplier ? raw : d.calculateFeeAmount(t.user, raw);
    }

    function totalTradeFeesRaw(G d, G.Trade memory t, uint256 positionSizeCollateral)
        internal
        view
        returns (uint256)
    {
        uint256 minSize = d.getCollateralFromUsdNormalizedValue(
            t.collateralIndex, d.pairMinPositionSizeUsd(t.pairIndex)
        ) * 1e3;
        uint256 basis = positionSizeCollateral * 1e3;
        if (basis < minSize) basis = minSize;
        return (basis * d.pairTotalPositionSizeFeeP(t.pairIndex)) / P_10 / 100 / 1e3;
    }

    function liquidationPrice(G d, G.Trade memory t, uint64 price) internal view returns (uint256) {
        return d.getTradeLiquidationPrice(
            G.LiqPriceInput({
                collateralIndex: t.collateralIndex,
                trader: t.user,
                pairIndex: t.pairIndex,
                index: t.index,
                openPrice: t.openPrice,
                long: t.long,
                collateral: t.collateralAmount,
                leverage: t.leverage,
                additionalFeeCollateral: 0,
                liquidationParams: d.getTradeLiquidationParams(t.user, t.index),
                currentPairPrice: price,
                isCounterTrade: t.isCounterTrade,
                partialCloseMultiplier: 1e18,
                beforeOpened: false
            })
        );
    }

    function positionSize(uint256 collateral, uint24 leverage) internal pure returns (uint256) {
        return (collateral * leverage) / 1e3;
    }

    function pnlPercent(uint64 openPrice, uint64 currentPrice, bool long, uint24 leverage)
        internal
        pure
        returns (int256 p)
    {
        if (openPrice == 0) return 0;
        int256 o = int256(uint256(openPrice));
        int256 c = int256(uint256(currentPrice));
        p = ((long ? c - o : o - c) * 100 * int256(P_10) * int256(uint256(leverage))) / o / 1e3;
        int256 minP = -100 * int256(P_10);
        if (p < minP) p = minP;
    }

    function fixedSpreadP(uint256 spreadP, bool long, bool open) internal pure returns (int256) {
        spreadP = spreadP / 2;
        if (!open) long = !long;
        return int256(spreadP) * (long ? int256(1) : int256(-1));
    }

    function priceAfterImpact(uint64 oraclePrice, int256 totalImpactP) internal pure returns (uint64) {
        int256 raw = int256(uint256(oraclePrice)) + (int256(uint256(oraclePrice)) * totalImpactP) / int256(P_10) / 100;
        return uint64(uint256(raw));
    }

    function tradeValuePure(uint256 collateral, int256 pnlP, int256 feesCollateral, uint128 precisionDelta)
        internal
        pure
        returns (uint256)
    {
        int256 pd = int256(uint256(precisionDelta));
        int256 v = (int256(collateral) * pd + (int256(collateral) * pd * pnlP) / int256(P_10) / 100) / pd
            - feesCollateral;
        return v > 0 ? uint256(v) : 0;
    }
}
