// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Stage 0 spike only (test code). Minimal subset of the gTrade v10 GNSMultiCollatDiamond ABI.
/// @dev Generated from the ABI in @gainsnetwork/sdk 1.8.10
///      (lib/contracts/types/generated/factories/GNSMultiCollatDiamond__factory.js): names, types, field
///      order and struct layouts are copied from that ABI, nothing hand-typed. Struct comments name the
///      Gains source struct. Precision: price/sl/tp 1e10, leverage 1e3, slippage 1e3, positionSizeToken 1e18.
interface IGainsDiamondSpike {
    /// ITradingStorage.Trade
    struct Trade {
        address user;
        uint32 index;
        uint16 pairIndex;
        uint24 leverage;
        bool long;
        bool isOpen;
        uint8 collateralIndex;
        uint8 tradeType;
        uint120 collateralAmount;
        uint64 openPrice;
        uint64 tp;
        uint64 sl;
        bool isCounterTrade;
        uint160 positionSizeToken;
        uint24 __placeholder;
    }

    /// ITradingStorage.TradeInfo
    struct TradeInfo {
        uint32 createdBlock;
        uint32 tpLastUpdatedBlock;
        uint32 slLastUpdatedBlock;
        uint16 maxSlippageP;
        uint48 lastOiUpdateTs;
        uint48 collateralPriceUsd;
        uint8 contractsVersion;
        uint32 lastPosIncreaseBlock;
        uint8 __placeholder;
    }

    /// IPairsStorage.GroupLiquidationParams
    struct GroupLiquidationParams {
        uint40 maxLiqSpreadP;
        uint40 startLiqThresholdP;
        uint40 endLiqThresholdP;
        uint24 startLeverage;
        uint24 endLeverage;
    }

    /// ITradingStorage.PendingOrder
    struct PendingOrder {
        Trade trade;
        address user;
        uint32 index;
        bool isOpen;
        uint8 orderType;
        uint32 createdBlock;
        uint16 maxSlippageP;
    }

    /// ITradingStorage.Counter
    struct Counter {
        uint32 currentIndex;
        uint32 openCount;
        uint192 __placeholder;
    }

    /// IFundingFees.TradeHoldingFees
    struct TradeHoldingFees {
        int256 fundingFeeCollateral;
        uint256 borrowingFeeCollateral;
        uint256 borrowingFeeCollateral_old;
        int256 totalFeeCollateral;
    }

    /// IFundingFees.TradeFeesData
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

    /// IBorrowingFees.LiqPriceInput
    struct LiqPriceInput {
        uint8 collateralIndex;
        address trader;
        uint16 pairIndex;
        uint32 index;
        uint64 openPrice;
        bool long;
        uint256 collateral;
        uint256 leverage;
        int256 additionalFeeCollateral;
        GroupLiquidationParams liquidationParams;
        uint64 currentPairPrice;
        bool isCounterTrade;
        uint256 partialCloseMultiplier;
        bool beforeOpened;
    }

    /// ITradingStorage.Collateral
    struct Collateral {
        address collateral;
        bool isActive;
        uint88 __placeholder;
        uint128 precision;
        uint128 precisionDelta;
    }

    /// ITradingStorage.Id
    struct Id {
        address user;
        uint32 index;
    }

    /// IPairsStorage.Feed
    struct Feed {
        address feed1;
        address feed2;
        uint8 feedCalculation;
        uint256 maxDeviationP;
    }

    /// IPairsStorage.Pair
    struct Pair {
        string from;
        string to;
        Feed feed;
        uint256 spreadP;
        uint256 groupIndex;
        uint256 feeIndex;
    }

    /// IPairsStorage.PairFlags
    struct PairFlags {
        bool skipBurn;
        bool skipFeeTierMultiplier;
        bool skipFeeTierMultiplierCounterTrade;
        uint232 __placeholder;
    }

    /// ITradingCommonUtils.TradePriceImpact
    struct TradePriceImpact {
        uint256 positionSizeToken;
        int256 fixedSpreadP;
        int256 cumulVolPriceImpactP;
        int256 skewPriceImpactP;
        int256 totalPriceImpactP;
        uint64 priceAfterImpact;
    }

    /// IUpdatePositionSize.DecreasePositionSizeValues
    struct DecreasePositionSizeValues {
        bool isLeverageUpdate;
        uint256 positionSizeCollateralDelta;
        uint256 existingPositionSizeCollateral;
        uint256 existingLiqPrice;
        uint256 newLiqPrice;
        TradePriceImpact priceImpact;
        int256 existingPnlPercent;
        int256 partialRawPnlCollateral;
        int256 partialNetPnlCollateral;
        int256 pnlToRealizeCollateral;
        uint256 closingFeeCollateral;
        uint256 totalAvailableCollateralInDiamond;
        int256 availableCollateralInDiamond;
        int256 collateralSentToTrader;
        uint120 newCollateralAmount;
        uint24 newLeverage;
    }

    /// IUpdatePositionSize.IncreasePositionSizeValues
    struct IncreasePositionSizeValues {
        uint256 positionSizeCollateralDelta;
        uint256 existingPositionSizeCollateral;
        uint256 newPositionSizeCollateral;
        uint256 newCollateralAmount;
        uint256 newLeverage;
        TradePriceImpact priceImpact;
        int256 existingPnlCollateral;
        uint256 oldPosSizePlusPnlCollateral;
        uint256 newOpenPrice;
        uint256 openingFeesCollateral;
        uint256 existingLiqPrice;
        uint256 newLiqPrice;
        bool isCounterTradeValidated;
        uint256 exceedingPositionSizeCollateral;
        uint256 counterTradeCollateralToReturn;
        uint256 newEffectiveLeverage;
    }

    /// IUpdateLeverage.UpdateLeverageValues
    struct UpdateLeverageValues {
        uint256 newLeverage;
        uint256 newCollateralAmount;
        uint256 existingLiqPrice;
        uint256 newLiqPrice;
        uint256 govFeeCollateral;
        uint256 newEffectiveLeverage;
        uint256 totalTradeAvailableCollateralInDiamond;
        uint256 availableCollateralInDiamond;
    }

    /// BufferChainlink.buffer
    struct buffer {
        bytes buf;
        uint256 capacity;
    }

    /// Chainlink.Request
    struct Request {
        bytes32 id;
        address callbackAddress;
        bytes4 callbackFunctionId;
        uint256 nonce;
        buffer buf;
    }

    event MarketOrderInitiated(Id orderId, address indexed trader, uint16 indexed pairIndex, bool open);
    event MarketExecuted(Id orderId, address indexed user, uint32 indexed index, Trade t, bool open, uint256 oraclePrice, uint256 marketPrice, uint256 liqPrice, TradePriceImpact priceImpact, int256 percentProfit, uint256 amountSentToTrader, uint256 collateralPriceUsd);
    event MarketOpenCanceled(Id orderId, address indexed trader, uint256 indexed pairIndex, uint8 cancelReason, uint256 collateralReturned);
    event MarketCloseCanceled(Id orderId, address indexed trader, uint256 indexed pairIndex, uint256 indexed index, uint8 cancelReason);
    event LimitExecuted(Id orderId, address indexed user, uint32 indexed index, uint32 indexed limitIndex, Trade t, address triggerCaller, uint8 orderType, uint256 oraclePrice, uint256 marketPrice, uint256 liqPrice, TradePriceImpact priceImpact, int256 percentProfit, uint256 amountSentToTrader, uint256 collateralPriceUsd, bool exactExecution);
    event TradeClosed(address indexed user, uint32 indexed index, bool isPnlPositive);
    event TradeStored(address indexed user, uint32 indexed index, Trade trade, TradeInfo tradeInfo, GroupLiquidationParams liquidationParams);
    event PendingOrderStored(PendingOrder pendingOrder);
    event PendingOrderClosed(Id orderId);
    event TradeSlUpdated(address indexed user, uint32 indexed index, uint64 newSl);
    event TradeTpUpdated(address indexed user, uint32 indexed index, uint64 newTp);
    event OpenOrderPlaced(address indexed trader, uint16 indexed pairIndex, uint32 indexed index);
    event OpenLimitCanceled(address indexed trader, uint16 indexed pairIndex, uint32 indexed index);
    event PositionSizeUpdateInitiated(Id orderId, address indexed trader, uint256 indexed pairIndex, uint256 indexed index, bool isIncrease, uint256 collateralDelta, uint256 leverageDelta);
    event PositionSizeDecreaseExecuted(Id orderId, uint8 cancelReason, uint8 indexed collateralIndex, address indexed trader, uint256 pairIndex, uint256 indexed index, bool long, uint256 oraclePrice, uint256 collateralPriceUsd, uint256 collateralDelta, uint256 leverageDelta, DecreasePositionSizeValues values);
    event PositionSizeIncreaseExecuted(Id orderId, uint8 cancelReason, uint8 indexed collateralIndex, address indexed trader, uint256 pairIndex, uint256 indexed index, bool long, uint256 oraclePrice, uint256 collateralPriceUsd, uint256 collateralDelta, uint256 leverageDelta, IncreasePositionSizeValues values);
    event LeverageUpdateInitiated(Id orderId, address indexed trader, uint256 indexed pairIndex, uint256 indexed index, bool isIncrease, uint256 newLeverage);
    event LeverageUpdateExecuted(Id orderId, bool isIncrease, uint8 cancelReason, uint8 indexed collateralIndex, address indexed trader, uint256 pairIndex, uint256 indexed index, uint256 oraclePrice, uint256 collateralDelta, UpdateLeverageValues values);
    event ChainlinkCallbackTimeout(Id pendingOrderId, uint256 indexed pairIndex);
    event CollateralReturnedAfterTimeout(Id pendingOrderId, uint8 indexed collateralIndex, address indexed trader, uint256 collateralAmount);
    event TradeValueTransferred(uint8 indexed collateralIndex, address indexed trader, uint32 indexed index, int256 collateralSentToTrader, int256 availableCollateralInDiamond);
    event FeesProcessed(uint8 indexed collateralIndex, address indexed trader, uint256 positionSizeCollateral, uint8 orderType, uint256 totalFeesCollateral);
    event LinkRequestCreated(Request request);
    event PriceRequested(uint8 indexed collateralIndex, uint256 indexed pairIndex, PendingOrder pendingOrder, uint256 positionSizeCollateral, uint256 fromBlock, bool isCounterTrade, bool isLookback, bytes32 job, uint256 linkFeePerNode, uint256 nodesCount);

    // PLAN.md section 2: calls (trader = msg.sender)
    function openTrade(Trade calldata _trade, uint16 _maxSlippageP, address _referrer) external;
    function closeTradeMarket(uint32 _index, uint64 _expectedPrice) external;
    function decreasePositionSize(uint32 _index, uint120 _collateralDelta, uint24 _leverageDelta, uint64 _expectedPrice) external;
    function increasePositionSize(uint32 _index, uint120 _collateralDelta, uint24 _leverageDelta, uint64 _expectedPrice, uint16 _maxSlippageP) external;
    function updateSl(uint32 _index, uint64 _newSl) external;
    function updateTp(uint32 _index, uint64 _newTp) external;
    function updateLeverage(uint32 _index, uint24 _newLeverage) external;
    function cancelOpenOrder(uint32 _index) external;
    function cancelOrderAfterTimeout(uint32 _orderIndex) external;

    // PLAN.md section 2: reads
    function getTrades(address _trader) external view returns (Trade[] memory);
    function getTradeInfos(address _trader) external view returns (TradeInfo[] memory);
    function getTradesLiquidationParams(address _trader) external view returns (GroupLiquidationParams[] memory);
    function getPendingOrders(address _user) external view returns (PendingOrder[] memory);
    function getCounters(address _trader, uint8 _type) external view returns (Counter memory);
    function getTradePendingHoldingFeesCollateral(address _trader, uint32 _index, uint64 _currentPairPrice) external view returns (TradeHoldingFees memory tradeHoldingFees);
    function getTradeFeesData(address _trader, uint32 _index) external view returns (TradeFeesData memory);
    function getTradeLiquidationPrice(LiqPriceInput calldata _input) external view returns (uint256);
    function getPairMaxOi(uint8 _collateralIndex, uint16 _pairIndex) external view returns (uint256);
    function pairMinPositionSizeUsd(uint256 _pairIndex) external view returns (uint256);
    function getCollateral(uint8 _index) external view returns (Collateral memory);
    function getTradingDelegate(address _trader) external view returns (address);

    // Stage 0 only: reads needed to verify section 2 claims and the NAV formula (PLAN.md 4.3)
    function getCollateralIndex(address _collateral) external view returns (uint8);
    function getTrade(address _trader, uint32 _index) external view returns (Trade memory);
    function getTradeInfo(address _trader, uint32 _index) external view returns (TradeInfo memory);
    function getPendingOrder(Id calldata _orderId) external view returns (PendingOrder memory);
    function pairMaxLeverage(uint256 _pairIndex) external view returns (uint256);
    function pairMinLeverage(uint256 _pairIndex) external view returns (uint256);
    function pairMinFeeUsd(uint256 _pairIndex) external view returns (uint256);
    function pairTotalPositionSizeFeeP(uint256 _pairIndex) external view returns (uint256);
    function pairTotalLiqCollateralFeeP(uint256 _pairIndex) external view returns (uint256);
    function pairSpreadP(address _trader, uint256 _pairIndex) external view returns (uint256);
    function pairs(uint256 _index) external view returns (Pair memory);
    function getPairFlags(uint8 _collateralIndex, uint16 _pairIndex) external view returns (PairFlags memory);
    function calculateFeeAmount(address _trader, uint256 _normalFeeAmountCollateral) external view returns (uint256);
    function getUsdNormalizedValue(uint8 _collateralIndex, uint256 _collateralValue) external view returns (uint256);
    function getCollateralFromUsdNormalizedValue(uint8 _collateralIndex, uint256 _normalizedValue) external view returns (uint256);
    function getTradeRealizedPnlCollateral(address _trader, uint32 _index) external view returns (int256 realizedPnlCollateral, uint256 realizedTradingFeesCollateral, int256 totalRealizedPnlCollateral);
    function getTradeSkewPriceImpactP(uint8 _collateralIndex, uint16 _pairIndex, bool _long, uint256 _positionSizeToken, bool _open) external view returns (int256 priceImpactP);
    function getTradeCumulVolPriceImpactP(address _trader, uint16 _pairIndex, bool _long, uint256 _tradeOpenInterestUsd, bool _isPnlPositive, bool _open, uint256 _lastPosIncreaseBlock) external view returns (int256 priceImpactP);
    function getTradeLiquidationParams(address _trader, uint32 _index) external view returns (GroupLiquidationParams memory);
    function getMarketOrdersTimeoutBlocks() external view returns (uint16);
    function getOracles() external view returns (address[] memory);
    function getMinAnswers() external view returns (uint8);
    function fulfill(bytes32 _requestId, uint256 _priceData) external;
}
