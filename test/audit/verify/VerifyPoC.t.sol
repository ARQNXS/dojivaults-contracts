// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {AuditBase} from "../AuditBase.t.sol";
import {HyperVault} from "../../../src/HyperVault.sol";
import {HyperVaultFactory} from "../../../src/HyperVaultFactory.sol";

/// @notice Verification pass (round 3, 1bd2153..875c1c4), inverted after the V-01 / V-03 fixes: an emergency settle
///         is a partial fill plus return (only the paid shares are burned, the rest come back to the redeemer), so a
///         late redeemer is paid at fair value whatever happened in earlier epochs, and nobody else gains.
///         Run: forge test --match-path test/audit/verify/VerifyPoC.t.sol -vv
contract VerifyPoC is AuditBase {
    int64 internal perp;
    uint64 internal spot;

    function _core(HyperVault v) internal {
        _setCore(address(v), perp, 0, spot);
        _setWithdrawable(address(v), perp > 0 ? uint64(perp) : 0);
    }

    /// @dev Anyone (emergency) brings exactly `amount` home; modelled as arriving at once. Window then closes.
    function _bridgeHome(HyperVault v, uint256 amount) internal {
        vm.prank(sentinel);
        v.bridgeToEvm(amount);
        spot -= uint64(amount);
        usdc.mint(address(v), amount);
        _core(v);
        vm.roll(vm.getBlockNumber() + 11);
    }

    /// @dev One attacker-shaped pro rata epoch: brings home exactly the liquidity for a `fillBps` fill of what is
    ///      pending (the attacker's own redemption), then anyone settles.
    function _steer(HyperVault v, uint256 fillBps) internal {
        v.accrueFees(); // same block as the settle: settle's own accrual adds nothing
        uint256 redAssets = v.previewRedeem(v.pendingRedeemShares());
        uint256 paid = (redAssets * fillBps) / 10_000;
        if (paid > v.idleAssets()) _bridgeHome(v, paid - v.idleAssets());
        vm.prank(sentinel);
        v.settle();
    }

    // ==================================================================
    // V-01 (Critical, fixed)  Earlier near-complete pro rata epochs cannot hurt a later redeemer: each request
    //                         belongs to its own epoch, only the shares the epoch paid for are burned and the rest
    //                         are returned. The attacker's redemptions are paid at fair value and nothing more.
    // ==================================================================
    function test_VERIFY_V01_lateRedeemersArePaidOrReturned() public {
        (HyperVault v,) = _malloryVault();
        vm.prank(mallory2);
        v.requestDeposit(2_000_000e6, mallory2); // the attacker's sybil, not an insider
        _fundAndDeploy(v, mallory, 1_000_000e6, 0); // alice 1M + mallory2 2M settled; alice's 1M bridged
        v.claim(mallory2);
        vm.prank(mallory);
        v.bridgeToCore(2_000_000e6);
        perp = 0;
        spot = 3_000_000e6;
        _core(v);
        vm.roll(vm.getBlockNumber() + 11);

        // The manager stops settling; the sybil queues a redemption, the epoch goes overdue, anyone triggers emergency.
        uint256 unit = v.balanceOf(mallory2) / 2_000_000; // shares per USDC
        uint256 sybilBefore = _value(v, mallory2) + usdc.balanceOf(mallory2); // everything it owns, before any request
        vm.prank(mallory2);
        v.requestRedeem(400_000 * unit, mallory2, mallory2);
        vm.warp(vm.getBlockTimestamp() + 7 days);
        v.checkRisk();
        vm.prank(stranger);
        v.triggerEmergency();

        _steer(v, 9_999);
        vm.prank(mallory2);
        v.requestRedeem(400_000 * unit, mallory2, mallory2); // claims the previous epoch first (paid + returned)
        _steer(v, 9_990);
        vm.prank(mallory2);
        v.requestRedeem(150_000 * unit, mallory2, mallory2);
        _steer(v, 9_999);
        v.claim(mallory2);
        uint256 sybilAfterOwn = _value(v, mallory2) + usdc.balanceOf(mallory2);
        assertApproxEqRel(sybilAfterOwn, sybilBefore, 1e15, "the sybil's own redemptions are paid at fair value, no more (a week of fees aside)");

        // Honest exit: alice asks for her whole 1M.
        uint256 aliceShares = v.balanceOf(alice);
        vm.prank(alice);
        v.requestRedeem(aliceShares, alice, alice);

        // A minimum bridge (100 USDC) and a settle: alice is paid 100 USDC pro rata and gets the rest of her shares back.
        v.accrueFees();
        uint256 aliceValue = v.convertToAssets(aliceShares);
        _bridgeHome(v, 100e6);
        vm.prank(sentinel);
        v.settle();
        assertEq(v.pendingRedeemShares(), 0, "nothing rolls over");
        (uint256 sharesBack, uint256 paid) = lens.claimable(v, alice);
        (uint256 fillShares, uint256 fillPaid, uint256 fillEpoch) = lens.partialFill(v, alice);
        assertEq(fillShares, sharesBack);
        assertEq(fillPaid, paid);
        assertEq(fillEpoch, v.currentEpoch() - 1);

        uint256 before = usdc.balanceOf(alice);
        v.claim(alice);
        uint256 got = usdc.balanceOf(alice) - before;
        emit log_named_decimal_uint("alice's shares were worth ", aliceValue, 6);
        emit log_named_decimal_uint("alice received in USDC    ", got, 6);
        emit log_named_decimal_uint("alice's returned shares   ", v.convertToAssets(v.balanceOf(alice)), 6);
        assertEq(got, paid);
        assertApproxEqAbs(got, 100e6, 2, "the 100 USDC that came home, all of it");
        assertEq(v.balanceOf(alice), sharesBack, "the unpaid shares came back");
        assertApproxEqAbs(got + v.convertToAssets(v.balanceOf(alice)), aliceValue, 1e6, "paid at fair value or returned");
        assertApproxEqRel(_value(v, mallory2) + usdc.balanceOf(mallory2), sybilBefore, 1e15, "the attacker gained nothing");

        // She can queue the remainder again in one transaction (requestRedeem claims first).
        vm.prank(alice);
        v.requestRedeem(sharesBack, alice, alice);
        assertEq(v.pendingRedeemShares(), sharesBack);
    }

    // ==================================================================
    // V-03 (Info, fixed)  The factory cannot be renounced and the role check also covers the pending owner.
    // ==================================================================
    function test_VERIFY_V03_factoryOwnershipCannotBeRenouncedAndPendingOwnerIsChecked() public {
        vm.prank(owner);
        vm.expectRevert(HyperVaultFactory.RolesCollide.selector);
        factory.renounceOwnership();
        address next = makeAddr("nextOwner");
        vm.startPrank(owner);
        factory.transferOwnership(next);
        vm.expectRevert(HyperVaultFactory.RolesCollide.selector);
        factory.setSentinel(next); // would become owner == sentinel after acceptance
        vm.expectRevert(HyperVaultFactory.RolesCollide.selector);
        factory.setAgentRegistrar(next);
        factory.setGuardian(next); // owner == guardian is the intended setup
        vm.stopPrank();
        vm.prank(next);
        factory.acceptOwnership();
        assertEq(factory.owner(), next);
        assertEq(factory.guardian(), next);
    }
}
