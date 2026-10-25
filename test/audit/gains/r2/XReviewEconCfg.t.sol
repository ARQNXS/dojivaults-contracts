// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {console2} from "forge-std/Test.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {R1Base} from "../R1Base.t.sol";
import {GovBase} from "../gov/GovBase.t.sol";
import {GainsVault} from "../../../../src/gains/GainsVault.sol";
import {GainsVaultPolicy} from "../../../../src/gains/GainsVaultPolicy.sol";
import {GainsVaultFactory} from "../../../../src/gains/GainsVaultFactory.sol";
import {InitParams, IGainsVaultErrors as E} from "../../../../src/gains/GainsTypes.sol";
import {BreachReason} from "../../../../src/VaultTypes.sol";

/// @notice Round 2 cross-review of the ECON and CFG domains (XREVIEW-ECON-CFG.md). Each test asserts today's
///         behaviour and passes on the current code. Mock diamond, the ECON live-like policy for the ECON part, the
///         CFG factory launch for the CFG part.
contract XReviewEconTest is R1Base {
    address internal carol = makeAddr("xr.carol");

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

    function _mk(uint16 mgmt, uint16 perf) internal returns (GainsVault v) {
        uint32[] memory assets = new uint32[](2);
        assets[0] = BTC;
        assets[1] = ETH;
        v = GainsVault(Clones.clone(address(vaultImpl)));
        GainsVaultPolicy p = GainsVaultPolicy(Clones.clone(address(policyImpl)));
        p.initialize(owner, _live(), assets, 2 days, address(platform), address(v));
        InitParams memory ip = _standaloneParams(p);
        ip.managementFeeBps = mgmt;
        ip.performanceFeeBps = perf;
        v.initialize(ip);
        usdc.mint(carol, 20_000_000e6);
        address[3] memory who = [alice, bob, carol];
        for (uint256 i; i < who.length; ++i) {
            vm.prank(who[i]);
            usdc.approve(address(v), type(uint256).max);
        }
    }

    // =================================================================================================================
    // GR2-ECON-03: can the manager force a leverage breach at will? (no price move, no gain needed)
    // =================================================================================================================
    /// @dev Flat 100k vault, prices unchanged. One open that passes checkOrder at exactly the 5x limit puts vault
    ///      leverage over the limit at once (the NAV values the new trade at the adverse band edge), so anyone's
    ///      checkRisk sets LEVERAGE. At 4.9x it does not. The manager therefore chooses, per settle, whether the
    ///      settle is a normal one (perf crystallised) or a leverage-breach one (deposits minted, perf skipped).
    ///      The settle that follows is a normal-mode settle by the manager: bob's queued deposit is minted and the HWM
    ///      does not move.
    function test_GR2_XR_ECON03_managerForcesLeverageBreachAtWill_noPriceMove() public {
        GainsVault v = _mk(0, 2_000);
        _depositTo(v, alice, 100_000e6);
        _settleV(v);
        v.claim(alice);
        _depositTo(v, bob, 50_000e6); // queued before the breach (deposits close once breached)
        uint256 snap = vm.snapshotState();

        // control: 4.9x, no breach
        uint256 nav = v.totalAssets();
        _open(v, ETH, true, uint120(nav * 49_000 / 10_000 / 10), 10_000);
        (uint256 lev,,) = v.checkRisk();
        assertFalse(v.breached(), "4.9x: no breach");
        console2.log("leverage after a 4.9x open (bps)", lev);

        vm.revertToState(snap);
        nav = v.totalAssets();
        _open(v, ETH, true, uint120(nav * 50_000 / 10_000 / 10), 10_000); // exactly the limit: accepted
        (lev,,) = v.checkRisk();
        console2.log("leverage after an exactly-5x open (bps)", lev);
        assertGt(lev, 50_000, "the open's own adverse-edge cost puts leverage over the limit");
        assertEq(uint8(v.breachReason()), uint8(BreachReason.LEVERAGE), "LEVERAGE breach, no price move");
        uint256 hwm = v.highWaterMark();
        _skip(1 hours);
        vm.prank(manager);
        v.settle(); // a normal-mode settle in a leverage breach
        assertGt(v.balanceOf(address(v)), 0, "bob's deposit minted (claimable shares held by the vault)");
        assertEq(v.highWaterMark(), hwm, "HWM unchanged: no performance fee in this settle");
        // and a depositor can no longer queue (or re-queue) while it lasts
        vm.prank(carol);
        vm.expectRevert(E.DepositsClosed.selector);
        v.requestDeposit(10_000e6, carol);
    }

    // =================================================================================================================
    // GR2-ECON-02: the redemption-only half is bounded by maxNavMoveBps (the REAUDIT3 question-a bound)
    // =================================================================================================================
    /// @dev ECON-02's scenario (200k vault, 4.9x ETH long, -3.5 % -> daily loss breach, bob redeems) with a full
    ///      rebound (ETH back to p0, NAV +20.5 % over the dip checkpoint). The redemption-only settle at once is
    ///      refused NavMoved: the settler can only pay the dip while the rebound stays within maxNavMoveBps of the
    ///      checkpoint. The gap is therefore bounded by maxNavMoveBps (20 %) of the redemption, which is exactly the
    ///      lag REAUDIT3 section 10 accepted ("at most one hour and at most m behind ... favours the holders who stay").
    ///      bob's own defence (cancel, then redeem after the next ratchet) works at any time.
    function test_GR2_XR_ECON02_redemptionOnlyGapBoundedByNavMove_andCancelDefence() public {
        GainsVault v = _mk(0, 0);
        _depositTo(v, alice, 100_000e6);
        _depositTo(v, bob, 100_000e6);
        _settleV(v);
        v.claim(alice);
        v.claim(bob);
        _skip(12 hours);
        _settleV(v);
        uint256 nav = v.totalAssets();
        _open(v, ETH, true, uint120(nav * 49_000 / 10_000 / 10), 10_000);
        _skip(2 hours);
        uint64 p0 = _px(ETH);
        _setPrice(ETH, p0 * 965 / 1000);
        v.checkRisk();
        assertEq(uint8(v.breachReason()), uint8(BreachReason.DAILY_LOSS));
        uint256 dip = v.checkpointNav();
        uint256 bobShares = v.balanceOf(bob);
        _redeemFrom(v, bob, bobShares);
        _skip(30 minutes);
        _setPrice(ETH, p0); // full rebound
        uint256 navNow = v.totalAssets();
        console2.log("dip checkpoint / NAV after full rebound (USDC)", dip / 1e6, navNow / 1e6);
        assertGt((navNow - dip) * 10_000, dip * 2_000, "rebound > 20 % above the checkpoint");
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(GainsVaultPolicy.NavMoved.selector, navNow, dip));
        v.settle();

        // bob's defence: cancel now (always allowed in a breach), redeem again once anyone ratchets the checkpoint
        vm.prank(bob);
        v.cancelRedeemRequest();
        assertEq(v.balanceOf(bob), bobShares, "shares back");
    }

    /// @dev ECON-02's exit-only half does not need an overdue epoch: the owner may trigger the emergency at ANY time
    ///      (GainsVaultGovernance.triggerEmergency), after which the owner or the manager settles exit-only at
    ///      min(NAV, checkpoint). Same numbers as ECON's overdue PoC (4x ETH long, -2.5 % dip fixed by the owner's
    ///      checkRisk, full rebound 40 min later), but the epoch is 2 h old. The manager closes the book for liquidity
    ///      (exits are always open to it), then settles. Cost to the insider: the vault is in emergency (agent revoked,
    ///      deposits refunded, only the guardian ends it), so this is visible and one-shot, not a quiet harvest.
    ///      Also shown: on the live shape (owner == manager) the manager's own settle of an overdue epoch is a NORMAL
    ///      settle at the live NAV (treasury), so ECON's "owner (also the manager on the live vault)" exit-only route
    ///      only exists through this emergency, or for an owner who is not the manager.
    ///      Fixed (GR2-KEY-06, fix round WP2): an exit-only settle on a fresh checkpoint pays up to the value the dip's
    ///      ratchet replaced, so after the rebound the emergency route pays bob what a normal settle pays.
    function test_GR2_XR_ECON02_fix_ownerEmergencyNoLongerPaysTheDip() public {
        GainsVault v = _mk(0, 0);
        _depositTo(v, alice, 100_000e6);
        _depositTo(v, bob, 100_000e6);
        _settleV(v);
        v.claim(alice);
        v.claim(bob);
        uint256 nav = v.totalAssets();
        uint32 idx = _open(v, ETH, true, uint120(nav * 40_000 / 10_000 / 10), 10_000);
        _redeemFrom(v, bob, v.balanceOf(bob) / 2);
        _skip(2 hours); // NOT overdue (1 day epochs)
        uint64 p0 = _px(ETH);
        _setPrice(ETH, p0 * 975 / 1000);
        vm.prank(owner);
        v.checkRisk(); // fixes the checkpoint at the dip (no breach: -10 % NAV < 15 %)
        assertFalse(v.breached());
        _skip(40 minutes);
        _setPrice(ETH, p0);
        uint256 snap = vm.snapshotState();

        vm.prank(owner);
        v.triggerEmergency(); // owner: any time
        vm.prank(manager);
        v.closeTrade(idx, _px(ETH)); // liquidity for the exit
        _fillLast(v, _px(ETH));
        vm.prank(manager);
        v.settle(); // emergency: exit-only, min(NAV, checkpoint)
        uint256 b0 = usdc.balanceOf(bob);
        v.claim(bob);
        uint256 paidEmergency = usdc.balanceOf(bob) - b0;

        vm.revertToState(snap);
        _passHold(); // outside the emergency the manager's close waits out the GR2-KEY-01b minimum hold
        _closeFilled(v, idx, _px(ETH));
        vm.prank(manager);
        v.settle(); // normal settle at the same price
        b0 = usdc.balanceOf(bob);
        v.claim(bob);
        uint256 paidNormal = usdc.balanceOf(bob) - b0;
        console2.log("bob (half) paid via the owner's emergency / via a normal settle", paidEmergency, paidNormal);
        assertLe(paidEmergency, paidNormal, "never above the live NAV");
        assertApproxEqRel(paidEmergency, paidNormal, 0.001e18, "the emergency route takes nothing from bob (within 0.1 %)");
    }

    /// @dev On the live shape (owner == manager) an overdue epoch settled by that address is a treasury (normal)
    ///      settle at the live NAV, not exit-only at min(NAV, checkpoint).
    function test_GR2_XR_ECON02_ownerIsManager_overdueSettleIsNormalNotExitOnly() public {
        GainsVault v = _mk(0, 0);
        vm.prank(owner);
        v.queue(abi.encodeCall(GainsVault.setManager, (owner)));
        _skip(2 days);
        v.execute(abi.encodeCall(GainsVault.setManager, (owner)));
        assertEq(v.manager(), owner);
        _depositTo(v, alice, 100_000e6);
        _depositTo(v, bob, 100_000e6);
        _settleV(v);
        v.claim(alice);
        v.claim(bob);
        uint256 nav = v.totalAssets();
        uint32 idx = _open(v, ETH, true, uint120(nav * 40_000 / 10_000 / 10), 10_000);
        _redeemFrom(v, bob, v.balanceOf(bob) / 2);
        _skip(1 days + 1);
        uint64 p0 = _px(ETH);
        _setPrice(ETH, p0 * 975 / 1000);
        vm.prank(owner);
        v.checkRisk();
        _skip(40 minutes);
        _setPrice(ETH, p0);
        _passHold(); // the manager's close waits out the GR2-KEY-01b minimum hold (fix round WP2)
        _closeFilled(v, idx, _px(ETH));
        uint256 live = v.totalAssets();
        uint256 cp = v.checkpointNav();
        assertLt(cp * 100, live * 92, "checkpoint at the dip");
        vm.prank(owner);
        v.settle(); // treasury caller: normal mode
        uint256 b0 = usdc.balanceOf(bob);
        v.claim(bob);
        uint256 paid = usdc.balanceOf(bob) - b0;
        assertApproxEqRel(paid, live / 4, 0.001e18, "bob's quarter of the supply paid at the live NAV, not the dip");
    }

    // =================================================================================================================
    // "Checked and sound" #1: the residual a full exit leaves cannot be captured by a later depositor
    // =================================================================================================================
    /// @dev ECON section 4 ("first depositor after a full exit"): a full exit priced at the checkpoint leaves a
    ///      residual R against a few dust share units. Reproduced here as 7 dust units held by alice plus 522 USDC of
    ///      idle value nobody's shares account for (the seed-7 / 1M numbers of ECONOMICS.md). carol then puts 10M in
    ///      and takes it out while the vault is flat. With the virtual offset (+1 asset, +1e6 shares) her round trip
    ///      returns exactly her deposit to within rounding: the residual stays with the virtual shares (and the dust
    ///      holder), so the "nobody can capture it quickly" claim holds, and in fact nobody can capture it at all at
    ///      fair prices. ECONOMICS.md's "released pro rata to later holders as the supply grows" is not what the
    ///      arithmetic does: the residual's value follows the share price of 1e6 virtual units.
    function test_GR2_XR_ECON_residualAfterFullExitNotCapturableByLargeDepositor() public {
        GainsVault v = _mk(0, 0);
        _depositTo(v, alice, 10e6);
        _settleV(v);
        v.claim(alice);
        // alice leaves all but 7 share units
        _redeemFrom(v, alice, v.balanceOf(alice) - 7);
        _skip(2 hours);
        _settleV(v);
        v.claim(alice);
        assertEq(v.totalSupply(), 7, "7 dust share units left");
        usdc.mint(address(v), 522e6); // the stranded residual
        uint256 r0 = v.totalAssets();
        console2.log("residual NAV (USDC, 1e6) against 7 units", r0);

        uint256 c0 = usdc.balanceOf(carol);
        _depositTo(v, carol, 10_000_000e6);
        _skip(2 hours);
        _settleV(v);
        v.claim(carol);
        _redeemFrom(v, carol, v.balanceOf(carol));
        _skip(2 hours);
        _settleV(v);
        v.claim(carol);
        uint256 c1 = usdc.balanceOf(carol);
        console2.log("carol in 10,000,000 USDC; out (1e6)", c1 + 10_000_000e6 - c0);
        assertLe(c1, c0, "carol gains nothing from the residual");
        assertGe(c1 + 2, c0, "and loses only rounding");
        assertGe(v.totalAssets() + 2, r0, "the residual is still in the vault");
    }
}

/// @notice CFG cross-review on the factory launch (GovBase), same scenario helpers as ConfigTimelock.t.sol.
contract XReviewCfgTest is GovBase {
    address internal mallory = makeAddr("mallory"); // owner == manager == fee recipient
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

    function _assertNoSelfHelp(GainsVault v) internal {
        vm.prank(alice);
        vm.expectRevert(E.NotOverdue.selector);
        v.triggerEmergency();
        vm.prank(platformSentinel);
        vm.expectRevert(E.Unauthorized.selector);
        v.settle();
    }

    function _paidAlice(GainsVault v) internal returns (uint256 paid) {
        uint256 b = usdc.balanceOf(alice);
        v.claim(alice);
        paid = usdc.balanceOf(alice) - b;
    }

    /// @dev CFG-01 rescue path 1: the cold guardian may trigger the emergency at ANY time (no overdue condition,
    ///      GainsVaultGovernance.triggerEmergency), and the hot sentinel then settles exit-only. alice is paid in full
    ///      before the loosening's eta. Under the exit-before-effect fix the eta is the stored one (queue + epoch +
    ///      1 day), and the loosening still cannot be used in the emergency.
    function test_GR2_XR_CFG01_guardianEmergencyAnyTimeFreesRedeemerBeforeEta() public {
        (GainsVault v, GainsVaultPolicy p) = _launch(1 days, 30 days, bytes32(uint256(901)));
        _queueAndRedeem(v, p, _loose(p, 30 days));
        uint256 eta = p.pendingConfig().eta;
        _skip(1 hours);
        _assertNoSelfHelp(v);
        vm.prank(platformGuardian);
        v.triggerEmergency(); // not overdue: allowed for the guardian
        vm.prank(platformSentinel);
        v.settle(); // exit-only in emergency
        uint256 paid = _paidAlice(v);
        assertApproxEqAbs(paid, ALICE_IN, 1e6, "paid in full (less an hour of management fee)");
        assertLt(vm.getBlockTimestamp(), eta, "before the eta");
        // the loosening still applies later, but no new risk can be taken in the emergency
        _warp(eta);
        p.applyPendingConfig();
        vm.prank(mallory);
        vm.expectRevert(E.ReduceOnlyMode.selector);
        v.openTrade(_params(ETH, true, uint120(1_000e6), 12_000));
    }

    /// @dev CFG-01 rescue path 3 (hot key only): the sentinel's full stop blocks the manager's new risk and every
    ///      non-emergency settle (ReduceOnlyMode), so alice stays locked until the guardian or, once overdue, anyone
    ///      triggers the emergency. The sentinel alone removes the loss, not the lock. Under the exit-before-effect
    ///      fix the overdue date (queue + 30 days) comes a day before the loosening's eta, so alice is out first.
    function test_GR2_XR_CFG01_sentinelFullStopRemovesTheRiskButNotTheLock() public {
        (GainsVault v, GainsVaultPolicy p) = _launch(1 days, 30 days, bytes32(uint256(903)));
        uint256 t0 = _queueAndRedeem(v, p, _loose(p, 30 days));
        uint256 eta = p.pendingConfig().eta;
        assertEq(eta, t0 + 31 days, "epoch + 1 day, not the 1 day timelock");
        vm.prank(platformSentinel);
        v.triggerBreach();
        _warp(t0 + 1 days);
        vm.expectRevert(GainsVaultPolicy.NotReady.selector);
        p.applyPendingConfig();
        vm.prank(mallory);
        vm.expectRevert(E.ReduceOnlyMode.selector);
        v.openTrade(_params(ETH, true, uint120(10_000e6), 12_000));
        vm.prank(platformSentinel);
        vm.expectRevert(E.ReduceOnlyMode.selector);
        v.settle();
        vm.prank(mallory);
        vm.expectRevert(E.ReduceOnlyMode.selector);
        v.settle();
        vm.prank(alice);
        vm.expectRevert(E.NotOverdue.selector);
        v.triggerEmergency();
        _warp(t0 + 30 days);
        vm.prank(alice);
        v.triggerEmergency();
        vm.prank(platformSentinel);
        v.settle();
        assertApproxEqAbs(_paidAlice(v), ALICE_IN, 20e6, "paid in full, 30 days late");
        assertLt(vm.getBlockTimestamp(), eta, "before the loosening could apply");
    }

    /// @dev Reachability: CFG-01's T < E state is still reachable from the LIVE vault's shape (T = 2 d, E = 1 d) after
    ///      one public queue (a config whose only change is maxEpochDuration 1 d -> 30 d). Under the exit-before-effect
    ///      fix it no longer traps anyone: the next loosening's eta is the new epoch's deadline plus a day, so a
    ///      redeemer who asks after it can force the exit herself before it applies.
    function test_GR2_XR_CFG01_liveShapeReachesTimelockBelowEpochInOneQueue() public {
        (GainsVault v, GainsVaultPolicy p) = _launch(2 days, 1 days, bytes32(uint256(904)));
        GainsVaultPolicy.RiskConfig memory c = p.config();
        c.maxEpochDuration = 30 days;
        vm.prank(mallory);
        p.proposeConfig(c);
        _warp(p.pendingConfig().eta);
        p.applyPendingConfig();
        assertEq(p.maxEpochDuration(), 30 days);
        assertLt(p.timelockDelay(), p.maxEpochDuration(), "T < E reached");

        uint256 t1 = _queueAndRedeem(v, p, _loose(p, 30 days));
        uint256 eta = p.pendingConfig().eta;
        assertGe(eta, t1 + 31 days, "the loosening waits the 30 day epoch plus a day");
        _warp(t1 + 30 days - 1);
        _assertNoSelfHelp(v);
        _warp(t1 + 30 days);
        vm.prank(alice);
        v.triggerEmergency();
        vm.prank(platformSentinel);
        v.settle();
        assertApproxEqAbs(_paidAlice(v), ALICE_IN, 20e6, "paid at the old risk");
        assertLt(vm.getBlockTimestamp(), eta);
    }
}
