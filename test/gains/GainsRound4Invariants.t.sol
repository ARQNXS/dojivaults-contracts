// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {CommonBase} from "forge-std/Base.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {StdUtils} from "forge-std/StdUtils.sol";
import {GainsBase} from "./GainsBase.t.sol";
import {GainsVault} from "../../src/gains/GainsVault.sol";
import {IGainsDiamond} from "../../src/gains/IGainsDiamond.sol";
import {OpenParams, operatorReduceCap, MIN_HOLD, MIN_HOLD_L2_BLOCKS} from "../../src/gains/GainsTypes.sol";
import {MockUSDC} from "../mocks/Mocks.sol";
import {MockGainsDiamond, MockChainlinkFeed} from "./mocks/GainsMocks.sol";

/// @dev Drives a standalone Gains vault (owner, manager, operator, guardian = sentinel) through deposits, redemptions,
///      settles, fee accruals, trades that fill, cancel in the callback or time out, price moves, funding, liquidations,
///      risk checks, breaches, emergencies and price outages, and lets strangers, depositors and the operator try
///      everything they must not do. Mirrors test/Round4Invariants.t.sol and adds the Gains invariants.
contract GainsHandler is CommonBase, StdCheats, StdUtils {
    GainsVault internal vault;
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

    // ghost violations (must stay 0)
    uint256 public vFlowMovedMetrics;
    uint256 public vOutsiderActed;
    uint256 public vOperatorEscaped;
    uint256 public vExposureUp;
    uint256 public vSettledWithPending; // a settle went through while an order holding collateral was pending (GR1-04)
    uint256 public vExitBlocked; // an exit reverted (prices down or not)
    uint256 public settles;
    uint256 public settlesImprovedMetrics; // settles whose deposits lifted the share price (GR1-02)
    uint256 public breaches;
    uint256 public timeouts;
    uint256 public exitsUnderOutage;

    constructor(
        GainsVault v,
        MockUSDC u,
        MockGainsDiamond d,
        MockChainlinkFeed eth,
        MockChainlinkFeed btc,
        MockChainlinkFeed seq,
        address o,
        address m,
        address op,
        address g
    ) {
        vault = v;
        usdc = u;
        diamond = d;
        ethFeed = eth;
        btcFeed = btc;
        sequencer = seq;
        owner = o;
        manager = m;
        operator = op;
        guardian = g;
        for (uint256 i; i < 3; ++i) {
            u.mint(actors[i], 10_000_000e6);
            vm.prank(actors[i]);
            u.approve(address(v), type(uint256).max);
        }
    }

    function actor(uint256 i) external view returns (address) {
        return actors[i];
    }

    // ------------------------------------------------------------------ helpers
    function _px(uint16 pair) internal view returns (uint64) {
        return pair == 0 ? btcPx : ethPx;
    }

    function _fresh() internal {
        ethFeed.set(int256(uint256(ethPx / 100)), vm.getBlockTimestamp());
        btcFeed.set(int256(uint256(btcPx / 100)), vm.getBlockTimestamp());
    }

    function _skip(uint256 dt) internal {
        vm.warp(vm.getBlockTimestamp() + dt);
        _fresh();
    }

    function _metrics() internal view returns (uint256 daily, uint256 dd, bool dust) {
        uint256 ta = vault.totalAssets();
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

    /// @dev The test plays the oracle: answers every pending order at the Chainlink price.
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

    // ------------------------------------------------------------------ flows
    function deposit(uint256 who, uint256 amt) external {
        amt = bound(amt, 1e6, 500_000e6);
        vm.prank(actors[who % 3]);
        try vault.requestDeposit(amt, actors[who % 3]) {} catch {}
    }

    function redeem(uint256 who, uint256 pct) external {
        address a = actors[who % 3];
        try vault.claim(a) {} catch {}
        uint256 sh = (vault.balanceOf(a) * bound(pct, 1, 100)) / 100;
        if (sh == 0) return;
        vm.prank(a);
        try vault.requestRedeem(sh, a, a) {} catch {}
    }

    function claim(uint256 who) external {
        try vault.claim(actors[who % 3]) {} catch {}
    }

    /// @dev Usually lets the oracle answer first and frees what the queue needs (the operator reduces); sometimes
    ///      tries to settle with orders still pending, which must never go through.
    function settle(bool byOperator, uint256 mode) external {
        if (mode % 4 != 0) _fillAll();
        try vault.convertToAssets(vault.pendingRedeemShares()) returns (uint256 owed) {
            owed += 2e6;
            uint256 idle = vault.idleAssets();
            if (owed > idle && mode % 4 != 0) {
                IGainsDiamond.Trade[] memory t = diamond.getTrades(address(vault));
                for (uint256 i; i < t.length && owed > vault.idleAssets(); ++i) {
                    if (!t[i].isOpen || t[i].tradeType != 0) continue;
                    vm.prank(operator);
                    try vault.reduceTrade(t[i].index, t[i].collateralAmount / 2, 0, _px(t[i].pairIndex)) {} catch {}
                    _fillAll();
                }
            }
        } catch {}
        _skip(1 hours);
        try vault.checkRisk() {} catch {}
        // GR1-04: only an order that holds collateral is "in flight"; a pending close or partial close may settle
        bool pending = vault.ordersPending();
        (uint256 d0, uint256 dd0, bool dust0) = _metrics();
        bool b0 = vault.breached();
        vm.prank(byOperator ? operator : manager);
        try vault.settle() {
            settles++;
            if (pending) vSettledWithPending++;
            (uint256 d1, uint256 dd1, bool dust1) = _metrics();
            if (!dust0 && !dust1 && b0 == vault.breached()) {
                // GR1-02: deposits mint at the favourable band edge while trades are open, so a settle with deposits
                // can lift the share price for the holders (the depositor pays the edge). Only a move that worsens
                // daily loss or drawdown is a violation; an improvement is counted apart.
                uint256 m = _up(d0, d1) > _up(dd0, dd1) ? _up(d0, d1) : _up(dd0, dd1);
                if (m > 1 && m > vFlowMovedMetrics) vFlowMovedMetrics = m;
                if (d1 + 1 < d0 || dd1 + 1 < dd0) settlesImprovedMetrics++;
            }
        } catch {}
    }

    /// @dev How much `b` is above `a` (0 when below).
    function _up(uint256 a, uint256 b) internal pure returns (uint256) {
        return b > a ? b - a : 0;
    }

    function accrue(uint256 secs) external {
        _skip(bound(secs, 1 hours, 20 hours));
        (uint256 d0, uint256 dd0, bool dust0) = _metrics();
        try vault.accrueFees() {
            (uint256 d1, uint256 dd1, bool dust1) = _metrics();
            if (!dust0 && !dust1) {
                uint256 m = _dev(d0, d1) > _dev(dd0, dd1) ? _dev(d0, d1) : _dev(dd0, dd1);
                if (m > 1 && m > vFlowMovedMetrics) vFlowMovedMetrics = m;
            }
        } catch {}
    }

    // ------------------------------------------------------------------ trading
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
            if (w < 4) diamond.fill(address(vault), o, _px(pair)); // filled within seconds
            else if (w == 4) diamond.cancelInCallback(address(vault), o); // slippage / exposure cancel
            // w == 5: left pending (times out unless filled later)
        } catch {}
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

    function oracle() external {
        _fillAll();
    }

    function timeout() external {
        vm.roll(vm.getBlockNumber() + 200);
        IGainsDiamond.PendingOrder[] memory o = diamond.getPendingOrders(address(vault));
        for (uint256 i; i < o.length; ++i) {
            vm.prank(stranger); // the keeper: anyone may cancel a timed-out order
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
                diamond.trigger(address(vault), t[i].index, _px(t[i].pairIndex)); // Gains' liquidator
            }
        }
    }

    // ------------------------------------------------------------------ market and risk
    function move(bool btc, int256 bps) external {
        bps = bound(bps, -300, 300);
        if (btc) btcPx = uint64(uint256(int256(uint256(btcPx)) + (int256(uint256(btcPx)) * bps) / 10_000));
        else ethPx = uint64(uint256(int256(uint256(ethPx)) + (int256(uint256(ethPx)) * bps) / 10_000));
        ethPx = (ethPx / 100) * 100;
        btcPx = (btcPx / 100) * 100;
        _fresh();
        try vault.checkRisk() {} catch {}
        if (vault.breached()) breaches++;
    }

    function crash(uint256 what) external {
        if (what % 8 != 0) return;
        ethPx = ((ethPx * 85) / 100 / 100) * 100;
        btcPx = ((btcPx * 85) / 100 / 100) * 100;
        _fresh();
        try vault.checkRisk() {} catch {}
        if (vault.breached()) breaches++;
    }

    function check() external {
        try vault.checkRisk() {} catch {}
    }

    function clearLeverage() external {
        _skip(20 minutes);
        try vault.clearLeverageBreach() {} catch {}
    }

    function resume() external {
        vm.prank(owner);
        try vault.resume() {} catch {}
    }

    function guardianActs(uint256 what) external {
        uint256 w = what % 24;
        vm.prank(guardian);
        if (w == 0) try vault.triggerBreach() {} catch {}
        else if (w == 1 || w == 2) try vault.clearBreach() {} catch {}
        else if (w == 3) try vault.triggerEmergency() {} catch {}
        else if (w == 4) try vault.exitEmergency() {} catch {}
    }

    /// @dev A price outage (sequencer down or every feed stale): every exit must still go through.
    function outage(uint256 what, bool sequencerDown) external {
        if (what % 5 != 0) return;
        if (sequencerDown) sequencer.setStatus(1, vm.getBlockTimestamp());
        else vm.warp(vm.getBlockTimestamp() + 2 days); // past every BTC/ETH heartbeat
        exitsUnderOutage++;
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
        // back to normal
        sequencer.setStatus(0, vm.getBlockTimestamp() - 2 hours);
        _fresh();
    }

    function seed() external {
        vm.prank(actors[0]);
        vault.requestDeposit(1_000_000e6, actors[0]);
        _skip(1 hours); // GR1-02: a settle that prices deposits runs an hour into the epoch
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

    // ------------------------------------------------------------------ hostile callers
    function outsiders(uint256 who) external {
        if (!vault.breached() && !vault.emergency()) return;
        address[2] memory xs = [stranger, actors[who % 3]];
        IGainsDiamond.Trade[] memory t = diamond.getTrades(address(vault));
        for (uint256 i; i < 2; ++i) {
            vm.prank(xs[i]);
            try vault.flatten(1, 0, ethPx, type(uint256).max) {
                vOutsiderActed++;
            } catch {}
            vm.prank(xs[i]);
            try vault.settle() {
                vOutsiderActed++;
            } catch {}
            if (t.length > 0) {
                vm.prank(xs[i]);
                try vault.closeTrade(t[0].index, ethPx) {
                    vOutsiderActed++;
                } catch {}
                vm.prank(xs[i]);
                try vault.reduceTrade(t[0].index, 1e6, 0, ethPx) {
                    vOutsiderActed++;
                } catch {}
            }
        }
    }

    function operatorEscapes(uint256 what) external {
        IGainsDiamond.Trade[] memory t = diamond.getTrades(address(vault));
        uint32 idx = t.length > 0 ? t[0].index : 0;
        OpenParams memory p = OpenParams(1, true, 1_000e6, 2_000, ethPx, 1_000, 0, 0, 0);
        vm.startPrank(operator);
        uint256 w = what % 16;
        bool calm = !vault.breached() && !vault.emergency();
        uint256 over = operatorReduceCap(vault.redemptionShortfall()) + 1;
        bool ok;
        if (w == 0) try vault.openTrade(p) { ok = true; } catch {}
        else if (w == 1) try vault.queue(abi.encodeCall(GainsVault.setManager, (operator))) { ok = true; } catch {}
        else if (w == 2) try vault.setDepositsPaused(true) { ok = true; } catch {}
        else if (w == 3) try vault.triggerBreach() { ok = true; } catch {}
        else if (w == 4) try vault.clearBreach() { ok = true; } catch {}
        else if (w == 5) try vault.setOperator(address(0xE5C)) { ok = true; } catch {}
        else if (w == 6) try vault.setDepositCap(1) { ok = true; } catch {}
        else if (w == 7) try vault.lowerFees(0, 0) { ok = true; } catch {}
        else if (w == 8) try vault.revokeAgent() { ok = true; } catch {}
        else if (w == 9) try vault.resume() { ok = true; } catch {}
        else if (w == 10) try vault.increaseTrade(idx, 1e6, 2_000, ethPx, 1_000) { ok = true; } catch {}
        else if (w == 11) try vault.setSlTp(idx, 1, 0) { ok = true; } catch {}
        else if (w == 12) try vault.updateLeverage(idx, 1_100) { ok = true; } catch {}
        // Outside a breach the operator only reduces to fund redemptions: never above the shortfall, never a close.
        else if (w == 14) { if (calm) try vault.reduceTrade(idx, uint120(over), 0, ethPx) { ok = true; } catch {} }
        else if (w == 15) { if (calm) try vault.closeTrade(idx, ethPx) { ok = true; } catch {} }
        else try vault.cancelOrder(idx) { ok = true; } catch {}
        vm.stopPrank();
        if (ok) vOperatorEscaped++;
    }

    function exposureInReduceOnly(uint256 lev) external {
        if (!vault.breached() && !vault.emergency()) return;
        OpenParams memory p = OpenParams(1, true, 1_000e6, 2_000, ethPx, 1_000, 0, 0, 0);
        vm.prank(manager);
        try vault.openTrade(p) {
            vExposureUp++;
        } catch {}
        IGainsDiamond.Trade[] memory t = diamond.getTrades(address(vault));
        if (t.length == 0 || t[0].tradeType != 0) return;
        vm.prank(manager);
        try vault.increaseTrade(t[0].index, 1e6, 2_000, _px(t[0].pairIndex), 1_000) {
            vExposureUp++;
        } catch {}
        vm.prank(manager);
        try vault.updateLeverage(t[0].index, t[0].leverage + uint24(bound(lev, 1, 1_000))) {
            vExposureUp++;
        } catch {}
        // more margin is fine in a leverage breach, never in a loss breach or a full stop
        if (vault.emergency() || uint8(vault.breachReason()) >= 2) {
            vm.prank(manager);
            try vault.updateLeverage(t[0].index, t[0].leverage > 1_200 ? t[0].leverage - 100 : t[0].leverage) {
                vExposureUp++;
            } catch {}
        }
    }
}

contract GainsRound4Invariants is GainsBase {
    GainsHandler internal h;
    address internal operator = makeAddr("operator");

    function setUp() public override {
        super.setUp();
        diamond.setPair(ETH, 3.5e8, 285.7e18, 0.1e18, 1e7); // 0.035% per side, a small spread
        diamond.setPair(BTC, 3.5e8, 285.7e18, 0.1e18, 1e7);
        vm.prank(owner);
        vault.setOperator(operator);
        h = new GainsHandler(vault, usdc, diamond, ethFeed, btcFeed, sequencer, owner, manager, operator, guardian);
        h.seed();
        targetContract(address(h));
        bytes4[] memory skip = new bytes4[](2);
        skip[0] = GainsHandler.seed.selector;
        skip[1] = GainsHandler.actor.selector;
        excludeSelector(FuzzSelector({addr: address(h), selectors: skip}));
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 100
    /// forge-config: default.invariant.fail-on-revert = false
    /// forge-config: default.invariant.show-metrics = true
    function invariant_flowsAndFeesNeverMoveTheRiskMetrics() public view {
        assertEq(h.vFlowMovedMetrics(), 0, "deposit / redeem / fee flows moved daily loss or drawdown");
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 100
    /// forge-config: default.invariant.fail-on-revert = false
    function invariant_onlyListedRolesUnwind() public view {
        assertEq(h.vOutsiderActed(), 0, "a stranger or depositor flattened, closed, reduced or settled");
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 100
    /// forge-config: default.invariant.fail-on-revert = false
    function invariant_operatorStaysInTheTreasury() public view {
        assertEq(h.vOperatorEscaped(), 0, "the operator reached a non treasury function");
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 100
    /// forge-config: default.invariant.fail-on-revert = false
    function invariant_reduceOnlyNeverIncreasesExposure() public view {
        assertEq(h.vExposureUp(), 0, "exposure went up in reduce only mode");
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 100
    /// forge-config: default.invariant.fail-on-revert = false
    function invariant_noSettleWithPendingOrTimedOutOrders() public view {
        assertEq(h.vSettledWithPending(), 0, "a settle priced collateral in flight");
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 100
    /// forge-config: default.invariant.fail-on-revert = false
    function invariant_exitsAlwaysCallable() public view {
        assertEq(h.vExitBlocked(), 0, "an exit reverted");
    }

    /// @dev Reserves are always backed, and every share is held by someone the vault knows about.
    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 100
    /// forge-config: default.invariant.fail-on-revert = false
    function invariant_sharesAndAssetsAccounting() public view {
        uint256 reserved = vault.pendingDepositAssets() + vault.deferredDepositAssets() + vault.claimableRedeemAssets();
        assertGe(usdc.balanceOf(address(vault)), reserved, "queued deposits and claimable redemptions are backed");
        uint256 held = vault.balanceOf(address(vault)) + vault.balanceOf(feeRecipient);
        for (uint256 i; i < 3; ++i) {
            held += vault.balanceOf(h.actor(i));
        }
        assertEq(held, vault.totalSupply(), "every share accounted for");
        assertGe(vault.balanceOf(address(vault)), vault.pendingRedeemShares(), "queued redemptions are escrowed");
        assertEq(usdc.allowance(address(vault), address(diamond)), 0, "never a standing approval");
    }

    /// @dev NAV is never above what Gains would pay at the oracle price: idle USDC + every open trade closed at the
    ///      oracle (here = Chainlink) price + resting collateral + pending opens net of the cancel gov fee.
    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 100
    /// forge-config: default.invariant.fail-on-revert = false
    function invariant_navNeverAboveTheOraclePayout() public view {
        uint256 payout = vault.idleAssets();
        IGainsDiamond.Trade[] memory t = diamond.getTrades(address(vault));
        for (uint256 i; i < t.length; ++i) {
            if (t[i].tradeType != 0) payout += t[i].collateralAmount;
            else payout += diamond.closeValue(address(vault), t[i].index, t[i].pairIndex == BTC ? h.btcPx() : h.ethPx());
        }
        IGainsDiamond.PendingOrder[] memory o = diamond.getPendingOrders(address(vault));
        for (uint256 i; i < o.length; ++i) {
            bool holds = o[i].orderType == 0 || o[i].orderType == 8
                || (o[i].orderType == 7 && o[i].trade.leverage < diamond.getTrade(address(vault), o[i].trade.index).leverage);
            if (holds) {
                uint256 fee = diamond.minGovFee(o[i].trade.pairIndex);
                payout += o[i].trade.collateralAmount > fee ? o[i].trade.collateralAmount - fee : 0;
            }
        }
        assertLe(vault.totalAssets(), payout, "NAV above collateral + PnL at the oracle price");
    }

    function afterInvariant() external {
        emit log_named_uint("settles", h.settles());
        emit log_named_uint("breach observations", h.breaches());
        emit log_named_uint("timed-out cancels", h.timeouts());
        emit log_named_uint("exit rounds under a price outage", h.exitsUnderOutage());
    }
}

contract GainsHandlerSanity is GainsBase {
    function test_handlerSettlesTradesAndTimesOut() public {
        address op = makeAddr("operator");
        vm.prank(owner);
        vault.setOperator(op);
        GainsHandler h = new GainsHandler(vault, usdc, diamond, ethFeed, btcFeed, sequencer, owner, manager, op, guardian);
        h.seed();
        h.deposit(1, 5_000e6);
        h.settle(true, 1);
        h.trade(false, true, 10, 5_000, 0);
        h.trade(true, false, 10, 5_000, 5); // left pending
        h.settle(false, 0); // tries with the order pending: refused
        assertEq(h.vSettledWithPending(), 0);
        h.timeout();
        assertGe(h.timeouts(), 1);
        h.redeem(0, 10);
        h.move(false, -100);
        h.settle(false, 1);
        h.accrue(5 hours);
        h.outage(0, true);
        h.outage(5, false);
        assertEq(h.vExitBlocked(), 0);
        h.oracle();
        h.deposit(2, 1_000e6);
        h.settle(true, 1);
        assertGe(h.settles(), 3, "the handler really settles");
    }
}
