// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {console2} from "forge-std/Test.sol";
import {R1Base} from "../R1Base.t.sol";
import {GainsVault} from "../../../../src/gains/GainsVault.sol";
import {GainsVaultPolicy} from "../../../../src/gains/GainsVaultPolicy.sol";
import {IGainsVaultErrors, OpenParams} from "../../../../src/gains/GainsTypes.sol";

/// @notice Cross-review (brief sections 3 / 6): boundary and refutation tests for the round 1 findings. Fix round:
///         the NAVBIAS and DUSTCHECKPOINT tests now assert the fixed behaviour (GR1-02, GR1-23; FIXES-R1.md).
contract XReviewTest is R1Base {
    // ------------------------------------------------------------------
    // GR1-02 (was NAVBIAS intraday): the 100k holder of the cross-review scenario
    // ------------------------------------------------------------------
    /// @dev Live shape (3x, daily loss 5%, drawdown 15%). The manager cycles open -> settle (bob in) -> close ->
    ///      settle (bob out) as fast as the vault lets him (old code: every 5 minutes, alice 100k -> 94,696 before the
    ///      daily-loss breach). Now a settle that mints waits an hour, and bob buys at the favourable edge: every
    ///      cycle costs bob and alice loses at most rounding.
    function test_GR1_02_intradayCyclesNoLongerTakeFromTheHolder() public {
        GainsVaultPolicy.RiskConfig memory r = _defaultRisk();
        (GainsVault v,) = _vaultWith(r);
        _depositTo(v, alice, 100_000e6);
        _settleV(v);
        v.claim(alice);
        _skip(1 days);
        v.checkRisk();
        uint256 aliceStart = v.totalAssets();
        uint256 bobStart = usdc.balanceOf(bob);
        uint256 cycles;
        for (; cycles < 10; ++cycles) {
            _skip(5 minutes);
            uint256 idle = v.idleAssets();
            // fix round WP2: the GR2-KEY-01b turnover budget (TURNOVER_NAV_MULTIPLE x NAV a day) ends the loop
            OpenParams memory op = _params(ETH, true, uint120(idle), uint24(29_000 * idle / v.totalAssets() / 10));
            vm.prank(manager);
            try v.openTrade(op) {}
            catch (bytes memory err) {
                assertEq(err, abi.encodeWithSelector(IGainsVaultErrors.OrderRejected.selector, "turnover"), "only turnover");
                break;
            }
            (uint32 idx,) = _fillLast(v, _px(ETH));
            _depositTo(v, bob, 500_000e6);
            v.checkRisk();
            if (v.breached()) break;
            vm.prank(manager);
            try v.settle() {}
            catch (bytes memory err) {
                assertEq(bytes4(err), bytes4(keccak256("EpochTooYoung()")), "a settle that mints waits an hour");
                _settleV(v); // the earliest the vault allows
            }
            v.claim(bob);
            _passHold(); // GR2-KEY-01b: the manager's exit waits out the minimum hold
            _closeFilled(v, idx, _px(ETH));
            _redeemFrom(v, bob, v.balanceOf(bob));
            v.checkRisk();
            vm.prank(manager);
            v.settle(); // redemption-only flows: no minimum age
            v.claim(bob);
            if (v.breached()) break;
        }
        uint256 bobEnd = usdc.balanceOf(bob);
        console2.log("cycles run", cycles);
        assertGe(cycles, 3, "the loop ran several cycles before any limit");
        console2.log("bob's change (USDC, negative = loss)", int256(bobEnd) - int256(bobStart));
        console2.log("alice's 100k now (USDC)", v.totalAssets() / 1e6);
        assertLt(bobEnd, bobStart, "repeating the loop is unprofitable");
        assertGe(v.totalAssets() + 10, aliceStart, "the holder loses at most rounding");
    }

    /// @dev A passive depositor in while open and out while open now pays the band on both edges (bid / ask) on
    ///      his share of the open notional, to the holders: 2 x 20 bps x 290k x (100k / 200k) = 580 USDC, 0.58% of his
    ///      100k here. Before the fix this was neutral (both sides at the adverse edge).
    function test_XR_NAVBIAS_passiveInAndOutWhileOpenPaysTheSpread() public {
        (GainsVault v,) = _vaultWith(_defaultRisk());
        _depositTo(v, alice, 100_000e6);
        _settleV(v);
        v.claim(alice);
        _open(v, ETH, true, 100_000e6, 2_900);
        _depositTo(v, bob, 100_000e6);
        _settleV(v);
        v.claim(bob);
        uint256 b0 = usdc.balanceOf(bob);
        _redeemFrom(v, bob, v.balanceOf(bob));
        _settleV(v);
        v.claim(bob);
        uint256 out = usdc.balanceOf(bob) - b0;
        console2.log("bob in 100k while open, out while open (wei)", out);
        assertApproxEqRel(out, 100_000e6 * (10_000 - 58) / 10_000, 0.0005e18, "2 x B x notional x his share");
    }

    // ------------------------------------------------------------------
    // GR1-23 (was DUSTCHECKPOINT): the donation no longer needs the overdue exit-only settle to clear
    // ------------------------------------------------------------------
    function test_GR1_23_dustCheckpointNormalSettleRuns() public {
        GainsVaultPolicy.RiskConfig memory r = _defaultRisk();
        r.maxEpochDuration = 1 days; // live policy
        (GainsVault v,) = _vaultWith(r);
        _depositTo(v, alice, 1_000e6);
        _settleV(v);
        v.claim(alice);
        _skip(1 hours);
        _redeemFrom(v, alice, v.balanceOf(alice));
        _settleV(v);
        v.claim(alice);
        assertLt(v.totalAssets(), 10_000);

        address griefer = makeAddr("griefer");
        usdc.mint(griefer, 1e6);
        vm.prank(griefer);
        usdc.transfer(address(v), 1e6);
        _depositTo(v, bob, 10_000e6);

        _settleV(v); // a normal settle an hour later: old code NavMoved until the epoch was overdue
        v.claim(bob);
        assertGt(v.balanceOf(bob), 0, "bob's deposit priced in the same epoch");
        assertEq(v.checkpointNav(), v.totalAssets(), "checkpoint includes the donation");
    }
}
