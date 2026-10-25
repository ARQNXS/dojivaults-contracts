// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Vm} from "forge-std/Vm.sol";
import {IGainsDiamond} from "../../../../src/gains/IGainsDiamond.sol";
import {GainsPrice} from "../../../../src/gains/GainsPrice.sol";
import {GTrade} from "../../../../src/gains/IGainsDiamond.sol";
import {IGainsExtra, NavHarness} from "./NavForkBase.sol";

interface IGainsFeesData {
    struct TradeFeesData {
        uint128 realizedTradingFeesCollateral;
        int128 realizedPnlCollateral;
        uint128 manuallyRealizedNegativePnlCollateral;
        uint128 alreadyTransferredNegativePnlCollateral;
        uint128 virtualAvailableCollateralInDiamond;
        uint128 __placeholder;
        int128 initialAccFundingFeeP;
        uint128 initialAccBorrowingFeeP;
    }

    function getTradeFeesData(address _trader, uint32 _index) external view returns (TradeFeesData memory);
}

/// @notice Serializes every raw input of one trade's close value (diamond reads, Chainlink, band) plus GainsNav's
///         per-trade value, as one JSON object, for the TypeScript differential (contracts/audit/gains/nav/diff).
///         All numbers are decimal strings in the diamond's native units.
contract NavDump {
    Vm internal constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    IGainsDiamond internal immutable D;
    NavHarness internal immutable H;

    constructor(IGainsDiamond d, NavHarness h) {
        D = d;
        H = h;
    }

    function _s(uint256 x) internal pure returns (string memory) {
        return string.concat("\"", vm.toString(x), "\"");
    }

    function _si(int256 x) internal pure returns (string memory) {
        return string.concat("\"", vm.toString(x), "\"");
    }

    function _kv(string memory k, uint256 x) internal pure returns (string memory) {
        return string.concat("\"", k, "\":", _s(x), ",");
    }

    function _kvi(string memory k, int256 x) internal pure returns (string memory) {
        return string.concat("\"", k, "\":", _si(x), ",");
    }

    function _kvb(string memory k, bool b) internal pure returns (string memory) {
        return string.concat("\"", k, "\":", b ? "true" : "false", ",");
    }

    /// @param tag free text (case name)
    /// @param c Chainlink mid (1e10), band in bps; `price` = the valuation / fill price the record is evaluated at
    /// @param paid USDC Gains paid at `price` (0 with hasPaid false when not closed)
    function record(
        string memory tag,
        address user,
        uint32 idx,
        uint64 c,
        uint16 band,
        uint64 price,
        bool hasPaid,
        uint256 paid
    ) external view returns (string memory) {
        IGainsDiamond.Trade memory t = D.getTrade(user, idx);
        string memory head = string.concat(
            "{\"tag\":\"", tag, "\",", _kv("block", vm.getBlockNumber()), _kv("timestamp", vm.getBlockTimestamp()),
            _kv("chainlink", c), _kv("bandBps", band), _kv("price", price), _kvb("hasPaid", hasPaid), _kv("paid", paid)
        );
        return string.concat(head, _trade(t), _info(user, idx), _fees(t), _impact(t, price), _holding(t, price, c), _nav(t, price, c, band), "\"end\":0}");
    }

    function _trade(IGainsDiamond.Trade memory t) internal pure returns (string memory) {
        return string.concat(
            _kv("index", t.index), _kv("pairIndex", t.pairIndex), _kv("leverage", t.leverage), _kvb("long", t.long),
            _kvb("isOpen", t.isOpen), _kv("collateralIndex", t.collateralIndex), _kv("tradeType", t.tradeType),
            _kv("collateralAmount", t.collateralAmount), _kv("openPrice", t.openPrice), _kv("positionSizeToken", t.positionSizeToken),
            _kvb("isCounterTrade", t.isCounterTrade)
        );
    }

    function _info(address user, uint32 idx) internal view returns (string memory) {
        IGainsDiamond.TradeInfo memory i = D.getTradeInfo(user, idx);
        IGainsDiamond.GroupLiquidationParams memory l = D.getTradeLiquidationParams(user, idx);
        IGainsFeesData.TradeFeesData memory f = IGainsFeesData(address(D)).getTradeFeesData(user, idx);
        (int256 rp, uint256 rf, int256 rt) = D.getTradeRealizedPnlCollateral(user, idx);
        return string.concat(
            string.concat(
                _kv("contractsVersion", i.contractsVersion), _kv("createdBlock", i.createdBlock),
                _kv("lastPosIncreaseBlock", i.lastPosIncreaseBlock), _kv("maxLiqSpreadP", l.maxLiqSpreadP),
                _kv("startLiqThresholdP", l.startLiqThresholdP), _kv("endLiqThresholdP", l.endLiqThresholdP),
                _kv("startLeverage", l.startLeverage), _kv("endLeverage", l.endLeverage)
            ),
            _kv("fd_realizedTradingFeesCollateral", f.realizedTradingFeesCollateral), _kvi("fd_realizedPnlCollateral", f.realizedPnlCollateral),
            _kvi("rp_realizedPnl", rp), _kv("rp_realizedFees", rf), _kvi("rp_total", rt)
        );
    }

    function _fees(IGainsDiamond.Trade memory t) internal view returns (string memory) {
        uint256 minPosUsd = D.pairMinPositionSizeUsd(t.pairIndex);
        return string.concat(
            _kv("pairSpreadP", D.pairSpreadP(t.user, t.pairIndex)), _kv("totalPositionSizeFeeP", D.pairTotalPositionSizeFeeP(t.pairIndex)),
            _kv("minPositionSizeUsd", minPosUsd), _kv("minPositionSizeCollateral", D.getCollateralFromUsdNormalizedValue(t.collateralIndex, minPosUsd)),
            _kv("collateralPriceUsd", IGainsExtra(address(D)).getCollateralPriceUsd(t.collateralIndex)),
            _kv("feeTierOf1e12", D.calculateFeeAmount(t.user, 1e12)), _kvb("skipFeeTier", D.getPairFlags(t.collateralIndex, t.pairIndex).skipFeeTierMultiplier),
            _kv("govFeeP", D.getTradeFeeParams(t.collateralIndex, t.pairIndex).govFeeP),
            _kv("precisionDelta", D.getCollateral(t.collateralIndex).precisionDelta)
        );
    }

    function _impact(IGainsDiamond.Trade memory t, uint64 price) internal view returns (string memory) {
        IGainsExtra.PairOiToken memory oi = IGainsExtra(address(D)).getPairOiAfterV10Token(t.collateralIndex, t.pairIndex);
        uint256 size = GTrade.positionSize(t.collateralAmount, t.leverage);
        uint256 sizeUsd = D.getUsdNormalizedValue(t.collateralIndex, size);
        uint32 lpib = D.getTradeInfo(t.user, t.index).lastPosIncreaseBlock;
        return string.concat(
            _kv("oiLongToken", oi.oiLongToken), _kv("oiShortToken", oi.oiShortToken),
            _kv("skewDepth", IGainsExtra(address(D)).getPairSkewDepth(t.collateralIndex, t.pairIndex)),
            _kvi("diamondSkewP", D.getTradeSkewPriceImpactP(t.collateralIndex, t.pairIndex, t.long, t.positionSizeToken, false)),
            _kv("sizeUsd", sizeUsd),
            _kvi("cumulNeg", D.getTradeCumulVolPriceImpactP(t.user, t.pairIndex, t.long, sizeUsd, false, false, lpib)),
            _kvi("cumulPos", D.getTradeCumulVolPriceImpactP(t.user, t.pairIndex, t.long, sizeUsd, true, false, lpib)),
            _kv("l2block", GTrade.l2BlockNumber()), _kv("_priceUsed", price)
        );
    }

    function _holding(IGainsDiamond.Trade memory t, uint64 price, uint64 c) internal view returns (string memory) {
        IGainsDiamond.TradeHoldingFees memory h = D.getTradePendingHoldingFeesCollateral(t.user, t.index, price);
        IGainsDiamond.TradeHoldingFees memory hc = D.getTradePendingHoldingFeesCollateral(t.user, t.index, c);
        return string.concat(
            _kvi("h_funding", h.fundingFeeCollateral), _kv("h_borrowing", h.borrowingFeeCollateral), _kv("h_borrowingOld", h.borrowingFeeCollateral_old),
            _kvi("h_total", h.totalFeeCollateral), _kvi("hC_total", hc.totalFeeCollateral)
        );
    }

    function _nav(IGainsDiamond.Trade memory t, uint64 price, uint64 c, uint16 band) internal view returns (string memory) {
        uint256 liqP = _liq(t, price);
        uint256 liqC = _liq(t, c);
        return string.concat(
            _kv("diamondLiqAtPrice", liqP), _kv("diamondLiqAtC", liqC),
            _kv("gainsNavAtPrice", H.tradeValue(D, t, price, band)), _kv("gainsNavAtC", H.tradeValue(D, t, c, band)),
            _kv("gainsNavAtPriceNoBand", H.tradeValue(D, t, price, 0)), _kv("adverseP", GainsPrice.adverse(c, band, t.long))
        );
    }

    function _liq(IGainsDiamond.Trade memory t, uint64 price) internal view returns (uint256) {
        return D.getTradeLiquidationPrice(
            IGainsDiamond.LiqPriceInput({
                collateralIndex: t.collateralIndex,
                trader: t.user,
                pairIndex: t.pairIndex,
                index: t.index,
                openPrice: t.openPrice,
                long: t.long,
                collateral: t.collateralAmount,
                leverage: t.leverage,
                additionalFeeCollateral: 0,
                liquidationParams: D.getTradeLiquidationParams(t.user, t.index),
                currentPairPrice: price,
                isCounterTrade: t.isCounterTrade,
                partialCloseMultiplier: 1e18,
                beforeOpened: false
            })
        );
    }
}
