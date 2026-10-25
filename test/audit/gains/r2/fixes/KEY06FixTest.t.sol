// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {R1Base} from "../../R1Base.t.sol";
import {GainsVault} from "../../../../../src/gains/GainsVault.sol";
import {GainsVaultPolicy} from "../../../../../src/gains/GainsVaultPolicy.sol";
import {InitParams} from "../../../../../src/gains/GainsTypes.sol";
import {IGainsVaultErrors} from "../../../../../src/gains/GainsTypes.sol";
import {BreachReason} from "../../../../../src/VaultTypes.sol";

/// @notice GR2-KEY-06 (and GR2-ECON-02, GR2-CFG-02) fix test (contracts/audit/gains/r2/fixes/GR2-KEY-06). Asserts the
///         FIXED behaviour, so it fails on 4ec6feb and passes with fix.diff. Run it from
///         contracts/test/audit/gains/r2/fixes/. Same market path and vault as XReviewKey.t.sol (100k vault, thief 50k,
///         victim 50k redeeming, honest 4x ETH long, ETH -2.5 % then a full rebound inside the hour), live-like policy,
///         no fees.
///         Fixed rules: (1) redemption-only and exit-only settles pay min(NAV, cap) with cap = max(checkpoint, the value
///         its last ratchet replaced) while the checkpoint is fresh, and the checkRisk ratchet of the stale checkpoint
///         otherwise; (2) the epoch deadline is fixed when the epoch starts.
contract KEY06FixTest is R1Base {
    address internal thief = makeAddr("xr.thief");
    address internal victim = makeAddr("xr.victim");

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
        ip.timelockDelay = 2 days;
        v.initialize(ip);
        address[2] memory who = [thief, victim];
        for (uint256 i; i < who.length; ++i) {
            usdc.mint(who[i], 1_000_000e6);
            vm.prank(who[i]);
            usdc.approve(address(v), type(uint256).max);
        }
    }

    /// @dev XReviewKey._setup: 100k vault, 4x ETH long, the victim queues a full exit, two hours later ETH dips 2.5 %.
    function _setup() internal returns (GainsVault v, GainsVaultPolicy p, uint64 p0) {
        (v, p) = _mk();
        _depositTo(v, thief, 50_000e6);
        _depositTo(v, victim, 50_000e6);
        _settleV(v);
        v.claim(thief);
        v.claim(victim);
        uint256 nav = v.totalAssets();
        _open(v, ETH, true, uint120(nav * 40_000 / 10_000 / 10), 10_000);
        _redeemFrom(v, victim, v.balanceOf(victim));
        _skip(2 hours);
        p0 = _px(ETH);
        _setPrice(ETH, p0 * 975 / 1000);
    }

    function _values(GainsVault v) internal returns (uint256 thiefValue, uint256 victimUsdc) {
        (uint256 e,,) = v.requests(victim);
        if (e < v.currentEpoch()) v.claim(victim);
        thiefValue = v.totalAssets() * v.balanceOf(thief) / v.totalSupply();
        victimUsdc = usdc.balanceOf(victim);
    }

    function _control(GainsVault v) internal returns (uint256 t, uint256 vic) {
        vm.prank(manager);
        v.settle();
        (t, vic) = _values(v);
    }

    /// @notice XR-01 (guardian key): emergency + exit-only settle after the dip checkpoint and the rebound now pays the
    ///         victim exactly what the treasury's normal settle pays.
    function test_KEY06_fix_XR01_guardianEmergencyAtTheRebound_movesNothing() public {
        (GainsVault v,, uint64 p0) = _setup();
        vm.prank(guardian);
        v.checkRisk(); // checkpoint at the dip
        _skip(40 minutes);
        _setPrice(ETH, p0);
        uint256 snap = vm.snapshotState();
        vm.startPrank(guardian);
        v.triggerEmergency();
        v.settle();
        vm.stopPrank();
        (uint256 tA, uint256 vA) = _values(v);
        vm.revertToState(snap);
        (uint256 tC, uint256 vC) = _control(v);
        assertApproxEqAbs(vA, vC, 1e6, "the victim is paid what the normal settle pays");
        assertApproxEqAbs(tA, tC, 1e6, "the thief gains nothing");
    }

    /// @notice XR-02 (owner == manager key): the same through the owner's own emergency.
    function test_KEY06_fix_XR02_ownerManagerEmergencyAtTheRebound_movesNothing() public {
        (GainsVault v,, uint64 p0) = _setup();
        _timelocked(v, abi.encodeCall(GainsVault.setManager, (owner)));
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
        vm.prank(owner);
        v.settle();
        (uint256 tC, uint256 vC) = _values(v);
        assertApproxEqAbs(vA, vC, 1e6, "the victim is paid what the normal settle pays");
        assertApproxEqAbs(tA, tC, 1e6, "the thief gains nothing");
    }

    /// @notice XR-03 (owner != manager): the instant maxEpochDuration tightening no longer makes the running epoch
    ///         overdue, so the owner's exit-only settle is refused; the treasury's normal settle is unaffected.
    function test_KEY06_fix_XR03_epochTighteningAppliesFromTheNextEpoch() public {
        (GainsVault v, GainsVaultPolicy p, uint64 p0) = _setup();
        GainsVaultPolicy.RiskConfig memory c = _live();
        c.maxEpochDuration = 1 hours;
        vm.prank(owner);
        p.proposeConfig(c);
        assertEq(p.maxEpochDuration(), 1 hours, "the tightening itself is still instant");
        vm.prank(owner);
        v.checkRisk();
        _skip(40 minutes);
        _setPrice(ETH, p0);
        vm.prank(owner);
        vm.expectRevert(IGainsVaultErrors.Unauthorized.selector);
        v.settle(); // not overdue: the running epoch keeps its 1 day deadline
        vm.prank(manager);
        v.settle(); // the treasury settles normally
        (, uint256 vic) = _values(v);
        assertGt(vic, 1_000_000e6 - 50_000e6 + 49_000e6, "victim paid at the live NAV");
    }

    /// @notice XR-03 one epoch later (the tightened 1 hour epoch is in force): the owner may settle exit-only once it is
    ///         overdue, but a dip checkpoint inside the hour no longer prices the redemption at the dip.
    function test_KEY06_fix_XR03_nextEpochExitOnlyAtTheRebound_movesNothing() public {
        (GainsVault v, GainsVaultPolicy p) = _mk();
        _depositTo(v, thief, 50_000e6);
        _depositTo(v, victim, 50_000e6);
        _settleV(v);
        v.claim(thief);
        v.claim(victim);
        _open(v, ETH, true, uint120(v.totalAssets() * 40_000 / 10_000 / 10), 10_000);
        GainsVaultPolicy.RiskConfig memory c = _live();
        c.maxEpochDuration = 1 hours;
        vm.prank(owner);
        p.proposeConfig(c);
        _skip(2 hours);
        vm.prank(manager);
        v.settle(); // the next epoch starts with a 1 hour deadline
        _redeemFrom(v, victim, v.balanceOf(victim));
        uint64 p0 = _px(ETH);
        _skip(1 hours);
        _setPrice(ETH, p0 * 975 / 1000);
        vm.prank(owner);
        v.checkRisk(); // dip checkpoint
        _skip(40 minutes);
        _setPrice(ETH, p0);
        uint256 snap = vm.snapshotState();
        vm.prank(owner);
        v.settle(); // overdue: exit-only
        (uint256 tA, uint256 vA) = _values(v);
        vm.revertToState(snap);
        (uint256 tC, uint256 vC) = _control(v);
        assertApproxEqAbs(vA, vC, 1e6, "the victim is paid what the normal settle pays");
        assertApproxEqAbs(tA, tC, 1e6, "the thief gains nothing");
    }

    /// @notice XR-04 (sentinel key): the full stop forces the emergency path, which now pays the victim at the live NAV
    ///         even after a dip checkpoint taken by the sentinel inside the hour.
    function test_KEY06_fix_XR04_sentinelForcedEmergencyAtTheRebound_paysLiveNav() public {
        (GainsVault v,, uint64 p0) = _setup();
        _setPrice(ETH, p0);
        address sen = v.sentinel();
        vm.prank(sen);
        v.triggerBreach();
        _skip(1 days); // overdue
        _setPrice(ETH, p0 * 975 / 1000);
        vm.prank(sen);
        v.checkRisk(); // dip checkpoint
        _skip(40 minutes);
        _setPrice(ETH, p0);
        vm.prank(stranger);
        v.triggerEmergency();
        uint256 shares = v.pendingRedeemShares();
        uint256 fair = shares * (v.totalAssets() + 1) / (v.totalSupply() + 1e6);
        uint256 before = usdc.balanceOf(victim);
        vm.prank(owner);
        v.settle();
        v.claim(victim);
        assertApproxEqAbs(usdc.balanceOf(victim) - before, fair, 1e6, "paid at the live NAV, not at the dip");
    }

    /// @notice GR2-ECON-02 / C-01 kept: a NAV above every checkpoint of the last interval is still not paid out by an
    ///         exit-only settle (a pump inside the hour is capped at the fresh checkpoint).
    function test_KEY06_fix_C01_pumpAboveTheFreshCheckpointIsStillCapped() public {
        (GainsVault v,, uint64 p0) = _setup();
        _setPrice(ETH, p0);
        uint256 cp0 = v.checkpointNav(); // the settle's checkpoint (2 hours old)
        v.checkRisk(); // fresh checkpoint at the current NAV; cp0 becomes the prior value
        uint256 cp1 = v.checkpointNav();
        uint256 cap = cp0 > cp1 ? cp0 : cp1;
        _setPrice(ETH, p0 * 1025 / 1000); // +2.5 % ETH: NAV about +10 %
        assertGt(v.totalAssets(), cap * 105 / 100, "NAV above both checkpoints of the interval");
        vm.prank(guardian);
        v.triggerEmergency();
        uint256 shares = v.pendingRedeemShares();
        uint256 supply = v.totalSupply();
        uint256 atCap = shares * (cap + 1) / (supply + 1e6);
        uint256 atLive = shares * (v.totalAssets() + 1) / (supply + 1e6);
        uint256 before = usdc.balanceOf(victim);
        vm.prank(guardian);
        v.settle();
        v.claim(victim);
        uint256 paid = usdc.balanceOf(victim) - before;
        assertLt(paid + 3_000e6, atLive, "the pump is not paid out (C-01, REAUDIT3 question a)");
        assertApproxEqAbs(paid, atCap, 1e6, "paid at the highest checkpoint of the interval");
    }

    /// @notice GR2-ECON-02: a STALE low checkpoint (older than the 1 hour interval) is not a price cap; the payout is
    ///         what a checkRisk right before the settle would allow (here the live NAV, within maxNavMoveBps).
    function test_KEY06_fix_ECON02_staleLowCheckpointIsNotACap() public {
        (GainsVault v,, uint64 p0) = _setup();
        v.checkRisk(); // dip checkpoint
        _skip(2 hours);
        _setPrice(ETH, p0); // rebound, nobody checkpointed it
        vm.prank(guardian);
        v.triggerEmergency();
        uint256 shares = v.pendingRedeemShares();
        uint256 fair = shares * (v.totalAssets() + 1) / (v.totalSupply() + 1e6);
        uint256 before = usdc.balanceOf(victim);
        vm.prank(guardian);
        v.settle();
        v.claim(victim);
        assertApproxEqAbs(usdc.balanceOf(victim) - before, fair, 1e6, "stale low checkpoint does not cap the payout");
    }

    /// @notice Lens parity: previewEmergencyRedeem and emergencyFillBps follow the same cap as the settle.
    function test_KEY06_fix_lensPreviewMatchesTheExitOnlyPayout() public {
        (GainsVault v,, uint64 p0) = _setup();
        v.checkRisk();
        _skip(40 minutes);
        _setPrice(ETH, p0);
        vm.prank(guardian);
        v.triggerEmergency();
        uint256 shares = v.pendingRedeemShares();
        (uint256 preview,) = lens.previewEmergencyRedeem(v, shares);
        uint256 before = usdc.balanceOf(victim);
        vm.prank(guardian);
        v.settle();
        v.claim(victim);
        assertApproxEqAbs(usdc.balanceOf(victim) - before, preview, 1, "lens preview = exit-only payout");
    }

    /// @notice GR2-CFG-02: a loosening that raises maxEpochDuration no longer lifts an overdue epoch.
    function test_KEY06_fix_CFG02_epochRaiseDoesNotLiftAnOverdueEpoch() public {
        (GainsVault v, GainsVaultPolicy p,) = _setup();
        GainsVaultPolicy.RiskConfig memory c = _live();
        c.maxEpochDuration = 30 days;
        vm.prank(owner);
        p.proposeConfig(c); // a loosening: queued behind the 2 day policy timelock
        _skip(2 days);
        p.applyPendingConfig();
        assertEq(p.maxEpochDuration(), 30 days);
        assertTrue(lens.epochOverdue(v), "the running epoch stays overdue");
        vm.prank(stranger);
        v.triggerEmergency(); // anyone, overdue with a redemption waiting
        assertTrue(v.emergency());
    }
}
