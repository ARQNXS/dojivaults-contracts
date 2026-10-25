// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Vm, console2} from "forge-std/Test.sol";
import {LifecycleForkBase} from "../lifecycle/LifecycleForkBase.sol";
import {IArbSys} from "../../../gains/fork/GainsForkBase.sol";
import {IGainsDiamondSpike as G} from "../../../gains/spike/IGainsDiamondSpike.sol";
import {GainsVault} from "../../../../src/gains/GainsVault.sol";
import {GainsVaultPolicy} from "../../../../src/gains/GainsVaultPolicy.sol";
import {GainsNav} from "../../../../src/gains/GainsNav.sol";
import {IGainsDiamond, GTrade} from "../../../../src/gains/IGainsDiamond.sol";
import {IGainsVaultErrors} from "../../../../src/gains/GainsTypes.sol";

interface IGainsR2 {
    function getTradersCount() external view returns (uint256);
    function getTraders(uint32 offset, uint32 limit) external view returns (address[] memory);
    function initiateManualNegativePnlRealization(address trader, uint32 index, bool isHoldingFeesRealization) external;
    function getTradePendingOrderBlock(IGainsDiamond.Id calldata tradeId, uint8 orderType) external view returns (uint256);
}

/// @dev Answers navPrice like the policy (band 0) at prices the test sets per pair: the size check does not depend on it.
contract StubNavPolicy {
    mapping(uint32 => uint64) public px;

    function set(uint32 asset, uint64 p) external {
        px[asset] = p;
    }

    function navPrice(uint32 asset) external view returns (uint64, uint16) {
        return (px[asset], 0);
    }
}

/// @dev Etched at a real trader's address, so GainsNav.snapshot (address(this) = the trader) reads that trader's
///      trades through the vault's own decoder, plausibility and size checks.
contract SnapHarness {
    function snap(IGainsDiamond d, address p, uint8 ci) external view returns (GainsNav.Snapshot memory) {
        return GainsNav.snapshot(d, GainsVaultPolicy(p), ci, false);
    }
}

/// @notice VERIFY-R2 on the Arbitrum One fork (real gTrade v10 diamond).
///         Item 1 (GV-01): real mainnet trades through GainsNav.snapshot (live, and right after real partial closes,
///         partial opens and leverage updates), and a vault trade taken through every size-changing operation and a
///         month of holding fees. Item 2 (GV-02): every order type the vault creates, and the ones third parties create
///         on its trades, on the real diamond. Item 5: gas at 20 positions.
contract VerifyR2ForkTest is LifecycleForkBase {
    uint256 internal constant ARB_TX_LIMIT = 32_000_000;
    bytes4 internal LAYOUT = IGainsVaultErrors.DiamondLayoutChanged.selector;
    IGainsR2 internal X = IGainsR2(address(0xFF162c694eAA571f685030649814282eA457f169));

    struct Ratio {
        uint256 lo; // 1e6 = 1
        uint256 hi;
        address loUser;
        uint32 loIndex;
        address hiUser;
        uint32 hiIndex;
    }

    /// @dev positionSizeToken / (collateral x precisionDelta x leverage / openPrice), 1e6 = 1. The expected size is
    ///      GainsNav._checkSize's, verbatim.
    function _ratio(IGainsDiamond.Trade memory t) internal view returns (uint256) {
        uint128 pd = D.getCollateral(t.collateralIndex).precisionDelta;
        uint256 expected = (uint256(t.collateralAmount) * pd * t.leverage * GTrade.P_10) / (GTrade.LEVERAGE_PRECISION * t.openPrice);
        return (uint256(t.positionSizeToken) * 1e6) / expected;
    }

    function _track(Ratio memory r, IGainsDiamond.Trade memory t) internal view {
        uint256 x = _ratio(t);
        if (x < r.lo) (r.lo, r.loUser, r.loIndex) = (x, t.user, t.index);
        if (x > r.hi) (r.hi, r.hiUser, r.hiIndex) = (x, t.user, t.index);
    }

    /// @dev GainsNav.INDEX_SET_SLOT (GR2-LIVE-01, ERC-7201 "dojipad.gains.indexset"): tradeCursor | orderCursor << 32, then
    ///      the tracked trade and order arrays.
    bytes32 internal constant INDEX_SET_SLOT_ = 0x1e0e33189adf15c317126004a6f02aa0237ebae0ec8b70332f043a2eb5abd400;

    /// @dev GR2-LIVE-01 port (WP5): GainsNav no longer reads getTrades / getPendingOrders; it reads the index set of
    ///      address(this) (`holder`) plus the unseen range [cursor, Gains' counter of `trader`), one getTrade /
    ///      getPendingOrder per index. To put exactly trade `index` of `trader` through the reads: the holder's index set
    ///      is written empty with the trade cursor at `index` (order cursor 0), and Gains' counters of `trader` are mocked
    ///      to (index + 1) trades and 0 pending orders. The only candidate is then `index`: no other trade of the trader
    ///      (a pre-v10 one, say) can reach the checks.
    function _isolate(address holder, address trader, uint32 index) internal {
        vm.store(holder, INDEX_SET_SLOT_, bytes32(uint256(index)));
        vm.store(holder, bytes32(uint256(INDEX_SET_SLOT_) + 1), bytes32(0));
        vm.store(holder, bytes32(uint256(INDEX_SET_SLOT_) + 2), bytes32(0));
        vm.mockCall(
            address(D),
            abi.encodeCall(IGainsDiamond.getCounters, (trader, uint8(0))),
            abi.encode(IGainsDiamond.Counter(index + 1, 1, 0))
        );
        vm.mockCall(
            address(D), abi.encodeCall(IGainsDiamond.getCounters, (trader, uint8(1))), abi.encode(IGainsDiamond.Counter(0, 0, 0))
        );
    }

    /// @dev Snapshot of `trader` (the harness etched at it) with `t` as the only candidate index (`_isolate`), pending
    ///      orders none: the trade's real values through the real checks. Returns the revert selector (0 = passed).
    function _snapOne(StubNavPolicy stub, IGainsDiamond.Trade memory t) internal returns (bytes4 err) {
        _isolate(t.user, t.user, t.index);
        stub.set(t.pairIndex, t.openPrice);
        try SnapHarness(t.user).snap(D, address(stub), t.collateralIndex) {}
        catch (bytes memory r) {
            err = _sel(r);
            if (err == bytes4(0)) err = bytes4(0xffffffff);
        }
    }

    // ==================================================================
    // Item 1 (GV-01): every live trade on the diamond
    // ==================================================================
    /// @notice At FORK_BLOCK: every trader with open trades (getTraders), their whole list through GainsNav.readTrades
    ///         (the decoder and the plausibility check on every open element, limit / stop orders included), then every
    ///         open market trade alone through GainsNav.snapshot (the size check). No v10 trade may trip it; every
    ///         pre-v10 trade (positionSizeToken 0, a vault never holds one) must, which shows the check runs.
    struct Tally {
        uint256 sampled;
        uint256 withOpen;
        uint256 skippedLong;
        uint256 traders;
        uint256 elements;
        uint256 v10;
        uint256 legacy;
        uint256 legacyCaught;
        uint256 falsePositive;
        uint256 other;
        uint256 precompileSkipped;
    }

    /// @dev WP5 port (GR2-LIVE-01): a SAMPLE, not every trader. The diamond lists 16,121 traders at 517,076,707 (the
    ///      comment above said ~1,000), and every element read is now one getTrade per index on the fork, so the full walk
    ///      did not finish in 3.5 hours. VERIFY_GV01_TRADERS (default 300) traders are taken at an even, deterministic
    ///      stride over the whole list; a trader with more than VERIFY_GV01_MAX_INDEX (default 5,000) lifetime trade
    ///      indexes is skipped and counted (Gains' own getTrades walks them all on the fork). Each open element goes
    ///      through GainsNav.readTrades alone and each open market trade through GainsNav.snapshot alone (`_isolate`).
    function test_R2_GV01_everyLiveTradeThroughTheVaultChecks() public {
        vm.pauseGasMetering(); // hundreds of traders in one test pass forge's 2^30 test gas limit; nothing here is a gas figure
        bytes memory code = address(new SnapHarness()).code;
        StubNavPolicy stub = new StubNavPolicy();
        uint256 count = X.getTradersCount();
        uint256 want = vm.envOr("VERIFY_GV01_TRADERS", uint256(300));
        if (want > count) want = count;
        uint256 stride = count / want;
        Ratio memory r = Ratio(type(uint256).max, 0, address(0), 0, address(0), 0);
        Tally memory n;
        for (uint256 k; k < want; ++k) {
            // the middle of each stride, never 0: Gains' getTraders(0, 0) returns the WHOLE list (a zero limit means
            // all), which made the first port of this sample walk all 16,121 traders
            uint32 at = uint32(k * stride + stride / 2 + 1);
            address[] memory ts = X.getTraders(at, at);
            if (ts.length == 0 || ts[0] == address(0)) continue; // removed traders read as zero
            ++n.sampled;
            _liveTrader(ts[0], code, stub, r, n);
        }
        console2.log("SAMPLE, not every trader: traders listed / sampled (stride)", count, n.sampled, stride);
        console2.log("sampled traders with open trades / skipped (too many lifetime indexes)", n.withOpen, n.skippedLong);
        console2.log("block", _arbBlock());
        console2.log("traders, elements read, v10 market trades", n.traders, n.elements, n.v10);
        console2.log("elements of precompile traders (readTrades only)", n.precompileSkipped);
        console2.log("pre-v10 market trades, of them caught by the size check", n.legacy, n.legacyCaught);
        console2.log("v10 ratio min (1e6 = 1)", r.lo, r.loUser, r.loIndex);
        console2.log("v10 ratio max (1e6 = 1)", r.hi, r.hiUser, r.hiIndex);
        console2.log("margin to the 4x bound: low side x(1e6), high side x(1e6)", (r.lo * 1e6) / 250_000, (4e12) / r.hi);
        assertGt(n.v10, 0, "the sample holds v10 market trades");
        assertEq(n.falsePositive, 0, "no v10 trade trips DiamondLayoutChanged");
        assertEq(n.other, 0, "no other revert");
        assertEq(n.legacyCaught, n.legacy, "the check runs: every pre-v10 trade (size 0) is refused");
        assertGt(r.lo, 990_000);
        assertLt(r.hi, 1_010_000);
    }

    function _liveTrader(address u, bytes memory code, StubNavPolicy stub, Ratio memory r, Tally memory n) internal {
        if (D.getCounters(u, 0).currentIndex > vm.envOr("VERIFY_GV01_MAX_INDEX", uint256(5_000))) {
            ++n.skippedLong;
            return;
        }
        ++n.traders;
        // the trader's open elements (Gains' list, test side), then each one alone through the vault's reader, which
        // reverts DiamondLayoutChanged on an implausible element
        IGainsDiamond.Trade[] memory all = D.getTrades(u);
        if (all.length > 0) ++n.withOpen;
        for (uint256 k; k < all.length; ++k) {
            _isolate(address(this), u, all[k].index);
            IGainsDiamond.Trade[] memory one = GainsNav.readTrades(D, u);
            assertEq(one.length, 1, "the isolated element reads alone");
            assertEq(one[0].index, all[k].index);
        }
        n.elements += all.length;
        // a precompile address cannot carry the harness: its trades go through readTrades (above) only
        if (uint160(u) < 0x10000) {
            n.precompileSkipped += all.length;
            console2.log("precompile trader, snapshot skipped", u, all.length);
            return;
        }
        vm.etch(u, code);
        for (uint256 k; k < all.length; ++k) {
            IGainsDiamond.Trade memory t = all[k];
            if (!t.isOpen || t.tradeType != GTrade.TRADE) continue;
            bool isV10 = D.getTradeInfo(u, t.index).contractsVersion >= GTrade.V10;
            bytes4 err = _snapOne(stub, t);
            if (isV10) {
                ++n.v10;
                _track(r, t);
                if (err == LAYOUT) {
                    ++n.falsePositive;
                    console2.log("FALSE POSITIVE", u, t.index);
                } else if (err != bytes4(0)) {
                    ++n.other;
                    console2.log("other revert", u, t.index);
                    console2.logBytes4(err);
                }
            } else {
                ++n.legacy;
                assertEq(t.positionSizeToken, 0, "pre-v10 trades carry no size");
                if (err == LAYOUT) ++n.legacyCaught;
            }
        }
    }

    // ==================================================================
    // Item 1 (GV-01): real trades right after a size-changing operation
    // ==================================================================
    struct Hist {
        uint256 block_;
        address user;
        uint32 index;
        string what;
    }

    /// @dev Filled from audit/gains/verify-r2/data/history-*.json (scan-history.mjs): for each kind of operation the
    ///      executed event whose post-state ratio is furthest from 1, plus long-held trades.
    function _hist() internal pure returns (Hist[] memory h) {
        h = new Hist[](12);
        // from data/history-495321788-516057788.json: 49,529 executed operations on v10 trades in 60 days, the extreme of each kind
        h[0] = Hist(509773537, 0x0D78fF46a85a9354924d99Af3db4Fa403cbB9900, 815, "partial close, lowest ratio (0.98567)");
        h[1] = Hist(509577067, 0x3da3B64E63b57Ed4926D4D9836cd08e0FFc830a0, 844, "partial close, highest (1.004424)");
        h[2] = Hist(508402824, 0xd6c5fa4e27db9d313302122770270143BDA976EF, 966, "leverage-only size decrease, lowest (0.998053)");
        h[3] = Hist(499120702, 0x201321Dd6ed5796c586F8e3379afB409D4B19eB8, 10681, "leverage-only size decrease, highest (1.001692)");
        h[4] = Hist(508833286, 0x201321Dd6ed5796c586F8e3379afB409D4B19eB8, 11620, "partial open with collateral, lowest (0.991036)");
        h[5] = Hist(507282570, 0x3da3B64E63b57Ed4926D4D9836cd08e0FFc830a0, 844, "partial open with collateral, highest (1.00592)");
        h[6] = Hist(509196849, 0xabF68ea28e2522726F53b6413b87Ef7067FDf21A, 645, "leverage-only partial open, lowest (0.997278)");
        h[7] = Hist(496557002, 0x9970a45f0fCc66E592F43257a6C0E066319B933F, 113, "leverage-only partial open, highest (1.001705)");
        h[8] = Hist(508833338, 0x2773F25af5497A20B783fA86D886c4aa9799Ac41, 838, "leverage increase, lowest (0.993594)");
        h[9] = Hist(501325028, 0x05FC3e584D4c6BB2f460D2b66955A13C32fd0eB3, 32, "leverage increase, highest (1.00277)");
        h[10] = Hist(505315634, 0xC19286cDFd63461228d3A0e0328DFC1e210b0dA4, 1665, "leverage decrease, lowest (0.995956)");
        h[11] = Hist(507901662, 0x2773F25af5497A20B783fA86D886c4aa9799Ac41, 825, "leverage decrease, highest (1.005977)");
    }

    /// @notice Fork at the block of each real operation (the state after it) and run the trade alone through
    ///         GainsNav.snapshot.
    function test_R2_GV01_realTradesAfterPartialClosesOpensAndLeverageUpdates() public {
        Hist[] memory h = _hist();
        for (uint256 i; i < h.length; ++i) {
            vm.createSelectFork("arbitrum", h[i].block_);
            vm.etch(ARB_SYS, hex"00");
            vm.mockCall(ARB_SYS, abi.encodeWithSelector(IArbSys.arbBlockNumber.selector), abi.encode(h[i].block_));
            IGainsDiamond.Trade memory t = D.getTrade(h[i].user, h[i].index);
            assertTrue(t.isOpen, h[i].what);
            assertGe(D.getTradeInfo(t.user, t.index).contractsVersion, GTrade.V10, h[i].what);
            StubNavPolicy stub = new StubNavPolicy();
            vm.etch(t.user, address(new SnapHarness()).code);
            bytes4 err = _snapOne(stub, t);
            console2.log(h[i].what, _ratio(t));
            assertEq(err, bytes4(0), h[i].what);
        }
    }

    // ==================================================================
    // Item 1 (GV-01): a vault trade through every size-changing operation and a month of fees
    // ==================================================================
    function _step(uint32 idx, string memory what) internal returns (uint256 x) {
        IGainsDiamond.Trade memory t = _trade(idx);
        x = _ratio(t);
        uint256 nav = v.totalAssets(); // the real _checkSize
        console2.log(what, x, nav);
        console2.log("  collateral, leverage, openPrice", t.collateralAmount, t.leverage, t.openPrice);
        assertGt(x, 990_000, what);
        assertLt(x, 1_010_000, what);
    }

    function _move(uint16 pair, int256 bps) internal {
        uint64 p = cl[_feed(pair)];
        _setCl(_feed(pair), _round(uint64(uint256(int256(uint256(p)) + (int256(uint256(p)) * bps) / 10_000))));
    }

    function test_R2_GV01_vaultTradeThroughEveryOperationAndAMonthOfFees() public {
        _depositSettle(alice, 100_000e6);
        uint32 idx = _openFilledV(BTC, true, 2_000e6, 5_000); // 10k at 5x
        _step(idx, "open 2k x 5x");

        // partial open with collateral, 3% higher: the open price becomes the size-weighted average
        _move(BTC, 300);
        Vm.Log[] memory req = _req(mgr, abi.encodeCall(GainsVault.increaseTrade, (idx, uint120(1_000e6), uint24(10_000), cl[BTC_USD], uint16(1_000))));
        _rollFresh(1);
        _fill(req, cl[BTC_USD]);
        _step(idx, "partial open +1k x 10x at +3%");

        // leverage-only increase, 2% lower
        _move(BTC, -200);
        req = _req(mgr, abi.encodeCall(GainsVault.increaseTrade, (idx, uint120(0), uint24(2_000), cl[BTC_USD], uint16(1_000))));
        _rollFresh(1);
        _fill(req, cl[BTC_USD]);
        _step(idx, "leverage-only increase +2x at -2%");

        // leverage update up and down (constant size; the collateral delta goes out, then in)
        uint24 lev = _trade(idx).leverage;
        req = _req(mgr, abi.encodeCall(GainsVault.updateLeverage, (idx, lev + 2_000)));
        _rollFresh(1);
        _fill(req, cl[BTC_USD]);
        _step(idx, "update leverage +2x");
        req = _req(mgr, abi.encodeCall(GainsVault.updateLeverage, (idx, lev - 1_000)));
        _rollFresh(1);
        _fill(req, cl[BTC_USD]);
        _step(idx, "update leverage down to the start -1x");

        // partial close by collateral, then a leverage-only size decrease, 1.5% higher
        _passHold(); // GR2-KEY-01b (WP5 port): the manager's reduces wait the 10-minute minimum hold
        _move(BTC, 150);
        req = _req(mgr, abi.encodeCall(GainsVault.reduceTrade, (idx, uint120(700e6), uint24(0), cl[BTC_USD])));
        _rollFresh(1);
        _fill(req, cl[BTC_USD]);
        _step(idx, "partial close -700 collateral at +1.5%");
        req = _req(mgr, abi.encodeCall(GainsVault.reduceTrade, (idx, uint120(0), uint24(1_000), cl[BTC_USD])));
        _rollFresh(1);
        _fill(req, cl[BTC_USD]);
        _step(idx, "leverage-only decrease -1x");

        // a month of funding and borrowing, settled every 4 h with a deposit at the end
        for (uint256 d; d < 30; ++d) {
            _rollFresh(345_600); // one day of Arbitrum blocks
            v.checkRisk();
            vm.prank(keeper);
            v.settle();
        }
        _step(idx, "after 30 days of holding fees");
        _depositSettle(bob, 10_000e6);
        _step(idx, "after a settle that prices a deposit");

        // the exits still run
        (uint256 sent,) = _sentFlatten(BTC);
        assertEq(sent, 1);
    }

    function _sentFlatten(uint16 pair) internal returns (uint256 sent, uint256 remaining) {
        vm.prank(mgr);
        (sent, remaining) = v.flatten(pair, 0, cl[_feed(pair)], type(uint256).max);
    }

    // ==================================================================
    // Item 2 (GV-02): every order type on the real diamond
    // ==================================================================
    function _expectPending(uint8 kind, bool blocks, string memory what) internal view {
        IGainsDiamond.PendingOrder memory o = _lastPending();
        assertEq(o.orderType, kind, what);
        assertEq(v.ordersPending(), blocks, what);
        assertEq(v.venue().blocking, blocks ? 1 : 0, what);
    }

    function test_R2_GV02_everyTypeTheVaultCreates_onTheRealDiamond() public {
        _depositSettle(alice, 100_000e6);
        uint64 p = cl[ETH_USD];

        Vm.Log[] memory req = _req(mgr, abi.encodeCall(GainsVault.openTrade, (_openParams(ETH, true, 2_000e6, 10_000))));
        _expectPending(GTrade.MARKET_OPEN, true, "0 MARKET_OPEN holds");
        _rollFresh(1);
        uint32 idx = uint32(uint256(_find(_fill(req, p), G.MarketExecuted.selector).topics[2]));

        req = _req(mgr, abi.encodeCall(GainsVault.increaseTrade, (idx, uint120(500e6), uint24(10_000), p, uint16(1_000))));
        _expectPending(GTrade.MARKET_PARTIAL_OPEN, true, "8 partial open with collateral holds");
        _rollFresh(1);
        _fill(req, p);

        req = _req(mgr, abi.encodeCall(GainsVault.increaseTrade, (idx, uint120(0), uint24(2_000), p, uint16(1_000))));
        _expectPending(GTrade.MARKET_PARTIAL_OPEN, false, "8 leverage-only increase holds nothing");
        _rollFresh(1);
        _fill(req, p);

        uint24 lev = _trade(idx).leverage;
        req = _req(mgr, abi.encodeCall(GainsVault.updateLeverage, (idx, lev + 2_000)));
        _expectPending(GTrade.UPDATE_LEVERAGE, false, "7 leverage increase holds nothing");
        _rollFresh(1);
        _fill(req, p);

        req = _req(mgr, abi.encodeCall(GainsVault.updateLeverage, (idx, lev)));
        _expectPending(GTrade.UPDATE_LEVERAGE, true, "7 leverage decrease holds the delta");
        _rollFresh(1);
        _fill(req, p);

        _passHold(); // GR2-KEY-01b (WP5 port): the manager's reduce and close wait the 10-minute minimum hold
        req = _req(mgr, abi.encodeCall(GainsVault.reduceTrade, (idx, uint120(300e6), uint24(0), p)));
        _expectPending(GTrade.MARKET_PARTIAL_CLOSE, false, "9 partial close holds nothing");
        _rollFresh(1);
        _fill(req, p);

        req = _req(mgr, abi.encodeCall(GainsVault.closeTrade, (idx, p)));
        _expectPending(GTrade.MARKET_CLOSE, false, "1 close holds nothing");
        _rollFresh(1);
        _fill(req, p);
        assertFalse(_trade(idx).isOpen);
        assertEq(_pending().length, 0);
    }

    /// @notice Types Gains files under the CALLER, not the trader: a bot's TP trigger (4) and anyone's manual holding
    ///         fee (12) and negative PnL (13) realization on the vault's trade. None appears in the vault's pending
    ///         list, none holds settle; the vault can still close; NAV after their fills is compared with before.
    function test_R2_GV02_ordersThirdPartiesCreateOnTheVaultsTrade() public {
        _depositSettle(alice, 100_000e6);
        uint32 idx = _openFilledV(ETH, true, 5_000e6, 20_000);
        IGainsDiamond.Id memory id = IGainsDiamond.Id(address(v), idx);

        // a TP trigger by a bot
        uint64 tp = (cl[ETH_USD] * 101) / 100;
        vm.prank(mgr);
        v.setSlTp(idx, 0, tp);
        Vm.Log[] memory trig = _trigger(bot, T_TP, idx);
        assertGt(X.getTradePendingOrderBlock(id, T_TP), 0, "Gains marks the trade");
        assertEq(_pending().length, 0, "4 TP_CLOSE is filed under the bot");
        assertFalse(v.ordersPending());
        assertEq(D.getPendingOrders(bot).length, 1);
        _rollFresh(1);
        _fill(trig, cl[ETH_USD]); // below the TP: Gains cancels the trigger
        assertTrue(_trade(idx).isOpen);

        // manual realizations by a stranger, after a 2% loss and a day of holding fees
        _move(ETH, -200);
        _rollFresh(345_600);
        uint256 nav0 = _nav();
        for (uint256 k; k < 2; ++k) {
            uint8 kind = k == 0 ? 12 : 13;
            vm.recordLogs();
            vm.prank(stranger);
            (bool ok, bytes memory ret) = address(D).call(abi.encodeCall(IGainsR2.initiateManualNegativePnlRealization, (address(v), idx, k == 0)));
            Vm.Log[] memory r = vm.getRecordedLogs();
            if (!ok) {
                console2.log("manual realization refused by Gains, type", kind);
                console2.logBytes(ret);
                continue;
            }
            assertEq(_pending().length, 0, "filed under the stranger");
            assertEq(D.getPendingOrders(stranger).length, 1);
            assertFalse(v.ordersPending(), "settle does not wait");
            _rollFresh(1);
            _fill(r, cl[ETH_USD]);
            uint256 nav1 = _nav();
            console2.log("type, NAV before, after its fill", kind, nav0, nav1);
            assertApproxEqAbs(nav1, nav0, 2e6, "a realization moves value inside Gains, not out of the trade");
            nav0 = nav1;
        }

        // the vault still closes and settles
        Vm.Log[] memory c = _req(mgr, abi.encodeCall(GainsVault.closeTrade, (idx, cl[ETH_USD])));
        _rollFresh(1);
        uint256 usdc0 = _usdc();
        _fill(c, cl[ETH_USD]);
        uint256 paid = _usdc() - usdc0;
        console2.log("NAV before the close, USDC paid, NAV after", nav0, paid, _nav());
        assertFalse(_trade(idx).isOpen);
        // NAV valued the trade at the adverse edge (20 bps of 100k notional) net of the closing fee: the close at the
        // mid lands within that of it
        assertApproxEqAbs(_nav(), nav0, 400e6, "the realizations left NAV and the payout consistent");
        _rollFresh(4 * 3_600);
        v.checkRisk();
        vm.prank(keeper);
        v.settle();
    }

    // ==================================================================
    // Item 5: gas at 20 positions
    // ==================================================================
    function _fill20(bool mixed, uint16 only) internal {
        _depositSettle(alice, 100_000e6);
        uint16[3] memory pairs = [BTC, ETH, SOL];
        uint256 n = v.venue().orders;
        while (n < v.MAX_POSITIONS()) {
            _openFilledV(mixed ? pairs[n % 3] : only, n % 2 == 0, 400e6, 3_000);
            n = v.venue().orders;
        }
        assertEq(n, 20);
    }

    function _headroom(string memory what, uint256 g) internal pure {
        console2.log(what, g);
        console2.log("  headroom to 32M (gas, % of the limit)", ARB_TX_LIMIT - g, ((ARB_TX_LIMIT - g) * 100) / ARB_TX_LIMIT);
        assertLt(g, ARB_TX_LIMIT, what);
    }

    function test_R2_gas_settleTotalAssetsCheckRisk_20Trades() public {
        _fill20(true, 0);
        (uint256 gTa,) = _gas(address(this), abi.encodeCall(GainsVault.totalAssets, ()));
        _headroom("gas totalAssets (20 trades, BTC/ETH/SOL)", gTa);
        _rollFresh(4 * 3_600);
        (uint256 gCr,) = _gas(keeper, abi.encodeCall(GainsVault.checkRisk, ()));
        _headroom("gas checkRisk (20 trades)", gCr);

        vm.prank(bob);
        v.requestDeposit(1_000e6, bob);
        uint256 shares = v.balanceOf(alice) / 100;
        vm.prank(alice);
        v.requestRedeem(shares, alice, alice);
        _rollFresh(4 * 3_600);
        v.checkRisk();
        (uint256 gS,) = _gas(keeper, abi.encodeCall(GainsVault.settle, ()));
        _headroom("gas settle with deposits + a redemption (20 trades)", gS);
        assertEq(v.pendingDepositAssets(), 0, "deposits priced");

        vm.prank(alice);
        v.requestRedeem(shares, alice, alice);
        _rollFresh(4 * 3_600);
        v.checkRisk();
        (uint256 gR,) = _gas(keeper, abi.encodeCall(GainsVault.settle, ()));
        _headroom("gas settle, redemption only (20 trades)", gR);
        (uint256 gV,) = _gas(address(this), abi.encodeCall(GainsVault.venue, ()));
        _headroom("gas venue() view, both edges (20 trades)", gV);
    }

    function test_R2_gas_flattenAndFlattenIndices_20Trades() public {
        _fill20(false, ETH);
        IGainsDiamond.Trade[] memory t = D.getTrades(address(v));
        uint32[] memory ix = new uint32[](t.length);
        for (uint256 i; i < t.length; ++i) {
            ix[i] = t[i].index;
        }
        uint256 snap = vm.snapshotState();
        (uint256 g1,) = _gas(fGuardian, abi.encodeCall(GainsVault.flatten, (ETH, uint256(0), cl[ETH_USD], type(uint256).max)));
        _headroom("gas flatten (20 ETH trades, one call)", g1);
        assertEq(_pending().length, 20);
        vm.revertToState(snap);
        (uint256 g2,) = _gas(fGuardian, abi.encodeCall(GainsVault.flattenIndices, (ix, uint256(0), cl[ETH_USD])));
        _headroom("gas flattenIndices (20 indices, one call)", g2);
        assertEq(_pending().length, 20);
    }
}
