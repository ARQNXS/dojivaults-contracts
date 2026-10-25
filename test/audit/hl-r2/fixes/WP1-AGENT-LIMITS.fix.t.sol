// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// WP1 (round 2 fix round, internal, AI-assisted; not an independent audit): the platform agent's turnover budget and
// order-rate cap in placeOrder (HL-PROXY follow-up F5, the Gains GR2-KEY-01b turnover budget's shape). Never
// block.timestamp / block.number here (via_ir rematerialisation): vm.getBlockTimestamp().

import {HloBase} from "../../hl-open/HloBase.t.sol";
import {HyperCore} from "../../../../src/hypercore/HyperCore.sol";
import {IHyperVaultErrors} from "../../../../src/VaultTypes.sol";
import {VaultPolicy} from "../../../../src/VaultPolicy.sol";

contract WP1_AgentLimits_Fix is HloBase {
    address internal agent = makeAddr("platformAgent");
    uint128 internal cloid = 0x1234_5678_9abc_def0_1234_5678_9abc_def0;

    function setUp() public override {
        super.setUp();
        _setAgent(vault, agent);
        // 100k USDC of perp equity, no position: NAV 100k
        _setCore(address(vault), 100_000e6, 0, 0);
        _setWithdrawable(address(vault), 100_000e6);
        // start at a clock hour boundary so the hourly windows below are exact
        vm.warp((vm.getBlockTimestamp() / 1 hours + 1) * 1 hours);
    }

    // ------------------------------------------------------------------ helpers
    /// @dev 0.1 BTC = $10,050 at the 100,500 limit (mark 100,000, inside the 1% band).
    function _open(address who, uint64 sz) internal {
        vm.prank(who);
        vault.placeOrder(BTC, true, 100_500e8, sz, false, HyperCore.TIF_IOC, cloid++);
    }

    function _reduce(address who, uint64 sz) internal {
        vm.prank(who);
        vault.placeOrder(BTC, false, 99_500e8, sz, true, HyperCore.TIF_IOC, cloid++);
    }

    function _limits(uint32 turnoverBps, uint16 ordersPerHour) internal pure returns (VaultPolicy.AgentLimits memory) {
        return VaultPolicy.AgentLimits({maxTurnoverBps: turnoverBps, maxOrdersPerHour: ordersPerHour});
    }

    function _rejected(string memory reason) internal {
        vm.expectRevert(abi.encodeWithSelector(IHyperVaultErrors.OrderRejected.selector, reason));
    }

    // ------------------------------------------------------------------ defaults
    function test_WP1_defaultsAre20xNavAnd120OrdersAnHour() public view {
        VaultPolicy.AgentLimits memory a = policy.agentLimits();
        assertEq(a.maxTurnoverBps, 200_000, "20x NAV");
        assertEq(a.maxOrdersPerHour, 120);
        assertEq(policy.DEFAULT_AGENT_TURNOVER_BPS(), 200_000);
        assertEq(policy.DEFAULT_AGENT_ORDERS_PER_HOUR(), 120);
    }

    /// @dev At the default 20x a thief with the agent key opens at most 2M of notional a day on a 100k vault: six
    ///      orders of 2.9 BTC ($291.45k each, under the 3x leverage cap per order) fit, the seventh does not.
    function test_WP1_default20xNavBudgetStopsTheSeventhLargeOpen() public {
        for (uint256 i; i < 6; ++i) {
            _open(agent, 290_000_000);
        }
        (uint256 used, uint256 orders) = vault.agentFlow();
        assertEq(used, 6 * 291_450e6);
        assertEq(orders, 6);
        _rejected("turnover");
        _open(agent, 290_000_000);
        // still within the day
        vm.warp(vm.getBlockTimestamp() + 23 hours);
        _rejected("turnover");
        _open(agent, 290_000_000);
        // the hour of the six opens leaves the rolling window
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        _open(agent, 290_000_000);
    }

    // ------------------------------------------------------------------ turnover budget
    function test_WP1_turnoverIsRolling24hOfOpenedNotional() public {
        vm.prank(owner);
        policy.proposeAgentLimits(_limits(2_000, 60)); // 0.2x NAV = 20k a day (tighter: instant)
        _open(agent, 1e7); // 10,050
        vm.warp(vm.getBlockTimestamp() + 5 hours);
        _open(agent, 9e6); // 9,045: 19,095 in the window
        _rejected("turnover");
        _open(agent, 1e6); // 1,005 more is 20,100 > 20,000
        // 19 hours after the first open it is still in the window
        vm.warp(vm.getBlockTimestamp() + 18 hours);
        _rejected("turnover");
        _open(agent, 1e6);
        // 24 hours after the first open's clock hour, its 10,050 is out; the 9,045 stays
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        (uint256 used,) = vault.agentFlow();
        assertEq(used, 9_045e6);
        _open(agent, 1e7);
        _rejected("turnover");
        _open(agent, 1e6);
    }

    function test_WP1_budgetScalesWithNav() public {
        vm.prank(owner);
        policy.proposeAgentLimits(_limits(2_000, 60)); // 0.2x
        _setCore(address(vault), 50_000e6, 0, 0); // NAV halves: 10k a day
        _rejected("turnover");
        _open(agent, 1e7); // 10,050 > 10,000
        _open(agent, 9e6);
    }

    function test_WP1_reduceOnlyNeverSpendsNorIsRefused() public {
        vm.prank(owner);
        policy.proposeAgentLimits(_limits(0, 0)); // the agent opens nothing
        _rejected("order rate");
        _open(agent, 1e6);
        _setPosition(address(vault), BTC, 100_000_000);
        for (uint256 i; i < 5; ++i) {
            _reduce(agent, 1e7);
        }
        (uint256 used, uint256 orders) = vault.agentFlow();
        assertEq(used, 0);
        assertEq(orders, 0);
    }

    function test_WP1_managerIsNotBoundByTheAgentLimits() public {
        vm.prank(owner);
        policy.proposeAgentLimits(_limits(0, 0));
        _open(manager, 1e7);
        _open(manager, 1e7);
        (uint256 used, uint256 orders) = vault.agentFlow();
        assertEq(used + orders, 0);
    }

    // ------------------------------------------------------------------ order rate
    /// @dev Sliding hour: the previous clock hour counts by the share of it still inside the last 60 minutes
    ///      (rounded up), so the clock-hour boundary does not double the rate.
    function test_WP1_orderRateCapPerSlidingHour() public {
        vm.prank(owner);
        policy.proposeAgentLimits(_limits(200_000, 3));
        _open(agent, 1e6);
        _open(agent, 1e6);
        vm.warp(vm.getBlockTimestamp() + 59 minutes);
        _open(agent, 1e6);
        _rejected("order rate");
        _open(agent, 1e6);
        // reduce-only still goes through
        _setPosition(address(vault), BTC, 3_000_000);
        _reduce(agent, 1e6);
        // the next clock hour starts: the previous hour's 3 still count in full
        vm.warp(vm.getBlockTimestamp() + 1 minutes);
        _rejected("order rate");
        _open(agent, 1e6);
        // 20 minutes in: ceil(3 x 40 / 60) = 2 of them still count
        vm.warp(vm.getBlockTimestamp() + 20 minutes);
        _open(agent, 1e6);
        (uint256 used, uint256 orders) = vault.agentFlow();
        assertEq(orders, 3, "1 now + 2 carried");
        assertEq(used, 4 * 1_005e6, "turnover still counts the previous hour");
        _rejected("order rate");
        _open(agent, 1e6);
        // an hour after the boundary only this hour's order is left
        vm.warp(vm.getBlockTimestamp() + 40 minutes);
        (, orders) = vault.agentFlow();
        assertEq(orders, 1);
    }

    /// @dev The ring of 24 buckets reuses a bucket a day later: the old hour's count and notional are dropped.
    function test_WP1_bucketReusedADayLater() public {
        vm.prank(owner);
        policy.proposeAgentLimits(_limits(200_000, 2));
        _open(agent, 1e6);
        _open(agent, 1e6);
        vm.warp(vm.getBlockTimestamp() + 24 hours);
        _open(agent, 1e6);
        (uint256 used, uint256 orders) = vault.agentFlow();
        assertEq(orders, 1);
        assertEq(used, 1_005e6);
    }

    /// @dev HL-INV-01 (WP5, replaces the cross-review's bridgeInFlightCountsInTheNav): the budget reads the visible NAV
    ///      only. 100k idle + 100k perp; while the 100k bridged to Core has not landed idle + Core reads 100k, so at
    ///      0.1x the budget is 10k, not 20k. Once it lands the budget is 20k again.
    function test_WP1_bridgeInFlightDoesNotCountInTheBudget() public {
        _deposit(alice, 100_000e6);
        _settle();
        vm.prank(manager);
        vault.bridgeToCore(100_000e6);
        assertTrue(vault.bridgePending());
        vm.prank(owner);
        policy.proposeAgentLimits(_limits(1_000, 120));
        _open(agent, 9_000_000); // 9,045: inside 10k
        _rejected("turnover");
        _open(agent, 1_000_000); // 10,050 > 10,000
        _setCore(address(vault), 200_000e6, 0, 0); // landed
        _setWithdrawable(address(vault), 200_000e6);
        _open(agent, 1_000_000); // 10,050 of 20,000
    }

    /// @dev HL-INV-01 PoC as a fix test: the 100k bridged to Core is never credited on HyperCore. Before the fix the
    ///      budget read min(visible + bridgeAmount, equityAtBridge) = 200k for the whole window, so a stolen agent key
    ///      could open 2x the 100k that is really there. It now reads the 100k.
    function test_HLINV01_lostBridgeDoesNotInflateTheBudget() public {
        _deposit(alice, 100_000e6);
        _settle();
        vm.prank(manager);
        vault.bridgeToCore(100_000e6);
        // never credited: Core stays at 100k, idle is 0
        vm.roll(vm.getBlockNumber() + 10);
        assertTrue(vault.bridgePending());
        vm.prank(owner);
        policy.proposeAgentLimits(_limits(1_000, 120)); // 0.1x
        _rejected("turnover");
        _open(agent, 15_000_000); // 15,075: inside 0.1 x 200k (the old read), over 0.1 x 100k (the true NAV)
        _open(agent, 9_000_000);
    }

    /// @dev Cross-review: a replacement agent (timelocked, behind the exit notice) starts with a fresh budget.
    function test_WP1_newAgentStartsWithAFreshBudget() public {
        _open(agent, 1e7);
        (uint256 used,) = vault.agentFlow();
        assertGt(used, 0);
        address agent2 = makeAddr("platformAgent2");
        _setAgent(vault, agent2);
        uint256 orders;
        (used, orders) = vault.agentFlow();
        assertEq(used + orders, 0);
        _open(agent2, 1e7);
    }

    // ------------------------------------------------------------------ governance: tighten instant, loosen with notice
    function test_WP1_looseningWaitsTheExitNotice_tighteningIsInstant() public {
        vm.prank(owner);
        policy.proposeAgentLimits(_limits(100_000, 30));
        assertEq(policy.agentLimits().maxTurnoverBps, 100_000, "tightened at once");
        // loosen one field: queued behind max(timelock, epoch + 1 day)
        uint256 expect = policy.noticeEta();
        vm.prank(owner);
        policy.proposeAgentLimits(_limits(100_000, 120));
        VaultPolicy.PendingAgentLimits memory p = policy.pendingAgentLimits();
        assertTrue(p.exists);
        assertEq(p.eta, expect);
        assertGe(p.eta, vm.getBlockTimestamp() + 7 days + 1 days, "at least one epoch (7 d) plus a day");
        assertEq(policy.agentLimits().maxOrdersPerHour, 30, "not yet");
        vm.warp(p.eta - 1);
        vm.expectRevert(VaultPolicy.NotReady.selector);
        policy.applyAgentLimits();
        vm.warp(p.eta);
        policy.applyAgentLimits(); // anyone
        assertEq(policy.agentLimits().maxOrdersPerHour, 120);
        assertFalse(policy.pendingAgentLimits().exists);
    }

    function test_WP1_tighteningCancelsAQueuedLoosening() public {
        vm.prank(owner);
        policy.proposeAgentLimits(_limits(400_000, 60));
        assertTrue(policy.pendingAgentLimits().exists);
        vm.prank(owner);
        policy.proposeAgentLimits(_limits(100_000, 10));
        assertFalse(policy.pendingAgentLimits().exists);
        assertEq(policy.agentLimits().maxTurnoverBps, 100_000);
    }

    function test_WP1_onlyOwnerWithinTheCeilings() public {
        vm.prank(stranger);
        vm.expectRevert();
        policy.proposeAgentLimits(_limits(1, 1));
        vm.startPrank(owner);
        vm.expectRevert(VaultPolicy.InvalidConfig.selector);
        policy.proposeAgentLimits(_limits(1_000_001, 60));
        vm.expectRevert(VaultPolicy.InvalidConfig.selector);
        policy.proposeAgentLimits(_limits(200_000, 1_001));
        vm.expectRevert(VaultPolicy.NothingPending.selector);
        policy.cancelAgentLimits();
        policy.proposeAgentLimits(_limits(1_000_000, 1_000));
        policy.cancelAgentLimits();
        vm.stopPrank();
        vm.expectRevert(VaultPolicy.NothingPending.selector);
        policy.applyAgentLimits();
    }

    /// @dev Gas of the budget on the agent's open (24 bucket reads, one write) next to the HL-PROXY open.
    function test_WP1_gas_agentOpenWithLimits() public {
        vm.warp(vm.getBlockTimestamp() + 2 hours);
        vm.prank(agent);
        uint256 g = gasleft();
        vault.placeOrder(BTC, true, 100_500e8, 1e7, false, 3, cloid);
        emit log_named_uint("gas agent open with the limits", g - gasleft());
        assertLt(g - gasleft(), 1_000_000);
    }
}
