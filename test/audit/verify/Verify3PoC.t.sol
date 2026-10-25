// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {AuditBase} from "../AuditBase.t.sol";
import {HyperVault} from "../../../src/HyperVault.sol";
import {IHyperVaultErrors as E} from "../../../src/VaultTypes.sol";

/// @notice Verification pass 3 (101fb70..5dd5a91, W-01 fix), inverted after W-01b: the owner has no path to end an
///         emergency at all (not directly, not through the queue), so no empty or dust settle helps. Only the cold
///         guardian ends it, and only once nothing is pending and the last settle of the emergency paid in full.
///         Run: forge test --match-path test/audit/verify/Verify3PoC.t.sol -vv
contract Verify3PoC is AuditBase {
    int64 internal perp;
    uint64 internal spot;

    function _core(HyperVault v) internal {
        _setCore(address(v), perp, 0, spot);
        _setWithdrawable(address(v), perp > 0 ? uint64(perp) : 0);
    }

    function _home(HyperVault v, address who, uint256 amount) internal {
        vm.prank(who);
        v.bridgeToEvm(amount);
        if (spot >= amount) spot -= uint64(amount);
        else {
            perp -= int64(uint64(amount - spot));
            spot = 0;
        }
        usdc.mint(address(v), amount);
        _core(v);
        vm.roll(vm.getBlockNumber() + 11);
    }

    /// @dev Alice 1M on Core and redeeming; mallory2 (the owner's sybil) holds a little; emergency on; a rescuer
    ///      brought 100k home and a stranger settled: a 10% partial fill, alice's 90% came back as shares.
    function _afterPartialFill() internal returns (HyperVault v) {
        (v,) = _malloryVault();
        vm.prank(mallory2);
        v.requestDeposit(1_000e6, mallory2);
        _fundAndDeploy(v, mallory, 1_000_000e6, 0);
        v.claim(mallory2);
        perp = 1_000_000e6;
        _core(v);
        uint256 a = v.balanceOf(alice);
        vm.prank(alice);
        v.requestRedeem(a, alice, alice);
        vm.warp(vm.getBlockTimestamp() + 7 days);
        v.checkRisk();
        vm.prank(stranger);
        v.triggerEmergency();

        bytes memory exitData = abi.encodeCall(HyperVault.exitEmergency, ());
        vm.prank(mallory);
        vm.expectRevert(E.Unauthorized.selector);
        v.queue(exitData); // exitEmergency is not a queueable selector (W-01b)

        _home(v, sentinel, 100_000e6);
        vm.prank(sentinel);
        v.settle();
        assertEq(v.pendingRedeemShares(), 0, "10% fill, the rest returned");
        vm.prank(guardian);
        vm.expectRevert(E.RedemptionsPending.selector);
        v.exitEmergency(); // the guardian waits for the returned shares to be re-requested
    }

    function _assertOwnerCannotExit(HyperVault v) internal {
        vm.prank(mallory);
        vm.expectRevert(E.Unauthorized.selector);
        v.exitEmergency();
        vm.prank(mallory);
        vm.expectRevert(E.Unauthorized.selector);
        v.queue(abi.encodeCall(HyperVault.exitEmergency, ()));
        assertTrue(v.emergency(), "still in emergency");
    }

    /// @dev Alice re-requests, the rest comes home, she is paid in full; only then the guardian ends the emergency.
    function _finishAndGuardianExits(HyperVault v) internal {
        v.claim(alice);
        uint256 back = v.balanceOf(alice);
        assertGt(back, 0);
        vm.prank(alice);
        v.requestRedeem(back, alice, alice);
        _home(v, sentinel, 100e6); // anyone keeps bridging: the emergency is still on
        _home(v, sentinel, 899_900e6);
        vm.prank(sentinel);
        v.settle();
        v.claim(alice);
        assertApproxEqRel(usdc.balanceOf(alice), 1_000_000e6, 2e15, "alice is out");
        vm.prank(guardian);
        v.exitEmergency();
        assertFalse(v.emergency());
    }

    // ==================================================================
    // W-01b (Medium, fixed)  An empty settle right after the partial fill changes nothing for the owner: there is no
    //       owner path. The guardian may end the emergency after it (trusted, documented operational rule), but
    //       here waits until alice has been paid.
    // ==================================================================
    function test_VERIFY3_W01b_emptySettleDoesNotHelpTheOwner() public {
        HyperVault v = _afterPartialFill();
        vm.prank(sentinel);
        v.settle(); // empty epoch
        _assertOwnerCannotExit(v);
        _finishAndGuardianExits(v);
    }

    /// @dev W-01b variant: a sybil dust redemption, filled in full, does not help the owner either.
    function test_VERIFY3_W01b_dustRedemptionDoesNotHelpTheOwner() public {
        HyperVault v = _afterPartialFill();
        vm.prank(mallory2);
        v.requestRedeem(1e6, mallory2, mallory2); // ~1 wei of value
        vm.prank(sentinel);
        v.settle();
        _assertOwnerCannotExit(v);
        _finishAndGuardianExits(v);
    }

    /// @dev The guardian's own gate: pending redemptions and a partial last fill both block the exit; a full fill
    ///      (or an epoch without redemptions) after the partial one opens it.
    function test_VERIFY3_W01b_guardianGate() public {
        HyperVault v = _afterPartialFill();
        v.claim(alice);
        uint256 back = v.balanceOf(alice);
        vm.prank(alice);
        v.requestRedeem(back, alice, alice);
        vm.prank(guardian);
        vm.expectRevert(E.RedemptionsPending.selector);
        v.exitEmergency(); // pending
        _home(v, sentinel, 900_000e6);
        vm.prank(sentinel);
        v.settle();
        vm.prank(guardian);
        v.exitEmergency();
        assertFalse(v.emergency());
    }
}
