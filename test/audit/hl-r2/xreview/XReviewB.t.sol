// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {console2} from "forge-std/console2.sol";

import {HostileBase} from "../hostile/HostileBase.t.sol";
import {EconBase} from "../econ/EconBase.t.sol";
import {HyperVault} from "../../../../src/HyperVault.sol";
import {VaultPolicy} from "../../../../src/VaultPolicy.sol";
import {HyperCore} from "../../../../src/hypercore/HyperCore.sol";
import {IHyperVaultErrors as E} from "../../../../src/VaultTypes.sol";

/// @notice hl-r2 cross-review B (challenger): counter-PoCs against HLR2-H01 / the ALERT mitigation, and the
///         instant-tightening variant of HLR2-E01. Every test passes on the current code.
///         Run: forge test --match-path "test/audit/hl-r2/xreview/*" -vv
contract XReviewBHostile is HostileBase {
    /// @dev Lands a guardian bridgeToEvm of the whole Core balance (the bridge itself is modelled as in HostileBase:
    ///      the precompiles drop, the EVM USDC appears) and lets the 10 block window close.
    function _guardianBringsEverythingHome(HyperVault v, uint256 amount) internal {
        vm.prank(guardian);
        v.bridgeToEvm(amount);
        _setCore(address(v), 0, 0, 0);
        _setWithdrawable(address(v), 0);
        usdc.mint(address(v), amount);
        vm.roll(vm.getBlockNumber() + 11);
        v.syncBridge();
    }

    // ------------------------------------------------------------------
    // XB-H01-a: the defence HLR2-H01 leaves out. The factory guardian may triggerEmergency at ANY time
    // (VaultGovernance.sol:244-246, `privileged`). Inside the 2-day policy timelock that freezes new risk for good
    // (placeOrder is reduce only in emergency, VaultLogic.sol:538; only the guardian exits an emergency) and the
    // guardian unwinds and pays the redeemer at the old risk. The loosening still applies, but to a vault that can
    // only reduce. H01 therefore holds only when the platform guardian does not act within the timelock; today
    // nothing alerts it (ConfigQueued is only a history row, server/src/history/replay.ts:344).
    // ------------------------------------------------------------------
    function test_XB_H01a_guardianEmergencyInsideTheTimelockGetsTheRedeemerOutAtTheOldRisk() public {
        HyperVault v = _platformVaultLike(address(0));
        VaultPolicy pol = v.policy();
        uint256 t0 = vm.getBlockTimestamp();
        uint256 shares = v.balanceOf(alice);
        uint256 aliceBefore = v.convertToAssets(shares);

        vm.startPrank(platformVaultOwner);
        v.setOperator(address(0));
        pol.proposeConfig(_loose());
        vm.stopPrank();
        vm.prank(alice);
        v.requestRedeem(shares, alice, alice);

        // t0 + 1 day: the guardian reacts (not overdue, no breach: its own privilege).
        vm.warp(t0 + 1 days);
        vm.prank(guardian);
        v.triggerEmergency();
        // the owner cannot end it (only the guardian exits an emergency)
        vm.prank(platformVaultOwner);
        vm.expectRevert(E.Unauthorized.selector);
        v.exitEmergency();

        // At the stored eta (H01: max(timelock, epoch + 1 day), no longer queue + 2 days) the loosening applies, but
        // the manager's 45x order is refused: reduce only.
        vm.warp(pol.pendingConfig().eta);
        pol.applyPendingConfig();
        assertEq(pol.maxLeverageBps(), 500_000);
        vm.prank(platformVaultOwner);
        vm.expectRevert(E.ReduceOnlyMode.selector);
        v.placeOrder(BTC, true, 100_000e8, 45e8, false, HyperCore.TIF_GTC, 0);

        // The guardian brings the USDC home and settles (exit-only, priced at min(NAV, checkpoint)).
        _guardianBringsEverythingHome(v, 100_002e6);
        vm.prank(guardian);
        v.settle();
        uint256 b0 = usdc.balanceOf(alice);
        v.claim(alice);
        uint256 paid = usdc.balanceOf(alice) - b0;
        console2.log("XB-H01a alice value at request", aliceBefore);
        console2.log("XB-H01a alice paid by the guardian's emergency settle", paid);
        assertApproxEqRel(paid, aliceBefore, 1e15, "paid in full at the old risk (0.1%)");
    }

    // ------------------------------------------------------------------
    // XB-ALERT: the ALERT's platform vault mitigation `proposeTimelockDelay(777600)` (9 days) is instant (a raise) and,
    // with maxEpochDuration 7 days, closes the loss leg of H01 without the guardian's discretion: a redeemer who
    // reacts to the queue can trigger the emergency herself at the old deadline (anyone, overdue + pending), which
    // freezes new risk before the eta. Her payout still needs a platform role to unwind and settle (no automation
    // in emergency, HLR2-L01). A later lowering of the delay itself waits the 9 days.
    // ------------------------------------------------------------------
    function test_XB_ALERT_nineDayPolicyTimelockLetsTheRedeemerFreezeRiskBeforeTheLooseningApplies() public {
        HyperVault v = _platformVaultLike(address(0));
        VaultPolicy pol = v.policy();
        uint256 epochStart = v.epochStartedAt();

        // Mitigation, from the policy owner: instant raise.
        vm.prank(platformVaultOwner);
        pol.proposeTimelockDelay(777_600);
        assertEq(pol.timelockDelay(), 9 days, "raised at once");
        assertEq(pol.pendingTimelockEta(), 0);

        // Hostile owner afterwards: drop the operator, queue the loosening (eta + 9 d). Alice requests at once.
        uint256 t0 = vm.getBlockTimestamp();
        vm.startPrank(platformVaultOwner);
        v.setOperator(address(0));
        pol.proposeConfig(_loose());
        vm.stopPrank();
        assertEq(pol.pendingConfig().eta, t0 + 9 days);
        uint256 shares = v.balanceOf(alice);
        uint256 aliceBefore = v.convertToAssets(shares);
        vm.prank(alice);
        v.requestRedeem(shares, alice, alice);

        // At the OLD deadline (epoch start + 7 d, before the eta) alice herself triggers the emergency.
        vm.warp(epochStart + 7 days);
        assertLt(vm.getBlockTimestamp(), t0 + 9 days, "before the eta");
        vm.prank(alice);
        v.triggerEmergency();
        assertTrue(v.emergency());

        // The eta passes: the loosening applies, the vault can only reduce.
        vm.warp(t0 + 9 days);
        pol.applyPendingConfig();
        vm.prank(platformVaultOwner);
        vm.expectRevert(E.ReduceOnlyMode.selector);
        v.placeOrder(BTC, true, 100_000e8, 45e8, false, HyperCore.TIF_GTC, 0);

        // A platform role unwinds and pays (manual today).
        _guardianBringsEverythingHome(v, 100_002e6);
        vm.prank(guardian);
        v.settle();
        uint256 b0 = usdc.balanceOf(alice);
        v.claim(alice);
        assertApproxEqRel(usdc.balanceOf(alice) - b0, aliceBefore, 1e15, "alice out at the old risk");

        // And a lowering of the delay itself is queued behind the 9 days (a depositor sees it first).
        vm.prank(platformVaultOwner);
        pol.proposeTimelockDelay(1 days);
        assertEq(pol.timelockDelay(), 9 days);
        assertEq(pol.pendingTimelockEta(), vm.getBlockTimestamp() + 9 days);
    }

}

contract XReviewBEcon is EconBase {
    // ------------------------------------------------------------------
    // XB-E01-c: the defence HLR2-E01 notes but does not test in an honest emergency. checkRisk is permissionless and
    // runs in emergency (VaultGovernance._check has no emergency guard); each call at least an hour after the last
    // checkpoint walks it up by maxNavMoveBps. During a guardian unwind that takes hours, two calls an hour apart
    // remove the whole +30% gap. The honest-case loss of E01 exists because nobody calls it (the keeper sends no
    // checkRisk in a full stop, risk/contractRisk.ts:253-254).
    // ------------------------------------------------------------------
    function test_XB_E01c_anyoneWalksTheCheckpointUpInAnHonestEmergency() public {
        vm.prank(owner);
        vault.lowerFees(0, 0);
        _fundTwo(100_000e6, 100_000e6);
        _hours(20);
        _setCoreValue(260_000e6);
        uint256 aliceShares = vault.balanceOf(alice);
        _redeem(alice, aliceShares);

        vm.prank(guardian);
        vault.triggerEmergency();
        vm.prank(stranger);
        vault.checkRisk(); // 200k -> 240k
        _hours(1);
        vm.prank(stranger);
        vault.checkRisk(); // 240k -> 260k (cap 288k)
        assertEq(vault.checkpointNav(), 260_000e6);

        _toEvm(260_000e6);
        vm.prank(guardian);
        vault.settle();
        uint256 b0 = usdc.balanceOf(alice);
        vault.claim(alice);
        assertApproxEqAbs(usdc.balanceOf(alice) - b0, 130_000e6, 1e6, "fair value once the checkpoint is fresh");
    }

}
