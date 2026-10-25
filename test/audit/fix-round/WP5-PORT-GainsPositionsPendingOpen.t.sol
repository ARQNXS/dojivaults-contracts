// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {GainsBase} from "../../gains/GainsBase.t.sol";
import {IGainsVaultErrors as E, MAX_POSITIONS, MIN_HOLD_L2_BLOCKS, OpenParams} from "../../../src/gains/GainsTypes.sol";

/// @notice WP5 uncross: the stronger form of GainsPositions' test_ExitsAreNeverRefusedAtTheCeiling after the WP2 port
///         (796a5f0). The port waits out the minimum hold (2,400 blocks) first; with Gains' market order timeout at
///         200 blocks the pending market open of the setUp is then already timed out when the exits run, so the
///         test no longer exits at the ceiling while that open is live, as the original did. Here the timeout is set
///         above the hold so the open stays pending through the exits, and a second test shows the never-held exits
///         (guardian flatten) at the ceiling inside the hold, where the manager's close is refused "min hold" and
///         never TooManyPositions.
contract WP5PortGainsPositionsPendingOpenTest is GainsBase {
    uint32 internal limitOrder;
    uint32 internal stuckOrder;

    function setUp() public override {
        super.setUp();
        diamond.setTimeoutBlocks(uint16(MIN_HOLD_L2_BLOCKS + 1_000));
        _deposit(alice, 1_000_000e6);
        _settle();
        _claim(alice);
        for (uint256 i; i < 17; ++i) {
            _open(vault, i % 2 == 0 ? BTC : ETH, i % 3 == 0, 1_000e6, 2_000);
        }
        for (uint256 i; i < 2; ++i) {
            OpenParams memory lp = _params(ETH, true, 1_000e6, 2_000);
            lp.tradeType = uint8(1 + i);
            lp.expectedPrice = i == 0 ? _px(ETH) * 95 / 100 : _px(ETH) * 105 / 100;
            vm.prank(manager);
            vault.openTrade(lp);
        }
        limitOrder = 17;
        stuckOrder = _request(vault, BTC, true, 1_000e6, 2_000);
        assertEq(lens.openPositions(vault), MAX_POSITIONS);
    }

    function _stillPending() internal {
        vm.prank(stranger);
        vm.expectRevert(bytes("WaitTimeout"));
        vault.cancelTimedOut(stuckOrder);
    }

    function test_WP5_PORT_exitsAtTheCeilingWithTheMarketOpenStillPending() public {
        _passHold();
        _stillPending(); // the open is live, as in the original test
        uint64 btc = _px(BTC);
        uint64 eth = _px(ETH);
        vm.startPrank(manager);
        vault.closeTrade(0, btc); // 21 with the close in flight
        vault.reduceTrade(1, 500e6, 0, eth);
        vault.cancelOrder(limitOrder);
        vm.stopPrank();
        _stillPending();
        vm.prank(guardian);
        vault.flatten(BTC, 0, btc, type(uint256).max);
        vm.roll(vm.getBlockNumber() + MIN_HOLD_L2_BLOCKS + 1_000);
        vm.prank(stranger);
        vault.cancelTimedOut(stuckOrder);
        assertGt(lens.openPositions(vault), 0);
    }

    function test_WP5_PORT_neverHeldExitsAtTheCeilingInsideTheHold() public {
        uint64 btc = _px(BTC);
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(E.OrderRejected.selector, "min hold"));
        vault.closeTrade(0, btc);
        vm.prank(guardian);
        vault.flatten(BTC, 0, btc, type(uint256).max);
        vm.prank(guardian);
        vault.closeTrade(1, _px(ETH));
        assertGt(lens.openPositions(vault), 0);
    }
}
