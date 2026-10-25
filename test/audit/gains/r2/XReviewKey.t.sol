// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {console2} from "forge-std/Test.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {R1Base} from "../R1Base.t.sol";
import {GainsVault} from "../../../../src/gains/GainsVault.sol";
import {GainsVaultPolicy} from "../../../../src/gains/GainsVaultPolicy.sol";
import {InitParams} from "../../../../src/gains/GainsTypes.sol";
import {IGainsVaultErrors} from "../../../../src/gains/GainsTypes.sol";
import {BreachReason} from "../../../../src/VaultTypes.sol";

/// @notice Round 2 cross-review of KEY / EXE / FF (XREVIEW-KEY-EXE-FF.md). Each test asserts today's behaviour, so it
///         passes while the issue exists. Mock diamond, live-like policy (5x, 15 % daily loss, 50 % drawdown, 1 day
///         epochs, 20 % NAV move), ETH band 20 bps, no fees (so every USDC the redeemer loses is visible at the
///         confederate). Standalone vault: guardian == sentinel; owner != manager unless a test makes them equal.
///
///         The question: does ONE stolen key (plus the thief's own capital as an ordinary depositor, the same premise
///         KEYS.md uses for GR2-KEY-01) move depositor value to the thief? KEYS.md says "no single stolen key TAKES
///         depositor USDC through the vault". These tests show three keys that can, through the exit-only price
///         min(NAV, checkpoint) (ECONOMICS.md GR2-ECON-02) reached at the key holder's own choice of moment.
contract XReviewKeyTest is R1Base {
    address internal thief = makeAddr("xr.thief"); // the key holder's own depositor account (stays in the vault)
    address internal victim = makeAddr("xr.victim"); // an ordinary depositor who redeems

    function _live() internal pure returns (GainsVaultPolicy.RiskConfig memory) {
        return GainsVaultPolicy.RiskConfig({
            maxLeverageBps: 50_000,
            maxDailyLossBps: 1_500,
            maxDrawdownBps: 5_000,
            maxSlippageBps: 100,
            maxOrderNotional: 10_000_000e6,
            maxEpochDuration: 1 days,
            maxNavMoveBps: 2_000,
            maxFlattenSlippageBps: 300
        });
    }

    function _mk() internal returns (GainsVault v, GainsVaultPolicy p) {
        uint32[] memory assets = new uint32[](2);
        assets[0] = BTC;
        assets[1] = ETH;
        v = GainsVault(Clones.clone(address(vaultImpl)));
        p = GainsVaultPolicy(Clones.clone(address(policyImpl)));
        p.initialize(owner, _live(), assets, 2 days, address(platform), address(v));
        InitParams memory ip = _standaloneParams(p);
        ip.managementFeeBps = 0;
        ip.performanceFeeBps = 0;
        v.initialize(ip);
        address[2] memory who = [thief, victim];
        for (uint256 i; i < who.length; ++i) {
            usdc.mint(who[i], 1_000_000e6);
            vm.prank(who[i]);
            usdc.approve(address(v), type(uint256).max);
        }
    }

    /// @dev 100k vault: thief 50k, victim 50k. The honest manager runs a 4x ETH long. The victim queues a full exit.
    ///      Two hours after the opening settle (so the hourly checkpoint may move), ETH dips 2.5 %.
    function _setup() internal returns (GainsVault v, GainsVaultPolicy p, uint64 p0) {
        (v, p) = _mk();
        _depositTo(v, thief, 50_000e6);
        _depositTo(v, victim, 50_000e6);
        _settleV(v);
        v.claim(thief);
        v.claim(victim);
        uint256 nav = v.totalAssets();
        _open(v, ETH, true, uint120(nav * 40_000 / 10_000 / 10), 10_000); // 4x
        _redeemFrom(v, victim, v.balanceOf(victim));
        _skip(2 hours);
        p0 = _px(ETH);
        _setPrice(ETH, p0 * 975 / 1000); // -2.5 % ETH: NAV about -10 %, below the 15 % daily loss limit
    }

    /// @dev The thief's value in the vault (pro rata NAV) and the victim's USDC.
    function _values(GainsVault v) internal returns (uint256 thiefValue, uint256 victimUsdc) {
        (uint256 e,,) = v.requests(victim);
        if (e < v.currentEpoch()) v.claim(victim);
        thiefValue = v.totalAssets() * v.balanceOf(thief) / v.totalSupply();
        victimUsdc = usdc.balanceOf(victim);
    }

    function _report(string memory who, uint256 tA, uint256 vA, uint256 tC, uint256 vC) internal pure {
        console2.log(who);
        console2.log("  attack : thief's vault value / victim's USDC", tA, vA);
        console2.log("  control: thief's vault value / victim's USDC", tC, vC);
        console2.log("  victim loses (USDC 1e6)", int256(vC) - int256(vA));
        console2.log("  thief gains (USDC 1e6)", int256(tA) - int256(tC));
    }

    /// @dev Control: the honest manager's normal settle at the same moment (live NAV, adverse band edge).
    function _control(GainsVault v) internal returns (uint256 t, uint256 vic) {
        vm.prank(manager);
        v.settle();
        (t, vic) = _values(v);
    }

    // =================================================================================================================
    // XR-01: the GUARDIAN key alone (factory owner == guardian on live). No overdue epoch, no breach, no market
    // manipulation: the guardian checkpoints the dip (checkRisk is permissionless), waits for the rebound, enters
    // emergency (allowed at any time) and settles exit-only at min(NAV, checkpoint) = the dip.
    // Fixed (GR2-KEY-06, fix round WP2): on a fresh checkpoint the exit-only settle pays up to the value the dip's ratchet
    // replaced, so after the rebound the victim is paid what the control pays and the thief gains nothing.
    // =================================================================================================================
    function test_GR2_XR_01_fix_guardianKeyAlone_emergencyExitOnlyPaysTheRebound() public {
        (GainsVault v,, uint64 p0) = _setup();
        vm.prank(guardian);
        v.checkRisk(); // the checkpoint follows the dip; nobody can move it again for an hour
        _skip(40 minutes);
        _setPrice(ETH, p0); // full rebound
        uint256 snap = vm.snapshotState();

        vm.startPrank(guardian);
        v.triggerEmergency();
        v.settle(); // exit-only: min(NAV, checkpoint)
        vm.stopPrank();
        (uint256 tA, uint256 vA) = _values(v);

        vm.revertToState(snap);
        (uint256 tC, uint256 vC) = _control(v);
        _report("XR-01 guardian key, 100k vault, 4x ETH, -2.5 % dip then rebound", tA, vA, tC, vC);
        assertApproxEqAbs(vA, vC, 1e6, "the victim (50k redemption) is paid what the control pays");
        assertApproxEqAbs(tA, tC, 1e6, "the thief's own shares gain nothing");
        // The guardian then ends the emergency (nothing pending, the last settle paid in full): the vault runs on.
        vm.prank(guardian);
        v.exitEmergency();
        assertFalse(v.emergency(), "back to normal, no trace beyond the events");
    }

    // =================================================================================================================
    // XR-02: the OWNER key on the live shape (owner == manager == fee recipient). The owner may trigger an emergency at
    // any time; the manager's settle in emergency is exit-only. Only the guardian can end the emergency, so this is a
    // one-shot for a thief, but nothing stops the shot.
    // Fixed (GR2-KEY-06, fix round WP2): as XR-01, the shot pays the victim what the control pays.
    // =================================================================================================================
    function test_GR2_XR_02_fix_ownerEqualsManagerKey_emergencyExitOnlyPaysTheRebound() public {
        (GainsVault v,, uint64 p0) = _setup();
        // live shape: the owner is also the manager (timelocked once, at launch)
        _timelocked(v, abi.encodeCall(GainsVault.setManager, (owner)));
        assertEq(v.manager(), owner);
        // (the setup's dip stays in place: _timelocked skipped 2 days; refresh the dip and the checkpoint window)
        _setPrice(ETH, p0 * 975 / 1000);
        vm.prank(owner);
        v.checkRisk();
        _skip(40 minutes);
        _setPrice(ETH, p0);
        uint256 snap = vm.snapshotState();

        vm.startPrank(owner);
        v.triggerEmergency();
        v.settle();
        vm.stopPrank();
        (uint256 tA, uint256 vA) = _values(v);

        vm.revertToState(snap);
        // control: a normal settle by the (same) manager key without the emergency. The epoch ran 2 days, so the
        // owner-manager's settle is still a treasury settle (normal mode) because owner == manager.
        vm.prank(owner);
        v.settle();
        (uint256 tC, uint256 vC) = _values(v);
        _report("XR-02 owner == manager key, same market path", tA, vA, tC, vC);
        assertApproxEqAbs(vA, vC, 1e6, "the victim is paid what the control pays");
        assertApproxEqAbs(tA, tC, 1e6, "the thief's shares gain nothing");
    }

    // =================================================================================================================
    // XR-04: the SENTINEL key (hot) holds a vault in a full stop. Every triggerBreach restarts breachedAt, so an owner's
    // queued clearBreach never becomes executable (N-04 by design), every settle reverts ReduceOnlyMode, deposits are
    // closed. Exits resume only through an emergency: anyone once the epoch is overdue with redemptions waiting, then an
    // exit-only settle at min(NAV, checkpoint). Stop: the factory owner's setSentinel (instant) or the guardian.
    // =================================================================================================================
    function test_GR2_XR_04_sentinelKey_retriggerVoidsOwnerClearAndForcesTheExitOnlyPath() public {
        (GainsVault v,, uint64 p0) = _setup();
        _setPrice(ETH, p0);
        address sen = v.sentinel(); // standalone vault: the guardian address is also the sentinel
        vm.prank(sen);
        v.triggerBreach();
        bytes memory clear = abi.encodeCall(GainsVault.clearBreach, ());
        vm.prank(owner);
        v.queue(clear);
        _skip(2 days - 1 minutes);
        vm.prank(sen);
        v.triggerBreach(); // a minute before the owner's clear matures
        _skip(2 minutes);
        vm.expectRevert(IGainsVaultErrors.NotReady.selector);
        v.execute(clear);
        vm.prank(manager);
        vm.expectRevert(IGainsVaultErrors.ReduceOnlyMode.selector);
        v.settle();
        // the epoch is long overdue with the victim's redemption waiting: anyone may enter emergency; the redeemer is
        // then paid by an exit-only settle (here the owner's), at min(NAV, checkpoint)
        vm.prank(stranger);
        v.triggerEmergency();
        vm.prank(owner);
        v.settle();
        v.claim(victim);
        assertGt(usdc.balanceOf(victim), 1_000_000e6 - 50_000e6, "the victim is paid through the emergency path");
    }
}
