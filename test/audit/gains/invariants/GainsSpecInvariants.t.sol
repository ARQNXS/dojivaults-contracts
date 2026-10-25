// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {CommonBase} from "forge-std/Base.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {StdUtils} from "forge-std/StdUtils.sol";
import {GainsBase} from "../../../gains/GainsBase.t.sol";
import {GainsVault} from "../../../../src/gains/GainsVault.sol";
import {GainsVaultLens} from "../../../../src/gains/GainsVaultLens.sol";
import {GainsVaultPolicy} from "../../../../src/gains/GainsVaultPolicy.sol";
import {GainsPrice} from "../../../../src/gains/GainsPrice.sol";
import {IGainsDiamond} from "../../../../src/gains/IGainsDiamond.sol";
import {OpenParams, operatorReduceCap, MIN_HOLD, MIN_HOLD_L2_BLOCKS} from "../../../../src/gains/GainsTypes.sol";
import {BreachReason} from "../../../../src/VaultTypes.sol";
import {MockUSDC} from "../../../mocks/Mocks.sol";
import {MockGainsDiamond, MockChainlinkFeed} from "../../../gains/mocks/GainsMocks.sol";

/// @dev Round 1 (brief section 4 "Fuzzing"): SPEC.md properties not covered by test/gains/GainsRound4Invariants.t.sol.
///      Same driving actions (deposits, redemptions, settles by every role, fees, trades that fill / cancel / time
///      out, price moves, funding, liquidations, breaches, emergencies, outages) plus fee raises, policy config
///      changes, operator reduces at and above its cap, and attempts to trade reserved USDC. Every property is a ghost
///      counter that must stay 0, checked by ONE invariant function (one campaign of runs x depth; forge would run a
///      separate campaign per invariant_ function).
///
///      Properties: D1 D4 D5 D6 (claims <= epoch payout, returned shares <= escrow left, claim == lens.claimable)
///      D7 S1 S3 S8 N1 (NAV = idle + independent per-item sum) T4 K1 F2 F3 F4 G1 R5 X1/X2 (exits under outage).
contract SpecHandler is CommonBase, StdCheats, StdUtils {
    GainsVault internal vault;
    GainsVaultLens internal lens;
    GainsVaultPolicy internal policy;
    MockUSDC internal usdc;
    MockGainsDiamond internal diamond;
    MockChainlinkFeed internal ethFeed;
    MockChainlinkFeed internal btcFeed;
    MockChainlinkFeed internal sequencer;
    address internal owner;
    address internal manager;
    address internal operator;
    address internal guardian;
    address internal stranger = address(0xBAD);
    address[3] internal actors = [address(0xA1), address(0xA2), address(0xA3)];

    uint64 public ethPx = 3_000e10;
    uint64 public btcPx = 100_000e10;

    // ---------------------------------------------------------------- ghost violations (must stay 0)
    uint256 public vD1DepositPull; // requestDeposit pulled != assets
    uint256 public vD4RedeemBlocked; // a valid requestRedeem reverted
    uint256 public vD5CancelInexact; // a cancel returned != the request
    uint256 public vD6EpochOverpaid; // claims of an epoch's redeemers > what the epoch paid
    uint256 public vD6SharesOverReturned; // shares returned to an epoch's redeemers > escrow left after the burn
    uint256 public vD6ClaimAboveView; // a claim delivered more than lens.claimable
    uint256 public maxD6ClaimShortWei; // largest claim shortfall vs lens.claimable (rounding cap), informational
    uint256 public vD7ReserveTraded; // a trade / margin add was accepted above idle USDC
    uint256 public vS1SettledWithPending;
    uint256 public vS3PartialOutsideEmergency; // a settle outside emergency burned fewer shares than queued
    uint256 public vS8PostSettleState; // a settle left the state S8 says
    uint256 public vK1BreachDeescalated; // checkRisk lowered a breach (other than the daily reset) or touched a full stop
    uint256 public vF2HwmMoved; // HWM moved outside a normal settle (or went down)
    uint256 public vF2PerfInBreach; // performance fee rate switched outside a normal settle
    uint256 public vF4RaiseImmediate; // a performance fee raise took effect before the next normal settle
    uint256 public vF3FlowMovedMetrics; // deposits / redemptions / fee mints moved daily loss or drawdown (> 1 bps)
    uint256 public vG1ConfigRule; // a tightening did not apply at once, or a loosening did
    uint256 public vR5OperatorAboveCap; // operator reduce above cap / with leverage accepted outside a breach
    uint256 public vExitBlocked; // an exit reverted (prices down or not)

    // ---------------------------------------------------------------- per epoch claim ledgers
    mapping(uint256 => uint256) public claimedRedeemAssets;
    mapping(uint256 => uint256) public returnedRedeemShares;

    // ---------------------------------------------------------------- stats
    uint256 public settles;
    uint256 public normalSettles;
    uint256 public emergencySettles;
    uint256 public claims;
    uint256 public redeemClaims;
    uint256 public breachObs;
    uint256 public operatorReduces;
    uint256 public configTight;
    uint256 public configLoose;
    uint256 public feeRaises;
    uint256 public timeouts;
    uint256 public outages;

    constructor(
        GainsVault v,
        GainsVaultLens l,
        GainsVaultPolicy p,
        MockUSDC u,
        MockGainsDiamond d,
        MockChainlinkFeed eth,
        MockChainlinkFeed btc,
        MockChainlinkFeed seq,
        address[4] memory roles
    ) {
        vault = v;
        lens = l;
        policy = p;
        usdc = u;
        diamond = d;
        ethFeed = eth;
        btcFeed = btc;
        sequencer = seq;
        owner = roles[0];
        manager = roles[1];
        operator = roles[2];
        guardian = roles[3];
        for (uint256 i; i < 3; ++i) {
            u.mint(actors[i], 100_000_000e6);
            vm.prank(actors[i]);
            u.approve(address(v), type(uint256).max);
        }
    }

    function actor(uint256 i) external view returns (address) {
        return actors[i];
    }

    // ---------------------------------------------------------------- helpers
    function _px(uint16 pair) internal view returns (uint64) {
        return pair == 0 ? btcPx : ethPx;
    }

    function _fresh() internal {
        ethFeed.set(int256(uint256(ethPx / 100)), vm.getBlockTimestamp());
        btcFeed.set(int256(uint256(btcPx / 100)), vm.getBlockTimestamp());
    }

    /// @dev S1 (fix round, GR1-04): pending orders that hold collateral, counted from the diamond independently of
    ///      the vault: market opens, partial opens with collateral, leverage decreases. Closes, partial closes and
    ///      leverage increases hold nothing and no longer hold settle.
    function _holdingOrders() internal view returns (uint256 n) {
        IGainsDiamond.PendingOrder[] memory o = diamond.getPendingOrders(address(vault));
        for (uint256 i; i < o.length; ++i) {
            if (!o[i].isOpen) continue;
            uint8 t = o[i].orderType;
            if (t == 0 || (t == 8 && o[i].trade.collateralAmount > 0)) ++n;
            else if (t == 7 && o[i].trade.leverage < diamond.getTrade(address(vault), o[i].trade.index).leverage) ++n;
        }
    }

    function _skip(uint256 dt) internal {
        vm.warp(vm.getBlockTimestamp() + dt);
        _fresh();
    }

    function _metrics() internal view returns (uint256 daily, uint256 dd, bool dust) {
        uint256 ta;
        try vault.totalAssets() returns (uint256 x) {
            ta = x;
        } catch {
            return (0, 0, true);
        }
        uint256 s = vault.totalSupply();
        if (s == 0 || ta < 1e6) return (0, 0, true);
        uint256 price = ((ta + 1) * 1e12) / (s + 1e6);
        uint256 start = vault.dayStartSharePrice();
        uint256 peak = vault.peakSharePrice();
        if (start > price) daily = ((start - price) * 10_000) / start;
        if (peak > price) dd = ((peak - price) * 10_000) / peak;
    }

    function _dev(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a - b : b - a;
    }

    function _flowCheck(uint256 d0, uint256 dd0, bool dust0, bool b0) internal {
        _flowCheck(d0, dd0, dust0, b0, false);
    }

    /// @param improveOk fix round (GR1-02): a settle mints deposits at the favourable band edge while trades are open,
    ///        so the depositors' premium raises the share price (at the adverse-edge NAV the metrics use): daily loss
    ///        and drawdown may fall at a settle. They still never rise by more than 1 bps.
    function _flowCheck(uint256 d0, uint256 dd0, bool dust0, bool b0, bool improveOk) internal {
        (uint256 d1, uint256 dd1, bool dust1) = _metrics();
        if (!dust0 && !dust1 && b0 == vault.breached()) {
            uint256 m = _dev(d0, d1) > _dev(dd0, dd1) ? _dev(d0, d1) : _dev(dd0, dd1);
            if (improveOk) m = (d1 > d0 ? d1 - d0 : 0) > (dd1 > dd0 ? dd1 - dd0 : 0) ? (d1 > d0 ? d1 - d0 : 0) : (dd1 > dd0 ? dd1 - dd0 : 0);
            if (m > 1) vF3FlowMovedMetrics++;
        }
    }

    function _fillAll() internal {
        IGainsDiamond.PendingOrder[] memory o = diamond.getPendingOrders(address(vault));
        for (uint256 i; i < o.length; ++i) {
            try diamond.fill(address(vault), o[i].index, _px(o[i].trade.pairIndex)) {} catch {}
        }
    }

    function _hasPending(uint32 idx) internal view returns (bool) {
        IGainsDiamond.PendingOrder[] memory o = diamond.getPendingOrders(address(vault));
        for (uint256 i; i < o.length; ++i) {
            if (o[i].orderType != 0 && o[i].trade.index == idx) return true;
        }
        return false;
    }

    function _reason() internal view returns (uint8) {
        return uint8(vault.breachReason());
    }

    /// @dev checkRisk with the K1 check around it: breaches only escalate; the only de-escalation checkRisk may do
    ///      is the daily loss reset on a new UTC day; a full stop (guardian, emergency) is never touched.
    function _checkRisk() internal {
        uint8 rb = _reason();
        bool bb = vault.breached();
        uint256 day0 = vault.riskDay();
        try vault.checkRisk() {
            uint8 ra = _reason();
            bool ba = vault.breached();
            bool dayChanged = vault.riskDay() != day0;
            if (rb >= uint8(BreachReason.GUARDIAN) && (ra != rb || !ba)) vK1BreachDeescalated++;
            else if (ra < rb && !(rb == uint8(BreachReason.DAILY_LOSS) && dayChanged)) vK1BreachDeescalated++;
            if (bb && !ba && !(rb == uint8(BreachReason.DAILY_LOSS) && dayChanged)) vK1BreachDeescalated++;
            if (!ba && ra != 0) vK1BreachDeescalated++;
            if (ba) breachObs++;
        } catch {}
    }

    /// @dev Claims for `a` with the D6 checks: the delivery equals lens.claimable (or less by the rounding cap), the
    ///      redemption part is booked against its epoch.
    function _claim(address a) internal {
        (uint256 e, uint256 dep, uint256 red) = vault.requests(a);
        if (e >= vault.currentEpoch() || (dep == 0 && red == 0)) return;
        (uint256 expShares, uint256 expAssets) = lens.claimable(vault, a);
        uint256 u0 = usdc.balanceOf(a);
        uint256 s0 = vault.balanceOf(a);
        try vault.claim(a) {
            claims++;
            uint256 du = usdc.balanceOf(a) - u0;
            uint256 ds = vault.balanceOf(a) - s0;
            if (du > expAssets || ds != expShares) vD6ClaimAboveView++;
            if (expAssets > du && expAssets - du > maxD6ClaimShortWei) maxD6ClaimShortWei = expAssets - du;
            if (red > 0 && dep == 0) {
                redeemClaims++;
                claimedRedeemAssets[e] += du;
                returnedRedeemShares[e] += ds;
                (,, uint256 eRedShares, uint256 eRedAssets, uint256 eBurned,,,) = vault.epochs(e);
                if (claimedRedeemAssets[e] > eRedAssets) vD6EpochOverpaid++;
                if (returnedRedeemShares[e] > eRedShares - eBurned) vD6SharesOverReturned++;
            }
        } catch {}
    }

    // ---------------------------------------------------------------- flows
    function deposit(uint256 who, uint256 amt) external {
        address a = actors[who % 3];
        _claim(a);
        (, uint256 dep0, uint256 red) = vault.requests(a);
        if (red > 0) return; // keep requests pure deposit or pure redeem (claim attribution)
        amt = bound(amt, 1e6, 500_000e6);
        uint256 u0 = usdc.balanceOf(a);
        uint256 p0 = vault.pendingDepositAssets();
        (uint256 d0, uint256 dd0, bool dust0) = _metrics();
        bool b0 = vault.breached();
        vm.prank(a);
        try vault.requestDeposit(amt, a) {
            (, uint256 dep1,) = vault.requests(a);
            if (u0 - usdc.balanceOf(a) != amt || vault.pendingDepositAssets() != p0 + amt || dep1 != dep0 + amt) vD1DepositPull++;
            _flowCheck(d0, dd0, dust0, b0);
        } catch {}
    }

    function redeem(uint256 who, uint256 pct) external {
        address a = actors[who % 3];
        _claim(a);
        (uint256 e, uint256 dep,) = vault.requests(a);
        if (dep > 0) return;
        uint256 sh = (vault.balanceOf(a) * bound(pct, 1, 100)) / 100;
        if (sh == 0) return;
        uint256 esc0 = vault.balanceOf(address(vault));
        vm.prank(a);
        try vault.requestRedeem(sh, a, a) {
            if (vault.balanceOf(address(vault)) != esc0 + sh) vD4RedeemBlocked++;
        } catch {
            if (e <= vault.currentEpoch()) vD4RedeemBlocked++;
        }
    }

    function claim(uint256 who) external {
        _claim(actors[who % 3]);
    }

    function cancelDeposit(uint256 who) external {
        address a = actors[who % 3];
        (uint256 e, uint256 dep,) = vault.requests(a);
        if (dep == 0 || e != vault.currentEpoch()) return;
        uint256 u0 = usdc.balanceOf(a);
        vm.prank(a);
        try vault.cancelDepositRequest() {
            if (usdc.balanceOf(a) - u0 != dep) vD5CancelInexact++;
        } catch {
            vD5CancelInexact++;
        }
    }

    function cancelRedeem(uint256 who) external {
        address a = actors[who % 3];
        (uint256 e, uint256 dep, uint256 red) = vault.requests(a);
        if (red == 0 || dep > 0 || e != vault.currentEpoch()) return;
        uint256 s0 = vault.balanceOf(a);
        vm.prank(a);
        try vault.cancelRedeemRequest() {
            if (vault.balanceOf(a) - s0 != red) vD5CancelInexact++;
        } catch {
            vD5CancelInexact++;
        }
    }

    /// @dev Settles as any role (manager, operator, owner, guardian = sentinel), usually after the oracle answered
    ///      and the operator freed the queue's USDC; sometimes with orders pending (must be refused, S1).
    function settle(uint256 role, uint256 mode) external {
        if (mode % 4 != 0) _fillAll();
        if (mode % 4 != 0) {
            try vault.convertToAssets(vault.pendingRedeemShares()) returns (uint256 owed) {
                owed += 2e6;
                IGainsDiamond.Trade[] memory t = diamond.getTrades(address(vault));
                for (uint256 i; i < t.length && owed > vault.idleAssets(); ++i) {
                    if (!t[i].isOpen || t[i].tradeType != 0) continue;
                    vm.prank(operator);
                    try vault.reduceTrade(t[i].index, t[i].collateralAmount / 2, 0, _px(t[i].pairIndex)) {} catch {}
                    _fillAll();
                }
            } catch {}
        }
        _skip(1 hours);
        _checkRisk();
        address who = [manager, operator, owner, guardian][role % 4];
        bool pending = _holdingOrders() > 0;
        bool normal = !vault.breached() && !vault.emergency();
        bool emerg = vault.emergency();
        // fix round WP2 (GR2-ECON-03, XF-01): the performance fee, the HWM and a scheduled raise move in every settle
        // that prices deposits: a treasury settle with no emergency and no loss breach (a leverage breach included).
        uint8 r0 = uint8(vault.breachReason());
        bool lossBreach0 = vault.breached() && (r0 == uint8(BreachReason.DAILY_LOSS) || r0 == uint8(BreachReason.DRAWDOWN));
        bool feeSettle = !emerg && !lossBreach0 && (who == manager || who == operator);
        uint256 hwm0 = vault.highWaterMark();
        uint16 perf0 = vault.performanceFeeBps();
        uint16 pend0 = vault.pendingPerformanceFeeBps();
        uint256 supply0 = vault.totalSupply();
        uint256 e = vault.currentEpoch();
        (uint256 d0, uint256 dd0, bool dust0) = _metrics();
        bool b0 = vault.breached();
        vm.prank(who);
        try vault.settle() {
            settles++;
            if (normal) normalSettles++;
            if (emerg) emergencySettles++;
            if (pending) vS1SettledWithPending++;
            (,, uint256 rs, , uint256 burned, uint256 nav,, uint64 at) = vault.epochs(e);
            if (!emerg && burned != rs) vS3PartialOutsideEmergency++;
            if (
                vault.currentEpoch() != e + 1 || vault.pendingRedeemShares() != 0 || vault.deferredDepositAssets() != 0
                    || vault.checkpointNav() != nav || vault.checkpointAt() != vm.getBlockTimestamp() || at != vm.getBlockTimestamp()
                    || vault.epochStartedAt() != vm.getBlockTimestamp()
            ) vS8PostSettleState++;
            uint256 hwm1 = vault.highWaterMark();
            bool firstMint = supply0 == 0 && vault.totalSupply() > 0;
            if (!feeSettle && hwm1 != hwm0 && !firstMint) vF2HwmMoved++;
            if (feeSettle && hwm1 < hwm0 && !firstMint) vF2HwmMoved++;
            // F4: a scheduled raise switches on exactly at a fee-charging settle; never at another one
            if (feeSettle && pend0 != 0 && (vault.performanceFeeBps() != pend0 || vault.pendingPerformanceFeeBps() != 0)) vF4RaiseImmediate++;
            if (!feeSettle && vault.performanceFeeBps() != perf0) vF2PerfInBreach++;
            _flowCheck(d0, dd0, dust0, b0, true);
        } catch {}
    }

    function accrue(uint256 secs) external {
        _skip(bound(secs, 1 hours, 20 hours));
        uint256 hwm0 = vault.highWaterMark();
        uint16 perf0 = vault.performanceFeeBps();
        (uint256 d0, uint256 dd0, bool dust0) = _metrics();
        bool b0 = vault.breached();
        try vault.accrueFees() {
            if (vault.highWaterMark() != hwm0) vF2HwmMoved++;
            if (vault.performanceFeeBps() != perf0) vF2PerfInBreach++;
            _flowCheck(d0, dd0, dust0, b0);
        } catch {}
    }

    /// @dev F4: the owner raises the performance fee through the timelock; it must not apply before a normal settle.
    function raiseFee(uint256 perf, uint256 mgmt) external {
        uint16 cur = vault.performanceFeeBps();
        uint16 p = uint16(bound(perf, 0, 3_000));
        uint16 m = uint16(bound(mgmt, 0, 500));
        bytes memory data = abi.encodeCall(GainsVault.setFees, (m, p));
        vm.prank(owner);
        try vault.queue(data) {} catch {
            return;
        }
        _skip(vault.timelockDelay());
        try vault.execute(data) {
            feeRaises++;
            if (p > cur && vault.performanceFeeBps() != cur) vF4RaiseImmediate++;
            if (p > cur && vault.pendingPerformanceFeeBps() != p) vF4RaiseImmediate++;
            if (p <= cur && vault.performanceFeeBps() != p) vF4RaiseImmediate++;
        } catch {}
    }

    // ---------------------------------------------------------------- trading
    function trade(bool btc, bool long, uint256 pct, uint256 lev, uint256 outcome) external {
        uint16 pair = btc ? 0 : 1;
        uint256 idle = vault.idleAssets();
        uint120 coll = uint120((idle * bound(pct, 1, 30)) / 100);
        uint24 leverage = uint24(bound(lev, 1_100, 50_000));
        OpenParams memory p = OpenParams(pair, long, coll, leverage, _px(pair), 1_000, 0, 0, 0);
        vm.prank(manager);
        try vault.openTrade(p) {
            uint32 o = diamond.orderCount(address(vault)) - 1;
            uint256 w = outcome % 6;
            if (w < 4) diamond.fill(address(vault), o, _px(pair));
            else if (w == 4) diamond.cancelInCallback(address(vault), o);
        } catch {}
    }

    function limitOrder(bool long, uint256 pct, uint256 exec) external {
        uint256 idle = vault.idleAssets();
        uint120 coll = uint120((idle * bound(pct, 1, 10)) / 100);
        uint64 px = long ? (ethPx * 99) / 100 : (ethPx * 101) / 100;
        OpenParams memory p = OpenParams(1, long, coll, 3_000, px, 1_000, 0, 0, 1);
        vm.prank(manager);
        try vault.openTrade(p) {
            if (exec % 3 == 0) {
                IGainsDiamond.Trade[] memory t = diamond.getTrades(address(vault));
                for (uint256 i; i < t.length; ++i) {
                    if (t[i].tradeType != 0) {
                        try diamond.executeLimit(address(vault), t[i].index, ethPx) {} catch {}
                        break;
                    }
                }
            }
        } catch {}
    }

    /// @dev D7: reserved USDC (pending / deferred deposits, claimable redemptions) never goes into a trade.
    function tradeReserved(uint256 extra, uint256 which) external {
        uint256 bal = usdc.balanceOf(address(vault));
        uint256 idle = vault.idleAssets();
        uint256 reserved = bal - idle;
        if (reserved == 0) return;
        uint120 coll = uint120(idle + bound(extra, 1, reserved));
        OpenParams memory p = OpenParams(1, true, coll, 1_100, ethPx, 1_000, 0, 0, 0);
        vm.prank(manager);
        try vault.openTrade(p) {
            vD7ReserveTraded++;
        } catch {}
        IGainsDiamond.Trade[] memory t = diamond.getTrades(address(vault));
        if (t.length == 0) return;
        IGainsDiamond.Trade memory x = t[which % t.length];
        if (x.tradeType != 0 || _hasPending(x.index)) return;
        vm.prank(manager);
        try vault.increaseTrade(x.index, coll, 1_100, _px(x.pairIndex), 1_000) {
            vD7ReserveTraded++;
        } catch {}
        // a leverage decrease that needs more margin than idle
        uint256 need = idle + 1;
        if (x.leverage > 1_100) {
            uint256 newLev = (uint256(x.collateralAmount) * x.leverage) / (uint256(x.collateralAmount) + need);
            if (newLev >= 1_100 && newLev < x.leverage) {
                uint256 delta = (uint256(x.collateralAmount) * x.leverage) / newLev - x.collateralAmount;
                if (delta > idle) {
                    vm.prank(manager);
                    try vault.updateLeverage(x.index, uint24(newLev)) {
                        vD7ReserveTraded++;
                    } catch {}
                }
            }
        }
    }

    function close(uint256 which, bool reduce) external {
        IGainsDiamond.Trade[] memory t = diamond.getTrades(address(vault));
        if (t.length == 0) return;
        IGainsDiamond.Trade memory x = t[which % t.length];
        if (x.tradeType != 0 || _hasPending(x.index)) return;
        vm.prank(manager);
        if (reduce) try vault.reduceTrade(x.index, x.collateralAmount / 3, 0, _px(x.pairIndex)) {} catch {}
        else try vault.closeTrade(x.index, _px(x.pairIndex)) {} catch {}
    }

    /// @dev R5: outside a breach the operator reduces only a collateral delta <= operatorReduceCap(shortfall).
    function operatorReduce(uint256 which, uint256 amt, uint256 lev) external {
        if (vault.breached() || vault.emergency()) return;
        IGainsDiamond.Trade[] memory t = diamond.getTrades(address(vault));
        if (t.length == 0) return;
        IGainsDiamond.Trade memory x = t[which % t.length];
        if (x.tradeType != 0 || _hasPending(x.index) || x.collateralAmount < 2) return;
        uint256 cap = operatorReduceCap(vault.redemptionShortfall());
        uint120 delta = uint120(bound(amt, 1, x.collateralAmount - 1));
        uint24 ld = lev % 4 == 0 ? uint24(bound(lev, 1, 1_000)) : 0;
        vm.prank(operator);
        try vault.reduceTrade(x.index, delta, ld, _px(x.pairIndex)) {
            operatorReduces++;
            if (ld != 0 || delta > cap) vR5OperatorAboveCap++;
            if (lev % 2 == 0) _fillAll();
        } catch {}
        vm.prank(operator);
        try vault.closeTrade(x.index, _px(x.pairIndex)) {
            vR5OperatorAboveCap++;
        } catch {}
    }

    function oracle() external {
        _fillAll();
    }

    function timeout() external {
        vm.roll(vm.getBlockNumber() + 200);
        IGainsDiamond.PendingOrder[] memory o = diamond.getPendingOrders(address(vault));
        for (uint256 i; i < o.length; ++i) {
            vm.prank(stranger);
            try vault.cancelTimedOut(o[i].index) {
                timeouts++;
            } catch {
                vExitBlocked++;
            }
        }
    }

    function funding(uint256 which, int256 amt) external {
        IGainsDiamond.Trade[] memory t = diamond.getTrades(address(vault));
        if (t.length == 0) return;
        IGainsDiamond.Trade memory x = t[which % t.length];
        amt = bound(amt, -int256(uint256(x.collateralAmount) / 50), int256(uint256(x.collateralAmount) / 50));
        diamond.setHolding(address(vault), x.index, diamond.holding(address(vault), x.index) + amt);
    }

    function liquidate() external {
        IGainsDiamond.Trade[] memory t = diamond.getTrades(address(vault));
        for (uint256 i; i < t.length; ++i) {
            if (t[i].tradeType == 0 && !_hasPending(t[i].index) && diamond.closeValue(address(vault), t[i].index, _px(t[i].pairIndex)) == 0) {
                diamond.trigger(address(vault), t[i].index, _px(t[i].pairIndex));
            }
        }
    }

    // ---------------------------------------------------------------- market, risk, governance
    function move(bool btc, int256 bps) external {
        bps = bound(bps, -300, 300);
        if (btc) btcPx = uint64(uint256(int256(uint256(btcPx)) + (int256(uint256(btcPx)) * bps) / 10_000));
        else ethPx = uint64(uint256(int256(uint256(ethPx)) + (int256(uint256(ethPx)) * bps) / 10_000));
        ethPx = (ethPx / 100) * 100;
        btcPx = (btcPx / 100) * 100;
        _fresh();
        _checkRisk();
    }

    function crash(uint256 what) external {
        if (what % 8 != 0) return;
        ethPx = ((ethPx * 85) / 100 / 100) * 100;
        btcPx = ((btcPx * 85) / 100 / 100) * 100;
        _fresh();
        _checkRisk();
    }

    function nextDay() external {
        _skip(1 days);
        _checkRisk();
    }

    function check() external {
        _checkRisk();
    }

    function clearLeverage() external {
        _skip(20 minutes);
        try vault.clearLeverageBreach() {} catch {}
    }

    function resume() external {
        _skip(1 days);
        vm.prank(owner);
        try vault.resume() {} catch {}
    }

    /// @dev Calm variant: full stops and emergencies are rare, so normal settles, fee raises and operator reduces get depth.
    bool public calm;

    function setCalm(bool c) external {
        calm = c;
    }

    function guardianActs(uint256 what) external {
        if (calm && what % 200 >= 6) return;
        uint256 w = what % 24;
        vm.prank(guardian);
        if (w == 0) try vault.triggerBreach() {} catch {}
        else if (w == 1 || w == 2) try vault.clearBreach() {} catch {}
        else if (w == 3) try vault.triggerEmergency() {} catch {}
        else if (w == 4 || w == 5) try vault.exitEmergency() {} catch {}
    }

    /// @dev G1: a tightening on every field applies at once; anything looser waits the policy timelock.
    function config(uint256 salt, bool apply_) external {
        GainsVaultPolicy.RiskConfig memory c = policy.config();
        GainsVaultPolicy.RiskConfig memory n = policy.config(); // a fresh copy (memory assignment would alias c)
        int256 dir = salt % 3 == 0 ? int256(1) : int256(-1); // mostly tighten, sometimes loosen
        uint256 f = bound(salt >> 8, 1, 10); // percent
        n.maxDailyLossBps = uint32(_scale(c.maxDailyLossBps, dir, f, 100, 2_000));
        n.maxDrawdownBps = uint32(_scale(c.maxDrawdownBps, dir, f, 300, 5_000));
        n.maxSlippageBps = uint32(_scale(c.maxSlippageBps, dir, f, 20, 300));
        n.maxOrderNotional = uint64(_scale(c.maxOrderNotional, dir, f, 10_000e6, 10_000_000e6));
        if ((salt >> 16) % 2 == 0) n.maxLeverageBps = uint32(_scale(c.maxLeverageBps, dir, f, 15_000, 30_000));
        bool tighter = n.maxLeverageBps <= c.maxLeverageBps && n.maxDailyLossBps <= c.maxDailyLossBps
            && n.maxDrawdownBps <= c.maxDrawdownBps && n.maxSlippageBps <= c.maxSlippageBps
            && n.maxOrderNotional <= c.maxOrderNotional && n.maxEpochDuration <= c.maxEpochDuration
            && n.maxNavMoveBps >= c.maxNavMoveBps && n.maxFlattenSlippageBps <= c.maxFlattenSlippageBps;
        vm.prank(owner);
        try policy.proposeConfig(n) {
            GainsVaultPolicy.RiskConfig memory now_ = policy.config();
            bool applied = _eq(now_, n);
            if (tighter) {
                configTight++;
                if (!applied) vG1ConfigRule++;
            } else {
                configLoose++;
                if (!_eq(now_, c)) vG1ConfigRule++;
                // not before eta
                try policy.applyPendingConfig() {
                    vG1ConfigRule++;
                } catch {}
                if (apply_) {
                    _skip(policy.timelockDelay());
                    try policy.applyPendingConfig() {} catch {}
                }
            }
        } catch {}
    }

    function _scale(uint256 v, int256 dir, uint256 pct, uint256 lo, uint256 hi) internal pure returns (uint256 r) {
        r = dir > 0 ? v + (v * pct) / 100 : v - (v * pct) / 100;
        if (r < lo) r = lo;
        if (r > hi) r = hi;
    }

    function _eq(GainsVaultPolicy.RiskConfig memory a, GainsVaultPolicy.RiskConfig memory b) internal pure returns (bool) {
        return keccak256(abi.encode(a)) == keccak256(abi.encode(b));
    }

    /// @dev A price outage (sequencer down or every feed stale): every exit, requestRedeem and claim still work.
    function outage(uint256 what, bool sequencerDown) external {
        if (what % 5 != 0) return;
        if (sequencerDown) sequencer.setStatus(1, vm.getBlockTimestamp());
        else vm.warp(vm.getBlockTimestamp() + 2 days);
        outages++;
        address a = actors[what % 3];
        (uint256 e, uint256 dep,) = vault.requests(a);
        uint256 sh = vault.balanceOf(a) / 10;
        if (sh > 0 && dep == 0 && e <= vault.currentEpoch()) {
            vm.prank(a);
            try vault.requestRedeem(sh, a, a) {} catch {
                vD4RedeemBlocked++;
            }
        }
        // GR2-KEY-01b: the manager's exits come after the minimum hold (time and L2 blocks); the guardian's never wait.
        vm.warp(vm.getBlockTimestamp() + MIN_HOLD);
        vm.roll(vm.getBlockNumber() + MIN_HOLD_L2_BLOCKS);
        IGainsDiamond.Trade[] memory t = diamond.getTrades(address(vault));
        for (uint256 i; i < t.length; ++i) {
            if (!t[i].isOpen || _hasPending(t[i].index)) continue;
            vm.prank(manager);
            if (t[i].tradeType != 0) {
                try vault.cancelOrder(t[i].index) {} catch {
                    vExitBlocked++;
                }
            } else if (i % 2 == 0 || t[i].collateralAmount < 2e6) {
                try vault.closeTrade(t[i].index, _px(t[i].pairIndex)) {} catch {
                    vExitBlocked++;
                }
            } else {
                try vault.reduceTrade(t[i].index, t[i].collateralAmount / 2, 0, _px(t[i].pairIndex)) {} catch {
                    vExitBlocked++;
                }
            }
        }
        vm.prank(guardian);
        try vault.flatten(1, 0, ethPx, type(uint256).max) {} catch {
            vExitBlocked++;
        }
        vm.prank(guardian);
        try vault.flatten(0, 0, btcPx, type(uint256).max) {} catch {
            vExitBlocked++;
        }
        sequencer.setStatus(0, vm.getBlockTimestamp() - 2 hours);
        _fresh();
    }

    function seed() external {
        vm.prank(actors[0]);
        vault.requestDeposit(1_000_000e6, actors[0]);
        _skip(1 hours); // fix round: a settle that prices deposits runs 1 h into the epoch (GR1-02)
        vault.checkRisk();
        vm.prank(manager);
        vault.settle();
        vault.claim(actors[0]);
        OpenParams memory p = OpenParams(1, true, 300_000e6, 3_000, ethPx, 1_000, 0, 0, 0);
        vm.prank(manager);
        vault.openTrade(p);
        _fillAll();
        p = OpenParams(0, false, 200_000e6, 2_000, btcPx, 1_000, 0, 0, 0);
        vm.prank(manager);
        vault.openTrade(p);
        _fillAll();
        vault.checkRisk();
    }
}

contract GainsSpecInvariants is GainsBase {
    SpecHandler internal h;
    address internal operator = makeAddr("operator");

    function setUp() public virtual override {
        super.setUp();
        diamond.setPair(ETH, 3.5e8, 285.7e18, 0.1e18, 1e7);
        diamond.setPair(BTC, 3.5e8, 285.7e18, 0.1e18, 1e7);
        vm.prank(owner);
        vault.setOperator(operator);
        h = new SpecHandler(
            vault, lens, policy, usdc, diamond, ethFeed, btcFeed, sequencer, [owner, manager, operator, guardian]
        );
        h.seed();
        targetContract(address(h));
        bytes4[] memory skip = new bytes4[](3);
        skip[0] = SpecHandler.seed.selector;
        skip[1] = SpecHandler.actor.selector;
        skip[2] = SpecHandler.setCalm.selector;
        excludeSelector(FuzzSelector({addr: address(h), selectors: skip}));
    }

    /// @dev N1, independent of GainsNav: idle + every open trade at the adverse band edge through the mock's own close
    ///      math (0 at or past liquidation, GR1-03) + resting collateral + pending collateral net of the cancel fee.
    function _expectedNav() internal view returns (bool ok, uint256 nav) {
        nav = vault.idleAssets();
        IGainsDiamond.Trade[] memory t = diamond.getTrades(address(vault));
        for (uint256 i; i < t.length; ++i) {
            if (!t[i].isOpen) continue;
            if (t[i].tradeType != 0) {
                nav += t[i].collateralAmount;
                continue;
            }
            uint64 mid;
            uint16 band;
            try policy.navPrice(t[i].pairIndex) returns (uint64 m, uint16 b) {
                (mid, band) = (m, b);
            } catch {
                return (false, 0);
            }
            uint64 p = GainsPrice.adverse(mid, band, t[i].long);
            uint256 dist = (uint256(t[i].openPrice) * 90 * 1e3) / (100 * uint256(t[i].leverage));
            uint256 liq = t[i].long ? (dist >= t[i].openPrice ? 0 : t[i].openPrice - dist) : uint256(t[i].openPrice) + dist;
            // fix round (GR1-03): zero only when the valuation price itself is at or past the liquidation price
            bool near = t[i].long ? uint256(p) <= liq : uint256(p) >= liq;
            if (!near) nav += diamond.closeValue(address(vault), t[i].index, p);
        }
        IGainsDiamond.PendingOrder[] memory o = diamond.getPendingOrders(address(vault));
        for (uint256 i; i < o.length; ++i) {
            if (!o[i].isOpen) continue;
            // fix round: a leverage-only partial open (collateral 0) holds nothing (GR1-01 / GR1-04), and the gov fee of
            // an order on an existing trade is the trade's own pair's (GR1-28)
            bool holds = o[i].orderType == 0 || (o[i].orderType == 8 && o[i].trade.collateralAmount > 0)
                || (o[i].orderType == 7 && o[i].trade.leverage < diamond.getTrade(address(vault), o[i].trade.index).leverage);
            if (holds) {
                uint16 feePair = o[i].orderType == 0 ? o[i].trade.pairIndex : diamond.getTrade(address(vault), o[i].trade.index).pairIndex;
                uint256 fee = diamond.minGovFee(feePair);
                if (o[i].trade.collateralAmount > fee) nav += o[i].trade.collateralAmount - fee;
            }
        }
        ok = true;
    }

    /// forge-config: default.invariant.runs = 2048
    /// forge-config: default.invariant.depth = 500
    /// forge-config: default.invariant.fail-on-revert = false
    /// forge-config: default.invariant.show-metrics = true
    function invariant_spec() public view {
        assertEq(h.vD1DepositPull(), 0, "D1 requestDeposit pulled exactly the assets");
        assertEq(h.vD4RedeemBlocked(), 0, "D4 requestRedeem always allowed");
        assertEq(h.vD5CancelInexact(), 0, "D5 cancels return exactly the request");
        assertEq(h.vD6EpochOverpaid(), 0, "D6 claims of an epoch <= what it paid");
        assertEq(h.vD6SharesOverReturned(), 0, "D6 returned shares <= escrow left after the burn");
        assertEq(h.vD6ClaimAboveView(), 0, "D6 claim == lens.claimable");
        assertEq(h.vD7ReserveTraded(), 0, "D7 reserved USDC never traded");
        assertEq(h.vS1SettledWithPending(), 0, "S1 no settle with pending orders");
        assertEq(h.vS3PartialOutsideEmergency(), 0, "S3/S4 redemptions paid in full outside emergency");
        assertEq(h.vS8PostSettleState(), 0, "S8 post settle state");
        assertEq(h.vK1BreachDeescalated(), 0, "K1 breaches only escalate");
        assertEq(h.vF2HwmMoved(), 0, "F2 HWM only moves (up) in a normal settle");
        assertEq(h.vF2PerfInBreach(), 0, "F2 performance rate only switches in a normal settle");
        assertEq(h.vF3FlowMovedMetrics(), 0, "F3 flows and fee mints never move the risk metrics");
        assertEq(h.vF4RaiseImmediate(), 0, "F4 performance fee raise waits for the next normal settle");
        assertEq(h.vG1ConfigRule(), 0, "G1 tighten at once, loosen behind the timelock");
        assertEq(h.vR5OperatorAboveCap(), 0, "R5 operator reduce within the cap");
        assertEq(h.vExitBlocked(), 0, "X1/X2 exits always callable");

        // reserves backed, shares accounted, escrow, T4
        uint256 reserved = vault.pendingDepositAssets() + vault.deferredDepositAssets() + vault.claimableRedeemAssets();
        assertGe(usdc.balanceOf(address(vault)), reserved, "D7 reserves backed");
        uint256 held = vault.balanceOf(address(vault)) + vault.balanceOf(feeRecipient);
        for (uint256 i; i < 3; ++i) {
            held += vault.balanceOf(h.actor(i));
        }
        assertEq(held, vault.totalSupply(), "every share accounted for");
        assertGe(vault.balanceOf(address(vault)), vault.pendingRedeemShares(), "queued redemptions escrowed");
        assertEq(usdc.allowance(address(vault), address(diamond)), 0, "T4 no standing approval");
        if (!vault.breached()) assertEq(uint8(vault.breachReason()), 0, "no reason without a breach");

        // N1
        (bool ok, uint256 exp) = _expectedNav();
        if (ok) {
            try vault.totalAssets() returns (uint256 nav) {
                assertEq(nav, exp, "N1 NAV = idle + items");
            } catch {}
        }
    }

    function afterInvariant() external {
        emit log_named_uint("settles", h.settles());
        emit log_named_uint("normal settles", h.normalSettles());
        emit log_named_uint("emergency settles", h.emergencySettles());
        emit log_named_uint("claims", h.claims());
        emit log_named_uint("redeem claims", h.redeemClaims());
        emit log_named_uint("breach observations", h.breachObs());
        emit log_named_uint("operator reduces", h.operatorReduces());
        emit log_named_uint("config tighten", h.configTight());
        emit log_named_uint("config loosen", h.configLoose());
        emit log_named_uint("fee changes", h.feeRaises());
        emit log_named_uint("timeouts", h.timeouts());
        emit log_named_uint("outages", h.outages());
        emit log_named_uint("max claim short wei", h.maxD6ClaimShortWei());
    }
}

/// @dev Same handler and checks with full stops and emergencies 33x rarer (normal-mode depth: normal settles, fee
///      raises, operator reduces under redemption shortfalls).
contract GainsSpecInvariantsCalm is GainsSpecInvariants {
    function setUp() public override {
        super.setUp();
        h.setCalm(true);
    }
}

/// @dev Exercises every handler action once so a broken action shows up as a failing unit test, not a silent no-op.
contract GainsSpecHandlerSanity is GainsBase {
    function test_specHandlerDrivesEveryAction() public {
        address op = makeAddr("operator");
        diamond.setPair(ETH, 3.5e8, 285.7e18, 0.1e18, 1e7);
        diamond.setPair(BTC, 3.5e8, 285.7e18, 0.1e18, 1e7);
        vm.prank(owner);
        vault.setOperator(op);
        SpecHandler h = new SpecHandler(vault, lens, policy, usdc, diamond, ethFeed, btcFeed, sequencer, [owner, manager, op, guardian]);
        h.seed();
        h.deposit(1, 50_000e6);
        h.settle(0, 1);
        h.claim(1);
        h.redeem(0, 20);
        h.redeem(1, 50);
        h.tradeReserved(1e6, 0);
        h.settle(1, 1);
        h.claim(0);
        h.claim(1);
        h.trade(false, true, 10, 5_000, 0);
        h.limitOrder(true, 5, 0);
        h.operatorReduce(0, 1e6, 1);
        h.raiseFee(2_500, 200);
        h.config(1, false);
        h.config(3, true);
        h.move(false, -200);
        h.nextDay();
        h.accrue(5 hours);
        h.deposit(2, 1_000e6);
        h.cancelDeposit(2);
        h.redeem(0, 10);
        h.cancelRedeem(0);
        h.outage(0, true);
        h.outage(5, false);
        h.guardianActs(3);
        h.redeem(0, 50);
        h.settle(3, 1);
        h.claim(0);
        assertGt(h.settles(), 2, "settles happen");
        assertGt(h.redeemClaims(), 0, "redeem claims happen");
        assertGt(h.configTight() + h.configLoose(), 0, "config changes happen");
        assertEq(h.vD6EpochOverpaid() + h.vD6ClaimAboveView() + h.vS8PostSettleState() + h.vK1BreachDeescalated(), 0);
        assertEq(h.vF2HwmMoved() + h.vF4RaiseImmediate() + h.vG1ConfigRule() + h.vR5OperatorAboveCap() + h.vD7ReserveTraded(), 0);
        assertEq(h.vD1DepositPull() + h.vD4RedeemBlocked() + h.vD5CancelInexact() + h.vExitBlocked(), 0);
    }
}
