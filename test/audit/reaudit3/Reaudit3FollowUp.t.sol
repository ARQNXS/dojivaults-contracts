// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Base} from "../../Base.t.sol";
import {HyperVault} from "../../../src/HyperVault.sol";
import {BreachReason, IHyperVaultErrors as E} from "../../../src/VaultTypes.sol";

/// @notice Follow-up to REAUDIT3 (sections 9-11): fix side effects, question (a) redemption-only settle at a
///         stale / inflated NAV, question (b) fees in a breach settle. PASS = the behaviour described in the report.
contract Reaudit3FollowUp is Base {
    address internal carol = makeAddr("carol");

    function setUp() public override {
        super.setUp();
        usdc.mint(carol, 1_000_000e6);
        vm.prank(carol);
        usdc.approve(address(vault), type(uint256).max);
    }

    // ------------------------------------------------------------------
    // helpers (as in Reaudit3PoC)
    // ------------------------------------------------------------------
    function _fund(uint256 amount) internal {
        _deposit(alice, amount);
        _settle();
        _claim(alice);
        vm.prank(manager);
        vault.bridgeToCore(amount);
        _setCore(address(vault), int64(uint64(amount)), 0, 0);
        vault.syncBridge();
        _skipBridgeWindow();
        vault.checkRisk();
    }

    function _hourlyChecks(uint256 n) internal {
        for (uint256 i; i < n; ++i) {
            vm.warp(vm.getBlockTimestamp() + 1 hours);
            vault.checkRisk();
        }
    }

    function _idle(uint256 amount) internal {
        vm.warp((vm.getBlockTimestamp() / 1 days + 1) * 1 days + 60);
        vault.checkRisk();
        _deposit(bob, amount);
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        vault.checkRisk();
        vm.prank(manager);
        vault.settle();
        _claim(bob);
    }

    /// @dev alice 100k on Core, bob 50k idle (1/3 of the shares); then Core drops to 70k: NAV 120k, drawdown 20%,
    ///      checkpoint ratcheted to 120k by the hourly checks; bob queues his full redemption.
    function _breachWithRedeemer() internal {
        _fund(100_000e6);
        _idle(50_000e6);
        vm.warp((vm.getBlockTimestamp() / 1 days + 1) * 1 days + 60);
        _setCore(address(vault), 70_000e6, 0, 0);
        _hourlyChecks(3);
        assertEq(uint8(vault.breachReason()), uint8(BreachReason.DRAWDOWN));
        assertApproxEqRel(uint256(vault.checkpointNav()), 120_000e6, 1e15);
        _redeem(bob, vault.balanceOf(bob));
    }

    function _feeValue() internal view returns (uint256) {
        return vault.convertToAssets(vault.balanceOf(feeRecipient));
    }

    // ==================================================================
    // Question (a): redemption-only settle prices at the live NAV within the checkpoint bound
    // ==================================================================
    /// @dev Per settle: a reading 19% above the checkpoint (a mark spike) is paid out in full; when it reverts the
    ///      holders who stay carry the difference. min(NAV, checkpoint) would have paid bob 40k.
    function test_REAUDIT3_QA_inflatedReadingWithinTheBoundIsPaidOut() public {
        // HARDENED (decision 1 after STOP 3, inverted): a redemption-only settle pays at min(live NAV, checkpoint),
        // so the momentary +19% reading is never paid out; bob is paid at the 120k checkpoint.
        _breachWithRedeemer();
        _setCore(address(vault), 92_800e6, 0, 0); // NAV 142.8k: +19% over the 120k checkpoint, momentary
        uint256 b0 = usdc.balanceOf(bob);
        vm.prank(guardian);
        vault.settle(); // redemption-only, priced at the 120k checkpoint
        _claim(bob);
        uint256 paid = usdc.balanceOf(bob) - b0;
        assertApproxEqRel(paid, 40_000e6, 2e3 * 1e12, "bob paid a third of the 120k checkpoint");

        _setCore(address(vault), 70_000e6, 0, 0); // the spike reverts
        uint256 aliceValue = vault.convertToAssets(vault.balanceOf(alice));
        assertApproxEqRel(aliceValue, 80_000e6, 2e3 * 1e12, "alice keeps her fair 80k");
    }

    /// @dev The bound per settle: a reading more than maxNavMoveBps (20%) away from the checkpoint reverts.
    function test_REAUDIT3_QA_readingBeyondTheBoundReverts() public {
        _breachWithRedeemer();
        _setCore(address(vault), 95_200e6, 0, 0); // NAV 145.2k = +21%
        vm.prank(guardian);
        vm.expectRevert(); // VaultPolicy.NavMoved
        vault.settle();
    }

    /// @dev Over time the bound is a rate limit: hourly checkRisk ratchets the checkpoint 20% per step, so a reading
    ///      that STAYS 24% high is paid out after two hours. A crash is never paid at the old, higher checkpoint:
    ///      the settle reverts until the ratchet reaches the live NAV, then pays the live NAV.
    function test_REAUDIT3_QA_boundIsARateLimit_sustainedReadingAndCrash() public {
        _breachWithRedeemer();
        uint256 snap = vm.snapshotState();

        _setCore(address(vault), 98_800e6, 0, 0); // NAV 148.8k, +24%, sustained
        vm.prank(guardian);
        vm.expectRevert();
        vault.settle();
        _hourlyChecks(2); // 120k -> 144k -> 148.8k
        uint256 b0 = usdc.balanceOf(bob);
        vm.prank(guardian);
        vault.settle();
        _claim(bob);
        assertApproxEqRel(usdc.balanceOf(bob) - b0, 49_600e6, 2e15, "paid a third of the sustained 148.8k");

        vm.revertToState(snap);
        _setCore(address(vault), 10_000e6, 0, 0); // NAV 60k, -50%
        vm.prank(guardian);
        vm.expectRevert();
        vault.settle(); // never at the stale 120k
        _hourlyChecks(4); // 120k -> 96k -> 76.8k -> 61.4k -> 60k
        b0 = usdc.balanceOf(bob);
        vm.prank(guardian);
        vault.settle();
        _claim(bob);
        assertApproxEqRel(usdc.balanceOf(bob) - b0, 20_000e6, 2e15, "paid a third of the live 60k");
    }

    // ==================================================================
    // Question (b): fees in a breach settle
    // ==================================================================
    /// @dev Leverage breach, +10% above the HWM: the settle mints the management fee only, the HWM stays, and the
    ///      daily loss / drawdown read the same before and after (references rescaled).
    function test_REAUDIT3_QB_leverageBreachSettle_managementOnly_hwmKept_metricsUnmoved() public {
        _fund(100_000e6);
        vm.warp(vm.getBlockTimestamp() + 2 hours);
        _setCore(address(vault), 104_000e6, 0, 0);
        vault.checkRisk(); // peak / day start at 104k
        _setCore(address(vault), 103_000e6, 315_000e6, 0); // 3.06x and -~1% today
        vault.checkRisk();
        assertEq(uint8(vault.breachReason()), uint8(BreachReason.LEVERAGE));
        vm.warp(vm.getBlockTimestamp() + 10 hours);
        (, uint256 d0, uint256 dd0) = vault.checkRisk();

        uint256 hwm = vault.highWaterMark();
        uint256 last = vault.lastFeeAccrual();
        uint256 nav = vault.totalAssets();
        vm.prank(manager);
        vault.settle();
        uint256 expected = (nav * 200 * (vm.getBlockTimestamp() - last)) / (10_000 * 365 days);
        assertApproxEqRel(_feeValue(), expected, 1e15, "management fee only (performance would be ~600 USDC)");
        assertEq(vault.highWaterMark(), hwm, "HWM unchanged in a breach settle");
        (, uint256 d1, uint256 dd1) = vault.checkRisk();
        assertApproxEqAbs(d1, d0, 1, "daily loss unmoved by the fee mint");
        assertApproxEqAbs(dd1, dd0, 1, "drawdown unmoved by the fee mint");
    }

    /// @dev Consecutive redemption-only settles: each charges the management fee for its own interval only.
    function test_REAUDIT3_QB_consecutiveRedemptionOnlySettles_noDoubleAccrual() public {
        _breachWithRedeemer();
        vm.prank(bob);
        vault.cancelRedeemRequest(); // keep the NAV constant across the settles
        uint256 t0 = vault.lastFeeAccrual();
        uint256 nav = vault.totalAssets();
        uint256 f0 = _feeValue();
        vm.prank(guardian);
        vault.settle();
        uint256 f1 = _feeValue() - f0;
        uint256 t1 = vm.getBlockTimestamp();
        assertApproxEqRel(f1, (nav * 200 * (t1 - t0)) / (10_000 * 365 days), 1e15);

        _hourlyChecks(1);
        vm.prank(manager);
        vault.settle();
        uint256 f2 = _feeValue() - f1 - f0;
        assertApproxEqRel(f2, (nav * 200 * 1 hours) / (10_000 * 365 days), 1e15, "second settle: one hour only");
        assertEq(vault.lastFeeAccrual(), vm.getBlockTimestamp());
    }

    /// @dev Emergency settle above the HWM: no performance fee, HWM kept.
    function test_REAUDIT3_QB_emergencySettle_noPerformanceFee() public {
        _fund(100_000e6);
        vm.warp(vm.getBlockTimestamp() + 2 hours);
        _setCore(address(vault), 110_000e6, 0, 0);
        _hourlyChecks(1);
        uint256 hwm = vault.highWaterMark();
        vm.prank(guardian);
        vault.triggerEmergency();
        vm.prank(guardian);
        vault.settle();
        assertEq(vault.highWaterMark(), hwm);
        assertLt(_feeValue(), 10e6, "management dust only, no ~2k performance fee");
    }

    /// @dev NEW (R3-06): a scheduled performance fee raise is switched on by a breach settle that charged no
    ///      performance fee, so the gains earned at the old rate are later charged at the new one (N2-02 again).
    function test_REAUDIT3_R306_breachSettleSwitchesAPendingRaiseWithoutChargingTheOldRate() public {
        _fund(100_000e6);
        vm.warp(vm.getBlockTimestamp() + 2 hours);
        _setCore(address(vault), 110_000e6, 0, 0); // +10k above the HWM, earned at 20%
        _hourlyChecks(1);
        _timelocked(vault, abi.encodeCall(HyperVault.setFees, (200, 3_000)));
        assertEq(vault.pendingPerformanceFeeBps(), 3_000);

        _setCore(address(vault), 110_000e6, 340_000e6, 0); // leverage breach
        _hourlyChecks(1);
        assertEq(uint8(vault.breachReason()), uint8(BreachReason.LEVERAGE));
        vm.prank(manager);
        vault.settle(); // FIXED (inverted): no performance fee charged, and the raise is NOT switched on
        assertEq(vault.performanceFeeBps(), 2_000);
        assertEq(vault.pendingPerformanceFeeBps(), 3_000, "the raise waits for a settle that charges the old rate");

        _setCore(address(vault), 110_000e6, 0, 0);
        vm.warp(vm.getBlockTimestamp() + 15 minutes);
        vault.clearLeverageBreach();
        _hourlyChecks(1);
        uint256 f0 = _feeValue();
        vm.prank(manager);
        vault.settle();
        uint256 perf = _feeValue() - f0;
        assertLt(perf, 2_200e6, "FIXED (inverted): the 10k gain earned under 20% is charged at 20% (~2k)");
        assertGt(perf, 1_800e6);
        assertEq(vault.performanceFeeBps(), 3_000, "the raise applies from here on");
    }

    // ==================================================================
    // Side effect of the R3-02 fix: anyone can set insiderInQueue
    // ==================================================================
    /// @dev A 1 wei deposit for controller = manager (sent by anyone) is an insider deposit: the next normal settle
    ///      must wait INSIDER_MIN_EPOCH_AGE. The manager cancelling the dust does not lift it. Bound: 1 hour per epoch.
    ///      Decision 2 after STOP 3: deposits start at MIN_DEPOSIT (10 USDC), so the 1 wei version reverts and arming
    ///      the delay costs the stranger 10 USDC, credited to the manager. The bound itself is unchanged (accepted).
    function test_REAUDIT3_INFO_strangerArmsInsiderDelay() public {
        _fund(100_000e6);
        vm.warp(vm.getBlockTimestamp() + 2 hours);
        vault.checkRisk();
        vm.prank(carol);
        vm.expectRevert(E.DepositTooSmall.selector);
        vault.requestDeposit(1, manager);
        vm.prank(carol);
        vault.requestDeposit(10e6, manager); // carol's 10 USDC, credited to the manager's request
        assertEq(vault.deferredDepositAssets(), 10e6);
        vm.prank(manager);
        vault.settle();
        vm.prank(manager);
        vault.cancelDepositRequest();
        vm.warp(vm.getBlockTimestamp() + 30 minutes);
        vault.checkRisk();
        vm.prank(manager);
        vm.expectRevert(E.EpochTooYoung.selector);
        vault.settle();
        vm.warp(vm.getBlockTimestamp() + 30 minutes);
        vm.prank(manager);
        vault.settle();
    }
}
