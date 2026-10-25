// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {R2Base} from "../../fixes/R2Base.sol";
import {TradeMid} from "../../fixes/R2Regression.t.sol";
import {GainsVault} from "../../../../../src/gains/GainsVault.sol";
import {IGainsDiamond, GTrade} from "../../../../../src/gains/IGainsDiamond.sol";
import {GainsNav} from "../../../../../src/gains/GainsNav.sol";
import {IGainsVaultErrors as E} from "../../../../../src/gains/GainsTypes.sol";

/// @notice Cross-review of GR2-LIVE-01: the 9 regression tests the patch breaks (they inject malformed getTrades /
///         getPendingOrders output, which the patched vault no longer calls) PORTED to the per-index reads
///         (getTrade(vault, i), getPendingOrder((vault, i)), getCounters). If the properties hold on the patched tree,
///         the "tests to port" are a test-harness change only, not a lost protection. Tree with all five patches.
contract XRLive01PortsTest is R2Base {
    bytes4 internal LAYOUT = E.DiamondLayoutChanged.selector;

    function _threeOpen() internal returns (GainsNav.Snapshot memory real, uint32 a, uint32 b, uint32 c) {
        _deposit(alice, 100_000e6);
        _settle();
        _claim(alice);
        a = _open(vault, ETH, true, 30_000e6, 3_000);
        b = _open(vault, BTC, true, 30_000e6, 3_000);
        c = _open(vault, ETH, false, 30_000e6, 3_000);
        real = vault.venue();
    }

    function _mockTrade(uint32 i, IGainsDiamond.Trade memory t) internal {
        vm.mockCall(address(diamond), abi.encodeCall(IGainsDiamond.getTrade, (address(vault), i)), abi.encode(t));
    }

    // ------------------------------------------------------------------ GV-01 (R2Regression x3)
    /// @notice A field inserted before positionSizeToken in getTrade: the snapshot and an open revert
    ///         DiamondLayoutChanged, for a tracked index (synced) and for an unseen one.
    function test_PORT_GV01_fieldInsertedBeforePositionSize_trackedAndUnseen() public {
        (, uint32 a,,) = _threeOpen();
        for (uint256 synced; synced < 2; ++synced) {
            if (synced == 1) vault.syncIndexes(type(uint256).max);
            IGainsDiamond.Trade memory q = diamond.getTrade(address(vault), a);
            TradeMid memory x = TradeMid(
                q.user, q.index, q.pairIndex, q.leverage, q.long, q.isOpen, q.collateralIndex, q.tradeType, q.collateralAmount,
                q.openPrice, q.tp, q.sl, q.isCounterTrade, 1, q.positionSizeToken, 0
            );
            vm.mockCall(address(diamond), abi.encodeCall(IGainsDiamond.getTrade, (address(vault), a)), abi.encode(x));
            vm.expectRevert(LAYOUT);
            vault.venue();
            vm.prank(manager);
            vm.expectRevert(LAYOUT);
            vault.openTrade(_params(BTC, true, 10_000e6, 20_000));
            vm.clearMockedCalls();
        }
    }

    function test_PORT_GV01_openTradeWithImpossibleSize() public {
        (GainsNav.Snapshot memory real, uint32 a,,) = _threeOpen();
        vault.syncIndexes(type(uint256).max);
        IGainsDiamond.Trade memory t = diamond.getTrade(address(vault), a);
        uint160 size = t.positionSizeToken;
        uint160[3] memory bad = [uint160(0), size / 5, size * 5];
        for (uint256 i; i < 3; ++i) {
            t.positionSizeToken = bad[i];
            _mockTrade(a, t);
            vm.expectRevert(LAYOUT);
            vault.venue();
        }
        t.positionSizeToken = (size * 11) / 10;
        _mockTrade(a, t);
        assertEq(vault.venue().value, real.value, "a 10 % drift still values");
    }

    function test_PORT_GV01_implausibleOpenTrade() public {
        (, , uint32 b,) = _threeOpen();
        for (uint256 k; k < 4; ++k) {
            IGainsDiamond.Trade memory t = diamond.getTrade(address(vault), b);
            if (k == 0) t.leverage = 0;
            if (k == 1) t.openPrice = 0;
            if (k == 2) t.collateralAmount = 0;
            if (k == 3) t.tradeType = 3;
            _mockTrade(b, t);
            vm.expectRevert(LAYOUT);
            vault.venue();
            vm.clearMockedCalls();
        }
        IGainsDiamond.Trade memory c = diamond.getTrade(address(vault), b);
        c.isOpen = false;
        c.leverage = 0;
        c.openPrice = 0;
        _mockTrade(b, c);
        vault.venue(); // a closed element may hold zeros
    }

    // ------------------------------------------------------------------ GV-02 (R2Regression, VerifyR2Mock)
    function _pendingOpen() internal returns (uint32 o, uint256 navKnown) {
        _seed(vault, alice, 50_000e6);
        _seed(vault, bob, 50_000e6);
        o = _request(vault, ETH, true, 15_000e6, 2_000); // holds 15k
        navKnown = vault.venue().value;
    }

    function test_PORT_GV02_unknownTypeBlocksAndCounts_everyKnownNonHoldingTypeDoesNot() public {
        (uint32 o, uint256 navKnown) = _pendingOpen();
        _redeem(bob, vault.balanceOf(bob));
        IGainsDiamond.PendingOrder memory p = diamond.getPendingOrder(address(vault), o);
        uint8[4] memory unknown = [10, 11, 12, 200];
        for (uint256 i; i < 4; ++i) {
            p.orderType = unknown[i];
            vm.mockCall(address(diamond), abi.encodeCall(IGainsDiamond.getPendingOrder, (IGainsDiamond.Id(address(vault), o))), abi.encode(p));
            assertTrue(vault.ordersPending(), "unknown type: settle waits");
            assertEq(vault.venue().value, navKnown, "collateral counted like a known open");
            vm.prank(manager);
            vm.expectRevert(E.OrdersPending.selector);
            vault.settle();
        }
        uint8[7] memory free = [GTrade.MARKET_CLOSE, GTrade.MARKET_PARTIAL_CLOSE, GTrade.LIMIT_OPEN, GTrade.STOP_OPEN, GTrade.TP_CLOSE, GTrade.SL_CLOSE, GTrade.LIQ_CLOSE];
        for (uint256 i; i < free.length; ++i) {
            p.orderType = free[i];
            vm.mockCall(address(diamond), abi.encodeCall(IGainsDiamond.getPendingOrder, (IGainsDiamond.Id(address(vault), o))), abi.encode(p));
            assertFalse(vault.ordersPending(), "known non-holding type does not block");
            assertEq(vault.venue().blocking, 0);
        }
        // and once synced (tracked rather than unseen) the same
        vm.clearMockedCalls();
        vault.syncIndexes(type(uint256).max);
        p.orderType = 10;
        vm.mockCall(address(diamond), abi.encodeCall(IGainsDiamond.getPendingOrder, (IGainsDiamond.Id(address(vault), o))), abi.encode(p));
        assertTrue(vault.ordersPending(), "tracked unknown type: settle waits");
    }

    // ------------------------------------------------------------------ GR1-08 (R1Regression, IntegrationMock, Liveness D1)
    /// @notice getTrade unreadable for one index (odd trailing bytes): NAV, flatten and opens revert
    ///         DiamondLayoutChanged; flattenIndices still closes; the guardian's full stop still stops (tryReadTrades
    ///         returns ok = false). Same with getCounters reverting.
    function test_PORT_GR1_08_unreadableGetTradeOrCounters_flattenIndicesAndFullStopWork() public {
        (, uint32 a,, uint32 c) = _threeOpen();
        for (uint256 mode; mode < 2; ++mode) {
            uint256 snap = vm.snapshotState();
            if (mode == 0) {
                vm.mockCall(address(diamond), abi.encodeCall(IGainsDiamond.getTrade, (address(vault), a)), abi.encodePacked(new bytes(65)));
            } else {
                vm.mockCallRevert(address(diamond), abi.encodeWithSelector(IGainsDiamond.getCounters.selector), bytes("cut"));
            }
            vm.expectRevert(LAYOUT);
            vault.venue();
            vm.prank(guardian);
            vm.expectRevert(LAYOUT);
            vault.flatten(ETH, 0, _px(ETH), type(uint256).max);
            uint32[] memory ix = new uint32[](3);
            ix[0] = a;
            ix[1] = c;
            ix[2] = 99;
            vm.prank(guardian);
            assertEq(vault.flattenIndices(ix, 0, _px(ETH)), 2, "both ETH trades close by index");
            vm.prank(guardian);
            vault.triggerBreach(); // the full stop never reverts on an unreadable layout
            assertTrue(vault.breached());
            vm.clearMockedCalls();
            vm.revertToState(snap);
        }
    }
}
