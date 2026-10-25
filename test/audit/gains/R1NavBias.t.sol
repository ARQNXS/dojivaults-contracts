// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {console2} from "forge-std/Test.sol";
import {R1Base} from "./R1Base.t.sol";
import {GainsVault} from "../../../src/gains/GainsVault.sol";
import {GainsVaultPolicy} from "../../../src/gains/GainsVaultPolicy.sol";

/// @notice GR1-02 (was NAVBIAS). Before the fix the adverse-edge NAV (PLAN.md 4.3) was used for BOTH sides of every
///         settle: deposits minted at the same understated NAV that redemptions burn at, so a deposit made while trades
///         were open and redeemed once they were closed took about B x vault leverage from the holders already in (3x:
///         bob +300, alice -301 on 100k each). Fix: deposits mint at the favourable band edge, redemptions are paid at
///         the adverse edge, and every settle that prices deposits runs at least an hour into the epoch. These
///         regression tests replay the same cycles and assert that the holder loses at most rounding and the cycle
///         costs the depositor the band instead (they fail on the old code).
contract R1NavBiasTest is R1Base {
    /// @dev Live configuration shape (policy 3x, ETH band 20 bps).
    function test_GR1_02_depositWhileOpenRedeemWhenFlat_3x() public {
        (uint256 bobOut, uint256 aliceOut) = _cycle(vault, 100_000e6, 30_000);
        console2.log("3x  bob in 100000 USDC, out", bobOut / 1e6);
        console2.log("3x  alice in 100000 USDC, out", aliceOut / 1e6);
        assertGe(aliceOut + 2, 100_000e6, "the holder loses at most rounding");
        assertLe(bobOut, 100_000e6, "the in-and-out depositor gains nothing");
        // GR2-ECON-03: the 3x trade at the adverse edge is a leverage breach, and a leverage-breach settle now charges the
        // performance fee (before the fix it skipped it). Bob's entry spread S is the vault's gain over the high water
        // mark, so 20 % of S stays with the fee recipient: nothing is created, and what is left is the fee on that gain,
        // no more. With equal stakes S = bob's loss + alice's gain (bob pays S less his share of the fee, alice gets her
        // share of the 80 %); here S is about 600 USDC and the fee about 120.
        uint256 left = vault.totalAssets();
        assertEq(vault.balanceOf(feeRecipient), vault.totalSupply(), "only the fee recipient is left");
        assertApproxEqAbs(bobOut + aliceOut + left, 200_000e6, 1e6, "nothing created; the rest is fees");
        uint256 spread = (100_000e6 - bobOut) + (aliceOut - 100_000e6);
        assertLe(left, spread * 2_000 / 10_000 + 1e6, "at most the performance fee on the gain");
        assertGt(left, 0, "the leverage-breach settle charged the fee (GR2-ECON-03)");
    }

    /// @dev The highest vault leverage the factory bound allows at maxNavMoveBps 2,000 and B = 20 bps (12.5x).
    function test_GR1_02_depositWhileOpenRedeemWhenFlat_atTheNavBound() public {
        GainsVaultPolicy.RiskConfig memory r = _defaultRisk();
        r.maxLeverageBps = 125_000;
        r.maxOrderNotional = 10_000_000e6;
        (GainsVault v,) = _vaultWith(r);
        (uint256 bobOut, uint256 aliceOut) = _cycle(v, 100_000e6, 125_000);
        console2.log("12.5x bob in 100000 USDC, out", bobOut / 1e6);
        console2.log("12.5x alice in 100000 USDC, out", aliceOut / 1e6);
        assertGe(aliceOut + 2, 100_000e6, "the holder loses at most rounding");
        assertLe(bobOut, 100_000e6, "the depositor gains nothing");
    }

    /// @dev Repeating the cycle is unprofitable: five daily cycles at 12x by a non-insider confederate.
    function test_GR1_02_repeatedCyclesUnprofitable() public {
        GainsVaultPolicy.RiskConfig memory r = _defaultRisk();
        r.maxLeverageBps = 125_000;
        r.maxOrderNotional = 10_000_000e6;
        (GainsVault v,) = _vaultWith(r);
        _depositTo(v, alice, 100_000e6);
        _settleV(v);
        v.claim(alice);
        uint256 bobStart = usdc.balanceOf(bob);
        for (uint256 k; k < 5; ++k) {
            _skip(1 days); // a new UTC day per cycle: the daily-loss reference restarts, feeds stay fresh
            uint256 idle = v.idleAssets();
            uint32 idx = _open(v, ETH, true, uint120(idle), uint24(120_000 * idle / v.totalAssets() / 10));
            _depositTo(v, bob, 100_000e6);
            _settleV(v);
            v.claim(bob);
            _passHold(); // GR2-KEY-01b: the manager's exit waits out the minimum hold
            _closeFilled(v, idx, _px(ETH));
            _redeemFrom(v, bob, v.balanceOf(bob));
            _settleV(v);
            v.claim(bob);
        }
        uint256 bobEnd = usdc.balanceOf(bob);
        console2.log("5 cycles: bob's balance change (USDC, negative = loss)", int256(bobEnd) - int256(bobStart));
        console2.log("alice's 100000 USDC is now worth", v.totalAssets() / 1e6);
        assertLt(bobEnd, bobStart, "every cycle costs the depositor");
        assertGe(v.totalAssets() + 10, 100_000e6, "alice loses at most rounding");
    }

    /// @dev Settles that price deposits can no longer be cycled within the hour (old code: every few minutes).
    function test_GR1_02_settleThatMintsWaitsAnHour() public {
        _deposit(alice, 100_000e6);
        _settle();
        _claim(alice);
        _deposit(bob, 10_000e6);
        vault.checkRisk();
        vm.prank(manager);
        vm.expectRevert(bytes4(keccak256("EpochTooYoung()")));
        vault.settle();
        _skip(1 hours);
        vault.checkRisk();
        vm.prank(manager);
        vault.settle();
    }

    /// @dev Alice holds the whole vault. The manager opens one ETH long with all idle at `levBps / 10` (Gains 1e3) so
    ///      vault leverage = levBps. Bob deposits while it is open, the trade closes at the SAME Chainlink price it
    ///      opened at (no PnL, no fees in the mock), bob redeems. Returns what each of them ends with.
    function _cycle(GainsVault v, uint256 amount, uint256 levBps) internal returns (uint256 bobOut, uint256 aliceOut) {
        _depositTo(v, alice, amount);
        _settleV(v);
        v.claim(alice);
        uint32 idx = _open(v, ETH, true, uint120(amount), uint24(levBps / 10));
        console2.log("NAV with the trade open (mid unchanged)", v.totalAssets() / 1e6);

        _depositTo(v, bob, amount);
        _settleV(v); // bob's shares are minted at the favourable edge
        v.claim(bob);

        uint256 paid = _closeFilled(v, idx, _px(ETH)); // Gains pays the full collateral at the unchanged price
        assertEq(paid, amount, "the close realizes the full value");

        _redeemFrom(v, bob, v.balanceOf(bob));
        _redeemFrom(v, alice, v.balanceOf(alice));
        _settleV(v);
        uint256 b0 = usdc.balanceOf(bob);
        uint256 a0 = usdc.balanceOf(alice);
        v.claim(bob);
        v.claim(alice);
        bobOut = usdc.balanceOf(bob) - b0;
        aliceOut = usdc.balanceOf(alice) - a0;
    }
}
