// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {R1Base} from "../../R1Base.t.sol";
import {GainsVault} from "../../../../../src/gains/GainsVault.sol";
import {GainsVaultPolicy} from "../../../../../src/gains/GainsVaultPolicy.sol";
import {IGainsDiamond} from "../../../../../src/gains/IGainsDiamond.sol";
import {InitParams, OpenParams} from "../../../../../src/gains/GainsTypes.sol";
import {MockGainsDiamond} from "../../../../gains/mocks/GainsMocks.sol";

/// @dev The mock with Gains' real limit execution (TradingCallbacksUtils.executeTriggerOpenOrderCallbackDirect, facet
///      0xe19779...: closeTrade(old limit index) then _registerTrade -> storeTrade at a NEW index). The base mock reuses
///      the resting index. Etched over the harness diamond: no new storage, same layout.
contract RealLimitDiamond is MockGainsDiamond {
    constructor(IERC20 u) MockGainsDiamond(u) {}

    function executeLimitNewIndex(address user, uint32 index, uint64 price) external returns (uint32 idx) {
        IGainsDiamond.Trade memory r = _trades[user][index];
        require(r.isOpen && r.tradeType != 0, "mock: no limit order");
        _trades[user][index].isOpen = false;
        r.tradeType = 0;
        idx = _storeTrade(user, r, price, _infos[user][index].maxSlippageP);
    }
}

/// @notice Cross-review of the GR2-LIVE-01 patch (contracts/audit/gains/r2/XREVIEW-FIXES.md). Runs on the tree with all
///         five patches applied (scratchpad XR-FIX/all).
contract XRLive01Test is R1Base {
    RealLimitDiamond internal rd;

    function setUp() public override {
        super.setUp();
        RealLimitDiamond impl = new RealLimitDiamond(IERC20(address(usdc)));
        vm.etch(address(diamond), address(impl).code);
        rd = RealLimitDiamond(address(diamond));
    }

    function _live() internal pure returns (GainsVaultPolicy.RiskConfig memory) {
        return GainsVaultPolicy.RiskConfig({
            maxLeverageBps: 50_000,
            maxDailyLossBps: 1_500,
            maxDrawdownBps: 5_000,
            maxSlippageBps: 100,
            maxOrderNotional: 250_000e6,
            maxEpochDuration: 1 days,
            maxNavMoveBps: 2_000,
            maxFlattenSlippageBps: 300
        });
    }

    function _mk() internal returns (GainsVault v) {
        uint32[] memory assets = new uint32[](2);
        assets[0] = BTC;
        assets[1] = ETH;
        v = GainsVault(Clones.clone(address(vaultImpl)));
        GainsVaultPolicy p = GainsVaultPolicy(Clones.clone(address(policyImpl)));
        p.initialize(owner, _live(), assets, 2 days, address(platform), address(v));
        InitParams memory ip = _standaloneParams(p);
        ip.managementFeeBps = 0;
        ip.performanceFeeBps = 0;
        ip.timelockDelay = 2 days;
        v.initialize(ip);
        vm.prank(alice);
        usdc.approve(address(v), type(uint256).max);
        _depositTo(v, alice, 100_000e6);
        _settleV(v);
        v.claim(alice);
    }

    function _limit(GainsVault v, uint16 pair, uint120 coll, uint24 lev, uint64 trigger) internal returns (uint32 idx) {
        OpenParams memory p = _params(pair, true, coll, lev);
        p.tradeType = 1;
        p.expectedPrice = trigger;
        vm.prank(manager);
        v.openTrade(p);
        idx = diamond.tradeCount(address(v)) - 1;
    }

    // ------------------------------------------------------------------ set comparison with Gains' own lists
    function _hasTrade(IGainsDiamond.Trade[] memory a, IGainsDiamond.Trade memory t) internal pure returns (bool) {
        for (uint256 i; i < a.length; ++i) {
            if (
                a[i].index == t.index && a[i].collateralAmount == t.collateralAmount && a[i].positionSizeToken == t.positionSizeToken
                    && a[i].tradeType == t.tradeType && a[i].leverage == t.leverage
            ) return true;
        }
        return false;
    }

    function _hasOrder(IGainsDiamond.PendingOrder[] memory a, IGainsDiamond.PendingOrder memory o) internal pure returns (bool) {
        for (uint256 i; i < a.length; ++i) {
            if (a[i].index == o.index && a[i].orderType == o.orderType && a[i].trade.collateralAmount == o.trade.collateralAmount) return true;
        }
        return false;
    }

    /// @dev The index-set reader returns exactly Gains' open trades and open pending orders (as sets; the snapshot is
    ///      a sum over them, so equal sets give the old reader's NAV, notional and counts).
    function _assertParity(GainsVault v, string memory what) internal view {
        (IGainsDiamond.Trade[] memory t1, IGainsDiamond.PendingOrder[] memory o1) = v.openItems();
        IGainsDiamond.Trade[] memory t0 = diamond.getTrades(address(v));
        IGainsDiamond.PendingOrder[] memory o0 = diamond.getPendingOrders(address(v));
        assertEq(t1.length, t0.length, string.concat(what, ": trade count"));
        assertEq(o1.length, o0.length, string.concat(what, ": order count"));
        for (uint256 i; i < t0.length; ++i) {
            assertTrue(_hasTrade(t1, t0[i]), string.concat(what, ": a Gains trade is missing from the index set"));
        }
        for (uint256 i; i < o0.length; ++i) {
            assertTrue(_hasOrder(o1, o0[i]), string.concat(what, ": a Gains order is missing from the index set"));
        }
    }

    function _indexSet(GainsVault v) internal view returns (uint32 tc, uint32 oc, uint32[] memory tr, uint32[] memory or_) {
        return v.indexSet();
    }

    // ------------------------------------------------------------------ 1. real limit execution (new index)
    /// @notice Gains executes a resting limit by closing its index and storing the trade at a NEW index. The new trade
    ///         is valued before any sync, and a stranger's sync tracks it and prunes the closed resting index.
    function test_XR_LIVE01_realLimitExecutionNewIndex_valuedAndTracked() public {
        GainsVault v = _mk();
        uint32 lim = _limit(v, ETH, 5_000e6, 10_000, _px(ETH) * 99 / 100);
        v.syncIndexes(type(uint256).max);
        (,, uint32[] memory tr,) = _indexSet(v);
        assertEq(tr.length, 1, "the resting limit is tracked");
        uint32 n = rd.executeLimitNewIndex(address(v), lim, _px(ETH) * 99 / 100);
        assertGt(n, lim, "new index");
        _assertParity(v, "after a real limit execution, no sync");
        _setPrice(ETH, _px(ETH) * 102 / 100);
        uint256 nav = v.totalAssets();
        assertGt(nav, 100_000e6 + 1_400e6, "the executed trade's gain is in NAV without a sync");
        vm.prank(stranger);
        v.syncIndexes(type(uint256).max);
        (,, tr,) = _indexSet(v);
        assertEq(tr.length, 1, "only the new trade is tracked");
        assertEq(tr[0], n, "it is the new index");
        assertEq(v.totalAssets(), nav, "a stranger's sync changes nothing");
        _assertParity(v, "after the stranger's sync");
    }

    // ------------------------------------------------------------------ 2. parity fuzz
    struct Ctx {
        GainsVault v;
        uint256 seed;
    }

    function _rnd(Ctx memory c) internal pure returns (uint256 r) {
        c.seed = uint256(keccak256(abi.encode(c.seed)));
        r = c.seed;
    }

    function _step(Ctx memory c) internal {
        GainsVault v = c.v;
        uint256 a = _rnd(c) % 13;
        IGainsDiamond.Trade[] memory ts = diamond.getTrades(address(v));
        IGainsDiamond.PendingOrder[] memory os = diamond.getPendingOrders(address(v));
        if (a == 0) {
            uint16 pair = _rnd(c) % 2 == 0 ? BTC : ETH;
            OpenParams memory p = _params(pair, _rnd(c) % 2 == 0, uint120(1_000e6 + _rnd(c) % 4_000e6), uint24(2_000 + _rnd(c) % 8_000));
            vm.prank(manager);
            try v.openTrade(p) {} catch {}
        } else if (a == 1 && os.length > 0) {
            IGainsDiamond.PendingOrder memory o = os[_rnd(c) % os.length];
            uint16 pair = o.trade.pairIndex;
            if (o.orderType != 0) pair = diamond.getTrade(address(v), o.trade.index).pairIndex;
            try diamond.fill(address(v), o.index, _px(pair)) {} catch {}
        } else if (a == 2) {
            uint16 pair = _rnd(c) % 2 == 0 ? BTC : ETH;
            OpenParams memory p = _params(pair, true, uint120(1_000e6 + _rnd(c) % 3_000e6), 5_000);
            p.tradeType = 1;
            p.expectedPrice = _px(pair) * 98 / 100;
            vm.prank(manager);
            try v.openTrade(p) {} catch {}
        } else if (a == 3 && ts.length > 0) {
            IGainsDiamond.Trade memory t = ts[_rnd(c) % ts.length];
            if (t.tradeType != 0) {
                if (_rnd(c) % 2 == 0) {
                    try rd.executeLimitNewIndex(address(v), t.index, _px(t.pairIndex)) {} catch {}
                } else {
                    try diamond.executeLimit(address(v), t.index, _px(t.pairIndex)) {} catch {}
                }
            }
        } else if (a == 4 && ts.length > 0) {
            IGainsDiamond.Trade memory t = ts[_rnd(c) % ts.length];
            vm.prank(manager);
            try v.closeTrade(t.index, _px(t.pairIndex)) {} catch {}
        } else if (a == 5 && ts.length > 0) {
            IGainsDiamond.Trade memory t = ts[_rnd(c) % ts.length];
            vm.prank(manager);
            try v.reduceTrade(t.index, t.collateralAmount / 3, 0, _px(t.pairIndex)) {} catch {}
        } else if (a == 6 && ts.length > 0) {
            IGainsDiamond.Trade memory t = ts[_rnd(c) % ts.length];
            if (t.tradeType == 0) {
                try diamond.trigger(address(v), t.index, _px(t.pairIndex)) {} catch {} // TP / SL / liquidation by Gains
            }
        } else if (a == 7 && os.length > 0) {
            try diamond.cancelInCallback(address(v), os[_rnd(c) % os.length].index) {} catch {}
        } else if (a == 8 && ts.length > 0) {
            IGainsDiamond.Trade memory t = ts[_rnd(c) % ts.length];
            vm.prank(manager);
            try v.cancelOrder(t.index) {} catch {}
        } else if (a == 9) {
            vm.prank(stranger);
            v.syncIndexes(_rnd(c) % 4);
        } else if (a == 10) {
            uint16 pair = _rnd(c) % 2 == 0 ? BTC : ETH;
            _setPrice(pair, _rnd(c) % 2 == 0 ? _px(pair) * 101 / 100 : _px(pair) * 99 / 100);
        } else if (a == 11 && os.length > 0) {
            vm.roll(vm.getBlockNumber() + 201);
            try v.cancelTimedOut(os[_rnd(c) % os.length].index) {} catch {}
        } else if (a == 12 && ts.length > 0) {
            IGainsDiamond.Trade memory t = ts[_rnd(c) % ts.length];
            if (t.tradeType == 0) {
                vm.prank(manager);
                try v.increaseTrade(t.index, uint120(500e6), 2_000, _px(t.pairIndex), SLIP) {} catch {}
            }
        }
    }

    /// @notice 60 random steps (market and limit opens, fills, real and mock limit executions, vault closes and partial
    ///         closes, Gains TP / SL / liquidation closes, callback cancels, limit cancels, timeouts, increases, price
    ///         moves, a stranger's syncIndexes with 0..3 steps at random moments): after every step the index-set reader
    ///         holds exactly Gains' open trades and pending orders. After a full sync the tracked arrays are exactly the
    ///         open items (bounded by them).
    function testFuzz_XR_LIVE01_parityWithGainsListsUnderRandomHistory(uint256 seed) public {
        Ctx memory c = Ctx(_mk(), seed);
        for (uint256 i; i < 60; ++i) {
            _step(c);
            _assertParity(c.v, "random step");
        }
        c.v.syncIndexes(type(uint256).max);
        (uint32 tc, uint32 oc, uint32[] memory tr, uint32[] memory or_) = _indexSet(c.v);
        assertEq(tc, diamond.tradeCount(address(c.v)), "trade cursor at the counter");
        assertEq(oc, diamond.orderCount(address(c.v)), "order cursor at the counter");
        assertEq(tr.length, diamond.getTrades(address(c.v)).length, "tracked trades = open trades");
        assertEq(or_.length, diamond.getPendingOrders(address(c.v)).length, "tracked orders = open orders");
    }

    // ------------------------------------------------------------------ 3. close-only churn: unseen ORDER range
    /// @notice Was the XF-03 PoC: closeTrade / reduceTrade / flatten did not sync, so a manager (or agent) who only
    ///         partially closed one trade grew the unseen pending-order range by one per request (300 after 300
    ///         reduces), and every NAV reader walked it until a sync. Fixed (GR2 XF-03, fix round WP2): every close,
    ///         reduce and flatten syncs first, so after 300 reduces at most the last request is unseen and the NAV
    ///         read costs what it costs synced, plus at most one index.
    function test_XR_LIVE01_XF03_fix_reduceChurnKeepsUnseenOrdersBounded() public {
        GainsVault v = _mk();
        uint32 t = _open(v, ETH, true, 50_000e6, 2_000);
        v.syncIndexes(type(uint256).max);
        uint256 g0 = gasleft();
        v.totalAssets();
        g0 -= gasleft();
        _passHold(); // the manager's reduces wait out the GR2-KEY-01b minimum hold
        uint256 n = 300;
        for (uint256 i; i < n; ++i) {
            vm.prank(manager);
            v.reduceTrade(t, 10e6, 0, _px(ETH));
            _fillLast(v, _px(ETH));
        }
        (, uint32 oc,,) = _indexSet(v);
        assertLe(diamond.orderCount(address(v)) - oc, 1, "at most the last request is unseen");
        uint256 g1 = gasleft();
        v.totalAssets();
        g1 -= gasleft();
        console2.log("totalAssets gas: synced / after 300 reduces", g0, g1);
        assertLt(g1, g0 + 50_000, "flat: no unseen range to walk");
        _assertParity(v, "after churn");
    }

    /// @notice The full stop (guardian triggerEmergency) and an exit-only settle work with a large unseen order range:
    ///         tryReadTrades walks only the trade range (no new trade index comes from closes), settle's sync(max) pays
    ///         the catch-up once.
    function test_XR_LIVE01_fullStopAndSettleWithUnseenOrders() public {
        GainsVault v = _mk();
        uint32 t = _open(v, ETH, true, 50_000e6, 2_000);
        _passHold(); // fix round WP2: the manager's reduces wait out the GR2-KEY-01b minimum hold
        for (uint256 i; i < 200; ++i) {
            vm.prank(manager);
            v.reduceTrade(t, 10e6, 0, _px(ETH));
            _fillLast(v, _px(ETH));
        }
        _redeemFrom(v, alice, v.balanceOf(alice) / 10);
        uint256 g = gasleft();
        vm.prank(guardian);
        v.triggerEmergency();
        g -= gasleft();
        console2.log("triggerEmergency gas with 200 unseen orders", g);
        _skip(1 hours);
        v.checkRisk();
        vm.prank(guardian);
        v.settle();
        assertEq(v.currentEpoch(), 2, "settled exit-only");
        (, uint32 oc,, uint32[] memory or_) = _indexSet(v);
        assertEq(oc, diamond.orderCount(address(v)), "settle synced the order cursor");
        assertEq(or_.length, 0, "nothing pending tracked");
    }
}
