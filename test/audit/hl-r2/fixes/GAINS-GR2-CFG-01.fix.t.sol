// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {GovBase} from "../../gains/gov/GovBase.t.sol";
import {GainsVaultFactory} from "../../../../src/gains/GainsVaultFactory.sol";
import {GainsVault} from "../../../../src/gains/GainsVault.sol";
import {GainsVaultPolicy} from "../../../../src/gains/GainsVaultPolicy.sol";
import {IGainsVaultErrors as E} from "../../../../src/gains/GainsTypes.sol";

/// @notice hl-r2 fix proof for Gains GR2-CFG-01 and GR2-CFG-02 ("exit before effect", the HLR2-H01 pattern).
///         Only compiles and passes with fixes/patches/GAINS-GR2-CFG-01.patch applied (fixes/verify.sh). Copied by
///         verify.sh to test/audit/hl-r2/fixes/. Same scenario as test/audit/gains/r2/ConfigTimelock.t.sol
///         (branch audit/gains-r2): owner = manager = fee recipient, operator removed, the owner never settles.
contract GainsCfgFix is GovBase {
    address internal mallory = makeAddr("mallory");
    uint256 internal constant ALICE_IN = 10_000e6;

    function _launch(uint256 tl, uint64 ep, bytes32 salt) internal returns (GainsVault v, GainsVaultPolicy p) {
        GainsVaultFactory.CreateParams memory c = _cparams(launcher, salt, address(0));
        c.owner = mallory;
        c.manager = mallory;
        c.feeRecipient = mallory;
        c.managementFeeBps = 200;
        c.performanceFeeBps = 2_000;
        c.timelockDelay = tl;
        c.risk.maxEpochDuration = ep;
        vm.prank(launcher);
        (address va, address pa) = platform.create(c, _noPermit());
        v = GainsVault(va);
        p = GainsVaultPolicy(pa);
        vm.prank(alice);
        usdc.approve(va, type(uint256).max);
        vm.prank(alice);
        v.requestDeposit(ALICE_IN, alice);
        _ageEpoch(v);
        v.checkRisk();
        vm.prank(keeper);
        v.settle();
        v.claim(alice);
    }

    function _loose(GainsVaultPolicy p, uint64 ep) internal view returns (GainsVaultPolicy.RiskConfig memory c) {
        c = p.config();
        c.maxLeverageBps = 120_000;
        c.maxDailyLossBps = 10_000;
        c.maxDrawdownBps = 10_000;
        c.maxEpochDuration = ep;
    }

    function _queueAndRedeem(GainsVault v, GainsVaultPolicy p, GainsVaultPolicy.RiskConfig memory c) internal returns (uint256 t0) {
        v.checkRisk();
        vm.prank(mallory);
        v.settle();
        t0 = vm.getBlockTimestamp();
        vm.prank(mallory);
        v.setOperator(address(0));
        vm.prank(mallory);
        p.proposeConfig(c);
        uint256 shares = v.balanceOf(alice);
        vm.prank(alice);
        v.requestRedeem(shares, alice, alice);
    }

    function _guardianPaysAlice(GainsVault v) internal returns (uint256 paid) {
        vm.prank(platformGuardian);
        v.settle();
        uint256 before = usdc.balanceOf(alice);
        v.claim(alice);
        paid = usdc.balanceOf(alice) - before;
    }

    // ==================================================================
    // GR2-CFG-01, patched: timelock 1 day, epoch 30 days. The loosening and the fee raise wait 31 days; alice reaches
    // the overdue epoch (no new risk, her own emergency) first and is paid at the old risk.
    // ==================================================================
    function test_FIX_GR2_CFG_01_redeemerPaidAtTheOldRiskBeforeTheLooseningApplies() public {
        (GainsVault v, GainsVaultPolicy p) = _launch(1 days, 30 days, bytes32(uint256(201)));
        uint256 t0 = _queueAndRedeem(v, p, _loose(p, 30 days));
        uint256 eta = p.pendingConfig().eta;
        assertEq(eta, t0 + 31 days, "eta = queue + epoch + EXIT_MARGIN, not queue + 1 day");
        assertEq(uint256(v.epochDeadline()), t0 + 30 days);
        bytes memory fees = abi.encodeCall(GainsVault.setFees, (uint16(500), uint16(3_000)));
        vm.prank(mallory);
        v.queue(fees);
        assertEq(v.queuedEta(keccak256(fees)), t0 + 31 days, "the vault queue waits as long");

        // At the old eta (t0 + 1 day) nothing applies and the 12x trade is still refused.
        _warp(t0 + 1 days);
        vm.expectRevert(GainsVaultPolicy.NotReady.selector);
        p.applyPendingConfig();
        vm.expectRevert(E.NotReady.selector);
        v.execute(fees);
        vm.prank(mallory);
        vm.expectRevert(abi.encodeWithSelector(E.OrderRejected.selector, "leverage"));
        v.openTrade(_params(ETH, true, uint120(10_000e6), 12_000));

        // The deadline: no new risk, alice forces the exit, the guardian pays her before the eta.
        _warp(t0 + 30 days);
        vm.prank(mallory);
        vm.expectRevert(E.EpochOverdue.selector);
        v.openTrade(_params(ETH, true, uint120(1_000e6), 3_000));
        vm.prank(alice);
        v.triggerEmergency();
        uint256 paid = _guardianPaysAlice(v);
        assertLt(vm.getBlockTimestamp(), eta);
        emit log_named_decimal_uint("FIX-CFG-01 alice paid (asked 10,000 at t0)", paid, 6);
        assertApproxEqAbs(paid, ALICE_IN, 20e6, "full value less 30 days of the 2% fee she accepted");
        assertEq(v.managementFeeBps(), 200, "the 5% raise never applied while she was in");
    }

    // ==================================================================
    // GR2-CFG-02, patched: timelock 2 days, epoch 1 day, the loosening raises the epoch to 30 days and nobody acts in
    // the window. The apply no longer lifts the overdue epoch.
    // ==================================================================
    function test_FIX_GR2_CFG_02_epochRaiseDoesNotLiftAnOverdueEpoch() public {
        (GainsVault v, GainsVaultPolicy p) = _launch(2 days, 1 days, bytes32(uint256(202)));
        uint256 t0 = _queueAndRedeem(v, p, _loose(p, 30 days));
        assertEq(uint256(p.pendingConfig().eta), t0 + 2 days, "timelock >= epoch + margin: unchanged eta");
        _warp(t0 + 2 days);
        p.applyPendingConfig();
        assertEq(p.maxEpochDuration(), 30 days);
        assertEq(uint256(v.epochDeadline()), t0 + 1 days, "the running deadline did not move");
        vm.prank(mallory);
        vm.expectRevert(E.EpochOverdue.selector);
        v.openTrade(_params(ETH, true, uint120(10_000e6), 12_000));
        vm.prank(stranger);
        v.triggerEmergency();
        uint256 paid = _guardianPaysAlice(v);
        assertApproxEqAbs(paid, ALICE_IN, 3e6, "paid in full");
    }

    // Controls ----------------------------------------------------------

    /// The live vault's shape (2 d / 1 d): an emergency inside the window survives the apply.
    function test_FIX_GR2_CFG_control_emergencyInsideTheWindowSurvivesTheApply() public {
        (GainsVault v, GainsVaultPolicy p) = _launch(2 days, 1 days, bytes32(uint256(203)));
        uint256 t0 = _queueAndRedeem(v, p, _loose(p, 30 days));
        _warp(t0 + 1 days);
        vm.prank(alice);
        v.triggerEmergency();
        _warp(t0 + 2 days);
        p.applyPendingConfig();
        vm.prank(mallory);
        vm.expectRevert(E.ReduceOnlyMode.selector);
        v.openTrade(_params(ETH, true, uint120(1_000e6), 3_000));
        assertApproxEqAbs(_guardianPaysAlice(v), ALICE_IN, 3e6);
    }

    /// An honest loosening on a 1 d / 30 d vault applies after the 31-day notice, and new risk is then accepted.
    function test_FIX_GR2_CFG_control_honestLooseningAppliesAfterTheNotice() public {
        (GainsVault v, GainsVaultPolicy p) = _launch(1 days, 30 days, bytes32(uint256(204)));
        GainsVaultPolicy.RiskConfig memory c = p.config();
        c.maxLeverageBps = 60_000;
        uint256 t0 = vm.getBlockTimestamp();
        vm.prank(mallory);
        p.proposeConfig(c);
        assertEq(uint256(p.pendingConfig().eta), t0 + 31 days);
        // the manager settles on time, so the epoch is never overdue and trading goes on
        _warp(t0 + 29 days);
        v.checkRisk();
        vm.prank(mallory);
        v.settle();
        _warp(t0 + 31 days);
        p.applyPendingConfig();
        assertEq(p.maxLeverageBps(), 60_000);
        assertFalse(v.emergency());
    }

    /// An instant epoch tightening applies from the next epoch (the HL XB01 class on Gains): the running epoch is
    /// not made overdue, and a loosening queued right after it waits past the running deadline (ceiling).
    function test_FIX_GR2_CFG_tighteningAppliesFromTheNextEpoch() public {
        (GainsVault v, GainsVaultPolicy p) = _launch(1 days, 30 days, bytes32(uint256(205)));
        uint256 deadline = v.epochDeadline();
        GainsVaultPolicy.RiskConfig memory c = p.config();
        c.maxEpochDuration = 1 hours;
        uint256 t0 = vm.getBlockTimestamp();
        vm.prank(mallory);
        p.proposeConfig(c);
        assertEq(p.maxEpochDuration(), 1 hours, "instant");
        assertEq(v.epochDeadline(), deadline, "running deadline unchanged");
        vm.prank(stranger);
        vm.expectRevert(E.NotOverdue.selector);
        v.triggerEmergency();
        GainsVaultPolicy.RiskConfig memory l = _loose(p, 1 hours);
        vm.prank(mallory);
        p.proposeConfig(l);
        assertEq(uint256(p.pendingConfig().eta), t0 + 30 days + 1 days, "ceiling (t0 + 30 d) + margin");
        assertGe(uint256(p.pendingConfig().eta), deadline + 1 days);
    }
}
