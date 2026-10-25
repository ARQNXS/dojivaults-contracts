// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {MutBase} from "./MutBase.t.sol";
import {HyperVault} from "../../../../src/HyperVault.sol";
import {BreachReason, IHyperVaultErrors as E} from "../../../../src/VaultTypes.sol";

/// @title hl-r2 mutation kill tests: the vault timelock (queue / execute / cancel), breach clears, switches
contract HLR2MutTimelockTest is MutBase {
    /// Mutant: clearBreach `if (emergency) revert InEmergency()` deleted: the guardian clears breaches, never an
    /// emergency (only exitEmergency ends one).
    function test_HLR2_M65_kills_clearBreachInEmergency() public {
        vm.prank(guardian);
        vault.triggerEmergency();
        vm.prank(guardian);
        vm.expectRevert(E.InEmergency.selector);
        vault.clearBreach();
        assertTrue(vault.breached());
        assertEq(uint8(vault.breachReason()), uint8(BreachReason.EMERGENCY));
    }

    /// Mutants: clearBreach `riskDay = block.timestamp / 1 days` deleted / `*`. A clear restarts the day's
    /// reference at the clear: a loss right after it, on a later day than the breach, is measured from the clear
    /// price (a stale riskDay would roll the day at the next check and start it from the post-loss price).
    function test_HLR2_M66_kills_clearRestartsTheDay() public {
        _fund(10_000e6);
        vm.prank(guardian); // standalone: the guardian is also the sentinel
        vault.triggerBreach();
        vm.warp((vm.getBlockTimestamp() / 1 days + 2) * 1 days + 60); // two days later, no check in between
        vm.prank(guardian);
        vault.clearBreach();
        _setCore(address(vault), 9_000e6, 0, 0); // -10% after the clear
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        (, uint256 daily,) = vault.checkRisk();
        assertApproxEqAbs(daily, 1_000, 1, "measured from the clear");
        assertTrue(vault.breached());
    }

    /// Mutant: setDepositsPaused's `depositsPaused = paused` deleted.
    function test_HLR2_M67_kills_depositPauseStored() public {
        vm.prank(guardian); // standalone: the guardian is also the sentinel
        vault.setDepositsPaused(true);
        assertTrue(vault.depositsPaused());
        vm.prank(alice);
        vm.expectRevert(E.DepositsClosed.selector);
        vault.requestDeposit(100e6, alice);
        vm.prank(owner);
        vault.setDepositsPaused(false);
        _deposit(alice, 100e6);
    }

    /// Mutants: queue's selector table (`||` -> `&&` drops setFeeRecipient / setTimelockDelay), execute's grace edge
    /// (`>` -> `>=`) and the queued entry deletion (an executed item could be executed again: a replay of an old
    /// setManager / setFees without a new timelock).
    function test_HLR2_M68_kills_queueTableGraceAndReplay() public {
        bytes memory feeRec = abi.encodeCall(HyperVault.setFeeRecipient, (makeAddr("fr2")));
        bytes memory delay = abi.encodeCall(HyperVault.setTimelockDelay, (3 days));
        bytes memory mgr = abi.encodeCall(HyperVault.setManager, (makeAddr("m2")));
        vm.startPrank(owner);
        vault.queue(feeRec);
        vault.queue(delay);
        vault.queue(mgr);
        vm.stopPrank();
        uint256 eta = vault.queuedEta(keccak256(mgr));
        vm.warp(eta + 14 days); // the last second of the grace period
        vault.execute(feeRec);
        vault.execute(delay);
        vault.execute(mgr);
        assertEq(vault.feeRecipient(), makeAddr("fr2"));
        assertEq(vault.timelockDelay(), 3 days);
        assertEq(vault.manager(), makeAddr("m2"));
        // the manager is changed again later; the old queued call cannot be replayed
        _timelocked(vault, abi.encodeCall(HyperVault.setManager, (manager)));
        vm.expectRevert(E.NotQueued.selector);
        vault.execute(mgr);
        assertEq(vault.manager(), manager);
    }

    /// Mutant: execute `queuedAt[id] <= breachedAt` -> `<`: a clear queued in the same block as the breach does not
    /// count (N-04: the owner must queue after the breach).
    function test_HLR2_M69_kills_clearQueuedInTheBreachBlock() public {
        bytes memory clear = abi.encodeCall(HyperVault.clearBreach, ());
        vm.prank(owner);
        vault.queue(clear);
        vm.prank(guardian); // standalone: the guardian is also the sentinel
        vault.triggerBreach(); // same timestamp
        // hl-r2 H01 (integrated): wait for the stored eta, so NotReady comes from the N-04 rule (the clear was queued
        // in the breach block) and not from the eta itself: at +2 days the H01 eta alone would mask the mutant
        vm.warp(vault.queuedEta(keccak256(clear)));
        vm.expectRevert(E.NotReady.selector);
        vault.execute(clear);
        assertTrue(vault.breached());
    }

    /// Mutant: cancel's `delete queuedEta[id]` deleted: a cancelled item must not execute.
    function test_HLR2_M70_kills_cancelIsFinal() public {
        bytes memory mgr = abi.encodeCall(HyperVault.setManager, (makeAddr("m2")));
        vm.prank(owner);
        bytes32 id = vault.queue(mgr);
        vm.prank(guardian);
        vault.cancel(id);
        vm.warp(vm.getBlockTimestamp() + 2 days);
        vm.expectRevert(E.NotQueued.selector);
        vault.execute(mgr);
        assertEq(vault.manager(), manager);
    }

    /// Mutant: exitEmergency `if (epoch > 0)` -> `>= 0`: at epoch 0 (no settle yet) there is no previous epoch to
    /// read; the guardian can still end the emergency.
    function test_HLR2_M71_kills_exitEmergencyAtEpochZero() public {
        vm.prank(guardian);
        vault.triggerEmergency();
        vm.prank(guardian);
        vault.exitEmergency();
        assertFalse(vault.emergency());
    }

    function _execFails(bytes memory data, bytes4 err) internal {
        vm.prank(owner);
        vault.queue(data);
        vm.warp(vault.queuedEta(keccak256(data))); // hl-r2 H01 (integrated): the stored eta, not timelockDelay
        vm.expectRevert(abi.encodeWithSelector(E.CallFailed.selector, abi.encodeWithSelector(err)));
        vault.execute(data);
    }

    /// Mutants: the timelocked setters' own checks (setManager / setFeeRecipient zero address, setTimelockDelay
    /// bounds, setFees caps): every one of them survived, no test executed an out-of-range value.
    function test_HLR2_M72_kills_timelockedSetterBounds() public {
        _execFails(abi.encodeCall(HyperVault.setManager, (address(0))), E.ZeroAddress.selector);
        _execFails(abi.encodeCall(HyperVault.setFeeRecipient, (address(0))), E.ZeroAddress.selector);
        _execFails(abi.encodeCall(HyperVault.setTimelockDelay, (1 days - 1)), E.InvalidTimelock.selector);
        _execFails(abi.encodeCall(HyperVault.setTimelockDelay, (0)), E.InvalidTimelock.selector);
        _execFails(abi.encodeCall(HyperVault.setTimelockDelay, (30 days + 1)), E.InvalidTimelock.selector);
        _execFails(abi.encodeCall(HyperVault.setTimelockDelay, (60 days)), E.InvalidTimelock.selector);
        _execFails(abi.encodeCall(HyperVault.setFees, (501, 2_000)), E.InvalidFee.selector);
        _execFails(abi.encodeCall(HyperVault.setFees, (1_000, 2_000)), E.InvalidFee.selector);
        _execFails(abi.encodeCall(HyperVault.setFees, (200, 3_001)), E.InvalidFee.selector);
        _execFails(abi.encodeCall(HyperVault.setFees, (200, 6_000)), E.InvalidFee.selector);
        // the bounds themselves are valid; address(1) is an address
        _timelocked(vault, abi.encodeCall(HyperVault.setManager, (address(1))));
        assertEq(vault.manager(), address(1));
        _timelocked(vault, abi.encodeCall(HyperVault.setFeeRecipient, (address(1))));
        assertEq(vault.feeRecipient(), address(1));
        _timelocked(vault, abi.encodeCall(HyperVault.setFees, (500, 3_000)));
        assertEq(vault.managementFeeBps(), 500);
        assertEq(vault.pendingPerformanceFeeBps(), 3_000, "a raise is scheduled");
        _timelocked(vault, abi.encodeCall(HyperVault.setTimelockDelay, (1 days)));
        assertEq(vault.timelockDelay(), 1 days);
        _timelocked(vault, abi.encodeCall(HyperVault.setTimelockDelay, (30 days)));
        assertEq(vault.timelockDelay(), 30 days);
        _timelocked(vault, abi.encodeCall(HyperVault.setTimelockDelay, (2 days)));
        assertEq(vault.timelockDelay(), 2 days);
    }
}
