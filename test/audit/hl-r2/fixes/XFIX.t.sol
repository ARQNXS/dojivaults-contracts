// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {console2} from "forge-std/console2.sol";

import {HostileBase} from "../hostile/HostileBase.t.sol";
import {HyperVault} from "../../../../src/HyperVault.sol";
import {VaultPolicy} from "../../../../src/VaultPolicy.sol";
import {IHyperVaultErrors as E} from "../../../../src/VaultTypes.sol";

/// @notice hl-r2 cross-review of the FIXES (XREVIEW-FIXES.md). Internal, AI-assisted review; not an independent audit.
///         Runs against contracts/src with fixes/patches/HLR2-H01.patch + COMBINED-B.patch (+ tests patches) applied,
///         in a throwaway (fixes/verify-xfix.sh, stage 1). Every test here PASSES while the issue exists.
contract XFIX_PoC is HostileBase {
    address internal agentKey = makeAddr("platformVault.agent");

    function _redeemAll(HyperVault v) internal returns (uint256 shares) {
        shares = v.balanceOf(alice);
        vm.prank(alice);
        v.requestRedeem(shares, alice, alice);
    }

    function _lastLimitPx() internal view returns (uint64 px) {
        (, uint24 id, bytes memory body) = _decode(writer.last());
        assertEq(id, 1, "limit order");
        (,, px,,,,) = abi.decode(body, (uint32, bool, uint64, uint64, bool, uint8, uint128));
    }

    // ------------------------------------------------------------------------------------------------------------
    // XF-03 (executor XA01 half + contract E06/XA01): the monitor's ACT sends the sentinel's triggerBreach. With E06
    // that is a platformHold: every settle (keeper, owner, manager) reverts until the cold guardian acts, or until
    // the epoch deadline lets a redeemer force the emergency. The contract XA01 path (a sentinel revoke) already
    // stops the deflated mint and keeps exits open.
    // ------------------------------------------------------------------------------------------------------------
    function _hostedWithIdle() internal returns (HyperVault v, uint256 redeemShares) {
        v = _platformVaultLike(agentKey);
        // the keeper keeps 20,000 USDC idle for redemptions; 80,002 on Core
        usdc.mint(address(v), 20_000e6);
        _setCore(address(v), 80_002e6, 0, 0);
        _setWithdrawable(address(v), 80_002e6);
        vm.warp(vm.getBlockTimestamp() + 1 hours + 1);
        v.checkRisk();
        redeemShares = v.balanceOf(alice) / 10; // ~10,000 USDC
        vm.prank(alice);
        v.requestRedeem(redeemShares, alice, alice);
    }

    function test_XF03_monitorActAsTriggerBreachFreezesEveryExitUntilTheDeadline() public {
        (HyperVault v,) = _hostedWithIdle();
        uint256 tReq = vm.getBlockTimestamp();
        vm.prank(sentinel);
        v.triggerBreach(); // what monitor.ts sends on an ACT with MONITOR_ACT_BREACH=true (default)
        assertTrue(v.platformHold());

        // The keeper's settle, the owner's and the manager's: all refused.
        vm.prank(keeper);
        vm.expectRevert(E.ReduceOnlyMode.selector);
        v.settle();
        vm.prank(platformVaultOwner);
        vm.expectRevert(E.ReduceOnlyMode.selector);
        v.settle();
        // The redeemer cannot force anything before the deadline.
        vm.warp(v.epochDeadline() - 1);
        vm.prank(alice);
        vm.expectRevert(E.NotOverdue.selector);
        v.triggerEmergency();
        vm.prank(keeper);
        vm.expectRevert(E.ReduceOnlyMode.selector);
        v.settle();

        // Only at the deadline (guardian still absent): emergency, then the exit-only settle.
        vm.warp(v.epochDeadline());
        vm.prank(alice);
        v.triggerEmergency();
        v.checkRisk(); // E01: walk the stale checkpoint first (permissionless)
        vm.prank(keeper);
        v.settle();
        uint256 b0 = usdc.balanceOf(alice);
        v.claim(alice);
        uint256 paid = usdc.balanceOf(alice) - b0;
        assertGt(paid, 9_000e6);
        uint256 waited = vm.getBlockTimestamp() - tReq;
        assertGt(waited, 6 days + 20 hours);
        console2.log("XF03: after the ACT's triggerBreach alice waited (s)", waited);
        console2.log("XF03: and the vault is now in a permanent emergency (agent revoked, reduce only), paid", paid);
    }

    /// Control: the same ACT as a sentinel revoke (contract XA01 depositHold): the keeper settles in the same block,
    /// alice is paid, a queued deposit is carried and nothing is minted.
    function test_XF03_control_revokeKeepsExitsOpenAndMintsNothing() public {
        (HyperVault v,) = _hostedWithIdle();
        vm.prank(bob);
        usdc.approve(address(v), type(uint256).max);
        vm.prank(bob);
        v.requestDeposit(50_000e6, bob);
        vm.prank(sentinel);
        v.revokeAgent();
        assertTrue(v.depositHold());
        assertFalse(v.breached());
        uint256 supply0 = v.totalSupply();
        vm.prank(keeper);
        v.settle(); // redemption-only
        uint256 b0 = usdc.balanceOf(alice);
        v.claim(alice);
        assertGt(usdc.balanceOf(alice) - b0, 9_000e6, "alice paid at once");
        assertLt(v.totalSupply(), supply0, "only burns: bob's deposit carried, not minted");
        assertFalse(v.emergency());
    }

    // ------------------------------------------------------------------------------------------------------------
    // XF-04 (E01 + executor): in emergency the keeper sends no checkRisk (risk/contractRisk.ts hardStop) and the
    // operator's emergency exit sends the settle straight away. With E01 one micro-USDC of NAV above a checkpoint
    // older than an hour reverts that settle. One permissionless checkRisk unblocks it.
    // ------------------------------------------------------------------------------------------------------------
    function test_XF04_aCentAboveAStaleCheckpointRevertsTheEmergencySettle() public {
        HyperVault v = _platformVaultLike(address(0));
        _redeemAll(v);
        vm.warp(v.epochDeadline());
        vm.prank(alice);
        v.triggerEmergency();
        // the guardian brings everything home (H04: the platform's job now)
        vm.prank(guardian);
        v.bridgeToEvm(100_002e6);
        _setCore(address(v), 0, 0, 0);
        _setWithdrawable(address(v), 0);
        usdc.mint(address(v), 100_002e6 + 10_000); // + 0.01 USDC (e.g. funding received before the flatten)
        vm.roll(vm.getBlockNumber() + 11);
        v.syncBridge();
        assertGt(vm.getBlockTimestamp(), uint256(v.checkpointAt()) + 1 hours, "checkpoint older than an hour");

        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(E.CheckpointBehind.selector, uint256(100_002e6), uint256(100_002e6 + 10_000)));
        v.settle();
        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSelector(E.CheckpointBehind.selector, uint256(100_002e6), uint256(100_002e6 + 10_000)));
        v.settle();

        v.checkRisk(); // anyone
        vm.prank(keeper);
        v.settle();
        uint256 b0 = usdc.balanceOf(alice);
        v.claim(alice);
        assertGt(usdc.balanceOf(alice) - b0, 99_000e6);
    }
}
