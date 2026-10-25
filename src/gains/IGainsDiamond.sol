// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

/// @title IGainsDiamond
/// @notice The subset of the gTrade v10 GNSMultiCollatDiamond that GainsVault uses (PLAN.md section 2).
/// @dev Names, types, field order and struct layouts are copied from the ABI in @gainsnetwork/sdk 1.8.10
///      (via test/gains/spike/IGainsDiamondSpike.sol, Stage 0), plus the two Chainlink events the diamond emits and
///      the SDK ABI lacks (ChainlinkRequested, ChainlinkFulfilled). Precision: price, SL, TP 1e10; leverage 1e3;
///      slippage 1e3 (1% = 1000); positionSizeToken 1e18. Trader = msg.sender = the vault.
interface IGainsDiamond {
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

    /// IFundingFees.TradeHoldingFees
    struct TradeHoldingFees {
        int256 fundingFeeCollateral;
        uint256 borrowingFeeCollateral;
        uint256 borrowingFeeCollateral_old;
        int256 totalFeeCollateral;
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

    /// ITradingStorage.Counter (GR2-LIVE-01): currentIndex = the next index Gains assigns; indexes are never reused
    struct Counter {
        uint32 currentIndex;
        uint32 openCount;
        uint192 __placeholder;
    }

    /// IPairsStorage.PairFlags
    struct PairFlags {
        bool skipBurn;
        bool skipFeeTierMultiplier;
        bool skipFeeTierMultiplierCounterTrade;
        uint232 __placeholder;
    }

    /// IPairsStorage.GlobalTradeFeeParams
    struct GlobalTradeFeeParams {
        uint24 referralFeeP;
        uint24 govFeeP;
        uint24 triggerOrderFeeP;
        uint24 gnsOtcFeeP;
        uint24 gTokenFeeP;
        uint24 gTokenOcFeeP;
        uint112 __placeholder;
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

    // Events the executor and indexer decode (PLAN.md 5.2). The first two are emitted by the diamond on every
    // request (one per oracle node) and fill, and are missing from the SDK ABI.
    event ChainlinkRequested(bytes32 indexed id);
    event ChainlinkFulfilled(bytes32 indexed id);
    event MarketOrderInitiated(Id orderId, address indexed trader, uint16 indexed pairIndex, bool open);
    event MarketExecuted(Id orderId, address indexed user, uint32 indexed index, Trade t, bool open, uint256 oraclePrice, uint256 marketPrice, uint256 liqPrice, TradePriceImpact priceImpact, int256 percentProfit, uint256 amountSentToTrader, uint256 collateralPriceUsd);
    event MarketOpenCanceled(Id orderId, address indexed trader, uint256 indexed pairIndex, uint8 cancelReason, uint256 collateralReturned);
    event MarketCloseCanceled(Id orderId, address indexed trader, uint256 indexed pairIndex, uint256 indexed index, uint8 cancelReason);
    event LimitExecuted(Id orderId, address indexed user, uint32 indexed index, uint32 indexed limitIndex, Trade t, address triggerCaller, uint8 orderType, uint256 oraclePrice, uint256 marketPrice, uint256 liqPrice, TradePriceImpact priceImpact, int256 percentProfit, uint256 amountSentToTrader, uint256 collateralPriceUsd, bool exactExecution);
    event TradeClosed(address indexed user, uint32 indexed index, bool isPnlPositive);
    event TradeSlUpdated(address indexed user, uint32 indexed index, uint64 newSl);
    event TradeTpUpdated(address indexed user, uint32 indexed index, uint64 newTp);
    event OpenOrderPlaced(address indexed trader, uint16 indexed pairIndex, uint32 indexed index);
    event OpenLimitCanceled(address indexed trader, uint16 indexed pairIndex, uint32 indexed index);
    event ChainlinkCallbackTimeout(Id pendingOrderId, uint256 indexed pairIndex);
    event CollateralReturnedAfterTimeout(Id pendingOrderId, uint8 indexed collateralIndex, address indexed trader, uint256 collateralAmount);
    event TradeValueTransferred(uint8 indexed collateralIndex, address indexed trader, uint32 indexed index, int256 collateralSentToTrader, int256 availableCollateralInDiamond);

    // Calls (trader = msg.sender)
    function openTrade(Trade calldata _trade, uint16 _maxSlippageP, address _referrer) external;
    function closeTradeMarket(uint32 _index, uint64 _expectedPrice) external;
    function decreasePositionSize(uint32 _index, uint120 _collateralDelta, uint24 _leverageDelta, uint64 _expectedPrice) external;
    function increasePositionSize(uint32 _index, uint120 _collateralDelta, uint24 _leverageDelta, uint64 _expectedPrice, uint16 _maxSlippageP) external;
    function updateSl(uint32 _index, uint64 _newSl) external;
    function updateTp(uint32 _index, uint64 _newTp) external;
    function updateLeverage(uint32 _index, uint24 _newLeverage) external;
    function updateMaxClosingSlippageP(uint32 _index, uint16 _maxSlippageP) external;
    function cancelOpenOrder(uint32 _index) external;
    function cancelOrderAfterTimeout(uint32 _orderIndex) external;

    // Reads
    function getTrades(address _trader) external view returns (Trade[] memory);
    function getTrade(address _trader, uint32 _index) external view returns (Trade memory);
    /// @dev GR2-LIVE-01. TradingStorageGetters; selectors 0xc6e729bb / 0x0212f0d6, both on facet
    ///      0xaFBD02cf04baAC6726ae017AC446e3Ae5E1190D9 of the Arbitrum diamond. _type: 0 = TRADE, 1 = PENDING_ORDER.
    function getPendingOrder(Id calldata _orderId) external view returns (PendingOrder memory);
    function getCounters(address _trader, uint8 _type) external view returns (Counter memory);
    function getTradeInfo(address _trader, uint32 _index) external view returns (TradeInfo memory);
    function getPendingOrders(address _user) external view returns (PendingOrder[] memory);
    function getTradeLiquidationParams(address _trader, uint32 _index) external view returns (GroupLiquidationParams memory);
    function getTradePendingHoldingFeesCollateral(address _trader, uint32 _index, uint64 _currentPairPrice) external view returns (TradeHoldingFees memory tradeHoldingFees);
    function getTradeRealizedPnlCollateral(address _trader, uint32 _index) external view returns (int256 realizedPnlCollateral, uint256 realizedTradingFeesCollateral, int256 totalRealizedPnlCollateral);
    function getTradeLiquidationPrice(LiqPriceInput calldata _input) external view returns (uint256);
    function getTradeSkewPriceImpactP(uint8 _collateralIndex, uint16 _pairIndex, bool _long, uint256 _positionSizeToken, bool _open) external view returns (int256 priceImpactP);
    /// @dev GNSPriceImpact (PriceImpactUtils.getPairSkewDepth): the pair's 1 % skew depth in tokens (1e18), 0 = no
    ///      skew impact. Selector 0xf0f045a7, on facet 0xDCAD09f7682e045d235FCf4Aa9f1B47AB2054e55 of the Arbitrum diamond.
    function getPairSkewDepth(uint8 _collateralIndex, uint16 _pairIndex) external view returns (uint256);
    /// @dev BorrowingFeesUtils.getPairMaxOiCollateral: Gains' open interest cap of the pair, in collateral precision.
    ///      Only a sanity ceiling on the pair cap (GR2 XF-04).
    function getPairMaxOiCollateral(uint8 _collateralIndex, uint16 _pairIndex) external view returns (uint256);
    function getTradeCumulVolPriceImpactP(address _trader, uint16 _pairIndex, bool _long, uint256 _tradeOpenInterestUsd, bool _isPnlPositive, bool _open, uint256 _lastPosIncreaseBlock) external view returns (int256 priceImpactP);
    function pairSpreadP(address _trader, uint256 _pairIndex) external view returns (uint256);
    function pairMinPositionSizeUsd(uint256 _pairIndex) external view returns (uint256);
    function pairMinFeeUsd(uint256 _pairIndex) external view returns (uint256);
    function pairTotalPositionSizeFeeP(uint256 _pairIndex) external view returns (uint256);
    function pairMaxLeverage(uint256 _pairIndex) external view returns (uint256);
    function getPairFlags(uint8 _collateralIndex, uint16 _pairIndex) external view returns (PairFlags memory);
    function getTradeFeeParams(uint8 _collateralIndex, uint16 _pairIndex) external view returns (GlobalTradeFeeParams memory);
    function calculateFeeAmount(address _trader, uint256 _normalFeeAmountCollateral) external view returns (uint256);
    function getUsdNormalizedValue(uint8 _collateralIndex, uint256 _collateralValue) external view returns (uint256);
    function getCollateralFromUsdNormalizedValue(uint8 _collateralIndex, uint256 _normalizedValue) external view returns (uint256);
    function getCollateral(uint8 _index) external view returns (Collateral memory);
    function getCollateralIndex(address _collateral) external view returns (uint8);
    function getTradingDelegate(address _trader) external view returns (address);
    function getMarketOrdersTimeoutBlocks() external view returns (uint16);
}

interface IArbSys {
    function arbBlockNumber() external view returns (uint256);
}

/// @title GTrade
/// @notice Constants and pure helpers for the gTrade v10 diamond (IGainsDiamond).
library GTrade {
    uint256 internal constant P_10 = 1e10; // price and percent precision
    uint256 internal constant LEVERAGE_PRECISION = 1e3;
    /// @dev Gains slippage is a percent with 1e3 precision (1% = 1000), so 1 bps = 10.
    uint256 internal constant SLIPPAGE_PER_BPS = 10;

    // ITradingStorage.TradeType
    uint8 internal constant TRADE = 0;
    uint8 internal constant LIMIT = 1;
    uint8 internal constant STOP = 2;

    // ITradingStorage.PendingOrderType (0 to 13; the SDK enum stops at 6, STAGE0.md B)
    uint8 internal constant MARKET_OPEN = 0;
    uint8 internal constant MARKET_CLOSE = 1;
    uint8 internal constant LIMIT_OPEN = 2;
    uint8 internal constant STOP_OPEN = 3;
    uint8 internal constant TP_CLOSE = 4;
    uint8 internal constant SL_CLOSE = 5;
    uint8 internal constant LIQ_CLOSE = 6;
    uint8 internal constant UPDATE_LEVERAGE = 7;
    uint8 internal constant MARKET_PARTIAL_OPEN = 8;
    uint8 internal constant MARKET_PARTIAL_CLOSE = 9;
    uint8 internal constant PNL_WITHDRAWAL = 11;

    // ITradingStorage.ContractsVersion
    uint8 internal constant V9_2 = 1;
    uint8 internal constant V10 = 2;

    /// @dev Arbitrum's ArbSys precompile: Gains counts the order timeout in L2 blocks (STAGE0.md A3).
    address internal constant ARB_SYS = address(100);

    /// @notice Position size in collateral units.
    function positionSize(uint256 collateral, uint256 leverage) internal pure returns (uint256) {
        return (collateral * leverage) / LEVERAGE_PRECISION;
    }

    /// @notice L2 block number as Gains reads it (ArbSys on Arbitrum One and Sepolia, block.number elsewhere).
    function l2BlockNumber() internal view returns (uint256) {
        if (block.chainid == 42161 || block.chainid == 421614) return IArbSys(ARB_SYS).arbBlockNumber();
        return block.number;
    }
}
