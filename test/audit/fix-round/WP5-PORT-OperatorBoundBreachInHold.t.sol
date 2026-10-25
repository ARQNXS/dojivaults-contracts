// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {GovBase} from "../gains/gov/GovBase.t.sol";
import {IGainsVaultErrors as E, MIN_HOLD} from "../../../src/gains/GainsTypes.sol";

/// @notice WP5 uncross: the stronger form of OperatorBound's GOV-01 agent grind after the WP2 port (796a5f0). The port
///         waits out the minimum hold before the agent's first reduce, so the daily-loss breach then starts after the
///         hold and the test no longer shows that a breach exit is never held. Here the grind runs entirely inside the
///         hold, on the same UTC day as the vault's daily baseline: outside the breach the agent's reduce is refused
///         "min hold"; once checkRisk records the daily-loss breach, the agent keeps its key and every reduce goes.
contract WP5PortOperatorBoundBreachInHoldTest is GovBase {
    function test_WP5_PORT_GOV_01_agentGrindsInADailyLossBreachInsideTheHold() public {
        diamond.setPair(ETH, 350_000_000, 285.7e18, 0.1e18, 0);
        _fundFv(10_000e6);
        uint256 day = vm.getBlockTimestamp() / 1 days;
        uint32 a = _openFv(ETH, 9_000e6, 2_000);
        uint256 openedAt = vm.getBlockTimestamp();
        assertEq(fv.redemptionShortfall(), 0);
        uint64 px = _px(ETH);
        // outside a breach, inside the hold: refused
        vm.prank(agentA);
        vm.expectRevert(abi.encodeWithSelector(E.OrderRejected.selector, "min hold"));
        fv.reduceTrade(a, 110_000, 0, px);
        // a daily loss breach: the agent is kept and reduce stays open to it, hold or not
        diamond.setHolding(address(fv), a, int256(1_000e6));
        fv.checkRisk();
        assertTrue(fv.breached(), "daily-loss breach");
        assertEq(fv.agent(), agentA, "risk breach keeps the agent");
        for (uint256 i; i < 10; ++i) {
            vm.prank(agentA);
            fv.reduceTrade(a, 110_000, 0, px);
            _fillLast(fv, px);
        }
        assertLt(vm.getBlockTimestamp(), openedAt + MIN_HOLD, "the whole grind ran inside the hold");
        assertEq(vm.getBlockTimestamp() / 1 days, day, "same UTC day as the baseline");
    }
}
