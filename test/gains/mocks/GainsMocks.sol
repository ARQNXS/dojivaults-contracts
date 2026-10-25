// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IGainsDiamond} from "../../../src/gains/IGainsDiamond.sol";

/// @notice Settable Chainlink aggregator (also the sequencer uptime feed: answer 0 = up, startedAt = status change).
contract MockChainlinkFeed {
    uint8 public decimals;
    int256 public answer;
    uint256 public startedAt;
    uint256 public updatedAt;
    uint80 public roundId = 1;
    bool public reverts;

    constructor(uint8 decimals_, int256 answer_) {
        decimals = decimals_;
        answer = answer_;
        startedAt = block.timestamp;
        updatedAt = block.timestamp;
    }

    function set(int256 answer_, uint256 updatedAt_) external {
        answer = answer_;
        updatedAt = updatedAt_;
        ++roundId;
    }

    /// @dev Sequencer feed: status and when it last changed.
    function setStatus(int256 answer_, uint256 startedAt_) external {
        answer = answer_;
        startedAt = startedAt_;
        updatedAt = startedAt_;
    }

    function setReverts(bool r) external {
        reverts = r;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        require(!reverts, "feed: down");
        return (roundId, answer, startedAt, updatedAt, roundId);
    }
}

/// @notice gTrade v10 stand-in for unit tests. Same ABI as IGainsDiamond; trading is request + fill like Gains, but
///         fills are driven by the test (`fill`, `cancelInCallback`, `trigger`, `executeLimit`), and the value math is
///         Gains' own close formula without price impact (spread / skew / cumulative volume are settable but default 0):
///         payout = collateral + pnl(price) - closing fee - holding fees + realized pnl, 0 past liquidation.
///         Liquidation price: -90% pnl. Collateral index 3 = the 6-decimal USDC passed in.
contract MockGainsDiamond {
    uint256 internal constant P_10 = 1e10;
    uint8 public constant USDC_INDEX = 3;
    uint128 internal constant PRECISION_DELTA = 1e12;

    IERC20 public immutable usdc;

    struct PairCfg {
        uint256 feeP; // pairTotalPositionSizeFeeP, 1e10 percent
        uint256 minPositionUsd; // 1e18
        uint256 minFeeUsd; // 1e18
        uint256 spreadP; // 1e10 percent
        uint256 maxLeverage; // 1e3
    }

    mapping(uint256 pair => PairCfg) public pairCfg;
    uint24 public govFeeP = 85_000; // 85% of the min fee / 2
    uint16 public timeoutBlocks = 200;

    mapping(address => mapping(uint32 => IGainsDiamond.Trade)) internal _trades;
    mapping(address => mapping(uint32 => IGainsDiamond.TradeInfo)) internal _infos;
    mapping(address => mapping(uint32 => int256)) public holding; // pending holding fees, collateral
    mapping(address => mapping(uint32 => uint256)) public realizedFees; // realizedTradingFeesCollateral
    mapping(address => mapping(uint32 => int256)) public realizedPnl; // realizedPnlCollateral
    mapping(address => uint32) public tradeCount;

    mapping(address => mapping(uint32 => IGainsDiamond.PendingOrder)) internal _orders;
    mapping(address => uint32) public orderCount;
    mapping(address => address) public delegate;

    /// @dev Total USDC paid to traders (payouts, refunds), for NAV vs payout checks.
    mapping(address => uint256) public paidTo;
    bool public rejectCalls;
    /// @dev A TP / SL / limit trigger in flight (filed under the bot, invisible to the trader): Gains then refuses
    ///      slippage updates and limit cancels for the trader's trades.
    bool public triggerInFlight;
    /// @dev Return closed trades and orders too (the vault must skip them; the real diamond lists open ones only).
    bool public includeClosed;

    event Filled(address indexed user, uint32 indexed orderIndex, uint8 orderType, uint256 paid);

    constructor(IERC20 usdc_) {
        usdc = usdc_;
        for (uint256 p; p < 64; ++p) {
            pairCfg[p] = PairCfg({feeP: 0, minPositionUsd: 285.7e18, minFeeUsd: 0.1e18, spreadP: 0, maxLeverage: 200_000});
        }
    }

    // ------------------------------------------------------------------ test admin
    function setPair(uint256 pair, uint256 feeP, uint256 minPositionUsd, uint256 minFeeUsd, uint256 spreadP) external {
        pairCfg[pair] = PairCfg(feeP, minPositionUsd, minFeeUsd, spreadP, pairCfg[pair].maxLeverage);
    }

    function setHolding(address user, uint32 index, int256 fees) external {
        holding[user][index] = fees;
    }

    function setTimeoutBlocks(uint16 b) external {
        timeoutBlocks = b;
    }

    function setRejectCalls(bool r) external {
        rejectCalls = r;
    }

    function setTriggerInFlight(bool b) external {
        triggerInFlight = b;
    }

    function setIncludeClosed(bool b) external {
        includeClosed = b;
    }

    function setContractsVersion(address user, uint32 index, uint8 v) external {
        _infos[user][index].contractsVersion = v;
    }

    /// @dev Rewrites a trade's size (tests that need a given vault leverage without going through checkOrder).
    function setTradeSize(address user, uint32 index, uint24 leverage, uint64 price) external {
        IGainsDiamond.Trade storage t = _trades[user][index];
        t.leverage = leverage;
        t.positionSizeToken = uint160(_sizeToken(t.collateralAmount, leverage, price));
    }

    // ------------------------------------------------------------------ calls (trader = msg.sender)
    function openTrade(IGainsDiamond.Trade calldata t, uint16 maxSlippageP, address) external {
        _live();
        require(t.user == msg.sender, "mock: user");
        require(t.collateralIndex == USDC_INDEX, "mock: collateral");
        require(t.collateralAmount >= 5 * pairCfg[t.pairIndex].minFeeUsd / PRECISION_DELTA, "InsufficientCollateral");
        require(t.leverage > 0 && t.leverage <= pairCfg[t.pairIndex].maxLeverage, "WrongLeverage");
        usdc.transferFrom(msg.sender, address(this), t.collateralAmount);
        if (t.tradeType == 0) {
            IGainsDiamond.PendingOrder storage o = _newOrder(msg.sender, 0, t);
            o.maxSlippageP = maxSlippageP;
        } else {
            uint32 idx = tradeCount[msg.sender]++;
            IGainsDiamond.Trade storage s = _trades[msg.sender][idx];
            s.user = msg.sender;
            s.index = idx;
            s.pairIndex = t.pairIndex;
            s.leverage = t.leverage;
            s.long = t.long;
            s.isOpen = true;
            s.collateralIndex = t.collateralIndex;
            s.tradeType = t.tradeType;
            s.collateralAmount = t.collateralAmount;
            s.openPrice = t.openPrice;
            s.tp = t.tp;
            s.sl = t.sl;
            _infos[msg.sender][idx].maxSlippageP = maxSlippageP;
        }
    }

    function closeTradeMarket(uint32 index, uint64 expectedPrice) external {
        require(expectedPrice != 0, "ZeroValue");
        IGainsDiamond.Trade memory t = _open(msg.sender, index);
        _noPending(msg.sender, index);
        IGainsDiamond.Trade memory p;
        p.user = msg.sender;
        p.index = index;
        p.pairIndex = t.pairIndex;
        p.openPrice = expectedPrice;
        _newOrder(msg.sender, 1, p);
    }

    function decreasePositionSize(uint32 index, uint120 collateralDelta, uint24 leverageDelta, uint64 expectedPrice) external {
        require(expectedPrice != 0, "ZeroValue");
        require(leverageDelta == 0 && collateralDelta > 0, "mock: collateral decreases only");
        IGainsDiamond.Trade memory t = _open(msg.sender, index);
        require(collateralDelta < t.collateralAmount, "mock: use close");
        _noPending(msg.sender, index);
        IGainsDiamond.Trade memory p;
        p.user = msg.sender;
        p.index = index;
        p.pairIndex = t.pairIndex;
        p.collateralAmount = collateralDelta;
        p.openPrice = expectedPrice;
        _newOrder(msg.sender, 9, p);
    }

    function increasePositionSize(uint32 index, uint120 collateralDelta, uint24 leverageDelta, uint64 expectedPrice, uint16)
        external
    {
        _live();
        IGainsDiamond.Trade memory t = _open(msg.sender, index);
        _noPending(msg.sender, index);
        if (collateralDelta > 0) usdc.transferFrom(msg.sender, address(this), collateralDelta);
        IGainsDiamond.Trade memory p;
        p.user = msg.sender;
        p.index = index;
        p.pairIndex = t.pairIndex;
        p.collateralAmount = collateralDelta;
        p.leverage = leverageDelta;
        p.openPrice = expectedPrice;
        _newOrder(msg.sender, 8, p);
    }

    function updateLeverage(uint32 index, uint24 newLeverage) external {
        _live();
        IGainsDiamond.Trade memory t = _open(msg.sender, index);
        _noPending(msg.sender, index);
        require(newLeverage != t.leverage && newLeverage > 0, "WrongLeverage");
        uint256 newColl = (uint256(t.collateralAmount) * t.leverage) / newLeverage;
        uint256 delta = newLeverage < t.leverage ? newColl - t.collateralAmount : t.collateralAmount - newColl;
        if (newLeverage < t.leverage) usdc.transferFrom(msg.sender, address(this), delta);
        IGainsDiamond.Trade memory p;
        p.user = msg.sender;
        p.index = index;
        p.pairIndex = t.pairIndex;
        p.leverage = newLeverage;
        p.collateralAmount = uint120(delta);
        _newOrder(msg.sender, 7, p);
    }

    function updateSl(uint32 index, uint64 sl) external {
        _open(msg.sender, index);
        _trades[msg.sender][index].sl = sl;
    }

    function updateTp(uint32 index, uint64 tp) external {
        _open(msg.sender, index);
        _trades[msg.sender][index].tp = tp;
    }

    function updateMaxClosingSlippageP(uint32 index, uint16 slippageP) external {
        require(!triggerInFlight, "PendingTrigger");
        IGainsDiamond.Trade memory t = _open(msg.sender, index);
        require(t.tradeType == 0, "WrongTradeType");
        require(slippageP != 0, "MaxSlippageZero");
        _infos[msg.sender][index].maxSlippageP = slippageP;
    }

    function cancelOpenOrder(uint32 index) external {
        require(!triggerInFlight, "PendingTrigger");
        IGainsDiamond.Trade storage t = _trades[msg.sender][index];
        require(t.isOpen && t.tradeType != 0, "mock: no limit order");
        t.isOpen = false;
        _pay(msg.sender, t.collateralAmount);
    }

    function cancelOrderAfterTimeout(uint32 orderIndex) external {
        IGainsDiamond.PendingOrder storage o = _orders[msg.sender][orderIndex];
        require(o.isOpen, "NoOrder");
        require(block.number >= uint256(o.createdBlock) + timeoutBlocks, "WaitTimeout");
        o.isOpen = false;
        if (o.orderType == 0 || o.orderType == 8 || (o.orderType == 7 && o.trade.leverage < _trades[msg.sender][o.trade.index].leverage)) {
            _pay(msg.sender, o.trade.collateralAmount);
        }
    }

    // ------------------------------------------------------------------ fills (the test plays the oracle)
    /// @notice Fills a pending market order at `price` (oracle price, 1e10).
    function fill(address user, uint32 orderIndex, uint64 price) external returns (uint32 tradeIndex, uint256 paid) {
        IGainsDiamond.PendingOrder storage o = _orders[user][orderIndex];
        require(o.isOpen, "mock: no order");
        o.isOpen = false;
        uint8 ot = o.orderType;
        if (ot == 0) {
            tradeIndex = _storeTrade(user, o.trade, price, o.maxSlippageP);
        } else if (ot == 1) {
            tradeIndex = o.trade.index;
            paid = _close(user, tradeIndex, price);
        } else if (ot == 9) {
            tradeIndex = o.trade.index;
            paid = _partialClose(user, tradeIndex, o.trade.collateralAmount, price);
        } else if (ot == 8) {
            tradeIndex = o.trade.index;
            _increase(user, tradeIndex, o.trade.collateralAmount, o.trade.leverage, price);
        } else if (ot == 7) {
            tradeIndex = o.trade.index;
            IGainsDiamond.Trade storage t = _trades[user][tradeIndex];
            if (o.trade.leverage > t.leverage) {
                t.collateralAmount -= o.trade.collateralAmount;
                paid = o.trade.collateralAmount;
                _pay(user, paid);
            } else {
                t.collateralAmount += o.trade.collateralAmount;
            }
            t.leverage = o.trade.leverage;
        }
        emit Filled(user, orderIndex, ot, paid);
    }

    /// @notice The callback cancels a pending order (slippage, exposure): an open returns collateral minus the gov fee.
    function cancelInCallback(address user, uint32 orderIndex) external returns (uint256 returned) {
        IGainsDiamond.PendingOrder storage o = _orders[user][orderIndex];
        require(o.isOpen, "mock: no order");
        o.isOpen = false;
        if (o.orderType == 0 || o.orderType == 8 || (o.orderType == 7 && o.trade.leverage < _trades[user][o.trade.index].leverage)) {
            uint256 gov = minGovFee(o.trade.pairIndex);
            returned = o.trade.collateralAmount > gov ? o.trade.collateralAmount - gov : 0;
            _pay(user, returned);
        }
    }

    /// @notice TP / SL / liquidation executed by Gains at `price`.
    function trigger(address user, uint32 index, uint64 price) external returns (uint256 paid) {
        _open(user, index);
        paid = _close(user, index, price);
    }

    /// @notice A resting limit / stop order triggers and opens at `price`.
    function executeLimit(address user, uint32 index, uint64 price) external {
        IGainsDiamond.Trade storage t = _trades[user][index];
        require(t.isOpen && t.tradeType != 0, "mock: no limit order");
        t.tradeType = 0;
        _fillOpen(user, index, price);
    }

    // ------------------------------------------------------------------ reads
    function getTrades(address user) external view returns (IGainsDiamond.Trade[] memory out) {
        uint32 n = tradeCount[user];
        uint256 k;
        for (uint32 i; i < n; ++i) {
            if (_trades[user][i].isOpen || includeClosed) ++k;
        }
        out = new IGainsDiamond.Trade[](k);
        k = 0;
        for (uint32 i; i < n; ++i) {
            if (_trades[user][i].isOpen || includeClosed) out[k++] = _trades[user][i];
        }
    }

    function getTrade(address user, uint32 index) external view returns (IGainsDiamond.Trade memory) {
        return _trades[user][index];
    }

    function getTradeInfo(address user, uint32 index) external view returns (IGainsDiamond.TradeInfo memory) {
        return _infos[user][index];
    }

    function getPendingOrders(address user) external view returns (IGainsDiamond.PendingOrder[] memory out) {
        uint32 n = orderCount[user];
        uint256 k;
        for (uint32 i; i < n; ++i) {
            if (_orders[user][i].isOpen || includeClosed) ++k;
        }
        out = new IGainsDiamond.PendingOrder[](k);
        k = 0;
        for (uint32 i; i < n; ++i) {
            if (_orders[user][i].isOpen || includeClosed) out[k++] = _orders[user][i];
        }
    }

    function getPendingOrder(address user, uint32 index) external view returns (IGainsDiamond.PendingOrder memory) {
        return _orders[user][index];
    }

    /// @dev GR2-LIVE-01: Gains' getPendingOrder(Id) and getCounters (currentIndex = next index; openCount unused)
    function getPendingOrder(IGainsDiamond.Id calldata id) external view returns (IGainsDiamond.PendingOrder memory) {
        return _orders[id.user][id.index];
    }

    function getCounters(address user, uint8 kind) external view returns (IGainsDiamond.Counter memory c) {
        c.currentIndex = kind == 0 ? tradeCount[user] : orderCount[user];
    }

    function getTradeLiquidationParams(address, uint32) external pure returns (IGainsDiamond.GroupLiquidationParams memory p) {
        return p;
    }

    function getTradePendingHoldingFeesCollateral(address user, uint32 index, uint64)
        external
        view
        returns (IGainsDiamond.TradeHoldingFees memory h)
    {
        h.totalFeeCollateral = holding[user][index];
    }

    function getTradeRealizedPnlCollateral(address user, uint32 index) public view returns (int256, uint256, int256) {
        int256 pnl = realizedPnl[user][index];
        uint256 fees = realizedFees[user][index];
        return (pnl, fees, pnl - int256(fees));
    }

    /// @dev -90% pnl: long open x (1 - 0.9 / leverage), short open x (1 + 0.9 / leverage).
    function getTradeLiquidationPrice(IGainsDiamond.LiqPriceInput calldata i) external pure returns (uint256) {
        return _liqPrice(i.openPrice, i.long, i.leverage);
    }

    function _liqPrice(uint64 openPrice, bool long, uint256 leverage) internal pure returns (uint256) {
        uint256 dist = (uint256(openPrice) * 90 * 1e3) / (100 * leverage);
        if (long) return dist >= openPrice ? 0 : openPrice - dist;
        return uint256(openPrice) + dist;
    }

    function getTradeSkewPriceImpactP(uint8, uint16, bool, uint256, bool) external pure returns (int256) {
        return 0;
    }

    /// @dev GR2-KEY-01: 1 % skew depth in tokens; unset = a depth no test reaches (the vault's per-pair cap never binds).
    mapping(uint16 pair => uint256) public skewDepth;

    function setSkewDepth(uint16 pair, uint256 depth) external {
        skewDepth[pair] = depth;
    }

    function getPairSkewDepth(uint8, uint16 pair) external view returns (uint256) {
        uint256 d = skewDepth[pair];
        return d == 0 ? 1e36 : d;
    }

    /// @dev GR2 XF-04: Gains' open interest cap of the pair (collateral precision); 0 = none set (the default).
    mapping(uint16 => uint256) public pairMaxOi;

    function setPairMaxOi(uint16 pair, uint256 maxOi) external {
        pairMaxOi[pair] = maxOi;
    }

    function getPairMaxOiCollateral(uint8, uint16 pair) external view returns (uint256) {
        return pairMaxOi[pair];
    }

    function getTradeCumulVolPriceImpactP(address, uint16, bool, uint256, bool, bool, uint256) external pure returns (int256) {
        return 0;
    }

    function pairSpreadP(address, uint256 pair) external view returns (uint256) {
        return pairCfg[pair].spreadP;
    }

    function pairMinPositionSizeUsd(uint256 pair) external view returns (uint256) {
        return pairCfg[pair].minPositionUsd;
    }

    function pairMinFeeUsd(uint256 pair) external view returns (uint256) {
        return pairCfg[pair].minFeeUsd;
    }

    function pairTotalPositionSizeFeeP(uint256 pair) external view returns (uint256) {
        return pairCfg[pair].feeP;
    }

    function pairMaxLeverage(uint256 pair) external view returns (uint256) {
        return pairCfg[pair].maxLeverage;
    }

    function getPairFlags(uint8, uint16) external pure returns (IGainsDiamond.PairFlags memory f) {
        f.skipFeeTierMultiplier = true;
    }

    function getTradeFeeParams(uint8, uint16) external view returns (IGainsDiamond.GlobalTradeFeeParams memory p) {
        p.govFeeP = govFeeP;
    }

    function calculateFeeAmount(address, uint256 amount) external pure returns (uint256) {
        return amount;
    }

    function getUsdNormalizedValue(uint8, uint256 v) external pure returns (uint256) {
        return v * PRECISION_DELTA;
    }

    function getCollateralFromUsdNormalizedValue(uint8, uint256 v) public pure returns (uint256) {
        return v / PRECISION_DELTA;
    }

    function getCollateral(uint8 index) external view returns (IGainsDiamond.Collateral memory c) {
        if (index != USDC_INDEX) return c;
        c.collateral = address(usdc);
        c.isActive = true;
        c.precision = 1e6;
        c.precisionDelta = PRECISION_DELTA;
    }

    function getCollateralIndex(address collateral) external view returns (uint8) {
        return collateral == address(usdc) ? USDC_INDEX : 0;
    }

    function getTradingDelegate(address trader) external view returns (address) {
        return delegate[trader];
    }

    function getMarketOrdersTimeoutBlocks() external view returns (uint16) {
        return timeoutBlocks;
    }

    // ------------------------------------------------------------------ value math (Gains close path, no impact)
    function feeOf(uint256 pair, uint256 size) public view returns (uint256) {
        uint256 minSize = getCollateralFromUsdNormalizedValue(USDC_INDEX, pairCfg[pair].minPositionUsd);
        uint256 basis = size < minSize ? minSize : size;
        return (basis * pairCfg[pair].feeP) / P_10 / 100;
    }

    function minGovFee(uint256 pair) public view returns (uint256) {
        return ((feeOf(pair, 0) / 2) * govFeeP) / 1e3 / 100;
    }

    /// @notice What a full close of `index` at `price` pays (0 past liquidation).
    function closeValue(address user, uint32 index, uint64 price) public view returns (uint256) {
        IGainsDiamond.Trade memory t = _trades[user][index];
        if (_liquidated(t, price)) return 0;
        uint256 size = (uint256(t.collateralAmount) * t.leverage) / 1e3;
        (,, int256 realized) = getTradeRealizedPnlCollateral(user, index);
        return _value(t.collateralAmount, _pnlP(t, _closePrice(t, price)), int256(feeOf(t.pairIndex, size)) + holding[user][index] - realized);
    }

    function _closePrice(IGainsDiamond.Trade memory t, uint64 price) internal view returns (uint64) {
        int256 spread = int256(pairCfg[t.pairIndex].spreadP / 2) * (t.long ? int256(-1) : int256(1));
        return uint64(uint256(int256(uint256(price)) + (int256(uint256(price)) * spread) / int256(P_10) / 100));
    }

    function _liquidated(IGainsDiamond.Trade memory t, uint64 price) internal pure returns (bool) {
        uint256 liq = _liqPrice(t.openPrice, t.long, t.leverage);
        return t.long ? price <= liq : price >= liq;
    }

    function _pnlP(IGainsDiamond.Trade memory t, uint64 price) internal pure returns (int256 p) {
        int256 o = int256(uint256(t.openPrice));
        int256 c = int256(uint256(price));
        p = ((t.long ? c - o : o - c) * 100 * int256(P_10) * int256(uint256(t.leverage))) / o / 1e3;
        if (p < -100 * int256(P_10)) p = -100 * int256(P_10);
    }

    function _value(uint256 collateral, int256 pnlP, int256 fees) internal pure returns (uint256) {
        int256 pd = int256(uint256(PRECISION_DELTA));
        int256 v = (int256(collateral) * pd + (int256(collateral) * pd * pnlP) / int256(P_10) / 100) / pd - fees;
        return v > 0 ? uint256(v) : 0;
    }

    // ------------------------------------------------------------------ internal
    function _live() internal view {
        require(!rejectCalls, "mock: trading paused");
    }

    function _open(address user, uint32 index) internal view returns (IGainsDiamond.Trade memory t) {
        t = _trades[user][index];
        require(t.isOpen, "DoesntExist");
    }

    function _noPending(address user, uint32 index) internal view {
        uint32 n = orderCount[user];
        for (uint32 i; i < n; ++i) {
            IGainsDiamond.PendingOrder storage o = _orders[user][i];
            require(!(o.isOpen && o.orderType != 0 && o.trade.index == index), "PendingMarketOrder");
        }
    }

    function _newOrder(address user, uint8 orderType, IGainsDiamond.Trade memory t)
        internal
        returns (IGainsDiamond.PendingOrder storage o)
    {
        uint32 idx = orderCount[user]++;
        o = _orders[user][idx];
        o.trade = t;
        o.user = user;
        o.index = idx;
        o.isOpen = true;
        o.orderType = orderType;
        o.createdBlock = uint32(block.number);
    }

    function _sizeToken(uint256 collateral, uint256 leverage, uint64 price) internal pure returns (uint256) {
        // size (USDC 1e6) -> USD 1e18 -> tokens 1e18 at price 1e10
        return ((collateral * leverage) / 1e3) * PRECISION_DELTA * P_10 / price;
    }

    function _storeTrade(address user, IGainsDiamond.Trade memory p, uint64 price, uint16 slippage) internal returns (uint32 idx) {
        idx = tradeCount[user]++;
        IGainsDiamond.Trade storage t = _trades[user][idx];
        t.user = user;
        t.index = idx;
        t.pairIndex = p.pairIndex;
        t.leverage = p.leverage;
        t.long = p.long;
        t.isOpen = true;
        t.collateralIndex = p.collateralIndex;
        t.collateralAmount = p.collateralAmount;
        t.tp = p.tp;
        t.sl = p.sl;
        _infos[user][idx].maxSlippageP = slippage;
        _fillOpen(user, idx, price);
    }

    function _fillOpen(address user, uint32 idx, uint64 price) internal {
        IGainsDiamond.Trade storage t = _trades[user][idx];
        t.openPrice = price;
        t.positionSizeToken = uint160(_sizeToken(t.collateralAmount, t.leverage, price));
        IGainsDiamond.TradeInfo storage i = _infos[user][idx];
        i.createdBlock = uint32(block.number);
        i.contractsVersion = 2;
        i.lastPosIncreaseBlock = uint32(block.number);
        // The opening fee is not taken from the collateral: it is booked as realized and settles at close.
        realizedFees[user][idx] = feeOf(t.pairIndex, (uint256(t.collateralAmount) * t.leverage) / 1e3);
    }

    function _close(address user, uint32 index, uint64 price) internal returns (uint256 paid) {
        paid = closeValue(user, index, price);
        _trades[user][index].isOpen = false;
        _pay(user, paid);
    }

    function _partialClose(address user, uint32 index, uint120 delta, uint64 price) internal returns (uint256 paid) {
        IGainsDiamond.Trade storage t = _trades[user][index];
        uint256 coll = t.collateralAmount;
        (,, int256 realized) = getTradeRealizedPnlCollateral(user, index);
        int256 pnlP = _pnlP(t, _closePrice(t, price));
        int256 valueNoFee = int256(_value(coll, pnlP, holding[user][index] - realized));
        int256 net = ((valueNoFee - int256(coll)) * int256(uint256(delta))) / int256(coll);
        int256 v = int256(uint256(delta)) + net - int256(feeOf(t.pairIndex, (uint256(delta) * t.leverage) / 1e3));
        paid = v > 0 ? uint256(v) : 0;
        uint256 rest = coll - delta;
        t.positionSizeToken = uint160((uint256(t.positionSizeToken) * rest) / coll);
        t.collateralAmount = uint120(rest);
        holding[user][index] = (holding[user][index] * int256(rest)) / int256(coll);
        realizedPnl[user][index] = (realizedPnl[user][index] * int256(rest)) / int256(coll);
        realizedFees[user][index] = (realizedFees[user][index] * rest) / coll;
        _pay(user, paid);
    }

    function _increase(address user, uint32 index, uint120 cd, uint24 ld, uint64 price) internal {
        IGainsDiamond.Trade storage t = _trades[user][index];
        uint256 addSize = ((cd == 0 ? uint256(t.collateralAmount) : cd) * ld) / 1e3;
        uint256 size = (uint256(t.collateralAmount) * t.leverage) / 1e3 + addSize;
        uint256 coll = uint256(t.collateralAmount) + cd;
        t.positionSizeToken += uint160(addSize * PRECISION_DELTA * P_10 / price);
        t.collateralAmount = uint120(coll);
        t.leverage = uint24((size * 1e3) / coll);
        t.openPrice = uint64((size * PRECISION_DELTA * P_10) / t.positionSizeToken);
        realizedFees[user][index] += feeOf(t.pairIndex, addSize);
    }

    function _pay(address user, uint256 amount) internal {
        if (amount == 0) return;
        paidTo[user] += amount;
        usdc.transfer(user, amount);
    }
}
