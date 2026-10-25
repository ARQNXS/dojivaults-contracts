// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {console2} from "forge-std/Test.sol";
import {R1Base} from "../gains/R1Base.t.sol";
import {GainsVault} from "../../../src/gains/GainsVault.sol";
import {GainsVaultPolicy} from "../../../src/gains/GainsVaultPolicy.sol";
import {IGainsVaultErrors, OpenParams} from "../../../src/gains/GainsTypes.sol";

/// @notice WP5 uncross: the stronger form of XReview's GR1-02 intraday cycles after the WP2 port (796a5f0). The port
///         stops the loop at the first OrderRejected("turnover") and checks the outcome over however many cycles ran
///         (at least 3). Here the manager cycles "as fast as the vault lets him" including the turnover budget: on a
///         turnover refusal he waits (one hour at a time, at most a day) and tries again, so all 10 cycles run as in the
///         original. Every cycle on its own costs bob, and alice loses at most rounding after every cycle.
contract WP5PortXReviewIntradayTest is R1Base {
    function _openWhenAllowed(GainsVault v, OpenParams memory op) internal returns (uint256 waited) {
        for (uint256 h; h <= 24; ++h) {
            vm.prank(manager);
            try v.openTrade(op) {
                return h;
            } catch (bytes memory err) {
                assertEq(err, abi.encodeWithSelector(IGainsVaultErrors.OrderRejected.selector, "turnover"), "only turnover");
                _skip(1 hours);
                v.checkRisk();
            }
        }
        revert("the turnover budget never refilled within a day");
    }

    function test_WP5_PORT_GR1_02_tenIntradayCyclesEachCostBobAndNeverAlice() public {
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
        uint256 turnoverWaits;
        for (; cycles < 10; ++cycles) {
            uint256 bobBefore = usdc.balanceOf(bob);
            _skip(5 minutes);
            uint256 idle = v.idleAssets();
            OpenParams memory op = _params(ETH, true, uint120(idle), uint24(29_000 * idle / v.totalAssets() / 10));
            turnoverWaits += _openWhenAllowed(v, op);
            (uint32 idx,) = _fillLast(v, _px(ETH));
            _depositTo(v, bob, 500_000e6);
            v.checkRisk();
            assertFalse(v.breached(), "no breach inside a cycle");
            vm.prank(manager);
            try v.settle() {}
            catch (bytes memory err) {
                assertEq(bytes4(err), bytes4(keccak256("EpochTooYoung()")), "a settle that mints waits an hour");
                _settleV(v);
            }
            v.claim(bob);
            _passHold();
            _closeFilled(v, idx, _px(ETH));
            _redeemFrom(v, bob, v.balanceOf(bob));
            v.checkRisk();
            vm.prank(manager);
            v.settle();
            v.claim(bob);
            assertFalse(v.breached(), "no breach after a cycle");
            assertLt(usdc.balanceOf(bob), bobBefore, "this cycle cost bob");
            assertGe(v.totalAssets() + 10, aliceStart, "after this cycle alice has lost at most rounding");
        }
        console2.log("cycles run", cycles);
        console2.log("hours waited for the turnover budget", turnoverWaits);
        console2.log("bob's change (USDC, negative = loss)", int256(usdc.balanceOf(bob)) - int256(bobStart));
        console2.log("alice's 100k now (USDC)", v.totalAssets() / 1e6);
        assertEq(cycles, 10, "all ten cycles ran");
        assertLt(usdc.balanceOf(bob), bobStart, "repeating the loop is unprofitable");
        assertGe(v.totalAssets() + 10, aliceStart, "the holder loses at most rounding");
    }
}
