// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {GainsVault} from "../../../src/gains/GainsVault.sol";
import {IGainsDiamond} from "../../../src/gains/IGainsDiamond.sol";
import {OpenParams} from "../../../src/gains/GainsTypes.sol";
import {CIWorld} from "../gains/r2/ConservationWorld.sol";
import {CIHandler, CIValuer} from "../gains/r2/ConservationHandler.sol";
import {WP5Diamond} from "./WP5-INV-GainsDiamond.sol";

/// @notice WP5 (fix round): the Gains round 2 conservation handler (CIHandler) plus a stolen-agent actor. Every `sa*`
///         action calls the vault from the agent address with fuzzed arguments, on every entry point the agent can
///         reach (and the role-gated ones, which must revert). Then "Gains" resolves the agent's request at a price
///         the thief pushed: the Chainlink mid moved against the vault by up to PUSH_MAX_BPS (Gains executes at the
///         oracle plus spread and impact; the push stands for the impact a thief can buy), accepted only within the
///         order's own slippage of its expected price, otherwise Gains cancels it in the callback (gov fee kept).
///
///         Loss accounting (independent of the vault): the depositors' value is idle USDC + the venue at the Chainlink
///         mid (CIValuer). Each agent action is measured at constant prices from before the request to after its
///         resolution; a fall is value lost to the agent's action. Per action it must stay within the code-derived
///         bound: notional x (PUSH_MAX + 2 x fee rate + spread) + min-fee and gov-fee floors + rounding.
contract WP5GainsStolenAgentHandler is CIHandler {
    using Math for uint256;

    uint256 public immutable pushMaxBps;
    uint256 public immutable dailyLossBps;
    uint256 public constant TURNOVER_MULTIPLE = 20; // GainsTypes TURNOVER_NAV_MULTIPLE
    /// @dev Rounding of the mock's value math per action (0.1 USDC, Gains' minimum fee): smoke and heavy runs found up to
    ///      0.042 USDC on a dust trade (1 wei collateral at 779x after leverage updates).
    uint256 public constant DUST = 1e5;
    WP5Diamond internal immutable d5;

    // ---------------- coverage ----------------
    uint256 public saCalls;
    uint256 public saOpens; // requests accepted (market, limit, stop)
    uint256 public saFills; // agent requests resolved by a fill / execution at a pushed price
    uint256 public saCloses; // close / reduce requests accepted
    uint256 public saCloseFills;
    uint256 public saIncreases;
    uint256 public saLeverageUpdates;
    uint256 public saSlTps;
    uint256 public saTriggers; // TP / SL the agent set, executed by Gains at a pushed price
    uint256 public saCallbackCancels;
    uint256 public saReverted;
    uint256 public saPublicOk;
    uint256 public saSettles;
    uint256 public saRebinds;
    uint256 public saForbiddenReverted;
    uint256 public saHoldWaits;

    // ---------------- violations (must stay 0) ----------------
    uint256 public vActionOverBound; // an agent action lost more than its per-action bound
    uint256 public vOutsidePolicy; // an agent open / increase accepted on a pair outside the policy
    uint256 public vUncappedPair; // an agent open accepted on the pair with no skew cap (pair 2)
    uint256 public vPairCap; // the vault's notional on a pair above its 1 % skew-depth cap after an agent request
    uint256 public vTurnover; // agent opened notional in a UTC day above 2 x 20 x NAV (token bucket: full + one day of refill)
    uint256 public vForbidden; // a role-gated call went through for the agent
    uint256 public vHold; // an agent close / reduce accepted inside the 10-minute hold (outside a breach)

    // ---------------- per UTC day ----------------
    mapping(uint256 day => uint256) public lossDay;
    mapping(uint256 day => uint256) public boundDay; // sum of the per-action bounds
    mapping(uint256 day => uint256) public ntlDay; // notional of the agent's resolved actions
    mapping(uint256 day => uint256) public openNtlDay; // agent opened notional (turnover formula)
    mapping(uint256 day => uint256) public navMaxDay;
    uint256[] public days_;
    mapping(uint256 => bool) internal _seen;
    uint256 public lossTotal;
    uint256 public maxActionLoss;

    constructor(CIWorld w_, CIValuer valuer_, uint256 pushMax_, uint256 dailyLoss_) CIHandler(w_, valuer_) {
        pushMaxBps = pushMax_;
        dailyLossBps = dailyLoss_;
        d5 = WP5Diamond(address(w_.diamond()));
    }

    function daysCount() external view returns (uint256) {
        return days_.length;
    }

    function _today() internal returns (uint256 d) {
        d = _now() / 1 days;
        if (!_seen[d]) {
            _seen[d] = true;
            days_.push(d);
        }
        uint256 n = idleNow() + venueNow().fav; // the largest NAV any read of the vault can show
        if (n > navMaxDay[d]) navMaxDay[d] = n;
    }

    function _value() internal view returns (uint256) {
        return idleNow() + venueNow().mid;
    }

    function _pxOf(uint16 pair) internal view returns (uint64) {
        if (pair == 0) return btcPx;
        if (pair == 1) return ethPx;
        return 150e10;
    }

    /// @dev The adverse pushed price: a long buys higher and sells lower, a short the other way round.
    function _pushed(uint64 mid, bool buy, uint256 pushBps) internal pure returns (uint64) {
        return uint64(buy ? (uint256(mid) * (BPS + pushBps)) / BPS : (uint256(mid) * (BPS - pushBps)) / BPS);
    }

    function _accepts(uint64 fill, uint64 expected, uint256 maxSlippageP) internal pure returns (bool) {
        if (expected == 0) return false;
        uint256 dev = fill > expected ? fill - expected : expected - fill;
        return dev * 100_000 <= uint256(expected) * maxSlippageP; // maxSlippageP: 1e3 precision percent
    }

    /// @dev Per-action bound: notional x (push + 2 x fee rate + spread), the fee floors on the minimum position, the gov
    ///      fee a cancel keeps, the 10 % of collateral Gains keeps at a liquidation (-90 %) the push may trigger, and
    ///      rounding (1e-9 of the notional + 10 wei). The push is taken against the mid but pnl against the fill: a
    ///      short filled p below the mid moves p / (1 - p) of its open price back to the mid, so the push term is that.
    function _actionBound(uint16 pair, uint256 ntl, uint256 coll) internal view returns (uint256 b) {
        (uint256 feeP, uint256 minPos,, uint256 spreadP,) = d5.pairCfg(pair);
        uint256 minSize = minPos / 1e12;
        uint256 basis = ntl < minSize ? minSize : ntl;
        b = Math.mulDiv(ntl, pushMaxBps, BPS - pushMaxBps, Math.Rounding.Ceil) + (2 * basis * feeP) / 1e12 + (ntl * spreadP) / 1e12 + d5.minGovFee(pair) + coll / 10 + ntl / 1e9 + DUST;
    }

    function _bookLoss(uint256 day, uint256 v0, uint16 pair, uint256 ntl, uint256 coll) internal {
        uint256 v1 = _value();
        uint256 loss = v0 > v1 ? v0 - v1 : 0;
        uint256 b = _actionBound(pair, ntl, coll);
        if (loss > b) {
            ++vActionOverBound;
        }
        if (loss > maxActionLoss) maxActionLoss = loss;
        lossDay[day] += loss;
        boundDay[day] += b;
        ntlDay[day] += ntl;
        lossTotal += loss;
    }

    function _pairOf(uint256 seed) internal pure returns (uint16) {
        uint256 k = seed % 12;
        if (k < 5) return 0;
        if (k < 10) return 1;
        if (k == 10) return 2; // in the policy, no skew cap: fail closed
        return uint16(3 + (seed >> 8) % 60); // outside the policy
    }

    function _pairNotional(uint16 pair) internal view returns (uint256 n) {
        IGainsDiamond.Trade[] memory t = diamond.getTrades(address(vault));
        uint64 px = _pxOf(pair);
        for (uint256 i; i < t.length; ++i) {
            if (t[i].pairIndex != pair) continue;
            if (t[i].tradeType == 0) n += (uint256(t[i].positionSizeToken) * px) / 1e22;
            else n += (uint256(t[i].collateralAmount) * t[i].leverage) / 1e3;
        }
        uint32 c = diamond.orderCount(address(vault));
        for (uint32 i; i < c; ++i) {
            IGainsDiamond.PendingOrder memory o = diamond.getRealOrder(address(vault), i);
            if (!o.isOpen || o.trade.pairIndex != pair) continue;
            if (o.orderType == 0 || o.orderType == 8) n += (uint256(o.trade.collateralAmount) * (o.orderType == 0 ? o.trade.leverage : o.trade.leverage)) / 1e3;
        }
    }

    function _pairCap(uint16 pair) internal view returns (uint256) {
        uint256 depth = diamond.getPairSkewDepth(3, pair);
        return Math.mulDiv(depth, _pxOf(pair), 1e22) * 100 / BPS;
    }

    // ==================================================================
    // Stolen agent: opens (market, limit, stop), resolved by "Gains" at a pushed price
    // ==================================================================
    struct OpenIn {
        uint256 pairSeed;
        bool long;
        uint256 pct;
        uint256 lev;
        uint256 kind;
        uint256 pxSeed;
        uint256 slip;
        uint256 tpsl;
        uint256 outcome;
        uint256 push;
    }

    function saOpen(OpenIn calldata x) external {
        ++saCalls;
        uint256 day = _today();
        uint16 pair = _pairOf(x.pairSeed);
        uint64 mid = _pxOf(pair);
        uint256 idle = idleNow();
        uint24 lev = uint24(x.lev % 8 == 0 ? bound(x.lev >> 3, 0, type(uint24).max) : bound(x.lev, 1_100, 60_000));
        // size by notional (1k to 300k, around the policy's 250k per order), collateral = notional / leverage
        uint256 c = x.pct % 16 == 0 ? bound(x.pct >> 4, 0, type(uint120).max) : (bound(x.pct, 1_000e6, 300_000e6) * 1e3) / (lev == 0 ? 1 : lev);
        if (x.pct % 16 != 0 && c > idle) c = idle;
        if (c > type(uint120).max) c = type(uint120).max;
        uint8 tt = uint8(x.kind % 9 < 6 ? 0 : x.kind % 9 == 6 ? 1 : x.kind % 9 == 7 ? 2 : 3 + (x.kind >> 8) % 250);
        uint64 ep = _expected(mid, x.long, x.pxSeed);
        uint16 slip = uint16(x.slip % 4 == 0 ? bound(x.slip >> 2, 0, type(uint16).max) : bound(x.slip, 1, 3_000));
        (uint64 tp, uint64 sl) = _tpsl(mid, x.long, x.tpsl);
        OpenParams memory p = OpenParams(pair, x.long, uint120(c), lev, ep, slip, tp, sl, tt);
        uint256 v0 = _value();
        uint256 toD0 = usdc.toDiamond();
        uint256 el0 = diamond.escrowLedger(address(vault));
        uint32 o = diamond.orderCount(address(vault));
        uint32 ti = diamond.tradeCount(address(vault));
        vm.prank(A);
        try vault.openTrade(p) {
            ++saOpens;
            agentRiskAt[pair] = _now();
            _pulled(toD0, el0, c);
            uint256 ntl = (c * lev) / 1e3;
            openNtlDay[day] += ntl;
            if (pair > 2) ++vOutsidePolicy;
            if (pair == 2) ++vUncappedPair;
            if (pair < 2 && _pairNotional(pair) > _pairCap(pair) + _pairCap(pair) / 50 + 1e6) ++vPairCap;
            if (openNtlDay[day] > 2 * TURNOVER_MULTIPLE * navMaxDay[day]) ++vTurnover;
            if (tt == 0) {
                uint256 w_ = x.outcome % 4;
                if (w_ == 1) {
                    try diamond.cancelInCallback(address(vault), o) {
                        ++saCallbackCancels;
                    } catch {}
                } else if (w_ >= 2) {
                    uint64 fpx = _pushed(mid, x.long, bound(x.push, 0, pushMaxBps));
                    if (_accepts(fpx, ep, slip)) {
                        try diamond.fill(address(vault), o, fpx) {
                            ++saFills;
                        } catch {}
                    } else {
                        try diamond.cancelInCallback(address(vault), o) {
                            ++saCallbackCancels;
                        } catch {}
                    }
                }
            } else if (x.outcome % 3 == 0) {
                // Gains' bot executes the resting order at the oracle (pushed); real Gains: at the trigger or the oracle
                try diamond.executeLimit(address(vault), ti, _pushed(mid, x.long, bound(x.push, 0, pushMaxBps))) {
                    ++saFills;
                } catch {}
            }
            _bookLoss(day, v0, pair, ntl, c);
        } catch {
            ++saReverted;
        }
    }

    function _expected(uint64 mid, bool long, uint256 seed) internal view returns (uint64) {
        uint256 k = seed % 8;
        uint256 b = policy.config().maxSlippageBps;
        uint256 off;
        if (k < 4) off = b; // the adverse band edge
        else if (k == 4) off = bound(seed >> 8, 0, b);
        else if (k == 5) off = b + bound(seed >> 8, 1, 500); // outside the band: refused for a market order
        else if (k == 6) return uint64(bound(seed >> 8, 1, type(uint64).max)); // far off (limit / stop: no band check)
        else return mid;
        uint256 dv = (uint256(mid) * off) / BPS;
        return uint64(long ? uint256(mid) + dv : uint256(mid) - dv);
    }

    function _tpsl(uint64 mid, bool long, uint256 seed) internal pure returns (uint64 tp, uint64 sl) {
        uint256 k = seed % 4;
        if (k == 0) return (0, 0);
        if (k == 3) return (uint64(seed >> 64), uint64(seed >> 128));
        uint256 a = 1 + (seed >> 8) % 3_000; // up to 30 %
        uint256 up = (uint256(mid) * (BPS + a)) / BPS;
        uint256 dn = (uint256(mid) * (BPS - a)) / BPS;
        (tp, sl) = long ? (uint64(up), uint64(dn)) : (uint64(dn), uint64(up));
        if (k == 2) (tp, sl) = (sl, tp); // wrong side
    }

    // ==================================================================
    // Stolen agent: exits (close, reduce) on any trade, resolved at a pushed price
    // ==================================================================
    function saClose(uint256 k, bool reduce, uint256 pct, uint256 pxSeed, uint256 push, uint256 waitSeed, uint256 outcome) external {
        ++saCalls;
        (bool ok, IGainsDiamond.Trade memory t) = _trade(k);
        if (!ok) return;
        if (waitSeed % 2 == 0) {
            // wait out the 10-minute hold (and Gains' block clock for the trade's own hold)
            _skip(10 minutes + 1);
            vm.roll(_blk() + 2_401);
            ++saHoldWaits;
        }
        uint256 day = _today();
        uint64 mid = _pxOf(t.pairIndex);
        // the vault never checks an exit's expected price: anything
        uint64 ep = pxSeed % 3 == 0 ? uint64(bound(pxSeed >> 2, 1, type(uint64).max)) : _pushed(mid, !t.long, bound(pxSeed >> 2, 0, 2 * pushMaxBps));
        uint120 delta = uint120((uint256(t.collateralAmount) * bound(pct, 1, 99)) / 100);
        bool held = !vault.breached() && !vault.emergency();
        uint256 v0 = _value();
        uint32 o = diamond.orderCount(address(vault));
        bool sent;
        vm.prank(A);
        if (reduce) {
            try vault.reduceTrade(t.index, delta, uint24(pct % 7 == 0 ? pct >> 8 : 0), ep) {
                sent = true;
            } catch {}
        } else {
            try vault.closeTrade(t.index, ep) {
                sent = true;
            } catch {}
        }
        if (!sent) {
            ++saReverted;
            return;
        }
        ++saCloses;
        if (held && !_holdOk(t)) ++vHold;
        uint256 ntl = t.tradeType == 0 ? (uint256(t.positionSizeToken) * mid) / 1e22 : 0;
        if (reduce) ntl = (ntl * delta) / t.collateralAmount + 1;
        if (diamond.getRealOrder(address(vault), o).isOpen && diamond.getRealOrder(address(vault), o).orderType != 0) {
            uint256 w_ = outcome % 4;
            if (w_ == 1) {
                try diamond.cancelInCallback(address(vault), o) {
                    ++saCallbackCancels;
                } catch {}
            } else if (w_ >= 2) {
                // a close sells a long (lower is adverse) and buys back a short
                uint64 fpx = _pushed(mid, !t.long, bound(push, 0, pushMaxBps));
                uint16 cs = diamond.getTradeInfo(address(vault), t.index).maxSlippageP;
                if (_accepts(fpx, ep, cs)) {
                    try diamond.fill(address(vault), o, fpx) {
                        ++saCloseFills;
                    } catch {}
                } else {
                    try diamond.cancelInCallback(address(vault), o) {
                        ++saCallbackCancels;
                    } catch {}
                }
            }
        }
        _bookLoss(day, v0, t.pairIndex, ntl, t.collateralAmount);
    }

    /// @dev The 10-minute hold after the agent's own last new-risk request on the pair (the vault's pairRiskAt also
    ///      counts the manager's, which this handler does not see) and the trade's own hold (its last increase on
    ///      Gains' block clock, block.number off Arbitrum), as GainsNav.checkHold reads them.
    mapping(uint16 => uint256) public agentRiskAt;

    function _holdOk(IGainsDiamond.Trade memory t) internal view returns (bool) {
        uint256 riskAt = agentRiskAt[t.pairIndex];
        uint256 inc = diamond.getTradeInfo(address(vault), t.index).lastPosIncreaseBlock;
        return !((riskAt != 0 && _now() < riskAt + 10 minutes) || (inc != 0 && _blk() < inc + 2_400));
    }

    // ==================================================================
    // Stolen agent: increase, leverage, TP / SL, cancels
    // ==================================================================
    function saIncrease(uint256 k, uint256 pct, uint256 ld, uint256 pxSeed, uint256 slip, uint256 push, uint256 outcome) external {
        ++saCalls;
        (bool ok, IGainsDiamond.Trade memory t) = _trade(k);
        if (!ok) return;
        uint256 day = _today();
        uint64 mid = _pxOf(t.pairIndex);
        uint24 l = uint24(bound(ld, 0, 60_000));
        uint256 cc = pct % 4 == 0 ? 0 : (bound(pct, 1_000e6, 300_000e6) * 1e3) / (l == 0 ? 1 : l);
        if (cc > idleNow()) cc = idleNow();
        uint120 c = uint120(cc);
        uint64 ep = _expected(mid, t.long, pxSeed);
        uint16 s = uint16(slip % 4 == 0 ? slip >> 2 : bound(slip, 1, 3_000));
        uint256 v0 = _value();
        uint256 toD0 = usdc.toDiamond();
        uint256 el0 = diamond.escrowLedger(address(vault));
        uint32 o = diamond.orderCount(address(vault));
        vm.prank(A);
        try vault.increaseTrade(t.index, c, l, ep, s) {
            ++saIncreases;
            agentRiskAt[t.pairIndex] = _now();
            _pulled(toD0, el0, c);
            uint256 ntl = ((c == 0 ? uint256(t.collateralAmount) : c) * l) / 1e3;
            openNtlDay[day] += ntl;
            if (openNtlDay[day] > 2 * TURNOVER_MULTIPLE * navMaxDay[day]) ++vTurnover;
            if (t.pairIndex < 2 && _pairNotional(t.pairIndex) > _pairCap(t.pairIndex) + _pairCap(t.pairIndex) / 50 + 1e6) ++vPairCap;
            if (outcome % 3 == 1) {
                try diamond.cancelInCallback(address(vault), o) {
                    ++saCallbackCancels;
                } catch {}
            } else if (outcome % 3 == 2) {
                uint64 fpx = _pushed(mid, t.long, bound(push, 0, pushMaxBps));
                // Gains cancels a position update on a trade at or past its liquidation price (LIQ_REACHED)
                if (_accepts(fpx, ep, s) && diamond.closeValue(address(vault), t.index, fpx) != 0) {
                    try diamond.fill(address(vault), o, fpx) {
                        ++saFills;
                    } catch {}
                } else {
                    try diamond.cancelInCallback(address(vault), o) {
                        ++saCallbackCancels;
                    } catch {}
                }
            }
            _bookLoss(day, v0, t.pairIndex, ntl, uint256(t.collateralAmount) + c);
        } catch {
            ++saReverted;
        }
    }

    function saLeverage(uint256 k, uint256 lev, uint256 outcome) external {
        ++saCalls;
        (bool ok, IGainsDiamond.Trade memory t) = _trade(k);
        if (!ok) return;
        uint256 day = _today();
        uint24 nl = uint24(lev % 8 == 0 ? lev >> 3 : bound(lev, 1_000, 60_000));
        uint256 delta = nl != 0 && nl < t.leverage ? (uint256(t.collateralAmount) * t.leverage) / nl - t.collateralAmount : 0;
        uint256 v0 = _value();
        uint256 toD0 = usdc.toDiamond();
        uint256 el0 = diamond.escrowLedger(address(vault));
        uint32 o = diamond.orderCount(address(vault));
        vm.prank(A);
        try vault.updateLeverage(t.index, nl) {
            ++saLeverageUpdates;
            _pulled(toD0, el0, delta);
            // Gains validates the update: the pair's max leverage, the minimum collateral, not at liquidation
            (,, uint256 minFee,, uint256 maxLev) = d5.pairCfg(t.pairIndex);
            uint256 newColl = nl == 0 ? 0 : (uint256(t.collateralAmount) * t.leverage) / nl;
            bool valid = nl <= maxLev && newColl >= (5 * minFee) / 1e12;
            if (outcome % 2 == 0 && valid && diamond.closeValue(address(vault), t.index, _pxOf(t.pairIndex)) != 0) {
                try diamond.fill(address(vault), o, _pxOf(t.pairIndex)) {} catch {}
            } else {
                try diamond.cancelInCallback(address(vault), o) {
                    ++saCallbackCancels;
                } catch {}
            }
            _bookLoss(day, v0, t.pairIndex, 0, uint256(t.collateralAmount) + delta);
        } catch {
            ++saReverted;
        }
    }

    /// @dev The agent sets any TP / SL; Gains may then execute it. Real Gains executes a TP / SL exactly at the
    ///      trigger only when the oracle range reached it, otherwise at the current oracle price (KEYS.md GR2-KEY-02):
    ///      here at the mid pushed against the vault.
    function saSlTp(uint256 k, uint256 seed, uint256 push, bool fire) external {
        ++saCalls;
        (bool ok, IGainsDiamond.Trade memory t) = _trade(k);
        if (!ok || t.tradeType != 0) return;
        uint256 day = _today();
        uint64 mid = _pxOf(t.pairIndex);
        (uint64 tp, uint64 sl) = _tpsl(mid, t.long, seed);
        vm.prank(A);
        try vault.setSlTp(t.index, sl, tp) {
            ++saSlTps;
        } catch {
            ++saReverted;
            return;
        }
        if (!fire) return;
        uint256 v0 = _value();
        uint256 ntl = (uint256(t.positionSizeToken) * mid) / 1e22;
        try diamond.trigger(address(vault), t.index, _pushed(mid, !t.long, bound(push, 0, pushMaxBps))) {
            ++saTriggers;
        } catch {}
        _bookLoss(day, v0, t.pairIndex, ntl, t.collateralAmount);
    }

    function saCancelResting(uint256 k, uint32 rawIndex, bool raw) external {
        ++saCalls;
        uint32 idx = rawIndex;
        if (!raw) {
            (bool ok, IGainsDiamond.Trade memory t) = _trade(k);
            if (!ok) return;
            idx = t.index;
        }
        uint256 day = _today();
        uint256 v0 = _value();
        vm.prank(A);
        try vault.cancelOrder(idx) {
            _bookLoss(day, v0, 0, 0, 0);
        } catch {
            ++saReverted;
        }
    }

    function saCancelTimedOut(uint256 k, bool roll) external {
        ++saCalls;
        if (roll) vm.roll(_blk() + 201);
        (bool ok, IGainsDiamond.PendingOrder memory o) = _order(k);
        if (!ok) return;
        uint256 day = _today();
        uint256 v0 = _value();
        vm.prank(A);
        try vault.cancelTimedOut(o.index) {
            nTimeouts++;
            _bookLoss(day, v0, 0, 0, 0);
        } catch {}
    }

    // ==================================================================
    // Stolen agent: permissionless calls, settle, claims for others, and the calls it must not get through
    // ==================================================================
    function saPublic(uint256 k) external {
        ++saCalls;
        uint256 who = k >> 8;
        k = k % 6;
        Pre memory p = _pre(A);
        bool ok;
        if (k == 5) {
            address a = actors[who % 5];
            Exp memory x = _expect(a);
            Flow memory f = _flow(a);
            usdc.expect(a);
            vm.prank(A);
            try vault.claim(a) {
                ok = true;
                _book(x, usdc.paidTo(a) - f.paidA, vault.balanceOf(a) - f.sharesA);
            } catch {}
            usdc.expect(address(0));
            if (ok) ++saPublicOk;
            return;
        }
        vm.prank(A);
        if (k == 0) (ok,) = address(vault).call(abi.encodeCall(GainsVault.checkRisk, ()));
        else if (k == 1) (ok,) = address(vault).call(abi.encodeCall(GainsVault.clearLeverageBreach, ()));
        else if (k == 2) (ok,) = address(vault).call(abi.encodeCall(GainsVault.syncIndexes, (k)));
        else if (k == 3) (ok,) = address(vault).call(abi.encodeCall(GainsVault.triggerEmergency, ())); // overdue only
        else if (k == 4) {
            (ok,) = address(vault).call(abi.encodeCall(GainsVault.accrueFees, ()));
            if (ok) _checkFees(p, vault.totalSupply() - p.supply, false);
        }
        if (ok) ++saPublicOk;
    }

    function saSettle(uint256 prep) external {
        ++saCalls;
        _skip(bound(prep, 1, 2 hours));
        uint256 n0 = nSettles;
        _settleAs(A);
        if (nSettles != n0) ++saSettles;
    }

    function saForbidden(uint256 k, uint256 a) external {
        ++saCalls;
        k = k % 22;
        bytes memory c;
        if (k == 0) c = abi.encodeCall(GainsVault.flatten, (uint16(a % 2), 0, btcPx, type(uint256).max));
        else if (k == 1) c = abi.encodeCall(GainsVault.flatten, (uint16(a % 2), bound(a, 1, 300), btcPx, 1));
        else if (k == 2) {
            uint32[] memory idx = new uint32[](1);
            idx[0] = uint32(a % 8);
            c = abi.encodeCall(GainsVault.flattenIndices, (idx, 0, btcPx));
        } else if (k == 3) c = abi.encodeCall(GainsVault.triggerBreach, ());
        else if (k == 4) c = abi.encodeCall(GainsVault.clearBreach, ());
        else if (k == 5) c = abi.encodeCall(GainsVault.exitEmergency, ());
        else if (k == 6) c = abi.encodeCall(GainsVault.resume, ());
        else if (k == 7) c = abi.encodeCall(GainsVault.setOperator, (A));
        else if (k == 8) c = abi.encodeCall(GainsVault.revokeOperator, ());
        else if (k == 9) c = abi.encodeCall(GainsVault.setDepositsPaused, (a % 2 == 0));
        else if (k == 10) c = abi.encodeCall(GainsVault.setTradingPaused, (a % 2 == 0));
        else if (k == 11) c = abi.encodeCall(GainsVault.setDepositCap, (a));
        else if (k == 12) c = abi.encodeCall(GainsVault.lowerFees, (0, 0));
        else if (k == 13) c = abi.encodeCall(GainsVault.rescueToken, (IERC20(address(usdc)), A));
        else if (k == 14) c = abi.encodeCall(GainsVault.queue, (abi.encodeCall(GainsVault.setFees, (500, 3_000))));
        else if (k == 15) c = abi.encodeCall(GainsVault.setAgent, (A));
        else if (k == 16) c = abi.encodeCall(GainsVault.revokeAgent, ());
        else if (k == 17) c = abi.encodeCall(GainsVault.leaveHosted, ());
        else if (k == 18) c = abi.encodeCall(GainsVault.lowerProtocolShare, (0));
        else if (k == 19) c = abi.encodeWithSignature("transferOwnership(address)", A);
        else if (k == 20) c = abi.encodeCall(GainsVault.setFees, (500, 3_000));
        else c = abi.encodeCall(GainsVault.setManager, (A));
        vm.prank(A);
        (bool ok,) = address(vault).call(c);
        if (ok) ++vForbidden;
        else ++saForbiddenReverted;
    }

    /// @dev After a full stop revoked it, the owner binds the same (stolen) agent again through the timelock.
    function saRebind(uint256 s) external {
        if (vault.agent() != address(0) || s % 3 != 0) return;
        bytes memory data = abi.encodeCall(GainsVault.setAgent, (A));
        vm.prank(M);
        try vault.queue(data) returns (bytes32 id) {
            uint256 eta = vault.queuedEta(id);
            if (eta > _now() + 15 days) return;
            if (eta > _now()) _skip(eta - _now());
            vm.prank(X);
            try vault.execute(data) {
                ++saRebinds;
            } catch {}
        } catch {}
    }

    function dayAt(uint256 i) external view returns (uint256) {
        return days_[i];
    }

    /// @dev Largest agent loss of a UTC day as bps of that day's largest NAV (measured, reported).
    function maxDayLossBps() external view returns (uint256 m) {
        for (uint256 i; i < days_.length; ++i) {
            uint256 nav = navMaxDay[days_[i]];
            if (nav == 0) continue;
            uint256 b = (lossDay[days_[i]] * BPS) / nav;
            if (b > m) m = b;
        }
    }
}
