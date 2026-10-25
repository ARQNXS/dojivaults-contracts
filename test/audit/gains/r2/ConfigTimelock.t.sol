// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {GovBase} from "../gov/GovBase.t.sol";
import {GainsVaultFactory} from "../../../../src/gains/GainsVaultFactory.sol";
import {GainsVault} from "../../../../src/gains/GainsVault.sol";
import {GainsVaultPolicy} from "../../../../src/gains/GainsVaultPolicy.sol";
import {IGainsVaultErrors as E} from "../../../../src/gains/GainsTypes.sol";

/// @notice Gains round 2, domain CFG (upgrades, timelock, configuration), question 2: does a depositor always get
///         time to exit before a queued loosening takes effect?
///
/// Worst case modelled (brief): the vault owner is also the manager (the live vault's shape), removes the operator
/// at once (setOperator(0)), settles normally right before queuing so the epoch restarts, queues a loosening and
/// never settles again. A redeemer who asks right after the queue can only be paid by an exit-only settle of a
/// platform role, which needs an overdue epoch (or an emergency, which a stranger may only trigger once the epoch is
/// overdue). The factory accepts any timelockDelay in [1 day, 30 days] and any maxEpochDuration in [1 h, 30 days]
/// independently, and the webapp launches with a fixed 2 day timelock and a free epoch length in days.
contract ConfigTimelockTest is GovBase {
    address internal mallory = makeAddr("mallory"); // owner == manager == fee recipient, as on the live vault

    uint256 internal constant ALICE_IN = 10_000e6;

    /// @dev A factory vault launched by the allowlisted launcher for `mallory` with timelock `tl` and epoch `ep`.
    ///      No agent (manual), operator = the platform keeper, BTC + ETH at 3x, fees 2% / 20%.
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
        // alice is in: 10,000 USDC, settled by the keeper (normal settle), claimed
        vm.prank(alice);
        v.requestDeposit(ALICE_IN, alice);
        _ageEpoch(v);
        v.checkRisk();
        vm.prank(keeper);
        v.settle();
        v.claim(alice);
    }

    /// @dev The loosening of the scenario: 3x -> 12x vault leverage (inside the 12.5x NAV bound of BTC / ETH at
    ///      maxNavMoveBps 20%), breakers off (100% daily loss and drawdown), optionally a longer epoch.
    function _loose(GainsVaultPolicy p, uint64 ep) internal view returns (GainsVaultPolicy.RiskConfig memory c) {
        c = p.config();
        c.maxLeverageBps = 120_000;
        c.maxDailyLossBps = 10_000;
        c.maxDrawdownBps = 10_000;
        c.maxEpochDuration = ep;
    }

    /// @dev mallory restarts the epoch with a normal settle, removes the operator and queues `c`; alice asks to redeem
    ///      all her shares in the same second. Returns t0 (queue time = epoch start).
    function _queueAndRedeem(GainsVault v, GainsVaultPolicy p, GainsVaultPolicy.RiskConfig memory c) internal returns (uint256 t0) {
        v.checkRisk();
        vm.prank(mallory);
        v.settle(); // nothing queued: a normal settle by the manager, the epoch starts now
        t0 = vm.getBlockTimestamp();
        assertEq(uint256(v.epochStartedAt()), t0, "epoch restarted at the queue");
        vm.prank(mallory);
        v.setOperator(address(0)); // instant
        vm.prank(mallory);
        p.proposeConfig(c);
        assertTrue(p.pendingConfig().exists, "a loosening is queued");
        assertEq(uint256(p.pendingConfig().eta), t0 + p.timelockDelay(), "eta = queue + policy timelock");
        uint256 shares = v.balanceOf(alice);
        vm.prank(alice);
        v.requestRedeem(shares, alice, alice);
    }

    /// @dev Every way a redeemer can be paid or protected, tried as each role, must fail right now.
    function _assertNoExitPath(GainsVault v) internal {
        vm.prank(alice);
        vm.expectRevert(E.NotOverdue.selector);
        v.triggerEmergency();
        vm.prank(stranger);
        vm.expectRevert(E.NotOverdue.selector);
        v.triggerEmergency();
        vm.prank(platformGuardian);
        vm.expectRevert(E.Unauthorized.selector); // exit-only settle needs an overdue epoch or an emergency
        v.settle();
        vm.prank(platformSentinel);
        vm.expectRevert(E.Unauthorized.selector);
        v.settle();
        vm.prank(keeper);
        vm.expectRevert(E.Unauthorized.selector); // the operator was removed at the queue
        v.settle();
        vm.prank(alice);
        vm.expectRevert(E.Unauthorized.selector);
        v.settle();
    }

    /// Control: the live vault's shape (timelock 2 days >= epoch 1 day). The epoch is overdue at t0 + 1 day, a full
    /// day before the eta: alice triggers the emergency herself, the guardian settles exit-only and pays her in full
    /// before the loosening can apply. Once overdue the manager cannot open new risk either (EpochOverdue).
    function test_GR2_CFG_01_control_timelockAtLeastEpoch_redeemerPaidBeforeEta() public {
        (GainsVault v, GainsVaultPolicy p) = _launch(2 days, 1 days, bytes32(uint256(102)));
        uint256 t0 = _queueAndRedeem(v, p, _loose(p, 1 days));
        _skip(1 days - 1);
        _assertNoExitPath(v);
        _skip(1);
        // overdue: no new risk, alice may force the exit
        vm.prank(mallory);
        vm.expectRevert(E.EpochOverdue.selector);
        v.openTrade(_params(ETH, true, uint120(1_000e6), 3_000));
        vm.prank(alice);
        v.triggerEmergency();
        vm.prank(platformSentinel);
        v.settle();
        uint256 before = usdc.balanceOf(alice);
        v.claim(alice);
        uint256 paid = usdc.balanceOf(alice) - before;
        assertApproxEqAbs(paid, ALICE_IN, 2e6, "paid in full (less one day of 2% management fee)");
        assertLt(vm.getBlockTimestamp(), t0 + 2 days, "before the loosening's eta");
        // the loosening applies later; alice is already out
        _warp(t0 + 2 days);
        p.applyPendingConfig();
        assertEq(v.balanceOf(alice), 0);
    }

    /// Sound half of CFG-02: an emergency triggered inside the window survives the apply (the emergency flag, not the
    /// epoch age, blocks new risk), so a redeemer who acts in [overdue, eta) is protected.
    function test_GR2_CFG_02_control_emergencyInsideTheWindowSurvivesTheApply() public {
        (GainsVault v, GainsVaultPolicy p) = _launch(2 days, 1 days, bytes32(uint256(104)));
        uint256 t0 = _queueAndRedeem(v, p, _loose(p, 30 days));
        _warp(t0 + 1 days);
        vm.prank(alice);
        v.triggerEmergency();
        _warp(t0 + 2 days);
        p.applyPendingConfig();
        vm.prank(mallory);
        vm.expectRevert(E.ReduceOnlyMode.selector);
        v.openTrade(_params(ETH, true, uint120(1_000e6), 3_000));
        vm.prank(platformGuardian);
        v.settle();
        uint256 before = usdc.balanceOf(alice);
        v.claim(alice);
        assertApproxEqAbs(usdc.balanceOf(alice) - before, ALICE_IN, 3e6, "paid in full");
    }

    // ==================================================================
    // Worst-case table (pure arithmetic over the factory's extremes), logged for CONFIG.md
    // ==================================================================
    /// Trap length for a redeemer who asks right after the queue (epoch restarted at the queue, operator removed,
    /// nobody forces anything inside an open window): exposure to the loosened policy = max(0, E_new - T) when
    /// T < E_old; when T >= E_old the redeemer is safe only by acting within T - E_old after overdue, else again
    /// E_new - T (CFG-02). E_new = 30 days is always available to the owner (a loosening may raise it).
    function test_GR2_CFG_table_worstCaseTrap() public {
        uint256[4] memory T = [uint256(1 days), 2 days, 7 days, 30 days];
        uint256[5] memory Eo = [uint256(1 hours), 1 days, 2 days, 7 days, 30 days];
        for (uint256 i; i < T.length; ++i) {
            for (uint256 j; j < Eo.length; ++j) {
                uint256 window = T[i] >= Eo[j] ? T[i] - Eo[j] : 0; // time to self-trigger emergency
                uint256 trapNoAction = 30 days > T[i] ? 30 days - T[i] : 0; // E_new = 30 d
                uint256 trapAlways = T[i] < Eo[j] ? Eo[j] - T[i] : 0; // even with E unchanged
                emit log_named_uint(
                    string.concat("T(h)=", vm.toString(T[i] / 1 hours), " E_old(h)=", vm.toString(Eo[j] / 1 hours), " self-help window(h)"),
                    window / 1 hours
                );
                emit log_named_uint("   trapped hours if E unchanged and T < E_old", trapAlways / 1 hours);
                emit log_named_uint("   trapped hours if nobody acts in the window (E raised to 30 d)", trapNoAction / 1 hours);
            }
        }
    }
}
