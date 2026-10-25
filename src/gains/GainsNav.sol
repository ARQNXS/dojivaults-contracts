// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IGainsDiamond, GTrade} from "./IGainsDiamond.sol";
import {GainsPrice} from "./GainsPrice.sol";
import {GainsVaultPolicy} from "./GainsVaultPolicy.sol";
import {
    IGainsVaultErrors as E,
    MIN_HOLD,
    MIN_HOLD_L2_BLOCKS,
    TURNOVER_NAV_MULTIPLE,
    VaultStorage
} from "./GainsTypes.sol";

interface IArbSys {
    function arbBlockNumber() external view returns (uint256);
}

/// @title GainsNav
/// @notice Conservative value of everything the vault (address(this)) holds on the gTrade diamond, the analog of
///         VaultMath.coreEquity (PLAN.md 4.3). Linked as an external library: runs by delegatecall in the vault.
///
///  1. Resting limit / stop orders (tradeType 1, 2): their collateral.
///  2. Pending orders that hold collateral (market open, partial open with collateral, leverage decrease): the
///     collateral minus the gov fee a callback cancel would keep. Timed-out orders count until cancelled (Gains can
///     still fill them). Pending closes, partial closes and leverage increases leave the trade valued as open.
///  3. Open trades through Gains' own close path (exact against the USDC Gains pays at P, STAGE0.md C): collateral +
///     pnl(P after spread and impact) - closing fee (no fee tier) - holding fees(P) + realized pnl, floored at 0, at
///     two prices (GR1-02): `value` at the adverse edge of Chainlink +- band (what redemptions, risk and fees use)
///     and, when asked for (`high`), `valueHigh` at the favourable edge (what deposits mint at; only a settle that
///     prices deposits asks, so every other reader pays for one valuation per trade). A trade whose valuation price
///     is at or past its liquidation price is worth 0 at that price (the band counts once, GR1-03).
///
/// Also returns the vault's exposure for vault leverage: positionSizeToken x Chainlink of every open trade, plus
/// resting orders and every pending order that adds size at its full added notional, including a leverage-only
/// increase (collateral 0) at the trade's collateral x the leverage delta (GR1-01).
///
/// The trade and pending-order lists are decoded here (readTrades / readPendingOrders), tolerant of fields Gains
/// appends to its structs on a facet upgrade (GR1-08): the element stride is taken from the returndata, only the
/// fields the vault uses are decoded, and every decoded word is range checked, so a layout the vault cannot read
/// reverts DiamondLayoutChanged() instead of a raw decode panic. Fields appended after positionSizeToken are read
/// past; a field inserted before it is caught by the open trades' plausibility and size checks (GV-01), not by the
/// range checks alone.
/// Reverts PriceStale(pair) / SequencerDown() through the policy. Exits never call the priced paths.
library GainsNav {
    uint256 internal constant BPS = 10_000;
    uint256 internal constant P_10 = 1e10;
    /// @dev ABI words of the v10 Trade the vault decodes (user .. positionSizeToken) and of v10's full Trade.
    uint256 internal constant TRADE_FIELDS = 14;
    uint256 internal constant TRADE_WORDS = 15;
    /// @dev ABI words of PendingOrder after the nested Trade (user, index, isOpen, orderType, createdBlock, maxSlippageP).
    uint256 internal constant ORDER_TAIL_WORDS = 6;
    /// @dev More list elements than any vault can hold (MAX_POSITIONS is 20): a larger length is a broken read.
    uint256 internal constant MAX_LIST = 1_000;

    error DiamondLayoutChanged();

    // ==================================================================
    // GR2-LIVE-01: the vault's own index set
    // ==================================================================
    /// @dev Every Gains trade / pending-order index the vault (address(this)) ever received is either below the cursor
    ///      and then tracked here if it was open when last seen, or at / above the cursor and not yet seen. Readers value
    ///      the tracked indexes plus the unseen range [cursor, Gains' counter), each with one getTrade / getPendingOrder,
    ///      so NAV, settle and openTrade cost O(open items + unseen), never O(lifetime indexes) like getTrades /
    ///      getPendingOrders, which walk every index ever used. `sync` moves the cursor and drops closed entries; the
    ///      vault calls it at the start of every state-changing path that reads NAV. Kept at an ERC-7201 slot so the
    ///      VaultStorage layout is untouched.
    struct IndexSet {
        uint32 tradeCursor;
        uint32 orderCursor;
        uint32[] trades;
        uint32[] orders;
    }

    /// @dev cast index-erc7201 dojipad.gains.indexset
    bytes32 internal constant INDEX_SET_SLOT = 0x1e0e33189adf15c317126004a6f02aa0237ebae0ec8b70332f043a2eb5abd400;
    uint8 internal constant COUNTER_TRADE = 0;
    uint8 internal constant COUNTER_ORDER = 1;

    function _indexSet() private pure returns (IndexSet storage x) {
        bytes32 slot = INDEX_SET_SLOT;
        assembly ("memory-safe") {
            x.slot := slot
        }
    }

    /// @notice The vault's tracked indexes and cursors (GR2-LIVE-01).
    function indexSet() external view returns (uint32 tradeCursor, uint32 orderCursor, uint32[] memory trades, uint32[] memory orders) {
        IndexSet storage x = _indexSet();
        return (x.tradeCursor, x.orderCursor, x.trades, x.orders);
    }

    /// @notice GR2-LIVE-01. Drops every tracked index that is no longer open and pulls up to `maxSteps` unseen indexes
    ///         (trades first, then pending orders) into the set. Runs in the vault's context (delegatecall).
    /// @return steps unseen indexes read
    function sync(IGainsDiamond d, uint256 maxSteps) public returns (uint256 steps) {
        IndexSet storage x = _indexSet();
        _prune(d, x.trades, true);
        _prune(d, x.orders, false);
        steps = _pull(d, x, true, maxSteps);
        steps += _pull(d, x, false, maxSteps - steps);
    }

    function _prune(IGainsDiamond d, uint32[] storage list, bool trade) private {
        uint256 i;
        while (i < list.length) {
            if (_stillOpen(d, list[i], trade)) {
                ++i;
                continue;
            }
            list[i] = list[list.length - 1];
            list.pop();
        }
    }

    function _pull(IGainsDiamond d, IndexSet storage x, bool trade, uint256 maxSteps) private returns (uint256 steps) {
        (bool ok, uint256 counter) = _counter(d, address(this), trade ? COUNTER_TRADE : COUNTER_ORDER);
        if (!ok) return 0; // unreadable: pull nothing (the strict readers revert DiamondLayoutChanged)
        uint256 cur = trade ? x.tradeCursor : x.orderCursor;
        while (cur < counter && steps < maxSteps) {
            if (_stillOpen(d, uint32(cur), trade)) {
                if (trade) x.trades.push(uint32(cur));
                else x.orders.push(uint32(cur));
            }
            ++cur;
            ++steps;
        }
        if (trade) x.tradeCursor = uint32(cur);
        else x.orderCursor = uint32(cur);
    }

    /// @dev An index the vault cannot decode is kept (fail closed: the strict readers then revert DiamondLayoutChanged).
    function _stillOpen(IGainsDiamond d, uint32 index, bool trade) private view returns (bool) {
        if (trade) {
            (bool ok, IGainsDiamond.Trade memory t,) = _tradeAt(d, address(this), index);
            return !ok || t.isOpen;
        }
        (bool okO, IGainsDiamond.PendingOrder memory o,) = _orderAt(d, address(this), index);
        return !okO || o.isOpen;
    }

    /// @dev Gains' next index of one kind, read without reverting (the full-stop path must never revert, GR1-08).
    function _counter(IGainsDiamond d, address trader, uint8 kind) private view returns (bool ok, uint256 counter) {
        bytes memory r;
        (ok, r) = address(d).staticcall(abi.encodeCall(IGainsDiamond.getCounters, (trader, kind)));
        if (!ok || r.length < 96) return (false, 0);
        counter = _word(r, 0);
        ok = counter <= type(uint32).max;
    }

    /// @dev Tracked indexes plus the unseen range [cursor, counter) of one kind; ok = false when the counter cannot be
    ///      read.
    function _candidates(IGainsDiamond d, address trader, uint8 kind) private view returns (bool ok, uint32[] memory c) {
        IndexSet storage x = _indexSet();
        uint32[] storage tracked = kind == COUNTER_TRADE ? x.trades : x.orders;
        uint256 from = kind == COUNTER_TRADE ? x.tradeCursor : x.orderCursor;
        uint256 counter;
        (ok, counter) = _counter(d, trader, kind);
        if (!ok) return (false, c);
        if (from > counter) from = counter;
        uint256 n = tracked.length;
        c = new uint32[](n + counter - from);
        for (uint256 i; i < n; ++i) {
            c[i] = tracked[i];
        }
        for (uint256 j = from; j < counter; ++j) {
            c[n++] = uint32(j);
        }
    }

    /// @dev getTrade(trader, index) decoded like one list element (GR1-08): ok = false when it cannot be read;
    ///      `words` = ABI words of the Trade.
    function _tradeAt(IGainsDiamond d, address trader, uint32 index)
        private
        view
        returns (bool ok, IGainsDiamond.Trade memory t, uint256 words)
    {
        bytes memory r;
        (ok, r) = address(d).staticcall(abi.encodeCall(IGainsDiamond.getTrade, (trader, index)));
        if (!ok || r.length % 32 != 0 || r.length < TRADE_WORDS * 32) return (false, t, 0);
        words = r.length / 32;
        (ok, t) = _trade(r, 0);
    }

    /// @dev getPendingOrder((trader, index)) decoded like one list element: ok = false when it cannot be read;
    ///      `tw` = ABI words of the nested Trade.
    function _orderAt(IGainsDiamond d, address trader, uint32 index)
        private
        view
        returns (bool ok, IGainsDiamond.PendingOrder memory o, uint256 tw)
    {
        bytes memory r;
        (ok, r) = address(d).staticcall(abi.encodeCall(IGainsDiamond.getPendingOrder, (IGainsDiamond.Id(trader, index))));
        if (!ok || r.length % 32 != 0 || r.length < (TRADE_WORDS + ORDER_TAIL_WORDS) * 32) return (false, o, 0);
        tw = r.length / 32 - ORDER_TAIL_WORDS;
        (ok, o.trade) = _trade(r, 0);
        if (!ok) return (false, o, 0);
        uint256 user = _word(r, tw);
        uint256 idx = _word(r, tw + 1);
        uint256 open = _word(r, tw + 2);
        uint256 orderType = _word(r, tw + 3);
        uint256 createdBlock = _word(r, tw + 4);
        uint256 slippage = _word(r, tw + 5);
        if (
            user > type(uint160).max || idx > type(uint32).max || open > 1 || orderType > type(uint8).max
                || createdBlock > type(uint32).max || slippage > type(uint16).max
        ) return (false, o, 0);
        o.user = address(uint160(user));
        o.index = uint32(idx);
        o.isOpen = open == 1;
        o.orderType = uint8(orderType);
        o.createdBlock = uint32(createdBlock);
        o.maxSlippageP = uint16(slippage);
    }

    /// @dev The open trades among the candidates. strict: revert DiamondLayoutChanged on anything unreadable or
    ///      implausible; otherwise ok = false.
    function _collectTrades(IGainsDiamond d, address trader, bool strict)
        private
        view
        returns (bool ok, IGainsDiamond.Trade[] memory trades, uint256 stride)
    {
        (bool readable, uint32[] memory c) = _candidates(d, trader, COUNTER_TRADE);
        if (!readable) {
            if (strict) revert DiamondLayoutChanged();
            return (false, new IGainsDiamond.Trade[](0), 0);
        }
        trades = new IGainsDiamond.Trade[](c.length);
        uint256 k;
        for (uint256 i; i < c.length; ++i) {
            (bool good, IGainsDiamond.Trade memory t, uint256 words) = _tradeAt(d, trader, c[i]);
            if (good && t.isOpen) good = t.user == trader && (!strict || _plausible(t)) && (stride == 0 || words == stride);
            if (!good) {
                if (strict) revert DiamondLayoutChanged();
                return (false, new IGainsDiamond.Trade[](0), 0);
            }
            if (!t.isOpen) continue;
            stride = words;
            trades[k++] = t;
        }
        assembly ("memory-safe") {
            mstore(trades, k)
        }
        ok = true;
    }

    struct Snapshot {
        uint256 value; // collateral precision, trades at the adverse band edge
        uint256 notional; // open + pending exposure, collateral precision (USDC = USD)
        uint256 orders; // open trades + resting orders + pending orders
        uint256 pending; // pending orders
        uint256 valueHigh; // as value, trades at the favourable band edge (deposits mint at it, GR1-02); 0 unless asked
        uint256 blocking; // pending orders that hold collateral: settle waits for them (GR1-04)
        uint256 pairNotional; // as notional, only the pair asked for (GR2-KEY-01); 0 unless asked
    }

    /// @dev `pairOf` value that asks for no pair notional.
    uint256 internal constant NO_PAIR = type(uint256).max;

    /// @dev Per pair price cache for one snapshot.
    struct Prices {
        uint32[] pairs;
        uint64[] mids;
        uint16[] bands;
        uint256 n;
    }

    /// @dev The price-independent inputs of one trade's value, read once for both band edges.
    struct TradeCtx {
        IGainsDiamond.TradeInfo info;
        IGainsDiamond.GroupLiquidationParams liq;
        int256 realized;
        uint256 size;
        uint256 sizeUsd;
        int256 baseImpact; // fixed spread + skew (v10)
        uint256 feesRaw; // closing fee, no fee tier (the value)
        uint256 feesTiered; // closing fee with the fee tier (Gains' protection factor decision, pass 1)
        uint128 precisionDelta;
    }

    /// @param high also value every trade at the favourable band edge (valueHigh)
    function snapshot(IGainsDiamond d, GainsVaultPolicy p, uint8 collateralIndex, bool high) external view returns (Snapshot memory) {
        return snapshot(d, p, collateralIndex, high, NO_PAIR);
    }

    /// @param pairOf also sum the notional of this pair into pairNotional (GR2-KEY-01); NO_PAIR = none
    function snapshot(IGainsDiamond d, GainsVaultPolicy p, uint8 collateralIndex, bool high, uint256 pairOf)
        public
        view
        returns (Snapshot memory s)
    {
        (IGainsDiamond.Trade[] memory trades, uint256 tradeStride) = _readTrades(d, address(this));
        IGainsDiamond.PendingOrder[] memory orders = _readPendingOrders(d, address(this), tradeStride);
        s.orders = trades.length + orders.length;
        s.pending = orders.length;
        Prices memory px = Prices(new uint32[](trades.length), new uint64[](trades.length), new uint16[](trades.length), 0);
        uint128 precisionDelta = d.getCollateral(collateralIndex).precisionDelta;

        for (uint256 i; i < trades.length; ++i) {
            IGainsDiamond.Trade memory t = trades[i];
            if (!t.isOpen) continue;
            if (t.tradeType != GTrade.TRADE) {
                s.value += t.collateralAmount;
                if (high) s.valueHigh += t.collateralAmount;
                uint256 restingNotional = GTrade.positionSize(t.collateralAmount, t.leverage);
                s.notional += restingNotional;
                if (t.pairIndex == pairOf) s.pairNotional += restingNotional;
                continue;
            }
            _checkSize(t, precisionDelta);
            (uint64 mid, uint16 band) = _price(p, px, t.pairIndex);
            TradeCtx memory c = _ctx(d, t, precisionDelta);
            s.value += _valueAt(d, t, c, GainsPrice.adverse(mid, band, t.long));
            if (high) s.valueHigh += _valueAt(d, t, c, GainsPrice.adverse(mid, band, !t.long));
            // positionSizeToken (1e18) x price (1e10) -> 1e6 collateral units
            uint256 tradeNotional = (uint256(t.positionSizeToken) * mid) / 1e22;
            s.notional += tradeNotional;
            if (t.pairIndex == pairOf) s.pairNotional += tradeNotional;
        }

        for (uint256 i; i < orders.length; ++i) {
            IGainsDiamond.PendingOrder memory o = orders[i];
            if (!o.isOpen) continue;
            (uint256 held, uint256 added, uint16 feePair, bool blocks) = _pendingEffect(d, address(this), o);
            s.notional += added;
            if (feePair == pairOf) s.pairNotional += added;
            if (blocks) ++s.blocking;
            if (held > 0) {
                uint256 fee = minGovFee(d, collateralIndex, feePair);
                if (held > fee) {
                    s.value += held - fee;
                    if (high) s.valueHigh += held - fee;
                }
            }
        }
    }

    /// @notice Pending orders settle waits for (GR1-04): those that hold collateral (market open, partial open with
    ///         collateral, leverage decrease) and every order type this vault does not know (GV-02, fail closed).
    ///         Closes, partial closes, leverage increases and Gains' own trigger executions hold nothing and leave their
    ///         trade valued as open. A plain read: no price, safe on exit paths.
    function blockingOrders(IGainsDiamond d, address trader) public view returns (uint256 n) {
        IGainsDiamond.PendingOrder[] memory orders = readPendingOrders(d, trader);
        for (uint256 i; i < orders.length; ++i) {
            if (!orders[i].isOpen) continue;
            (,,, bool blocks) = _pendingEffect(d, trader, orders[i]);
            if (blocks) ++n;
        }
    }

    /// @notice A pending order (any type) exists for trade `index` of `trader`.
    function hasPendingOrder(IGainsDiamond d, address trader, uint32 index) public view returns (bool) {
        IGainsDiamond.PendingOrder[] memory orders = readPendingOrders(d, trader);
        for (uint256 i; i < orders.length; ++i) {
            if (orders[i].isOpen && orders[i].orderType != GTrade.MARKET_OPEN && orders[i].trade.index == index) return true;
        }
        return false;
    }

    /// @dev What a pending order holds (collateral that comes back on a cancel), the size it adds once filled, and
    ///      the pair its gov fee is charged on. Gains leaves trade.pairIndex 0 on orders that refer to an existing
    ///      trade (partial open, leverage update), so the pair is read from the trade itself (GR1-28).
    ///      `blocks`: settle waits for it. Every type is listed: a type this vault does not know (a future Gains
    ///      version, or one it never creates) holds settle and is valued at the collateral it carries (GV-02). Round 1's
    ///      settle waited for every pending order; the GR1-04 fix lets through only the types known to hold nothing.
    function _pendingEffect(IGainsDiamond d, address trader, IGainsDiamond.PendingOrder memory o)
        private
        view
        returns (uint256 held, uint256 added, uint16 feePair, bool blocks)
    {
        feePair = o.trade.pairIndex;
        uint8 k = o.orderType;
        if (k == GTrade.MARKET_CLOSE || k == GTrade.MARKET_PARTIAL_CLOSE) return (0, 0, feePair, false);
        // Gains' own trigger executions (limit / stop opens of a resting order, TP / SL / liquidation): the collateral
        // is in the trade (valued there), the request holds none
        if (k == GTrade.LIMIT_OPEN || k == GTrade.STOP_OPEN || k == GTrade.TP_CLOSE || k == GTrade.SL_CLOSE || k == GTrade.LIQ_CLOSE) {
            return (0, 0, feePair, false);
        }
        if (k == GTrade.MARKET_OPEN) {
            held = o.trade.collateralAmount;
            added = GTrade.positionSize(o.trade.collateralAmount, o.trade.leverage);
        } else if (k == GTrade.MARKET_PARTIAL_OPEN) {
            IGainsDiamond.Trade memory t = d.getTrade(trader, o.trade.index);
            feePair = t.pairIndex;
            if (o.trade.collateralAmount > 0) {
                held = o.trade.collateralAmount;
                added = GTrade.positionSize(o.trade.collateralAmount, o.trade.leverage);
            } else {
                // Leverage-only increase: Gains stores collateral 0 and the leverage delta; the fill adds the
                // trade's collateral x the delta (GR1-01).
                added = GTrade.positionSize(t.collateralAmount, o.trade.leverage);
            }
        } else if (k == GTrade.UPDATE_LEVERAGE) {
            IGainsDiamond.Trade memory t = d.getTrade(trader, o.trade.index);
            feePair = t.pairIndex;
            // A decrease pulled extra collateral (returned on a cancel); an increase holds none. Size is constant.
            if (o.trade.leverage < t.leverage) held = o.trade.collateralAmount;
        } else {
            // unknown (or never created by this vault, e.g. PNL_WITHDRAWAL): fail closed
            return (o.trade.collateralAmount, 0, feePair, true);
        }
        blocks = held > 0;
    }

    /// @notice Value of one open trade at valuation price `price` (an edge of the band), PLAN.md 4.3 step 4.
    function tradeValue(IGainsDiamond d, IGainsDiamond.Trade memory t, uint64 price, uint128 precisionDelta)
        internal
        view
        returns (uint256)
    {
        return _valueAt(d, t, _ctx(d, t, precisionDelta), price);
    }

    function _ctx(IGainsDiamond d, IGainsDiamond.Trade memory t, uint128 precisionDelta) private view returns (TradeCtx memory c) {
        c.info = d.getTradeInfo(t.user, t.index);
        c.liq = d.getTradeLiquidationParams(t.user, t.index);
        (,, c.realized) = d.getTradeRealizedPnlCollateral(t.user, t.index);
        c.size = GTrade.positionSize(t.collateralAmount, t.leverage);
        c.feesRaw = totalTradeFeesRaw(d, t.collateralIndex, t.pairIndex, c.size);
        c.precisionDelta = precisionDelta;
        if (c.info.contractsVersion >= GTrade.V9_2) {
            c.baseImpact = fixedSpreadP(d.pairSpreadP(t.user, t.pairIndex), t.long);
            if (c.info.contractsVersion >= GTrade.V10) {
                c.baseImpact += d.getTradeSkewPriceImpactP(t.collateralIndex, t.pairIndex, t.long, t.positionSizeToken, false);
            }
            c.sizeUsd = d.getUsdNormalizedValue(t.collateralIndex, c.size);
            c.feesTiered = d.getPairFlags(t.collateralIndex, t.pairIndex).skipFeeTierMultiplier ? c.feesRaw : d.calculateFeeAmount(t.user, c.feesRaw);
        }
    }

    function _valueAt(IGainsDiamond d, IGainsDiamond.Trade memory t, TradeCtx memory c, uint64 price) private view returns (uint256) {
        if (_nearLiquidation(d, t, c.liq, price)) return 0;
        int256 holding = d.getTradePendingHoldingFeesCollateral(t.user, t.index, price).totalFeeCollateral;
        uint64 closePrice = _closingPrice(d, t, c, price, holding - c.realized);
        return tradeValuePure(
            t.collateralAmount, pnlPercent(t.openPrice, closePrice, t.long, t.leverage), int256(c.feesRaw) + holding - c.realized, c.precisionDelta
        );
    }

    /// @dev The valuation price (already an edge of the band) at or past the liquidation price: long P <= L, short
    ///      P >= L. The band is in P, so it is not applied a second time (GR1-03).
    function _nearLiquidation(IGainsDiamond d, IGainsDiamond.Trade memory t, IGainsDiamond.GroupLiquidationParams memory lp, uint64 price)
        private
        view
        returns (bool)
    {
        uint256 liq = d.getTradeLiquidationPrice(
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
                liquidationParams: lp,
                currentPairPrice: price,
                isCounterTrade: t.isCounterTrade,
                partialCloseMultiplier: 1e18,
                beforeOpened: false
            })
        );
        return t.long ? uint256(price) <= liq : uint256(price) >= liq;
    }

    /// @dev TradingCommonUtils.getTradeClosingPriceImpact (market close): fixed spread, skew (v10) and cumulative
    ///      volume impact in two passes, as Gains computes it (STAGE0.md C).
    function _closingPrice(IGainsDiamond d, IGainsDiamond.Trade memory t, TradeCtx memory c, uint64 price, int256 holdingMinusRealized)
        private
        view
        returns (uint64)
    {
        if (c.info.contractsVersion < GTrade.V9_2) return price;
        // pass 1: impact assuming negative pnl, to decide whether the protection close factor applies
        int256 cumul0 = d.getTradeCumulVolPriceImpactP(t.user, t.pairIndex, t.long, c.sizeUsd, false, false, c.info.lastPosIncreaseBlock);
        uint256 valueNoFactor = tradeValuePure(
            t.collateralAmount,
            pnlPercent(t.openPrice, priceAfterImpact(price, c.baseImpact + cumul0), t.long, t.leverage),
            int256(c.feesTiered) + holdingMinusRealized,
            c.precisionDelta
        );
        int256 cumul = d.getTradeCumulVolPriceImpactP(
            t.user, t.pairIndex, t.long, c.sizeUsd, valueNoFactor > t.collateralAmount, false, c.info.lastPosIncreaseBlock
        );
        return priceAfterImpact(price, c.baseImpact + cumul);
    }

    /// @notice Gains' minimum gov fee (TradingCommonUtils.getMinGovFeeCollateral), without fee tier: what a callback
    ///         cancel of a pending open keeps.
    function minGovFee(IGainsDiamond d, uint8 collateralIndex, uint16 pairIndex) internal view returns (uint256) {
        uint256 half = totalTradeFeesRaw(d, collateralIndex, pairIndex, 0) / 2;
        return (half * d.getTradeFeeParams(collateralIndex, pairIndex).govFeeP) / 1e3 / 100;
    }

    /// @dev Fee on max(size, pairMinPositionSizeUsd) without fee tier discount (conservative, PLAN.md 4.3).
    function totalTradeFeesRaw(IGainsDiamond d, uint8 collateralIndex, uint16 pairIndex, uint256 size) internal view returns (uint256) {
        uint256 minSize = d.getCollateralFromUsdNormalizedValue(collateralIndex, d.pairMinPositionSizeUsd(pairIndex)) * 1e3;
        uint256 basis = size * 1e3;
        if (basis < minSize) basis = minSize;
        return (basis * d.pairTotalPositionSizeFeeP(pairIndex)) / P_10 / 100 / 1e3;
    }

    function pnlPercent(uint64 openPrice, uint64 currentPrice, bool long, uint24 leverage) internal pure returns (int256 p) {
        if (openPrice == 0) return 0;
        int256 o = int256(uint256(openPrice));
        int256 c = int256(uint256(currentPrice));
        p = ((long ? c - o : o - c) * 100 * int256(P_10) * int256(uint256(leverage))) / o / 1e3;
        int256 minP = -100 * int256(P_10);
        if (p < minP) p = minP;
    }

    /// @dev Half the pair spread, against the trader on close.
    function fixedSpreadP(uint256 spreadP, bool long) internal pure returns (int256) {
        return int256(spreadP / 2) * (long ? int256(-1) : int256(1));
    }

    /// @dev Saturates at the uint64 range instead of wrapping (GR1-24): a wrap would turn a short's huge close price
    ///      into a tiny one.
    function priceAfterImpact(uint64 oraclePrice, int256 totalImpactP) internal pure returns (uint64) {
        int256 raw = int256(uint256(oraclePrice)) + (int256(uint256(oraclePrice)) * totalImpactP) / int256(P_10) / 100;
        if (raw <= 0) return 0;
        return uint256(raw) > type(uint64).max ? type(uint64).max : uint64(uint256(raw));
    }

    /// @dev TradingCommonUtils.getTradeValuePure.
    function tradeValuePure(uint256 collateral, int256 pnlP, int256 feesCollateral, uint128 precisionDelta) internal pure returns (uint256) {
        int256 pd = int256(uint256(precisionDelta));
        int256 v = (int256(collateral) * pd + (int256(collateral) * pd * pnlP) / int256(P_10) / 100) / pd - feesCollateral;
        return v > 0 ? uint256(v) : 0;
    }

    function _price(GainsVaultPolicy p, Prices memory px, uint16 pair) private view returns (uint64 mid, uint16 band) {
        for (uint256 i; i < px.n; ++i) {
            if (px.pairs[i] == pair) return (px.mids[i], px.bands[i]);
        }
        (mid, band) = p.navPrice(pair);
        px.pairs[px.n] = pair;
        px.mids[px.n] = mid;
        px.bands[px.n] = band;
        ++px.n;
    }

    // ==================================================================
    // Trade and pending-order lists (GR1-08)
    // ==================================================================
    /// @notice The open trades of trader (= address(this), the vault: its index set, GR2-LIVE-01), decoded tolerant
    ///         of fields Gains appends to Trade. Reverts DiamondLayoutChanged() when one cannot be read.
    function readTrades(IGainsDiamond d, address trader) public view returns (IGainsDiamond.Trade[] memory trades) {
        (trades,) = _readTrades(d, trader);
    }

    /// @notice The open pending orders of trader (= address(this): its index set, GR2-LIVE-01), decoded tolerant of
    ///         fields Gains appends to the nested Trade. Reverts DiamondLayoutChanged() when one cannot be read.
    function readPendingOrders(IGainsDiamond d, address trader) public view returns (IGainsDiamond.PendingOrder[] memory) {
        return _readPendingOrders(d, trader, 0);
    }

    /// @notice As readTrades, but never reverts: ok = false when the list cannot be read (the full-stop path cancels
    ///         resting orders with it and must still stop the vault).
    function tryReadTrades(IGainsDiamond d, address trader) internal view returns (bool ok, IGainsDiamond.Trade[] memory trades) {
        (ok, trades,) = _collectTrades(d, trader, false);
    }

    /// @dev GR2-LIVE-01: the open trades of the index set (tracked + unseen), not getTrades.
    /// @return trades the open trades
    /// @return stride ABI words per Trade (0 when there is none)
    function _readTrades(IGainsDiamond d, address trader) private view returns (IGainsDiamond.Trade[] memory trades, uint256 stride) {
        (, trades, stride) = _collectTrades(d, trader, true);
    }

    /// @dev GR2-LIVE-01: the open pending orders of the index set (tracked + unseen), not getPendingOrders.
    /// @param tradeStride the Trade stride seen in the trades (0 = unknown): the nested Trade must have the same
    function _readPendingOrders(IGainsDiamond d, address trader, uint256 tradeStride)
        private
        view
        returns (IGainsDiamond.PendingOrder[] memory orders)
    {
        (bool readable, uint32[] memory c) = _candidates(d, trader, COUNTER_ORDER);
        if (!readable) revert DiamondLayoutChanged();
        orders = new IGainsDiamond.PendingOrder[](c.length);
        uint256 k;
        for (uint256 i; i < c.length; ++i) {
            (bool good, IGainsDiamond.PendingOrder memory o, uint256 tw) = _orderAt(d, trader, c[i]);
            if (!good) revert DiamondLayoutChanged();
            if (!o.isOpen) continue;
            if (o.user != trader || (tradeStride != 0 && tw != tradeStride)) revert DiamondLayoutChanged();
            orders[k++] = o;
        }
        if (k > MAX_LIST) revert DiamondLayoutChanged();
        assembly ("memory-safe") {
            mstore(orders, k)
        }
    }

    function _call(IGainsDiamond d, bytes memory data) private view returns (bytes memory r) {
        bool ok;
        (ok, r) = address(d).staticcall(data);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(r, 32), mload(r))
            }
        }
    }

    /// @dev Header of an ABI-encoded dynamic array of static structs: offset 0x20, length n, then n elements of a
    ///      fixed number of words that is at least `minWords`. Fields Gains appends to a struct only widen the stride.
    /// @return ok the layout is readable
    /// @return n elements
    /// @return stride words per element
    function _list(bytes memory r, uint256 minWords) private pure returns (bool ok, uint256 n, uint256 stride) {
        if (r.length < 64 || r.length % 32 != 0 || _word(r, 0) != 32) return (false, 0, 0);
        n = _word(r, 1);
        uint256 words = r.length / 32 - 2;
        if (n == 0) return (words == 0, 0, 0);
        if (n > MAX_LIST || words % n != 0) return (false, 0, 0);
        stride = words / n;
        ok = stride >= minWords;
    }

    /// @dev The first TRADE_FIELDS words of a Trade at word `at`, each range checked against its v10 type.
    function _trade(bytes memory r, uint256 at) private pure returns (bool ok, IGainsDiamond.Trade memory t) {
        uint256[TRADE_FIELDS] memory w;
        for (uint256 k; k < TRADE_FIELDS; ++k) {
            w[k] = _word(r, at + k);
        }
        ok = w[0] <= type(uint160).max && w[1] <= type(uint32).max && w[2] <= type(uint16).max && w[3] <= type(uint24).max
            && w[4] <= 1 && w[5] <= 1 && w[6] <= type(uint8).max && w[7] <= type(uint8).max && w[8] <= type(uint120).max
            && w[9] <= type(uint64).max && w[10] <= type(uint64).max && w[11] <= type(uint64).max && w[12] <= 1
            && w[13] <= type(uint160).max;
        if (!ok) return (false, t);
        t.user = address(uint160(w[0]));
        t.index = uint32(w[1]);
        t.pairIndex = uint16(w[2]);
        t.leverage = uint24(w[3]);
        t.long = w[4] == 1;
        t.isOpen = w[5] == 1;
        t.collateralIndex = uint8(w[6]);
        t.tradeType = uint8(w[7]);
        t.collateralAmount = uint120(w[8]);
        t.openPrice = uint64(w[9]);
        t.tp = uint64(w[10]);
        t.sl = uint64(w[11]);
        t.isCounterTrade = w[12] == 1;
        t.positionSizeToken = uint160(w[13]);
    }

    /// @dev An open trade Gains could not hold (GV-01): a field shifted by a layout change can pass every range check
    ///      while carrying a zero where Gains never stores one. Open trades always have leverage, an open price and
    ///      collateral, and a type of TRADE, LIMIT or STOP.
    function _plausible(IGainsDiamond.Trade memory t) private pure returns (bool) {
        return t.leverage > 0 && t.openPrice > 0 && t.collateralAmount > 0 && t.tradeType <= GTrade.STOP;
    }

    /// @dev An open market trade's positionSizeToken against what its collateral, leverage and open price imply
    ///      (GV-01): a misread size (the PoC's inserted field reads it as 1, a notional of about 0) would let any open
    ///      pass the vault leverage check. Gains keeps the two consistent through partial opens (the open price is the
    ///      size weighted average), partial closes and leverage updates (constant size), so a factor of 4 either way
    ///      is never reached by a real trade.
    function _checkSize(IGainsDiamond.Trade memory t, uint128 precisionDelta) private pure {
        // collateral (collateral units) x precisionDelta -> 1e18 USD; x leverage (1e3); / openPrice (1e10) -> 1e18 tokens
        uint256 expected = (uint256(t.collateralAmount) * precisionDelta * t.leverage * GTrade.P_10) / (GTrade.LEVERAGE_PRECISION * t.openPrice);
        uint256 size = t.positionSizeToken;
        if (size == 0 || size * 4 < expected || size > expected * 4) revert DiamondLayoutChanged();
    }

    function _word(bytes memory r, uint256 i) private pure returns (uint256 v) {
        assembly ("memory-safe") {
            v := mload(add(add(r, 32), mul(i, 32)))
        }
    }

    // ------------------------------------------------------------------
    // GR2-KEY-01b (here for GainsVaultLogic's size; delegatecalled on the vault's storage)
    // ------------------------------------------------------------------
    /// @notice Opened notional is a token bucket of TURNOVER_NAV_MULTIPLE x NAV refilling linearly over a day (NAV = the
    ///         order's own read); also stamps the minimum hold of the vault and of the pair.
    function spendTurnover(VaultStorage storage $, uint16 pair, uint256 nav, uint256 notional) public {
        uint256 budget = nav * TURNOVER_NAV_MULTIPLE;
        uint256 refill = (block.timestamp - $.turnoverAt) * budget / 1 days;
        uint256 used = $.turnoverUsed;
        used = (used > refill ? used - refill : 0) + notional;
        if (used > budget) revert E.OrderRejected("turnover");
        $.turnoverUsed = uint128(used);
        $.turnoverAt = uint64(block.timestamp);
        $.lastRiskAt = uint64(block.timestamp);
        $.pairRiskAt[pair] = uint64(block.timestamp);
    }

    /// @notice The trade's pair hold (request time) and its own hold (Gains' fill-time lastPosIncreaseBlock).
    function holdTrade(VaultStorage storage $, uint32 index) public view {
        IGainsDiamond d = $.diamond;
        uint16 pair = d.getTrade(address(this), index).pairIndex;
        checkHold($.pairRiskAt[pair], d.getTradeInfo(address(this), index).lastPosIncreaseBlock);
    }

    /// @notice The pair's hold and the own hold of every open trade of the pair (the manager's flatten).
    function holdPair(VaultStorage storage $, uint16 pair) public view {
        checkHold($.pairRiskAt[pair], 0);
        IGainsDiamond d = $.diamond;
        IGainsDiamond.Trade[] memory trades = readTrades(d, address(this));
        for (uint256 i; i < trades.length; ++i) {
            IGainsDiamond.Trade memory t = trades[i];
            if (t.isOpen && t.pairIndex == pair && t.tradeType == GTrade.TRADE) {
                checkHold(0, d.getTradeInfo(address(this), t.index).lastPosIncreaseBlock);
            }
        }
    }

    /// @notice Reverts OrderRejected("min hold") inside MIN_HOLD of `riskAt` (0 = none) or MIN_HOLD_L2_BLOCKS of
    ///         `increaseBlock` (0 = none) on Gains' block clock: ArbSys on Arbitrum (block.number there is the L1
    ///         estimate), block.number elsewhere.
    function checkHold(uint256 riskAt, uint256 increaseBlock) public view {
        uint256 l2 = block.chainid == 42161 || block.chainid == 421614 ? IArbSys(address(100)).arbBlockNumber() : block.number;
        if ((riskAt != 0 && block.timestamp < riskAt + MIN_HOLD) || (increaseBlock != 0 && l2 < increaseBlock + MIN_HOLD_L2_BLOCKS)) {
            revert E.OrderRejected("min hold");
        }
    }
}
