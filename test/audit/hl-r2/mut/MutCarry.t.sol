// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {MutBase} from "./MutBase.t.sol";
import {BreachReason, IHyperVaultErrors as E} from "../../../../src/VaultTypes.sol";

/// @title hl-r2 mutation kill tests: redemption-only settles and the carry run of queued deposits (round 4)
/// @notice The earlier carry tests only checked that a carried deposit is claimable at all (balance > 0). These pin
///         the exact claim and the bookkeeping that routes it to the epoch that priced the run.
contract HLR2MutCarryTest is MutBase {
    address internal carol = makeAddr("carol");

    function setUp() public override {
        super.setUp();
        usdc.mint(carol, 1_000_000e6);
        vm.prank(carol);
        usdc.approve(address(vault), type(uint256).max);
        usdc.mint(manager, 1_000_000e6);
        vm.prank(manager);
        usdc.approve(address(vault), type(uint256).max);
    }

    function _drawdown(int64 navAfter) internal {
        vm.warp((vm.getBlockTimestamp() / 1 days + 1) * 1 days + 60);
        _setCore(address(vault), navAfter, 0, 0);
        for (uint256 i; i < 3; ++i) {
            vm.warp(vm.getBlockTimestamp() + 1 hours);
            vault.checkRisk();
        }
        assertEq(uint8(vault.breachReason()), uint8(BreachReason.DRAWDOWN));
    }

    function _settleNow() internal {
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        vault.checkRisk();
        vm.prank(manager);
        vault.settle();
    }

    function _shares(uint256 epoch, uint256 mine) internal view returns (uint256) {
        (uint256 depAssets, uint256 depShares,,,,,,) = vault.epochs(epoch);
        return (mine * depShares) / depAssets;
    }

    /// Mutants: settle `carryPricedIn[carryOrigin - 1] = epoch + 1` -> `epoch - 1`, `carryOrigin = epoch + 1` ->
    /// `epoch + 0`, `carryOrigin = 0` deleted / set to 1, `if (pendingDepositAssets > 0)` boundary, and the
    /// claim-side lookup. Two carry runs back to back: each carried deposit gets exactly its share of the epoch
    /// that priced ITS run.
    function test_HLR2_M22_kills_carryRunBookkeeping() public {
        _fund(100_000e6);
        _deposit(bob, 10_000e6);
        _drawdown(82_000e6);
        _settleNow(); // redemption-only: bob carried
        _settleNow(); // and again
        vm.warp(vault.breachedAt() + vault.RESUME_COOLDOWN());
        vm.prank(owner);
        vault.resume();
        _settleNow(); // prices run 1
        uint256 p1 = vault.currentEpoch() - 1;
        _claim(bob);
        assertEq(vault.balanceOf(bob), _shares(p1, 10_000e6), "run 1 priced in its epoch");
        assertGt(vault.balanceOf(bob), 0);

        // run 2: carol queues, a new drawdown, two redemption-only settles, resume, priced
        _deposit(carol, 7_000e6);
        _drawdown(65_000e6);
        _settleNow();
        _settleNow();
        vm.warp(vault.breachedAt() + vault.RESUME_COOLDOWN());
        vm.prank(owner);
        vault.resume();
        _settleNow();
        uint256 p2 = vault.currentEpoch() - 1;
        assertTrue(p2 != p1);
        _claim(carol);
        assertEq(vault.balanceOf(carol), _shares(p2, 7_000e6), "run 2 priced in its own epoch");
        (uint256 cf1, uint256 pi1) = vault.carry(p1 - 1);
        (uint256 cf2, uint256 pi2) = vault.carry(p2 - 1);
        assertTrue(cf1 != 0 && cf2 != 0 && cf1 != cf2, "two distinct runs");
        assertEq(pi1, p1 + 1);
        assertEq(pi2, p2 + 1);

        // run 3 (a reused origin would price it in run 2's epoch)
        uint256 bobBefore = vault.balanceOf(bob);
        _deposit(bob, 3_000e6);
        _drawdown(50_000e6);
        _settleNow();
        vm.expectRevert(E.RequestNotSettled.selector);
        vault.claim(bob); // still carried: nothing to deliver yet
        vm.warp(vault.breachedAt() + vault.RESUME_COOLDOWN());
        vm.prank(owner);
        vault.resume();
        _settleNow();
        uint256 p3 = vault.currentEpoch() - 1;
        _claim(bob);
        assertEq(vault.balanceOf(bob) - bobBefore, _shares(p3, 3_000e6), "run 3 priced in its own epoch");
    }

    /// Mutants: redemption-only settle `pendingDepositAssets += deferredDepositAssets` deleted / `-=`, and the
    /// `insiderInQueue = true` flag for carried insider deposits (deleted, false, `<=`). An insider deposit made
    /// for the next epoch must join the carried queue (otherwise its USDC is no longer reserved and becomes NAV),
    /// and the settle that prices it must wait INSIDER_MIN_EPOCH_AGE (R3-02) even right after a guardian clear.
    function test_HLR2_M23_kills_insiderDepositThroughARedemptionOnlySettle() public {
        _fund(100_000e6);
        vm.prank(manager);
        vault.requestDeposit(10_000e6, manager); // insider: priced next epoch
        _deposit(bob, 5_000e6);
        _drawdown(82_000e6);
        _settleNow(); // redemption-only
        assertEq(vault.pendingDepositAssets(), 15_000e6, "the insider's deposit joins the carried queue");
        assertEq(vault.deferredDepositAssets(), 0);
        vm.prank(guardian);
        vault.clearBreach();
        vm.prank(manager);
        vm.expectRevert(E.EpochTooYoung.selector);
        vault.settle(); // same block as the epoch start: the insider cannot be priced now
        vm.warp(vm.getBlockTimestamp() + 1 hours); // (no checkRisk: it would re-breach on the drawdown)
        vm.prank(manager);
        vault.settle();
        uint256 p = vault.currentEpoch() - 1;
        _claim(manager);
        _claim(bob);
        assertEq(vault.balanceOf(manager), _shares(p, 10_000e6));
        assertEq(vault.balanceOf(bob), _shares(p, 5_000e6));
    }

    /// Mutant: `if (deferredDepositAssets > 0) insiderInQueue = true` -> `>= 0`: without an insider deposit the
    /// pricing settle after a redemption-only one is not delayed.
    function test_HLR2_M24_kills_insiderDelayWithoutInsider() public {
        _fund(100_000e6);
        _deposit(bob, 5_000e6);
        _drawdown(82_000e6);
        _settleNow(); // redemption-only, no insider deposit
        vm.prank(guardian);
        vault.clearBreach();
        vm.prank(manager);
        vault.settle(); // prices bob at once
        _claim(bob);
        assertGt(vault.balanceOf(bob), 0);
    }
}
