// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {EconBase} from "../hl-r2/econ/EconBase.t.sol";

/// @notice WP5 (release verification, HL fix review): a discriminating test for the E01d / E01e leg of HLR2-E01.
///         `HLR2_E01_Fix.test_HLR2_E01_fix_soleHolderExitLeavesNoOrphanedGain` walks the checkpoint with two
///         checkRisk calls BEFORE it settles, so it passes with the E01 fix reverted too (WP5 revert run E01): it
///         does not show that the fix closes the orphaned gain. This test settles first, as the E01e PoC did: with
///         the fix the stale-checkpoint settle reverts (CheckpointBehind) and the exit only pays after the walk;
///         without it the sole holder is paid at the 20 h old checkpoint and the gain is left for the next first mint.
///         The assertions are on what the redeemer is paid and what is left in the vault, not on the revert.
contract WP5_HLFIX_E01 is EconBase {
    function test_WP5_HLFIX_E01_soleHolderSettledAtOnceIsPaidTheWholeNav() public {
        vm.prank(owner);
        vault.lowerFees(0, 0);
        _deposit(alice, 100_000e6);
        _settleAs(manager);
        vault.claim(alice);
        _toCore(100_000e6); // checkpoint 100k
        _hours(20);
        _setCoreValue(130_000e6); // a real +30%, never walked into the checkpoint
        _redeem(alice, vault.balanceOf(alice));
        vm.prank(owner);
        vault.triggerEmergency();
        _toEvm(130_000e6);

        // The settler tries at once (the E01e order). Whatever the contract allows, alice must end with the NAV.
        vm.prank(manager);
        try vault.settle() {} catch {}
        if (vault.pendingRedeemShares() > 0) {
            // the settle waited: anyone walks the checkpoint (one capped step per hour), then the exit pays
            for (uint256 i; i < 8 && vault.pendingRedeemShares() > 0; ++i) {
                vault.checkRisk();
                vm.prank(manager);
                try vault.settle() {} catch {}
                _hours(1);
            }
        }
        uint256 b0 = usdc.balanceOf(alice);
        vault.claim(alice);
        uint256 paid = usdc.balanceOf(alice) - b0;
        emit log_named_uint("alice paid (fair 130,000)", paid);
        assertApproxEqAbs(paid, 130_000e6, 1e6, "the sole redeemer is paid the whole NAV, not the stale checkpoint");
        assertEq(vault.totalSupply(), 0);
        assertLt(vault.totalAssets(), 1e6, "no orphaned gain left for a later first mint");
    }
}
