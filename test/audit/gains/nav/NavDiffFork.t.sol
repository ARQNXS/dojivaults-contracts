// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import "./NavForkBase.sol";
import {NavDump} from "./NavDump.sol";

/// @notice Differential NAV, fork side (round 1 review, sub-reviewer 3.1). Opens random trades through a GainsVault on
///         the real gTrade v10 diamond (pairs 0, 1, 33; long / short; 2x to 150x), ages them (holding fees over a day),
///         moves Chainlink, runs partial closes, leverage reduces, increases and leverage updates, then closes every
///         trade one at a time. Right before each close fills, it dumps every raw input of the trade's close value
///         plus GainsNav's value (NavDump), and the USDC Gains then pays at that price. A normal run writes nothing;
///         with NAV_DIFF_DUMP=1 the JSON goes to ./deployments/audit-nav-diff-<seed>.json, which is then copied to
///         contracts/audit/gains/nav/data/ (the committed copy); contracts/audit/gains/nav/diff/diff.ts recomputes the
///         value from the gainsnetwork SDK's pieces and compares.
contract NavDiffForkTest is NavForkBase {
    NavDump internal dump;
    uint256 internal rnd;
    string internal out;
    uint256 internal nRec;

    uint16[3] internal PAIRS = [BTC, ETH, SOL];

    function setUp() public override {
        super.setUp();
        if (!forked) return;
        dump = new NavDump(D, harness);
    }

    function _r() internal returns (uint256) {
        rnd = uint256(keccak256(abi.encode(rnd)));
        return rnd;
    }

    function _emit(string memory rec) internal {
        out = nRec == 0 ? rec : string.concat(out, ",\n", rec);
        nRec++;
    }

    function _try(address caller, bytes memory data) internal returns (bool ok, Vm.Log[] memory logs) {
        vm.recordLogs();
        vm.prank(caller);
        (ok,) = address(v).call(data);
        logs = vm.getRecordedLogs();
    }

    /// @dev Fills the vault's single pending order (if any) at `px`.
    function _fillIfAny(Vm.Log[] memory req, uint64 px) internal returns (bool filled) {
        for (uint256 i; i < req.length; i++) {
            if (req[i].topics.length > 0 && req[i].topics[0] == ORACLE_REQUEST) {
                _fill(req, px);
                return true;
            }
        }
        return false;
    }

    /// @dev C x (1 + u) with u uniform in [-maxBps, +maxBps] bps.
    function _jitter(uint64 c, uint256 maxBps) internal returns (uint64) {
        uint256 u = _r() % (2 * maxBps + 1);
        return uint64((uint256(c) * (10_000 * 100 + u * 100 - maxBps * 100)) / (10_000 * 100));
    }

    function _lev(uint16 pair) internal returns (uint24) {
        uint256 b = _r() % 3;
        uint256 lo = b == 0 ? 2_000 : b == 1 ? 10_000 : 50_000;
        uint256 hi = b == 0 ? 10_000 : b == 1 ? 50_000 : 150_000;
        uint256 l = lo + (_r() % (hi - lo + 1));
        uint256 mx = X.pairMaxLeverage(pair);
        uint256 mn = X.pairMinLeverage(pair);
        if (mx != 0 && l > mx) l = mx;
        if (l < mn) l = mn;
        return uint24(l);
    }

    function _openRandom() internal returns (bool) {
        uint16 pair = PAIRS[_r() % 3];
        bool long = _r() % 2 == 0;
        uint24 lev = _lev(pair);
        uint256 minPos = D.getCollateralFromUsdNormalizedValue(3, D.pairMinPositionSizeUsd(pair));
        uint256 minColl = 5 * D.getCollateralFromUsdNormalizedValue(3, D.pairMinFeeUsd(pair));
        uint256 notional = minPos + 500e6 + (_r() % 40_000e6);
        uint256 coll = (notional * 1e3) / lev;
        if (coll < minColl) coll = minColl + 1e6;
        (, bool ok) = _open(v, pair, long, uint120(coll), lev, _jitter(_c(pair), 10));
        return ok;
    }

    function _movePrices(uint256 maxBps) internal {
        for (uint256 i; i < 3; i++) {
            _setPx(PAIRS[i], _jitter(_c(PAIRS[i]), maxBps));
        }
    }

    /// @dev One random position update on trade `t`, filled at C +- 10 bps. Failures (Gains or vault refusals,
    ///      callback cancels) are fine: the trade stays as it is.
    function _randomOp(IGainsDiamond.Trade memory t) internal {
        uint256 k = _r() % 4;
        uint64 c = _c(t.pairIndex);
        bytes memory data;
        if (k == 0) {
            data = abi.encodeCall(GainsVault.reduceTrade, (t.index, uint120((uint256(t.collateralAmount) * 3) / 10), uint24(0), c));
        } else if (k == 1) {
            uint24 d = uint24((uint256(t.leverage) * 3) / 10);
            if (t.leverage - d < X.pairMinLeverage(t.pairIndex) || d == 0) return;
            data = abi.encodeCall(GainsVault.reduceTrade, (t.index, uint120(0), d, c));
        } else if (k == 2) {
            data = abi.encodeCall(GainsVault.increaseTrade, (t.index, uint120((uint256(t.collateralAmount) * 2) / 10), t.leverage, c, uint16(1_000)));
        } else {
            uint24 nl = uint24((uint256(t.leverage) * 7) / 10);
            if (nl < X.pairMinLeverage(t.pairIndex)) return;
            data = abi.encodeCall(GainsVault.updateLeverage, (t.index, nl));
        }
        (bool ok, Vm.Log[] memory req) = _try(mgr, data);
        if (!ok) return;
        _rollFresh(1);
        _fillIfAny(req, _jitter(c, 10));
    }

    /// @dev Closes every open trade of the vault one by one at its adverse band edge P, recording before each fill.
    function _closeAllRecorded(string memory tag) internal {
        _closeAllRecorded(tag, mgr);
    }

    /// @dev `closer`: the manager (held by GR2-KEY-01b's minimum hold) or the guardian (never held).
    function _closeAllRecorded(string memory tag, address closer) internal {
        G.Trade[] memory ts = DIAMOND.getTrades(address(v));
        for (uint256 i; i < ts.length; i++) {
            if (!ts[i].isOpen || ts[i].tradeType != 0) continue;
            uint32 idx = ts[i].index;
            uint16 pair = ts[i].pairIndex;
            uint64 p = _adverseP(pair, ts[i].long);
            Vm.Log[] memory req = _call(v, closer, abi.encodeCall(GainsVault.closeTrade, (idx, p)));
            _rollFresh(1);
            string memory pre = dump.record(tag, address(v), idx, _c(pair), _band(pair), p, false, 0);
            uint256 b = USDC.balanceOf(address(v));
            _fill(req, p);
            uint256 paid = USDC.balanceOf(address(v)) - b;
            // `pre` is the state the fill priced; the payout is attached to it
            _emit(string.concat("{\"rec\":", pre, ",\"paidAmount\":\"", vm.toString(paid), "\"}"));
        }
    }

    function _run(uint256 seed) internal {
        rnd = seed;
        // GR2-KEY-01b (WP5 port): up to 16 random trades of up to ~40k notional can put a pair above 1 % of its skew
        // depth at 517,076,707 (SOL: about 58k); this is a NAV-against-payout diff, not a pair cap test, so the three
        // caps are raised to the 10 % maximum.
        _raisePairCapToMax(BTC);
        _raisePairCapToMax(ETH);
        _raisePairCapToMax(SOL);
        (v, pol) = _create(bytes32(seed), _risk(50_000), 200, 2_000);
        _depositSettle(v, alice, 400_000e6);
        uint256 opened;
        for (uint256 i; i < 16; i++) {
            if (_openRandom()) opened++;
        }
        console2.log("trades opened", opened);
        _rollFresh(345_600); // one day of funding / borrowing
        _movePrices(150);
        G.Trade[] memory ts = DIAMOND.getTrades(address(v));
        for (uint256 i; i < ts.length; i++) {
            if (_r() % 2 == 0) _randomOp(_toI(ts[i]));
        }
        _rollFresh(86_400); // six hours
        _movePrices(60);
        _closeAllRecorded(string.concat("seed", vm.toString(seed)));
    }

    function _toI(G.Trade memory t) internal pure returns (IGainsDiamond.Trade memory r) {
        r.user = t.user;
        r.index = t.index;
        r.pairIndex = t.pairIndex;
        r.leverage = t.leverage;
        r.long = t.long;
        r.isOpen = t.isOpen;
        r.collateralIndex = t.collateralIndex;
        r.tradeType = t.tradeType;
        r.collateralAmount = t.collateralAmount;
        r.openPrice = t.openPrice;
        r.positionSizeToken = t.positionSizeToken;
    }

    function _write(string memory name) internal {
        console2.log("records", nRec);
        if (!vm.envOr("NAV_DIFF_DUMP", false)) return;
        string memory path = string.concat("./deployments/audit-nav-diff-", name, ".json");
        vm.writeFile(path, string.concat("[\n", out, "\n]\n"));
        console2.log("records", nRec, path);
    }

    function test_diff_randomTrades_seed1() public {
        _run(1);
        _write("seed1");
    }

    function test_diff_randomTrades_seed2() public {
        _run(2);
        _write("seed2");
    }

    function test_diff_randomTrades_seed3() public {
        _run(3);
        _write("seed3");
    }

    /// @dev SOL has depth bands: a profitable close within protectionCloseFactorBlocks (750) of the last increase
    ///      pays the 20x cumulative-volume protection factor. Exercise both passes of the close impact.
    function test_diff_solProtectionFactorWindow() public {
        rnd = 77;
        // GR2-KEY-01b (WP5 port): 65k of SOL is above 1 % of SOL's skew depth at 517,076,707; raised to the 10 % maximum
        // (this test is about the protection factor, not the pair cap).
        _raisePairCapToMax(SOL);
        (v, pol) = _create(bytes32(uint256(77)), _risk(50_000), 0, 0);
        _depositSettle(v, alice, 400_000e6);
        uint64 c = _c(SOL);
        (uint32 a,) = _open(v, SOL, true, 2_000e6, 10_000, c);
        (uint32 b,) = _open(v, SOL, false, 2_000e6, 10_000, c);
        (uint32 cc,) = _open(v, SOL, true, 1_000e6, 25_000, c);
        a;
        b;
        cc;
        _rollFresh(100);
        _setPx(SOL, uint64((uint256(c) * 10_150) / 10_000)); // +1.5%: the longs are in profit at P
        // GR2-KEY-01b (WP5 port): the window is 750 L2 blocks from the last increase and the manager's minimum hold is
        // 2,400, so the manager can no longer close inside it; the guardian's close (never held) still exercises the
        // protection factor pass of the close impact.
        _closeAllRecorded("solProtection", fGuardian);
        _write("solProtection");
    }
}
