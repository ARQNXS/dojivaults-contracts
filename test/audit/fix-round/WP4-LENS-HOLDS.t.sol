// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {SimBase} from "../hl-r2/async/SimBase.t.sol";
import {HyperVaultLens} from "../../../src/HyperVaultLens.sol";
import {IHyperVaultErrors, UNRESOLVED_WAIT_BLOCKS} from "../../../src/VaultTypes.sol";

/// @notice WP4: HyperVaultLens.holds() returns the round 2 hold state the webapp checks before it offers a settle,
///         a bridge or a deposit. Each field must equal the vault's own view, so the "Do all" button never sends a
///         settle that reverts on the bridge hold.
contract WP4_LensHolds is SimBase {
    HyperVaultLens internal lens;

    function setUp() public override {
        super.setUp();
        lens = new HyperVaultLens();
    }

    function _assertMatchesVault(HyperVaultLens.Holds memory h) internal view {
        assertEq(h.epochDeadline, vault.epochDeadline(), "epochDeadline");
        assertEq(h.noticeEta, vpolicy.noticeEta(), "noticeEta");
        assertEq(h.depositHold, vault.depositHold(), "depositHold");
        assertEq(h.platformHold, vault.platformHold(), "platformHold");
        assertEq(h.bridgeUnresolved, vault.bridgeUnresolved(), "bridgeUnresolved");
        assertEq(h.agentActiveAt, vault.agentActiveAt(), "agentActiveAt");
        assertEq(h.checkpointLagging, vault.checkpointLagging(), "checkpointLagging");
    }

    function test_WP4_holds_freshVaultMatchesTheVaultsViews() public view {
        HyperVaultLens.Holds memory h = lens.holds(vault);
        _assertMatchesVault(h);
        assertGt(h.epochDeadline, 0, "the first epoch's deadline is set at launch");
        assertGt(h.agentActiveAt, 0, "a platform agent vault has a warm-up");
        assertFalse(h.depositHold || h.platformHold || h.bridgeUnresolved, "no hold at launch");
        assertEq(h.bridgeHoldEndsBlock, 0);
    }

    /// The bridge hold: the lens shows it (and when it ends) exactly while settle reverts TransferUnresolved.
    function test_WP4_holds_bridgeHoldIsVisibleWhileSettleReverts() public {
        _bootstrap(100_000e6);
        _warp(1 hours);
        vault.checkRisk();
        sim.setEvm(UNRESOLVED_WAIT_BLOCKS + 10_000, false);
        vm.prank(operator);
        vault.bridgeToEvm(15_000e6);
        _tick(MAX_UNLANDED() + 1);
        _deposit(carol, 1_000e6);

        HyperVaultLens.Holds memory h = lens.holds(vault);
        _assertMatchesVault(h);
        assertTrue(h.bridgeUnresolved, "held");
        assertEq(h.bridgeHoldEndsBlock, vault.lastBridgeBlock() + UNRESOLVED_WAIT_BLOCKS, "ends a day of blocks after the bridge");
        vm.prank(operator);
        vm.expectRevert(IHyperVaultErrors.TransferUnresolved.selector);
        vault.settle();

        vm.prank(guardian);
        vault.writeOffBridge();
        h = lens.holds(vault);
        _assertMatchesVault(h);
        assertFalse(h.bridgeUnresolved, "written off");
        assertEq(h.bridgeHoldEndsBlock, 0);
    }

    /// The deposit hold after a platform revoke, and the platform hold after the sentinel's stop.
    function test_WP4_holds_depositAndPlatformHolds() public {
        _bootstrap(100_000e6);
        vm.prank(sentinel);
        vault.revokeAgent();
        HyperVaultLens.Holds memory h = lens.holds(vault);
        _assertMatchesVault(h);
        assertTrue(h.depositHold, "a platform revoke holds deposits");
        assertFalse(h.platformHold);

        vm.prank(sentinel);
        vault.triggerBreach();
        h = lens.holds(vault);
        _assertMatchesVault(h);
        assertTrue(h.platformHold, "the sentinel's stop is a platform hold");
    }

    /// The notice a change that adds risk gets: never before the running epoch's deadline plus the exit margin.
    function test_WP4_holds_noticeEtaIsAfterTheDeadline() public view {
        HyperVaultLens.Holds memory h = lens.holds(vault);
        assertGe(h.noticeEta, uint256(h.epochDeadline) + vpolicy.EXIT_MARGIN(), "exit before effect");
    }
}
