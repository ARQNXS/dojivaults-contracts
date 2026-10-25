// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {EconBase} from "../econ/EconBase.t.sol";
import {VaultPolicy} from "../../../../src/VaultPolicy.sol";
import {IHyperVaultErrors as E} from "../../../../src/VaultTypes.sol";

/// @notice Fix test for HLR2-E01 (+ XB01): an exit-only settle never pays at a checkpoint that trails the NAV and
///         could still be walked up. Runs with patches/HLR2-E01.patch applied (fixes/verify-B.sh), from
///         test/audit/hl-r2/fixes/.
contract HLR2_E01_Fix is EconBase {
    function _gain() internal returns (uint256 aliceShares, uint256 fair) {
        vm.prank(owner);
        vault.lowerFees(0, 0);
        _fundTwo(100_000e6, 100_000e6); // cp 200k
        _hours(20);
        _setCoreValue(260_000e6); // a real +30%
        aliceShares = vault.balanceOf(alice);
        _redeem(alice, aliceShares);
        fair = vault.convertToAssets(aliceShares);
    }

    function _paid(address who) internal returns (uint256) {
        uint256 b0 = usdc.balanceOf(who);
        vault.claim(who);
        return usdc.balanceOf(who) - b0;
    }

    /// E01a inverted: the owner's emergency + same-block settle cannot pay at the 20 h old checkpoint. The settle
    /// waits for the walk (anyone's checkRisk, one capped step per hour) and then pays the fair 130k.
    function test_HLR2_E01_fix_ownerEmergencySettleWaitsForTheWalkAndPaysFair() public {
        (, uint256 fair) = _gain();
        vm.prank(owner);
        vault.triggerEmergency();
        _toEvm(260_000e6);
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(E.CheckpointBehind.selector, uint256(200_000e6), uint256(260_000e6)));
        vault.settle();

        vm.prank(stranger);
        vault.checkRisk(); // 200k -> 240k, capped
        assertEq(vault.checkpointNav(), 240_000e6);
        assertTrue(vault.checkpointLagging());
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(E.CheckpointBehind.selector, uint256(240_000e6), uint256(260_000e6)));
        vault.settle(); // a fresh but capped checkpoint is not a price either

        _hours(1);
        vm.prank(alice); // the redeemer herself can drive it
        vault.checkRisk(); // 240k -> 260k
        assertFalse(vault.checkpointLagging());
        vm.prank(manager);
        vault.settle();
        uint256 paid = _paid(alice);
        assertApproxEqAbs(paid, fair, 1e6, "fair value");
        assertApproxEqAbs(paid, 130_000e6, 1e6);
        assertApproxEqAbs(_value(mallory), 130_000e6, 1e6, "the stayer keeps only her own share");
    }

    /// E01b inverted: overdue exit-only by the owner, same rule.
    function test_HLR2_E01_fix_overdueExitOnlyWaitsForTheWalk() public {
        vm.prank(owner);
        vault.lowerFees(0, 0);
        _fundTwo(100_000e6, 100_000e6);
        uint256 aliceShares = vault.balanceOf(alice);
        _redeem(alice, aliceShares);
        _hours(7 * 24);
        _setCoreValue(260_000e6);
        _toEvm(140_000e6);
        uint256 fair = vault.convertToAssets(aliceShares);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(E.CheckpointBehind.selector, uint256(200_000e6), uint256(260_000e6)));
        vault.settle();
        vault.checkRisk();
        _hours(1);
        vault.checkRisk();
        vm.prank(owner);
        vault.settle();
        assertApproxEqAbs(_paid(alice), fair, 1e6);
    }

    /// XB01 inverted (pricing half): the instant epoch tightening still makes the epoch overdue (fixA's deadline
    /// snapshot handles that), but the exit-only price is no longer the stale checkpoint.
    function test_HLR2_XB01_fix_epochTighteningNoLongerOpensTheStalePrice() public {
        (, uint256 fair) = _gain();
        _toEvm(140_000e6);
        VaultPolicy.RiskConfig memory c = _defaultRisk();
        c.maxEpochDuration = 1 hours;
        vm.prank(owner);
        policy.proposeConfig(c);
        // Without fixA's deadline snapshot the tightening is live and the owner's exit-only settle is refused on
        // price (CheckpointBehind); with it, the epoch is not overdue and the owner may not settle (Unauthorized).
        // Either way the stale price is never paid.
        vm.prank(owner);
        (bool ok, bytes memory ret) = address(vault).call(abi.encodeWithSignature("settle()"));
        assertFalse(ok);
        bytes4 sel = bytes4(ret);
        assertTrue(sel == E.CheckpointBehind.selector || sel == E.Unauthorized.selector);
        vault.checkRisk();
        _hours(1);
        vault.checkRisk();
        vm.prank(owner);
        (ok,) = address(vault).call(abi.encodeWithSignature("settle()"));
        if (!ok) {
            vm.prank(manager);
            vault.settle();
        }
        assertApproxEqAbs(_paid(alice), fair, 1e6);
        assertApproxEqAbs(_value(mallory), 130_000e6, 1e6);
    }

    /// E01d / E01e inverted: with the walk, nothing is left for the fee dust or the next first depositor.
    function test_HLR2_E01_fix_soleHolderExitLeavesNoOrphanedGain() public {
        vm.prank(owner);
        vault.lowerFees(0, 0);
        _deposit(alice, 100_000e6);
        _settleAs(manager);
        vault.claim(alice);
        _toCore(100_000e6);
        _hours(20);
        _setCoreValue(130_000e6);
        _redeem(alice, vault.balanceOf(alice));
        vm.prank(owner);
        vault.triggerEmergency();
        _toEvm(130_000e6);
        vault.checkRisk(); // 100k -> 120k
        _hours(1);
        vault.checkRisk(); // -> 130k
        _settleAs(manager);
        uint256 paid = _paid(alice);
        assertApproxEqAbs(paid, 130_000e6, 1e6, "alice is paid the whole NAV");
        assertEq(vault.totalSupply(), 0);
        assertLt(vault.totalAssets(), 1e6, "no orphaned gain for a later first mint");
    }

    /// The spike protection the min() exists for is kept: a rise younger than one checkpoint interval is withheld.
    function test_HLR2_E01_fix_freshSpikeIsStillWithheld() public {
        vm.prank(owner);
        vault.lowerFees(0, 0);
        _fundTwo(100_000e6, 100_000e6);
        _hours(20);
        vault.checkRisk(); // fresh checkpoint at 200k, not capped
        assertFalse(vault.checkpointLagging());
        _redeem(alice, vault.balanceOf(alice));
        vm.prank(owner);
        vault.triggerEmergency();
        _setCoreValue(250_000e6); // +25% in the same block (a spike)
        _toEvm(110_000e6);
        _settleAs(manager);
        assertApproxEqAbs(_paid(alice), 100_000e6, 1e6, "the one-block spike is not paid out");
    }

    /// A NAV below the checkpoint is paid at once at the NAV (the walk is only needed upward).
    function test_HLR2_E01_fix_lossIsPaidAtOnce() public {
        vm.prank(owner);
        vault.lowerFees(0, 0);
        _fundTwo(100_000e6, 100_000e6);
        _hours(20);
        _setCoreValue(180_000e6);
        _redeem(alice, vault.balanceOf(alice));
        vm.prank(owner);
        vault.triggerEmergency();
        _toEvm(180_000e6);
        _settleAs(manager);
        assertApproxEqAbs(_paid(alice), 90_000e6, 1e6);
    }

    /// Liveness bound at the policy floor (maxNavMoveBps 5%): a +30% gap needs ceil(ln 1.3 / ln 1.05) = 6 hourly
    /// steps, after which the exit settles at the fair price.
    function test_HLR2_E01_fix_livenessAtTheNavMoveFloor() public {
        VaultPolicy.RiskConfig memory c = _defaultRisk();
        c.maxNavMoveBps = 500; // a lowering is timelocked
        vm.prank(owner);
        policy.proposeConfig(c);
        // integrated with HLR2-H01: the loosening waits its stored notice eta (epoch + EXIT_MARGIN), not timelockDelay
        vm.warp(policy.pendingConfig().eta);
        policy.applyPendingConfig();
        vault.checkRisk();
        (, uint256 fair) = _gain();
        vm.prank(owner);
        vault.triggerEmergency();
        _toEvm(260_000e6);
        uint256 steps;
        while (true) {
            vm.prank(manager);
            (bool ok,) = address(vault).call(abi.encodeWithSignature("settle()"));
            if (ok) break;
            vault.checkRisk();
            ++steps;
            _hours(1);
            assertLt(steps, 10);
        }
        assertEq(steps, 6, "six hourly steps at 5%");
        assertApproxEqAbs(_paid(alice), fair, 1e6);
    }
}
