// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {MutBase} from "./MutBase.t.sol";
import {HyperVault} from "../../../../src/HyperVault.sol";
import {InitParams} from "../../../../src/VaultTypes.sol";
import {BreachReason, IHyperVaultErrors as E} from "../../../../src/VaultTypes.sol";

/// @title hl-r2 mutation kill tests: clearing breaches (clearLeverageBreach, resume) and checkRisk's latch
contract HLR2MutGovRiskTest is MutBase {
    function _leverageBreach() internal {
        _fund(10_000e6);
        _setCore(address(vault), 10_000e6, 31_000e6, 0); // 3.1x > 3x
        vault.checkRisk();
        assertEq(uint8(vault.breachReason()), uint8(BreachReason.LEVERAGE));
        vm.warp(vm.getBlockTimestamp() + vault.LEVERAGE_CLEAR_COOLDOWN());
    }

    function _drawdownBreach() internal {
        _fund(10_000e6);
        vm.warp((vm.getBlockTimestamp() / 1 days + 1) * 1 days + 60);
        _setCore(address(vault), 8_200e6, 0, 0);
        for (uint256 i; i < 3; ++i) {
            vm.warp(vm.getBlockTimestamp() + 1 hours);
            vault.checkRisk();
        }
        assertEq(uint8(vault.breachReason()), uint8(BreachReason.DRAWDOWN));
        vm.warp(vault.breachedAt() + vault.RESUME_COOLDOWN());
    }

    /// Mutants: clearLeverageBreach / resume `if (bridgePending()) revert BridgeInFlight()` deleted. A breach is
    /// never cleared on in-flight readings.
    function test_HLR2_M60_kills_clearInsideABridgeWindow() public {
        _leverageBreach();
        _setCore(address(vault), 10_000e6, 25_000e6, 0); // back under
        _setWithdrawable(address(vault), 1_000e6);
        vm.prank(manager);
        vault.bridgeToEvm(1_000e6);
        vm.expectRevert(E.BridgeInFlight.selector);
        vault.clearLeverageBreach();
        vm.roll(vm.getBlockNumber() + 11);
        usdc.mint(address(vault), 1_000e6);
        _setCore(address(vault), 9_000e6, 25_000e6, 0);
        vault.clearLeverageBreach();
        assertFalse(vault.breached());
    }

    function test_HLR2_M60b_kills_resumeInsideABridgeWindow() public {
        _drawdownBreach();
        _setWithdrawable(address(vault), 1_000e6);
        vm.prank(manager);
        vault.bridgeToEvm(1_000e6);
        vm.prank(owner);
        vm.expectRevert(E.BridgeInFlight.selector);
        vault.resume();
    }

    /// Mutants: clearLeverageBreach / resume `lev > maxLev` -> `>=`: leverage exactly at the limit is within it.
    function test_HLR2_M61_kills_leverageAtTheLimitClears() public {
        _leverageBreach();
        _setCore(address(vault), 10_000e6, 30_000e6, 0); // exactly 3x
        vault.clearLeverageBreach();
        assertFalse(vault.breached());
    }

    function test_HLR2_M61b_kills_leverageAtTheLimitResumes() public {
        _drawdownBreach();
        _setCore(address(vault), 8_200e6, 24_600e6, 0); // exactly 3x
        vm.prank(owner);
        vault.resume();
        assertFalse(vault.breached());
    }

    /// Mutant: VaultGovernance._check's leading `VaultLogic.syncBridge($)` deleted. The keeper's hourly checkRisk is
    /// the usual first call after a landing and must latch it (R-02), or the window reopens when the landed USDC
    /// moves on.
    function test_HLR2_M62_kills_checkRiskDoesNotLatch() public {
        _fund(10_000e6);
        _deposit(bob, 5_000e6);
        vm.warp(vm.getBlockTimestamp() + 2 hours);
        _settle();
        _claim(bob);
        vm.prank(manager);
        vault.bridgeToCore(5_000e6);
        _setCore(address(vault), 10_000e6, 0, 5_000e6); // landed on spot
        vm.roll(vm.getBlockNumber() + 11);
        vault.checkRisk(); // first call after the landing
        _setCore(address(vault), 13_000e6, 0, 0); // moved to perp off-chain, then -2,000
        assertFalse(vault.bridgePending(), "latched by checkRisk");
        assertEq(vault.totalAssets(), 13_000e6);
    }

    /// Mutant: `_check` `m.accountValue > 0 ? ntlPos * BPS / accountValue : max` -> `>= 0`: with positions open and a
    /// zero account value the leverage reads as unbounded (a breach), the risk check must not divide by zero and
    /// revert (that would also block the first settle, which runs checkRisk).
    function test_HLR2_M63_kills_zeroEquityWithPositions() public {
        _fund(10_000e6);
        _setCore(address(vault), 0, 5_000e6, 0);
        (uint256 lev,,) = vault.checkRisk();
        assertEq(lev, type(uint256).max);
        assertTrue(vault.breached());
    }

    /// Mutant: `equity >= MIN_RISK_NAV` with MIN_RISK_NAV doubled: the loss metrics are measured from 1 USDC of NAV
    /// on. A vault that fell from 10 to 1.5 USDC is in a drawdown breach.
    function test_HLR2_M64_kills_minRiskNav() public {
        _deposit(alice, 10e6);
        _settle();
        _claim(alice);
        vault.checkRisk();
        usdc.burnFrom(address(vault), 8_500_000); // 10 -> 1.5 USDC
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        (, uint256 daily, uint256 dd) = vault.checkRisk();
        assertGt(dd, 8_000);
        assertGt(daily, 8_000);
        assertTrue(vault.breached());
    }

    // ------------------------------------------------------------------
    // Limits exactly at their value. Supply 1e16 - 1e6 share units makes the share price floor((NAV + 1) / 1e4)
    // exactly, so a NAV can be chosen for any price (no fees).
    // ------------------------------------------------------------------
    function _exactVault() internal {
        vm.prank(owner);
        vault.lowerFees(0, 0);
        vm.warp((vm.getBlockTimestamp() / 1 days + 1) * 1 days + 60); // start of a UTC day
        usdc.mint(alice, 9_999_999_999);
        _deposit(alice, 9_999_999_999);
        _settle();
        _claim(alice);
        assertEq(vault.totalSupply(), 1e16 - 1e6);
        assertEq(vault.sharePrice(), 1e6);
    }

    /// @dev Sets the NAV (idle USDC only, Core equity `core`) to `nav`.
    function _nav(uint256 nav, int64 core, uint64 ntl) internal {
        uint256 idle = vault.totalAssets() - vault.coreEquity();
        uint256 want = nav - uint256(uint64(core));
        if (idle > want) usdc.burnFrom(address(vault), idle - want);
        else usdc.mint(address(vault), want - idle);
        _setCore(address(vault), core, ntl, 0);
        assertEq(vault.totalAssets(), nav);
    }

    /// Mutants: clearLeverageBreach `daily > maxDaily` -> `>=` and `dd > maxDd` -> `>=`; _check's breach rule
    /// `drawdownBps > maxDd` -> `>=`. A daily loss or drawdown exactly at its limit is within it.
    function test_HLR2_M77_kills_lossLimitsAtTheirValue() public {
        _exactVault();
        // a leverage breach (4x on 1 USDC of Core equity)
        _nav(9_999_999_999, 1e6, 4e6);
        vault.checkRisk();
        assertEq(uint8(vault.breachReason()), uint8(BreachReason.LEVERAGE));
        // -5.00% on the day exactly: price 950,000
        _nav(9_499_999_999, 1e6, 3e6);
        vm.warp(vm.getBlockTimestamp() + 15 minutes);
        (, uint256 daily,) = vault.checkRisk();
        assertEq(daily, 500, "exactly the limit");
        vault.clearLeverageBreach();
        assertFalse(vault.breached(), "cleared at exactly the daily limit");

        // next day: -15.00% from the peak exactly (price 850,000), first check of the day
        vm.warp((vm.getBlockTimestamp() / 1 days + 1) * 1 days + 60);
        _nav(8_499_999_999, 1e6, 3e6);
        (,, uint256 dd) = vault.checkRisk();
        assertEq(dd, 1_500);
        assertFalse(vault.breached(), "a drawdown exactly at the limit is not a breach");
        // a leverage breach at that drawdown clears too
        _setCore(address(vault), 1e6, 4e6, 0);
        vault.checkRisk();
        vm.warp(vm.getBlockTimestamp() + 15 minutes);
        _setCore(address(vault), 1e6, 3e6, 0);
        vault.clearLeverageBreach();
        assertFalse(vault.breached());
    }

    /// Mutant: resume `daily > maxDaily` -> `>=`: the owner may resume with the day's loss exactly at the limit.
    function test_HLR2_M78_kills_resumeAtTheDailyLimit() public {
        _exactVault();
        vm.warp((vm.getBlockTimestamp() / 1 days + 1) * 1 days + 60);
        _nav(8_399_999_999, 0, 0); // -16% from the peak: drawdown breach
        vault.checkRisk();
        assertEq(uint8(vault.breachReason()), uint8(BreachReason.DRAWDOWN));
        vm.warp(vm.getBlockTimestamp() + 24 hours);
        vault.checkRisk(); // first check of the new day: day start 840,000
        _nav(7_979_999_999, 0, 0); // price 798,000: -5.00% on the day exactly
        vm.prank(owner);
        vault.resume();
        assertFalse(vault.breached());
    }

    /// Mutant: `equity >= MIN_RISK_NAV` -> `>`: at exactly 1 USDC of NAV the loss metrics are measured.
    function test_HLR2_M79_kills_minRiskNavEdge() public {
        _deposit(alice, 10e6);
        _settle();
        _claim(alice);
        vault.checkRisk();
        usdc.burnFrom(address(vault), 9e6); // NAV exactly 1 USDC
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        (,, uint256 dd) = vault.checkRisk();
        assertGt(dd, 8_000);
        assertTrue(vault.breached());
    }

    /// Mutant: VaultMath.sharePrice rounding Floor -> Ceil: the share price (risk references, HWM) rounds down.
    function test_HLR2_M80_kills_sharePriceRoundsDown() public {
        _exactVault();
        _nav(1_234_567_890, 0, 0);
        assertEq(vault.sharePrice(), 123_456, "floor((NAV + 1) / 1e4)");
    }

    /// Mutants at the 1 wei / 1 share unit boundary that a test can pin: a 1 wei payout is delivered; one queued
    /// share unit lets a stranger trigger an overdue emergency and keeps the guardian from ending one; a missing Core
    /// account reads 0 and a 1 wei Core equity reads 1 wei.
    function test_HLR2_M81_kills_oneUnitBoundaries() public {
        _exactVault(); // 1e6 share units = 1 wei
        _redeem(alice, 1e6);
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        _settle();
        uint256 b = usdc.balanceOf(alice);
        _claim(alice);
        assertEq(usdc.balanceOf(alice) - b, 1, "a 1 wei payout is paid");
        // one share unit queued, epoch overdue: anyone may stop the vault
        _redeem(alice, 1);
        vm.warp(vm.getBlockTimestamp() + 7 days);
        vm.prank(stranger);
        vault.triggerEmergency();
        vm.prank(guardian);
        vm.expectRevert(E.RedemptionsPending.selector);
        vault.exitEmergency();
        // Core reads
        _setCore(address(vault), 1, 0, 0);
        assertEq(vault.coreEquity(), 1);
        _setCoreUser(address(vault), false);
        assertEq(vault.coreEquity(), 0);
    }

    /// Mutants: checkOrder `accountValue > 0 ? ... : 0` -> `> 1` / `: 1`: an account value of 1 wei is 1 wei of
    /// equity, a negative one is none.
    function test_HLR2_M82_kills_checkOrderEquityEdge() public view {
        // notional = 1e8 * 1e2 / 1e10 = 1 (6 decimals); leverage cap 3x
        (bool ok,) = policy.checkOrder(BTC, true, 1e8, 1e2, false, 1e8, 1, 0);
        assertTrue(ok, "1 wei of equity carries 3 wei of notional");
        (ok,) = policy.checkOrder(BTC, true, 1e8, 1e2, false, 1e8, -5, 0);
        assertFalse(ok, "negative equity carries nothing");
    }

    /// Mutants: initialize `if (p.seedUsdc > 0)` / `if (value > 0)` -> `> 1`: a 1 wei seed and 1 wei of HYPE are
    /// forwarded too.
    function test_HLR2_M83_kills_initSeedAndGasOfOneWei() public {
        InitParams memory p = _standaloneParams(policy);
        p.seedUsdc = 1;
        HyperVault v = HyperVault(Clones.clone(address(vaultImpl)));
        usdc.mint(address(v), 1);
        uint256 before = depositWallet.totalDeposited();
        uint256 hype = hypeSink.received();
        vm.deal(address(this), 1);
        v.initialize{value: 1}(p);
        assertEq(depositWallet.totalDeposited() - before, 1, "seed bridged");
        assertEq(hypeSink.received() - hype, 1, "gas forwarded");
    }
}
