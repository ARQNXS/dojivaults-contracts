// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Vm} from "forge-std/Vm.sol";
import {SimBase} from "../async/SimBase.t.sol";
import {HyperCore} from "../../../../src/hypercore/HyperCore.sol";
import {IHyperVaultEvents} from "../../../../src/VaultTypes.sol";

/// @notice hl-r2 fix tests for HLR2-A08 part 3 / E01e: NAV left in a vault whose every share was burned is minted to
///         the guardian at the next first mint, not handed to the new depositor
///         (fixes/patches/a-series/HLR2-A08-SUPPLY0.integrated.patch, on the integrated stack + the A-series patch).
contract HLR2_A08_Supply0_Fix is SimBase {
    /// The A08 PoC's last step with the patch: the guardian wrote the unwind off (alice was paid ~0), the transfer
    /// lands at supply 0, carol deposits 10 USDC. Carol gets 10 USDC of value; the 100k is the guardian's to return.
    function test_HLR2_A08p3_fix_lateArrivalAtSupplyZeroGoesToTheGuardian() public {
        _bootstrap(100_000e6);
        _redeem(alice, vault.balanceOf(alice));
        vm.prank(owner);
        vault.triggerEmergency();
        _tick(331); // XF01: the emergency bridge waits out the cooldown after the bootstrap bridge
        sim.setEvm(2_000, false);
        uint256 all = sim.spotUsd(address(vault)) + HyperCore.withdrawable(address(vault));
        vm.prank(operator);
        vault.bridgeToEvm(all);
        _tick(MAX_UNLANDED() + 1);
        vm.prank(guardian);
        vault.writeOffBridge(); // the guardian accepts the loss: the exit settles at the short NAV
        _settleBy(operator);
        vault.claim(alice);
        assertEq(vault.totalSupply(), 0, "every share burned");
        vm.startPrank(guardian);
        vault.exitEmergency();
        vault.clearBreach();
        vm.stopPrank();

        _tick(2_000); // the transfer lands
        uint256 left = vault.totalAssets();
        assertGt(left, 99_000e6, "the 100k is back, with no owner");
        _deposit(carol, 10e6);
        _warp(1 hours);
        vault.checkRisk();
        vm.recordLogs();
        _keeperSettle();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool reserved;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].topics[0] == IHyperVaultEvents.OrphanedNavReserved.selector) {
                reserved = true;
                assertEq(address(uint160(uint256(logs[i].topics[1]))), guardian);
            }
        }
        assertTrue(reserved, "OrphanedNavReserved(guardian)");
        vault.claim(carol);
        emit log_named_uint("carol value for 10 USDC", _valueOf(carol));
        emit log_named_uint("guardian value", _valueOf(guardian));
        assertLe(_valueOf(carol), 10e6, "carol gets what she paid, not the 100k");
        assertGt(_valueOf(carol), 9_990_000, "and no less");
        assertGt(_valueOf(guardian), left - 1e6, "the guardian holds the orphaned NAV");
    }

    /// Control: a full exit at a fair price leaves only the seed and rounding (<= ORPHAN_DUST): the next first
    /// depositor is minted as at launch and nothing goes to the guardian.
    function test_HLR2_A08p3_fix_control_dustStaysWithTheNextDepositor() public {
        vm.prank(owner);
        vault.lowerFees(0, 0); // no fee holders: alice's exit takes the supply to 0
        _bootstrap(100_000e6);
        _warp(1 hours);
        vault.checkRisk();
        uint256 all = sim.spotUsd(address(vault)) + HyperCore.withdrawable(address(vault));
        vm.prank(operator);
        vault.bridgeToEvm(all);
        _tick(13);
        vault.syncBridge();
        _redeem(alice, vault.balanceOf(alice));
        _warp(1 hours);
        _keeperSettle();
        vault.claim(alice);
        assertEq(vault.totalSupply(), 0);
        assertLe(vault.totalAssets(), 10e6, "only the seed and rounding are left");

        _deposit(carol, 1_000e6);
        _warp(1 hours);
        vault.checkRisk();
        uint256 g0 = vault.balanceOf(guardian); // the platform's fee shares, if any
        vm.recordLogs();
        _keeperSettle();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; i++) {
            assertTrue(logs[i].topics[0] != IHyperVaultEvents.OrphanedNavReserved.selector, "no reservation");
        }
        vault.claim(carol);
        assertEq(vault.balanceOf(guardian), g0, "nothing to the guardian");
        assertGe(_valueOf(carol), 1_000e6, "carol gets her deposit and the dust, as at launch");
    }
}
