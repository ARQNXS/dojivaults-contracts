// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {console2} from "forge-std/Test.sol";
import {stdStorage, StdStorage} from "forge-std/StdStorage.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {R1Base} from "../../R1Base.t.sol";
import {GainsVault} from "../../../../../src/gains/GainsVault.sol";
import {GainsVaultPolicy} from "../../../../../src/gains/GainsVaultPolicy.sol";
import {GainsNav} from "../../../../../src/gains/GainsNav.sol";
import {InitParams, OpenParams} from "../../../../../src/gains/GainsTypes.sol";

/// @notice GR2-LIVE-01 fix test, mock diamond (contracts/audit/gains/r2/fixes/GR2-LIVE-01). Run it from
///         contracts/test/audit/gains/r2/fixes/. The gas tests assert the FIXED behaviour (fail on 4ec6feb, pass with
///         fix.diff); the parity test asserts the snapshot numbers the 4ec6feb list reader (getTrades /
///         getPendingOrders) produces on a mixed state, so it passes on both trees: the index-set reader values exactly
///         what the old reader valued. New functions (syncIndexes, indexSet) are called with low-level calls so the
///         file compiles on 4ec6feb.
contract LIVE01FixTest is R1Base {
    using stdStorage for StdStorage;

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

    /// @dev `n` limit orders placed and cancelled through the vault: each consumes a Gains trade index for good.
    function _churn(GainsVault v, uint256 n) internal {
        uint64 trigger = _px(ETH) * 90 / 100;
        for (uint256 i; i < n; ++i) {
            uint32 idx = _limit(v, ETH, 1_000e6, 2_000, trigger);
            vm.prank(manager);
            v.cancelOrder(idx);
        }
    }

    function _sync(GainsVault v) internal {
        (bool ok,) = address(v).call(abi.encodeWithSignature("syncIndexes(uint256)", type(uint256).max));
        ok; // absent on 4ec6feb
    }

    function _gasCheckRisk(GainsVault v) internal returns (uint256 g) {
        _skip(1 hours);
        g = gasleft();
        v.checkRisk();
        g -= gasleft();
    }

    function _gasSettle(GainsVault v) internal returns (uint256 g) {
        _skip(1 hours);
        vm.prank(manager);
        g = gasleft();
        v.settle();
        g -= gasleft();
    }

    /// @notice Mixed state: two filled market trades, a resting limit, a pending market open, a pending close, and
    ///         history (a cancelled limit, a closed trade, a timed-out order cancelled). The numbers are what the
    ///         4ec6feb list reader returns (run-unfixed.txt); the index-set reader must return the same.
    function test_LIVE01_fix_navParityWithTheListReaderOnAMixedState() public {
        GainsVault v = _mk();
        uint32 a = _open(v, ETH, true, 10_000e6, 20_000); // 200k ETH long
        uint32 b = _open(v, BTC, false, 5_000e6, 10_000); // 50k BTC short
        uint32 dead = _open(v, ETH, false, 2_000e6, 5_000);
        _passHold(); // fix round WP2: the manager's close waits out the GR2-KEY-01b minimum hold
        _closeFilled(v, dead, _px(ETH)); // closed trade in the history
        uint32 cancelled = _limit(v, BTC, 1_000e6, 5_000, _px(BTC) * 95 / 100);
        vm.prank(manager);
        v.cancelOrder(cancelled); // cancelled limit in the history
        _request(v, ETH, true, 1_000e6, 5_000); // will time out
        vm.roll(vm.getBlockNumber() + 300);
        v.cancelTimedOut(diamond.orderCount(address(v)) - 1); // cancelled order in the history
        _limit(v, ETH, 3_000e6, 10_000, _px(ETH) * 97 / 100); // resting limit
        _request(v, BTC, true, 4_000e6, 10_000); // pending market open
        vm.prank(guardian); // never held: the BTC open just requested would hold the manager's close (GR2-KEY-01b)
        v.closeTrade(b, _px(BTC)); // pending close on b
        _setPrice(ETH, _px(ETH) * 102 / 100);
        _setPrice(BTC, _px(BTC) * 99 / 100);
        a;

        GainsNav.Snapshot memory s = v.venue();
        console2.log("value", s.value);
        console2.log("notional", s.notional);
        console2.log("orders / pending / blocking", s.orders, s.pending, s.blocking);
        console2.log("totalAssets", v.totalAssets());
        assertEq(s.value, 25_993_000_000, "value");
        assertEq(s.notional, 323_499_999_999, "notional");
        assertEq(s.orders, 5, "orders");
        assertEq(s.pending, 2, "pending");
        assertEq(s.blocking, 1, "blocking");
        assertEq(v.totalAssets(), 103_993_000_000, "totalAssets");
        assertEq(lens.openPositions(v), 5, "lens openPositions");
    }

    /// @notice A trade Gains creates for the vault on a fill (an index the vault never saw at its request) is valued
    ///         at once, without any sync: the unseen range [cursor, counter) is always read.
    function test_LIVE01_fix_fillCreatedIndexValuedWithoutSync() public {
        GainsVault v = _mk();
        uint256 navBefore = v.totalAssets();
        _request(v, ETH, true, 10_000e6, 20_000);
        _fillLast(v, _px(ETH));
        _setPrice(ETH, _px(ETH) * 101 / 100);
        assertGt(v.totalAssets(), navBefore + 1_500e6, "the filled trade's +2 % is in NAV");
    }

    /// @notice 300 limit orders placed and cancelled (300 lifetime trade indexes): checkRisk and settle cost the same
    ///         as before them (old reader: + ~4.2k gas per lifetime index on the mock, + ~2.4k on the real diamond).
    function test_LIVE01_fix_gasFlatInLifetimeIndexes_churn() public {
        GainsVault v = _mk();
        _open(v, ETH, true, 10_000e6, 20_000);
        uint256 c0 = _gasCheckRisk(v);
        uint256 s0 = _gasSettle(v);
        _churn(v, 300);
        _sync(v);
        uint256 c1 = _gasCheckRisk(v);
        uint256 s1 = _gasSettle(v);
        console2.log("checkRisk gas: 0 / 300 lifetime indexes", c0, c1);
        console2.log("settle gas:    0 / 300 lifetime indexes", s0, s1);
        assertLt(c1, c0 + 30_000, "checkRisk flat");
        assertLt(s1, s0 + 30_000, "settle flat");
        (bool ok, bytes memory r) = address(v).staticcall(abi.encodeWithSignature("indexSet()"));
        assertTrue(ok, "indexSet() exists");
        (,, uint32[] memory trades, uint32[] memory orders) = abi.decode(r, (uint32, uint32, uint32[], uint32[]));
        assertEq(trades.length, 1, "only the open trade is tracked");
        assertEq(orders.length, 0, "no pending order tracked");
    }

    /// @notice 50,000 lifetime indexes on both counters (vm.store on the mock, the vault synced once in chunks): the
    ///         per-settle cost stays at the fresh vault's.
    function test_LIVE01_fix_gasFlatInLifetimeIndexes_50k() public {
        GainsVault v = _mk();
        _open(v, ETH, true, 10_000e6, 20_000);
        uint256 c0 = _gasCheckRisk(v);
        uint256 s0 = _gasSettle(v);
        stdstore.target(address(diamond)).sig("tradeCount(address)").with_key(address(v)).checked_write(uint256(50_000));
        stdstore.target(address(diamond)).sig("orderCount(address)").with_key(address(v)).checked_write(uint256(50_000));
        vm.pauseGasMetering(); // the one-time catch-up of 100,000 unseen indexes (an organic vault syncs as it goes)
        for (uint256 i; i < 10; ++i) {
            (bool ok,) = address(v).call(abi.encodeWithSignature("syncIndexes(uint256)", uint256(10_000)));
            ok;
        }
        vm.resumeGasMetering();
        uint256 c1 = _gasCheckRisk(v);
        uint256 s1 = _gasSettle(v);
        console2.log("checkRisk gas: fresh / 50,000 lifetime indexes", c0, c1);
        console2.log("settle gas:    fresh / 50,000 lifetime indexes", s0, s1);
        assertLt(c1, c0 + 30_000, "checkRisk flat");
        assertLt(s1, s0 + 30_000, "settle flat");
    }
}
