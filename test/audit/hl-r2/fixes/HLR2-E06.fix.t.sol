// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {EconBase} from "../econ/EconBase.t.sol";
import {HostileBase} from "../hostile/HostileBase.t.sol";
import {HyperVault} from "../../../../src/HyperVault.sol";
import {BreachReason, IHyperVaultErrors as E} from "../../../../src/VaultTypes.sol";

/// @notice Fix test for HLR2-E06: a full stop the vault owner imposes alone settles redemption-only (exits stay
///         open, nothing is minted, deposits are carried); a full stop by the guardian or the sentinel still freezes
///         every settle. Runs with patches/HLR2-E06.patch applied (fixes/verify-B.sh).
contract HLR2_E06_Fix is EconBase {
    /// alice 100k + mallory 100k, alice redeems half, the redemption fully covered by idle USDC.
    function _standard() internal returns (uint256 aliceShares) {
        _fundTwo(100_000e6, 100_000e6);
        aliceShares = vault.balanceOf(alice) / 2;
        _redeem(alice, aliceShares);
        _toEvm(100_000e6);
    }

    /// E06 inverted: the owner's triggerBreach + operator removal no longer freezes the exit. Any listed role settles
    /// redemption-only at once; bob's queued deposit is carried, not minted.
    function test_HLR2_E06_fix_ownerStopSettlesRedemptionOnlyAtOnce() public {
        _standard();
        vm.prank(bob);
        vault.requestDeposit(20e6, bob);
        vm.prank(owner);
        vault.triggerBreach();
        vm.prank(owner);
        vault.setOperator(address(0));
        assertEq(uint8(vault.breachReason()), uint8(BreachReason.GUARDIAN));
        assertFalse(vault.platformHold());
        uint256 supplyBefore = vault.totalSupply();

        vm.prank(guardian);
        vault.settle(); // no wait for maxEpochDuration
        vault.claim(alice);
        assertGt(usdc.balanceOf(alice), 900_000e6 + 49_000e6, "alice is paid in the same block");
        (uint256 carriedFrom,) = vault.carry(vault.currentEpoch() - 1);
        assertGt(carriedFrom, 0, "bob's deposit is carried, not priced");
        assertLt(vault.totalSupply(), supplyBefore, "only burns, no mint");
        assertEq(vault.balanceOf(bob), 0);
        // the manager may settle the next one too (redemption-only); a stranger still may not
        vm.prank(stranger);
        vm.expectRevert(E.Unauthorized.selector);
        vault.settle();
    }


    /// The guardian's own full stop keeps freezing every settle, as before.
    function test_HLR2_E06_fix_guardianStopStillFreezesEverySettle() public {
        _standard();
        vm.prank(guardian);
        vault.triggerBreach();
        assertTrue(vault.platformHold());
        address[3] memory roles = [manager, owner, guardian];
        for (uint256 i; i < roles.length; ++i) {
            vm.prank(roles[i]);
            vm.expectRevert(E.ReduceOnlyMode.selector);
            vault.settle();
        }
    }

    /// An owner re-trigger never downgrades a platform hold; a guardian trigger upgrades an owner stop.
    function test_HLR2_E06_fix_holdOnlyEscalates() public {
        _standard();
        vm.prank(owner);
        vault.triggerBreach();
        vm.prank(guardian);
        vault.triggerBreach();
        vm.prank(owner);
        vault.triggerBreach();
        assertTrue(vault.platformHold(), "owner cannot downgrade");
        vm.prank(manager);
        vm.expectRevert(E.ReduceOnlyMode.selector);
        vault.settle();
        // the guardian clears: the hold goes with the breach
        vm.prank(guardian);
        vault.clearBreach();
        assertFalse(vault.platformHold());
        assertFalse(vault.breached());
    }

    /// The owner's stop still does what it is for: agent revoked, reduce only, deposits closed.
    function test_HLR2_E06_fix_ownerStopStillStopsRisk() public {
        _standard();
        vm.prank(owner);
        vault.triggerBreach();
        assertTrue(vault.breached());
        assertEq(vault.agent(), address(0));
        vm.prank(bob);
        vm.expectRevert(E.DepositsClosed.selector);
        vault.requestDeposit(20e6, bob);
    }
}

/// @notice The factory case: the sentinel is a separate key there. Its stop holds; the vault owner's does not.
contract HLR2_E06_FixFactory is HostileBase {
    function test_HLR2_E06_fix_sentinelStopHoldsOwnerStopDoesNot() public {
        HyperVault v = _platformVaultLike(address(0));
        _setCore(address(v), 50_002e6, 0, 0);
        usdc.mint(address(v), 50_000e6); // half home
        uint256 quarter = v.balanceOf(alice) / 4;
        vm.prank(alice);
        v.requestRedeem(quarter, alice, alice);

        vm.prank(sentinel);
        v.triggerBreach();
        assertTrue(v.platformHold());
        vm.prank(keeper);
        vm.expectRevert(E.ReduceOnlyMode.selector);
        v.settle();

        vm.prank(guardian);
        v.clearBreach();
        vm.prank(platformVaultOwner);
        v.triggerBreach();
        assertFalse(v.platformHold());
        uint256 b0 = usdc.balanceOf(alice);
        vm.prank(guardian);
        v.settle(); // redemption-only
        v.claim(alice);
        assertApproxEqAbs(usdc.balanceOf(alice) - b0, 25_000e6, 1e6, "a quarter of 100k paid at once");
    }
}
