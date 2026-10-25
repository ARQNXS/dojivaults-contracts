// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IGainsDiamond} from "../../../src/gains/IGainsDiamond.sol";

/// @notice WP5 (fix round): test/audit/gains/r2/ConservationMocks.sol CIDiamond, byte for byte except
///         getPairSkewDepth, which reads a per-pair depth the test sets (default: unbounded, as CIDiamond), so the
///         vault's 1 % pair cap (GR2-KEY-01b) binds in the stolen-agent campaign, and the liquidation price, which
///         carries the trade's fees and holding balance as gTrade v10 does (_liqPrice). Same ABI (the hl-r2 CI handler
///         and valuer use it through a CIDiamond cast).
/// @notice gTrade v10 stand-in for the conservation suite. A copy of test/gains/mocks/GainsMocks.sol MockGainsDiamond
///         (same ABI, same value math: Gains' close formula without price impact, -90% liquidation), extended so the
///         test can play every venue outcome and so the venue keeps its own ledger of the trader's collateral:
///  - `escrowLedger[user]`: collateral the diamond holds for the trader (in on request, out when released);
///    `escrowOf(user)` recomputes it from the open trades and orders; the two must agree;
///  - `released[user]` / `paid[user]`: collateral released and USDC paid back per trader; P&L = paid - released;
///  - `govKept[user]`: gov fees kept by callback cancels;
///  - an order's REPORTED type can be overridden (`retype`), e.g. a market open reported as type 10, 11, 12, 13 or
///    200 (GV-02); the mock keeps resolving it by its real type;
///  - Gains' own trigger executions (LIMIT_OPEN, STOP_OPEN, TP_CLOSE, SL_CLOSE, LIQ_CLOSE) can be filed as pending
///    orders that hold nothing and resolved later (`fileTrigger`, `resolveTrigger`);
///  - gov fee, pair fees, spread and holding fees are settable;
///  - fills and closes on a trade that is no longer open are cancelled (the original mock would pay twice).
contract WP5Diamond {
    uint256 internal constant P_10 = 1e10;
    uint8 public constant USDC_INDEX = 3;
    uint128 internal constant PRECISION_DELTA = 1e12;

    IERC20 public immutable usdc;

    struct PairCfg {
        uint256 feeP;
        uint256 minPositionUsd;
        uint256 minFeeUsd;
        uint256 spreadP;
        uint256 maxLeverage;
    }

    mapping(uint256 pair => PairCfg) public pairCfg;
    uint24 public govFeeP = 85_000;
    uint16 public timeoutBlocks = 200;

    mapping(address => mapping(uint32 => IGainsDiamond.Trade)) internal _trades;
    mapping(address => mapping(uint32 => IGainsDiamond.TradeInfo)) internal _infos;
    mapping(address => mapping(uint32 => int256)) public holding;
    mapping(address => mapping(uint32 => uint256)) public realizedFees;
    mapping(address => mapping(uint32 => int256)) public realizedPnl;
    mapping(address => uint32) public tradeCount;

    mapping(address => mapping(uint32 => IGainsDiamond.PendingOrder)) internal _orders;
    mapping(address => uint32) public orderCount;
    mapping(address => mapping(uint32 => uint8)) public reportedType;
    mapping(address => mapping(uint32 => bool)) public retyped;

    // venue ledger
    mapping(address => uint256) public escrowLedger;
    mapping(address => uint256) public released;
    mapping(address => uint256) public paid;
    mapping(address => uint256) public govKept;
    mapping(address => uint256) public pulled;

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

    function setGovFeeP(uint24 g) external {
        govFeeP = g;
    }

    function setHolding(address user, uint32 index, int256 fees) external {
        holding[user][index] = fees;
    }

    function setTimeoutBlocks(uint16 b) external {
        timeoutBlocks = b;
    }

    /// @notice Gains reports open order `orderIndex` with type `t` (the mock still resolves it by its real type).
    function retype(address user, uint32 orderIndex, uint8 t) external {
        require(_orders[user][orderIndex].isOpen, "mock: no order");
        reportedType[user][orderIndex] = t;
        retyped[user][orderIndex] = true;
    }

    function restoreType(address user, uint32 orderIndex) external {
        retyped[user][orderIndex] = false;
    }

    /// @notice A Gains trigger execution (2 LIMIT_OPEN, 3 STOP_OPEN, 4 TP_CLOSE, 5 SL_CLOSE, 6 LIQ_CLOSE) in flight
    ///         for trade `index`: holds nothing, listed among the trader's pending orders.
    function fileTrigger(address user, uint32 index, uint8 t) external returns (uint32 orderIndex) {
        require(t >= 2 && t <= 6, "mock: trigger type");
        IGainsDiamond.Trade memory tr = _open(user, index);
        if (t == 2 || t == 3) require(tr.tradeType != 0, "mock: not resting");
        else require(tr.tradeType == 0, "mock: not a trade");
        _noPending(user, index);
        IGainsDiamond.Trade memory p;
        p.user = user;
        p.index = index;
        p.pairIndex = tr.pairIndex;
        orderIndex = orderCount[user];
        _newOrder(user, t, p);
    }

    /// @notice Resolves a trigger order at `price`: executes it (open the resting order, or close the trade), or
    ///         drops it when `execute` is false (Gains' bot found the condition no longer met).
    function resolveTrigger(address user, uint32 orderIndex, uint64 price, bool execute) external returns (uint256 out) {
        IGainsDiamond.PendingOrder storage o = _orders[user][orderIndex];
        require(o.isOpen && o.orderType >= 2 && o.orderType <= 6, "mock: no trigger");
        o.isOpen = false;
        uint32 idx = o.trade.index;
        IGainsDiamond.Trade storage t = _trades[user][idx];
        if (!execute || !t.isOpen) return 0;
        if (o.orderType == 2 || o.orderType == 3) {
            if (t.tradeType == 0) return 0;
            t.tradeType = 0;
            _fillOpen(user, idx, price);
        } else {
            if (t.tradeType != 0) return 0;
            out = _close(user, idx, price);
        }
    }

    // ------------------------------------------------------------------ calls (trader = msg.sender)
    function openTrade(IGainsDiamond.Trade calldata t, uint16 maxSlippageP, address) external {
        require(t.user == msg.sender, "mock: user");
        require(t.collateralIndex == USDC_INDEX, "mock: collateral");
        require(t.collateralAmount >= 5 * pairCfg[t.pairIndex].minFeeUsd / PRECISION_DELTA, "InsufficientCollateral");
        require(t.leverage > 0 && t.leverage <= pairCfg[t.pairIndex].maxLeverage, "WrongLeverage");
        _pull(msg.sender, t.collateralAmount);
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
        require(t.tradeType == 0, "WrongTradeType");
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
        require(t.tradeType == 0, "WrongTradeType");
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
        IGainsDiamond.Trade memory t = _open(msg.sender, index);
        require(t.tradeType == 0, "WrongTradeType");
        _noPending(msg.sender, index);
        if (collateralDelta > 0) _pull(msg.sender, collateralDelta);
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
        IGainsDiamond.Trade memory t = _open(msg.sender, index);
        require(t.tradeType == 0, "WrongTradeType");
        _noPending(msg.sender, index);
        require(newLeverage != t.leverage && newLeverage > 0, "WrongLeverage");
        uint256 newColl = (uint256(t.collateralAmount) * t.leverage) / newLeverage;
        uint256 delta = newLeverage < t.leverage ? newColl - t.collateralAmount : t.collateralAmount - newColl;
        if (newLeverage < t.leverage) _pull(msg.sender, delta);
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
        IGainsDiamond.Trade memory t = _open(msg.sender, index);
        require(t.tradeType == 0, "WrongTradeType");
        require(slippageP != 0, "MaxSlippageZero");
        _infos[msg.sender][index].maxSlippageP = slippageP;
    }

    function cancelOpenOrder(uint32 index) external {
        IGainsDiamond.Trade storage t = _trades[msg.sender][index];
        require(t.isOpen && t.tradeType != 0, "mock: no limit order");
        _noPending(msg.sender, index);
        t.isOpen = false;
        _release(msg.sender, t.collateralAmount);
        _pay(msg.sender, t.collateralAmount);
    }

    function cancelOrderAfterTimeout(uint32 orderIndex) external {
        IGainsDiamond.PendingOrder storage o = _orders[msg.sender][orderIndex];
        require(o.isOpen, "NoOrder");
        require(o.orderType < 2 || o.orderType > 6, "mock: trigger");
        require(block.number >= uint256(o.createdBlock) + timeoutBlocks, "WaitTimeout");
        uint256 held = _held(msg.sender, o);
        o.isOpen = false;
        _release(msg.sender, held);
        _pay(msg.sender, held);
    }

    // ------------------------------------------------------------------ fills (the test plays the oracle)
    /// @notice Fills a pending market order at `price`. An order on a trade that is no longer open is cancelled
    ///         (its collateral, if any, returned in full).
    function fill(address user, uint32 orderIndex, uint64 price) external returns (uint32 tradeIndex, uint256 out) {
        IGainsDiamond.PendingOrder storage o = _orders[user][orderIndex];
        require(o.isOpen, "mock: no order");
        uint8 ot = o.orderType;
        require(ot < 2 || ot > 6, "mock: trigger");
        if (ot != 0 && !_trades[user][o.trade.index].isOpen) {
            uint256 held = _held(user, o);
            o.isOpen = false;
            _release(user, held);
            _pay(user, held);
            return (o.trade.index, held);
        }
        o.isOpen = false;
        if (ot == 0) {
            tradeIndex = _storeTrade(user, o.trade, price, o.maxSlippageP);
        } else if (ot == 1) {
            tradeIndex = o.trade.index;
            out = _close(user, tradeIndex, price);
        } else if (ot == 9) {
            tradeIndex = o.trade.index;
            IGainsDiamond.Trade storage t9 = _trades[user][tradeIndex];
            if (o.trade.collateralAmount >= t9.collateralAmount) out = _close(user, tradeIndex, price);
            else out = _partialClose(user, tradeIndex, o.trade.collateralAmount, price);
        } else if (ot == 8) {
            tradeIndex = o.trade.index;
            _increase(user, tradeIndex, o.trade.collateralAmount, o.trade.leverage, price);
        } else if (ot == 7) {
            tradeIndex = o.trade.index;
            IGainsDiamond.Trade storage t = _trades[user][tradeIndex];
            if (o.trade.leverage > t.leverage) {
                uint256 back = o.trade.collateralAmount < t.collateralAmount ? o.trade.collateralAmount : 0;
                t.collateralAmount -= uint120(back);
                _release(user, back);
                out = back;
                _pay(user, back);
            } else {
                t.collateralAmount += o.trade.collateralAmount;
            }
            t.leverage = o.trade.leverage;
        }
    }

    /// @notice The callback cancels a pending order: what it holds comes back minus the gov fee.
    function cancelInCallback(address user, uint32 orderIndex) external returns (uint256 returned) {
        IGainsDiamond.PendingOrder storage o = _orders[user][orderIndex];
        require(o.isOpen, "mock: no order");
        require(o.orderType < 2 || o.orderType > 6, "mock: trigger");
        uint256 held = _held(user, o);
        o.isOpen = false;
        if (held > 0) {
            uint16 pair = o.orderType == 0 ? o.trade.pairIndex : _trades[user][o.trade.index].pairIndex;
            uint256 gov = minGovFee(pair);
            returned = held > gov ? held - gov : 0;
            govKept[user] += held - returned;
            _release(user, held);
            _pay(user, returned);
        }
    }

    /// @notice TP / SL / liquidation executed by Gains at `price` (no pending order listed).
    function trigger(address user, uint32 index, uint64 price) external returns (uint256 out) {
        IGainsDiamond.Trade memory t = _open(user, index);
        require(t.tradeType == 0, "mock: not a trade");
        out = _close(user, index, price);
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
            if (_trades[user][i].isOpen) ++k;
        }
        out = new IGainsDiamond.Trade[](k);
        k = 0;
        for (uint32 i; i < n; ++i) {
            if (_trades[user][i].isOpen) out[k++] = _trades[user][i];
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
            if (_orders[user][i].isOpen) ++k;
        }
        out = new IGainsDiamond.PendingOrder[](k);
        k = 0;
        for (uint32 i; i < n; ++i) {
            if (_orders[user][i].isOpen) {
                out[k] = _orders[user][i];
                if (retyped[user][i]) out[k].orderType = reportedType[user][i];
                ++k;
            }
        }
    }

    /// @notice The order as the mock resolves it (real type), for the test's own ledger.
    function getRealOrder(address user, uint32 index) external view returns (IGainsDiamond.PendingOrder memory) {
        return _orders[user][index];
    }

    function getPendingOrder(address user, uint32 index) external view returns (IGainsDiamond.PendingOrder memory o) {
        o = _orders[user][index];
        if (retyped[user][index]) o.orderType = reportedType[user][index];
    }

    /// @dev GR2-LIVE-01: Gains' getPendingOrder(Id) (reported type, as above) and getCounters (currentIndex = next index).
    function getPendingOrder(IGainsDiamond.Id calldata id) external view returns (IGainsDiamond.PendingOrder memory o) {
        o = _orders[id.user][id.index];
        if (retyped[id.user][id.index]) o.orderType = reportedType[id.user][id.index];
    }

    function getCounters(address user, uint8 kind) external view returns (IGainsDiamond.Counter memory c) {
        c.currentIndex = kind == 0 ? tradeCount[user] : orderCount[user];
    }

    /// @dev GR2-KEY-01 / XF-04: skew depth effectively unbounded and no pair open-interest cap, so the pair cap never
    ///      binds in the conservation world (its subject is the vault's accounting, not exposure limits).
    function getPairSkewDepth(uint8, uint16 pair) external view returns (uint256) {
        uint256 d = skewDepth[pair];
        return d == 0 ? 1e36 : d;
    }

    /// @dev WP5: a finite skew depth (tokens, 1e18) for a pair, so the vault's 1 % pair cap binds.
    mapping(uint16 => uint256) public skewDepth;

    function setSkewDepth(uint16 pair, uint256 depth) external {
        skewDepth[pair] = depth;
    }

    function getPairMaxOiCollateral(uint8, uint16) external pure returns (uint256) {
        return 0;
    }

    /// @notice Collateral the diamond holds for `user`, recomputed from its open trades, resting orders and pending
    ///         orders (by real type). Must equal escrowLedger[user].
    function escrowOf(address user) external view returns (uint256 e) {
        uint32 n = tradeCount[user];
        for (uint32 i; i < n; ++i) {
            if (_trades[user][i].isOpen) e += _trades[user][i].collateralAmount;
        }
        n = orderCount[user];
        for (uint32 i; i < n; ++i) {
            if (_orders[user][i].isOpen) e += _held(user, _orders[user][i]);
        }
    }

    /// @notice What pending order `i` holds (by real type): market open, partial open with collateral, leverage
    ///         decrease; nothing for closes, leverage increases and triggers.
    function heldBy(address user, uint32 i) external view returns (uint256) {
        IGainsDiamond.PendingOrder memory o = _orders[user][i];
        if (!o.isOpen) return 0;
        return _held(user, o);
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

    function getTradeLiquidationPrice(IGainsDiamond.LiqPriceInput calldata i) external view returns (uint256) {
        int256 fees = _liqFees(i.trader, i.index, i.pairIndex, i.collateral, i.leverage) + i.additionalFeeCollateral;
        return _liqPrice(i.openPrice, i.long, i.collateral, i.leverage, fees);
    }

    /// @dev gTrade v10 BorrowingFeesUtils._getTradeLiquidationPrice (verified facet source, ported in
    ///      audit/gains/nav/diff/diff.ts and matched to the live getTradeLiquidationPrice, nav/DIFF-RESULTS.md):
    ///      distance = openPrice x (collateral x threshold - fees) / collateral / leverage, fees = closing fee (no fee
    ///      tier) + pending holding fees - realized pnl. This mock's liquidation params are all zero, so the threshold
    ///      is 0.9 and the v10 spread term is 0. At the liquidation price the trade is worth collateral x (1 - 0.9).
    function _liqPrice(uint64 openPrice, bool long, uint256 collateral, uint256 leverage, int256 fees) internal pure returns (uint256) {
        int256 open = int256(uint256(openPrice));
        // leverage has 1e3 precision; no collateral: nothing to carry fees against, the plain -90 % distance
        int256 dist = collateral == 0
            ? (open * 90 * 1e3) / (100 * int256(leverage))
            : (open * ((int256(collateral) * 90) / 100 - fees) * 1e3) / (int256(collateral) * int256(leverage));
        int256 liq = long ? open - dist : open + dist;
        return liq > 0 ? uint256(liq) : 0;
    }

    /// @dev The fees _liqPrice carries: closing fee on the full size, holding balance (negative: owed to the trader)
    ///      and realized pnl net of realized fees, as closeValue counts them.
    function _liqFees(address user, uint32 index, uint256 pair, uint256 collateral, uint256 leverage) internal view returns (int256) {
        (,, int256 realized) = getTradeRealizedPnlCollateral(user, index);
        return int256(feeOf(pair, (collateral * leverage) / 1e3)) + holding[user][index] - realized;
    }

    function getTradeSkewPriceImpactP(uint8, uint16, bool, uint256, bool) external pure returns (int256) {
        return 0;
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

    function getTradingDelegate(address) external pure returns (address) {
        return address(0);
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

    /// @notice What a full close of `index` at `price` pays (0 at or past liquidation).
    function closeValue(address user, uint32 index, uint64 price) public view returns (uint256) {
        IGainsDiamond.Trade memory t = _trades[user][index];
        if (_liquidated(user, index, t, price)) return 0;
        uint256 size = (uint256(t.collateralAmount) * t.leverage) / 1e3;
        (,, int256 realized) = getTradeRealizedPnlCollateral(user, index);
        return _value(t.collateralAmount, _pnlP(t, _closePrice(t, price)), int256(feeOf(t.pairIndex, size)) + holding[user][index] - realized);
    }

    function _closePrice(IGainsDiamond.Trade memory t, uint64 price) internal view returns (uint64) {
        int256 spread = int256(pairCfg[t.pairIndex].spreadP / 2) * (t.long ? int256(-1) : int256(1));
        return uint64(uint256(int256(uint256(price)) + (int256(uint256(price)) * spread) / int256(P_10) / 100));
    }

    function _liquidated(address user, uint32 index, IGainsDiamond.Trade memory t, uint64 price) internal view returns (bool) {
        int256 fees = _liqFees(user, index, t.pairIndex, t.collateralAmount, t.leverage);
        uint256 liq = _liqPrice(t.openPrice, t.long, t.collateralAmount, t.leverage, fees);
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
    function _held(address user, IGainsDiamond.PendingOrder memory o) internal view returns (uint256) {
        uint8 t = o.orderType;
        if (t == 0 || t == 8) return o.trade.collateralAmount;
        if (t == 7 && o.trade.leverage < _trades[user][o.trade.index].leverage) return o.trade.collateralAmount;
        return 0;
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
        realizedFees[user][idx] = feeOf(t.pairIndex, (uint256(t.collateralAmount) * t.leverage) / 1e3);
    }

    function _close(address user, uint32 index, uint64 price) internal returns (uint256 out) {
        out = closeValue(user, index, price);
        IGainsDiamond.Trade storage t = _trades[user][index];
        t.isOpen = false;
        _release(user, t.collateralAmount);
        _pay(user, out);
    }

    function _partialClose(address user, uint32 index, uint120 delta, uint64 price) internal returns (uint256 out) {
        IGainsDiamond.Trade storage t = _trades[user][index];
        uint256 coll = t.collateralAmount;
        (,, int256 realized) = getTradeRealizedPnlCollateral(user, index);
        int256 pnlP = _pnlP(t, _closePrice(t, price));
        int256 valueNoFee = int256(_value(coll, pnlP, holding[user][index] - realized));
        int256 net = ((valueNoFee - int256(coll)) * int256(uint256(delta))) / int256(coll);
        int256 v = int256(uint256(delta)) + net - int256(feeOf(t.pairIndex, (uint256(delta) * t.leverage) / 1e3));
        out = v > 0 ? uint256(v) : 0;
        uint256 rest = coll - delta;
        t.positionSizeToken = uint160((uint256(t.positionSizeToken) * rest) / coll);
        t.collateralAmount = uint120(rest);
        holding[user][index] = (holding[user][index] * int256(rest)) / int256(coll);
        realizedPnl[user][index] = (realizedPnl[user][index] * int256(rest)) / int256(coll);
        realizedFees[user][index] = (realizedFees[user][index] * rest) / coll;
        _release(user, delta);
        _pay(user, out);
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

    function _pull(address user, uint256 amount) internal {
        usdc.transferFrom(user, address(this), amount);
        escrowLedger[user] += amount;
        pulled[user] += amount;
    }

    function _release(address user, uint256 amount) internal {
        escrowLedger[user] -= amount;
        released[user] += amount;
    }

    function _pay(address user, uint256 amount) internal {
        if (amount == 0) return;
        paid[user] += amount;
        usdc.transfer(user, amount);
    }
}
