// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {HostileBase} from "../hostile/HostileBase.t.sol";
import {HyperVault} from "../../../../src/HyperVault.sol";
import {IHyperVaultErrors as E} from "../../../../src/VaultTypes.sol";

/// @notice Fix test for HLR2-H04 (contract half): in emergency only the guardian and the sentinel open a bridge
///         window, so no owner-chosen address can keep the exit settle out. Runs with patches/HLR2-H04.patch.
contract HLR2_H04_Fix is HostileBase {
    function _emergencyWithRedeemer() internal returns (HyperVault v) {
        v = _platformVaultLike(address(0));
        _setCore(address(v), 99_002e6, 0, 1_000e6); // 1,000 USDC on Core spot
        _setWithdrawable(address(v), 99_002e6);
        uint256 shares = v.balanceOf(alice);
        vm.prank(alice);
        v.requestRedeem(shares, alice, alice);
        vm.warp(v.epochStartedAt() + 7 days);
        vm.prank(alice);
        v.triggerEmergency(); // overdue: anyone
        assertTrue(v.emergency());
    }

    /// Integrated with XF01 (replaces the strict H04 rule): in emergency the manager, the owner and the operator may
    /// bridge again, but never within EMERGENCY_BRIDGE_COOLDOWN (330) blocks of the previous bridge. They cannot open
    /// a window right after one closes, so the exit settle lands in the gap; after the cooldown they bring USDC home
    /// without any platform key (XF-01: no exit that needs the platform forever).
    function test_HLR2_H04_fix_managerOwnerOperatorCannotChainBridgesInEmergency() public {
        HyperVault v = _emergencyWithRedeemer();
        vm.prank(sentinel);
        v.bridgeToEvm(1_000e6);
        usdc.mint(address(v), 1_000e6);
        _setCore(address(v), 99_002e6, 0, 0);
        vm.roll(vm.getBlockNumber() + v.BRIDGE_SETTLE_BLOCKS() + 1);
        v.syncBridge();
        assertFalse(v.bridgePending());
        vm.prank(platformVaultOwner); // manager and owner
        vm.expectRevert(E.BridgeInFlight.selector);
        v.bridgeToEvm(100e6);
        vm.prank(keeper); // the operator
        vm.expectRevert(E.BridgeInFlight.selector);
        v.bridgeToEvm(100e6);
        vm.prank(guardian);
        v.settle(); // exit-only, partial fill on the idle USDC, in the gap
        (,, uint256 rs,, uint256 rb,,,) = v.epochs(v.currentEpoch() - 1);
        assertGt(rb, 0);
        assertLt(rb, rs);
        // after the cooldown the operator brings the rest home with no platform key
        vm.roll(vm.getBlockNumber() + 330);
        _setWithdrawable(address(v), 99_002e6);
        vm.prank(keeper);
        v.bridgeToEvm(100e6);
        assertTrue(v.bridgePending());
    }

    /// The platform still brings USDC home in emergency: the sentinel (and the guardian) may bridge.
    function test_HLR2_H04_fix_sentinelAndGuardianStillBridgeInEmergency() public {
        HyperVault v = _emergencyWithRedeemer();
        vm.prank(sentinel);
        v.bridgeToEvm(1_000e6);
        assertTrue(v.bridgePending());
        usdc.mint(address(v), 1_000e6);
        _setCore(address(v), 99_002e6, 0, 0);
        vm.roll(vm.getBlockNumber() + v.BRIDGE_SETTLE_BLOCKS() + 1);
        v.syncBridge();
        vm.prank(guardian);
        v.bridgeToEvm(100e6);
        assertTrue(v.bridgePending());
    }

    /// Outside emergency nothing changes: the manager and the operator bridge, the platform roles do not.
    function test_HLR2_H04_fix_outsideEmergencyUnchanged() public {
        HyperVault v = _platformVaultLike(address(0));
        _setCore(address(v), 99_002e6, 0, 1_000e6);
        _setWithdrawable(address(v), 99_002e6);
        vm.prank(sentinel);
        vm.expectRevert(E.Unauthorized.selector);
        v.bridgeToEvm(100e6);
        vm.prank(platformVaultOwner);
        v.bridgeToEvm(100e6);
        assertTrue(v.bridgePending());
    }
}
