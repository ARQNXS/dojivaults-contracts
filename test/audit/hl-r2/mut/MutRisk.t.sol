// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {MutBase} from "./MutBase.t.sol";
import {BreachReason, IHyperVaultErrors as E} from "../../../../src/VaultTypes.sol";

/// @title hl-r2 mutation kill tests: settle authorisation, bridge latching by settle / accrueFees, risk references
contract HLR2MutRiskTest is MutBase {
    /// Mutant: settle `if (exitOnly && !emergency && !epochOverdue()) revert Unauthorized()` deleted. The owner,
    /// guardian and sentinel may only run an exit-only settle in emergency or once the epoch is overdue; at any
    /// other time it would refund every queued deposit and price exits at min(NAV, checkpoint) at their whim.
    function test_HLR2_M25_kills_platformExitOnlySettleBeforeOverdue() public {
        _deposit(alice, 1_000e6);
        _settle();
        _claim(alice);
        _deposit(bob, 500e6);
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        vault.checkRisk();
        address[3] memory who = [owner, guardian, sentinel];
        for (uint256 i; i < 3; ++i) {
            vm.prank(who[i]);
            vm.expectRevert(E.Unauthorized.selector);
            vault.settle();
        }
        // overdue: allowed
        vm.warp(vm.getBlockTimestamp() + 7 days);
        vm.prank(owner);
        vault.settle();
        (uint256 depAssets, uint256 depShares,,,,,,) = vault.epochs(vault.currentEpoch() - 1);
        assertEq(depAssets, 500e6);
        assertEq(depShares, 0, "exit only: refunded");
    }

    /// @dev Bridges 5,000 to Core, lands it on spot, closes the window without any latching call.
    function _landedToCore() internal {
        _fund(10_000e6);
        _deposit(bob, 5_000e6);
        vm.warp(vm.getBlockTimestamp() + 2 hours);
        _settle();
        _claim(bob);
        vm.prank(manager);
        vault.bridgeToCore(5_000e6);
        _setCore(address(vault), 10_000e6, 0, 5_000e6); // landed on spot
        vm.roll(vm.getBlockNumber() + 11);
    }

    /// Mutant: settle's leading `_syncBridge($)` deleted. The settle is the first transaction that sees the landing
    /// and must latch it: when the landed USDC then moves on (the agent can move spot to perp itself, an action
    /// the vault does not see), the window must not reopen on the stale snapshot.
    function test_HLR2_M26_kills_settleDoesNotLatch() public {
        _landedToCore();
        vm.prank(manager);
        vault.settle();
        _setCore(address(vault), 13_000e6, 0, 0); // moved to perp off-chain, then -2,000 of PnL
        assertFalse(vault.bridgePending(), "latched by the settle");
        assertEq(vault.totalAssets(), 13_000e6);
    }

    /// Mutant: accrueFees' leading `_syncBridge($)` deleted (same rule).
    function test_HLR2_M27_kills_accrueFeesDoesNotLatch() public {
        _landedToCore();
        vault.accrueFees();
        _setCore(address(vault), 13_000e6, 0, 0);
        assertFalse(vault.bridgePending(), "latched by accrueFees");
        assertEq(vault.totalAssets(), 13_000e6);
    }

    /// Mutant: settle `$.peakSharePrice = price` at the first mint deleted. A vault that empties after a high and
    /// refills starts its drawdown reference from the new first-mint price, not from the old peak (else the first
    /// risk check after the refill reads a phantom drawdown).
    function test_HLR2_M28_kills_firstMintKeepsTheOldPeak() public {
        vm.prank(owner);
        vault.lowerFees(0, 0); // no fee shares: the supply can reach zero
        _deposit(alice, 1_000e6);
        _settle();
        _claim(alice);
        usdc.mint(address(vault), 500e6); // +50%
        for (uint256 i; i < 3; ++i) {
            vm.warp(vm.getBlockTimestamp() + 1 hours);
            vault.checkRisk(); // ratchet, the peak follows
        }
        assertGt(vault.peakSharePrice(), 1.4e6);
        _redeem(alice, vault.balanceOf(alice)); // everyone leaves
        _settle();
        _claim(alice);
        assertEq(vault.totalSupply(), 0);
        _deposit(bob, 1_000e6);
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        _settle(); // first mint again, at ~1 USDC per share
        assertLt(vault.peakSharePrice(), 1.1e6, "the peak restarts at the first mint");
        (,, uint256 dd) = vault.checkRisk();
        assertEq(dd, 0);
        assertFalse(vault.breached());
    }

    /// Mutant: settle `if (price > peakSharePrice) peakSharePrice = price` deleted. A settle that prices at a new
    /// high must move the drawdown peak: a fall from it right after is a drawdown, not only a daily loss.
    function test_HLR2_M29_kills_settleDoesNotRaiseThePeak() public {
        vm.prank(owner);
        vault.lowerFees(0, 0);
        _deposit(alice, 10_000e6);
        _settle();
        _claim(alice);
        vault.checkRisk();
        usdc.mint(address(vault), 1_900e6); // +19% (within the 20% NAV bound)
        vm.warp(vm.getBlockTimestamp() + 2 hours);
        vm.prank(manager);
        vault.settle(); // no checkRisk before: only the settle sees the high
        uint256 high = vault.sharePrice();
        assertGt(vault.peakSharePrice(), 1.1e6);
        assertEq(vault.peakSharePrice(), high);
        usdc.burnFrom(address(vault), 2_000e6); // a loss of 2,000 (stands in for a trading loss)
        vault.checkRisk();
        assertTrue(vault.breached());
        assertEq(uint8(vault.breachReason()), uint8(BreachReason.DRAWDOWN), "measured from the settle's high");
    }
}
