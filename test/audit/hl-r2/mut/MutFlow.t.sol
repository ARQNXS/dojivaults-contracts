// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {MutBase} from "./MutBase.t.sol";
import {IHyperVaultErrors as E} from "../../../../src/VaultTypes.sol";

/// @title hl-r2 mutation kill tests on the depositor flow (request, cancel, claim)
contract HLR2MutFlowTest is MutBase {
    function _settled(uint256 aliceAmount) internal {
        _deposit(alice, aliceAmount);
        _settle();
        _claim(alice);
    }

    /// Mutants: VaultLogic.cancelRedeemRequest `r.redeemShares = 0` deleted / set to 1. A cancelled redemption
    /// must be gone: otherwise the controller cancels again and takes the shares other redeemers escrowed (here
    /// bob's), and the settle would still pay the cancelled request.
    function test_HLR2_M13_kills_cancelRedeemTwice() public {
        _settled(1_000e6);
        _deposit(bob, 1_000e6);
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        _settle();
        _claim(bob);
        uint256 a = vault.balanceOf(alice);
        uint256 b = vault.balanceOf(bob);
        _redeem(alice, a / 2);
        _redeem(bob, b);
        vm.prank(alice);
        vault.cancelRedeemRequest();
        (, , uint256 left) = vault.requests(alice);
        assertEq(left, 0, "request cleared");
        vm.prank(alice);
        vm.expectRevert(E.NothingToCancel.selector);
        vault.cancelRedeemRequest();
        assertEq(vault.balanceOf(alice), a, "alice has her own shares back, not more");
        assertEq(vault.balanceOf(address(vault)), b, "bob's escrow intact");
        assertEq(vault.pendingRedeemShares(), b);
    }

    /// Mutant: VaultLogic.cancelDepositRequest `if (!carried) revert NothingToCancel()` deleted. A deposit that was
    /// already priced (shares minted, not yet claimed) must not be cancellable: the cancel would refund it out of
    /// the next depositors' queued USDC while its shares stay minted.
    function test_HLR2_M14_kills_cancelOfAPricedDeposit() public {
        _deposit(alice, 1_000e6);
        _settle(); // alice's shares minted, unclaimed
        _deposit(bob, 1_000e6); // bob's USDC queued
        vm.prank(alice);
        vm.expectRevert(E.NothingToCancel.selector);
        vault.cancelDepositRequest();
        assertEq(vault.pendingDepositAssets(), 1_000e6, "bob's deposit intact");
        _claim(alice);
        assertGt(vault.balanceOf(alice), 0);
    }

    /// Mutants: requestDeposit / requestRedeem `controller == address(0)` guards deleted or turned to address(1).
    function test_HLR2_M15_kills_zeroController() public {
        vm.prank(alice);
        vm.expectRevert(E.ZeroAddress.selector);
        vault.requestDeposit(100e6, address(0));
        _settled(1_000e6);
        vm.prank(alice);
        vm.expectRevert(E.ZeroAddress.selector);
        vault.requestRedeem(1, address(0), alice);
        // address(1) is an ordinary controller
        vm.prank(alice);
        vault.requestDeposit(100e6, address(1));
        (, uint256 dep,) = vault.requests(address(1));
        assertEq(dep, 100e6);
    }

    /// Mutant: requestDeposit cap check `>` -> `>=`: a deposit that fills the cap exactly is allowed.
    function test_HLR2_M16_kills_capBoundary() public {
        vm.prank(owner);
        vault.setDepositCap(1_000e6);
        _deposit(alice, 1_000e6); // NAV 0 + 1,000 == cap
        vm.prank(bob);
        vm.expectRevert(E.CapExceeded.selector);
        vault.requestDeposit(10e6, bob);
    }

    /// Mutants: zero amount guards (requestDeposit, requestRedeem, cancelDepositRequest) deleted: the call must
    /// revert with the documented error, not run as a no-op (requestRedeem(0) on someone else's behalf would rewrite
    /// their request pointer; requestDeposit(0) is caught by MIN_DEPOSIT with another error).
    function test_HLR2_M17_kills_zeroAmountGuards() public {
        vm.prank(alice);
        vm.expectRevert(E.ZeroAmount.selector);
        vault.requestDeposit(0, alice);
        vm.prank(alice);
        vm.expectRevert(E.ZeroAmount.selector);
        vault.requestRedeem(0, alice, alice);
        vm.prank(stranger);
        vm.expectRevert(E.ZeroAmount.selector);
        vault.requestRedeem(0, alice, alice);
        vm.prank(alice);
        vm.expectRevert(E.NothingToCancel.selector);
        vault.cancelDepositRequest();
        vm.prank(alice);
        vm.expectRevert(E.NothingToCancel.selector);
        vault.cancelRedeemRequest();
    }
}
