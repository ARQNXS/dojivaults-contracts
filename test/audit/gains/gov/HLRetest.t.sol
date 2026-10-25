// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {GovBase} from "./GovBase.t.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {GainsVault} from "../../../../src/gains/GainsVault.sol";
import {GainsVaultFactory} from "../../../../src/gains/GainsVaultFactory.sol";
import {GainsVaultPolicy} from "../../../../src/gains/GainsVaultPolicy.sol";
import {IGainsVaultErrors as E, OpenParams, operatorReduceCap} from "../../../../src/gains/GainsTypes.sol";
import {BreachReason} from "../../../../src/VaultTypes.sol";
import {MockChainlinkFeed} from "../../../gains/mocks/GainsMocks.sol";

/// @notice Task 5: retests of past HL finding classes on Gains (HL-RETEST.md has one row per id; this file holds the
///         ones not already covered by test/gains/* or the other files of this directory). Each test asserts the
///         FIXED behaviour, i.e. it passes when the class "holds", unless its name says GOV-xx (a PoC).
contract GovHLRetestTest is GovBase {
    // ------------------------------------------------------------------ H-01: what the owner can do without a timelock
    function test_HL_H01_ownerInstantPowersAreTheListedOnes() public {
        // instant: setOperator, unpause after a sentinel pause, deposit cap, lowerFees, policy tightening (incl.
        // maxNavMoveBps up), disallowAsset, policy timelock raise; triggerBreach / triggerEmergency
        vm.prank(platformSentinel);
        fv.setTradingPaused(true);
        vm.startPrank(fvOwner);
        fv.setTradingPaused(false);
        fv.setOperator(stranger);
        fv.setDepositCap(1_000e6);
        vm.stopPrank();
        assertEq(fv.operator(), stranger);
        // not instant: clearBreach, setAgent, exitEmergency, setManager, setFees (direct calls refused)
        vm.startPrank(fvOwner);
        vm.expectRevert(E.Unauthorized.selector);
        fv.clearBreach();
        vm.expectRevert(E.Unauthorized.selector);
        fv.setAgent(agentA);
        vm.expectRevert(E.Unauthorized.selector);
        fv.exitEmergency();
        vm.expectRevert(E.Unauthorized.selector);
        fv.setManager(stranger);
        vm.expectRevert(E.Unauthorized.selector);
        fv.setFees(0, 0);
        vm.expectRevert(E.Unauthorized.selector);
        fv.setPairFeed(ETH, address(ethFeed), BTC_MAX_AGE, 20);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------ N-05: lowerFees(current, current)
    function test_HL_N05_lowerFeesCurrentNeverCrystallisesPerformance() public {
        uint32 idx = _fundVenue(10_000e6);
        vm.prank(owner);
        vm.expectRevert(E.InvalidFee.selector);
        vault.lowerFees(200, 2_000);
        // a scheduled perf raise exists: lowerFees(current, current) is allowed and drops it ...
        _timelocked(vault, abi.encodeCall(GainsVault.setFees, (200, 3_000)));
        assertEq(vault.pendingPerformanceFeeBps(), 3_000);
        // ... after a 10% gain, it charges no performance fee and does not move the HWM (N-05 / N-08)
        _setVenueValue(vault, idx, 11_000e6);
        uint256 hwm = vault.highWaterMark();
        uint256 before = vault.balanceOf(feeRecipient);
        vm.prank(owner);
        vault.lowerFees(200, 2_000);
        assertEq(vault.pendingPerformanceFeeBps(), 0);
        assertEq(vault.highWaterMark(), hwm, "HWM unchanged");
        // only the management fee for the elapsed time (2 days at 2%/yr on ~11,000 = ~1.2 USDC of shares)
        uint256 minted = vault.balanceOf(feeRecipient) - before;
        assertLt(vault.convertToAssets(minted), 2e6, "no performance fee (would be ~200 USDC)");
    }

    // ------------------------------------------------------------------ N-06: roles read live, rotation mid-emergency
    function test_HL_N06_guardianRotatedMidEmergency() public {
        vm.prank(fvOwner);
        fv.triggerEmergency();
        address g2 = makeAddr("g2");
        vm.prank(platformOwner);
        platform.setGuardian(g2);
        vm.prank(platformGuardian);
        vm.expectRevert(E.Unauthorized.selector);
        fv.exitEmergency();
        vm.prank(g2);
        fv.exitEmergency();
        assertFalse(fv.emergency());
        // the old sentinel loses its powers the same way
        address s2 = makeAddr("s2");
        vm.prank(platformOwner);
        platform.setSentinel(s2);
        vm.prank(platformSentinel);
        vm.expectRevert(E.Unauthorized.selector);
        fv.triggerBreach();
        vm.prank(s2);
        fv.triggerBreach();
    }

    // ------------------------------------------------------------------ N-07 / GOV-02: one agent per vault?
    /// GOV-02 PoC: registerPlatformAgent for an EXISTING vault never checks agentOfVault (GainsVaultFactory.sol:336
    /// only guards non-vaults), so the registrar binds any number of agents to one vault and overwrites agentOfVault;
    /// unregistering the newest deletes agentOfVault while the vault's live agent is still trading. SPEC L2 "one agent
    /// per vault" does not hold for existing vaults; agentOfVault is not a reliable "agent of this vault" view.
    function test_GOV_02_manyAgentsPerVault_agentOfVaultDesyncs() public {
        address x = makeAddr("x");
        address y = makeAddr("y");
        vm.startPrank(registrar);
        platform.registerPlatformAgent(x, address(fv));
        platform.registerPlatformAgent(y, address(fv));
        vm.stopPrank();
        assertEq(platform.platformAgentFor(agentA), address(fv));
        assertEq(platform.platformAgentFor(x), address(fv));
        assertEq(platform.platformAgentFor(y), address(fv));
        assertEq(platform.agentOfVault(address(fv)), y, "overwritten twice");
        vm.prank(registrar);
        platform.unregisterPlatformAgent(y);
        assertEq(platform.agentOfVault(address(fv)), address(0), "view says: no agent");
        assertEq(fv.agent(), agentA, "but the live agent still trades");
        // the owner can still switch to x (bound), through the timelock only
        _timelocked(fv, abi.encodeCall(GainsVault.setAgent, (x)));
        assertEq(fv.agent(), x);
        // and agentA, superseded but still registered, can be set back the same way (no one-way rotation)
        _timelocked(fv, abi.encodeCall(GainsVault.setAgent, (agentA)));
        assertEq(fv.agent(), agentA);
    }

    // ------------------------------------------------------------------ I-03 / V-03: renounce
    function test_HL_I03_V03_renounce() public {
        vm.prank(fvOwner);
        vm.expectRevert(E.Unauthorized.selector);
        fv.renounceOwnership();
        vm.prank(platformOwner);
        vm.expectRevert(GainsVaultFactory.RolesCollide.selector);
        platform.renounceOwnership();
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        platform.renounceOwnership();
        // the policy no longer has it either (GR1-30, Governance.t.sol test_GR1_30_*): its owner is the vault's
        vm.prank(fvOwner);
        vm.expectRevert(GainsVaultPolicy.OwnershipFollowsVault.selector);
        fp.renounceOwnership();
        assertEq(fp.owner(), fvOwner);
    }

    // ------------------------------------------------------------------ W-01 / W-01b: the owner never exits emergency
    function test_HL_W01_ownerHasNoExitPath() public {
        vm.prank(fvOwner);
        fv.triggerEmergency();
        vm.prank(fvOwner);
        vm.expectRevert(E.Unauthorized.selector);
        fv.exitEmergency();
        vm.prank(fvOwner);
        vm.expectRevert(E.Unauthorized.selector);
        fv.queue(abi.encodeCall(GainsVault.exitEmergency, ()));
        vm.prank(platformSentinel);
        vm.expectRevert(E.Unauthorized.selector);
        fv.exitEmergency();
        vm.prank(keeper);
        vm.expectRevert(E.Unauthorized.selector);
        fv.exitEmergency();
    }

    // ------------------------------------------------------------------ R3-03: a second emergency restarts breachedAt
    function test_HL_R303_secondEmergencyInvalidatesClearQueuedAfterTheFirst() public {
        vm.prank(fvOwner);
        fv.triggerEmergency();
        _skip(1);
        bytes memory c = abi.encodeCall(GainsVault.clearBreach, ());
        vm.prank(fvOwner);
        fv.queue(c);
        vm.prank(platformGuardian);
        fv.exitEmergency();
        assertTrue(fv.breached(), "full stop stays after the exit");
        _skip(1 hours);
        vm.prank(stranger); // not overdue: refused
        vm.expectRevert(E.NotOverdue.selector);
        fv.triggerEmergency();
        vm.prank(platformGuardian);
        fv.triggerEmergency();
        vm.prank(platformGuardian);
        fv.exitEmergency();
        _skip(2 days);
        vm.expectRevert(E.NotReady.selector);
        fv.execute(c);
    }

    // ------------------------------------------------------------------ R3-06 after GR2-ECON-03: a leverage-breach settle
    // charges the performance fee like a normal settle (it mints deposits), so it also switches a scheduled raise on;
    // a loss-breach or emergency settle still does neither (GR2-ECON-03 fix test).
    function test_HL_R306_leverageBreachSettleSwitchesTheRaiseLikeANormalSettle() public {
        uint32 idx = _fundVenue(10_000e6);
        _timelocked(vault, abi.encodeCall(GainsVault.setFees, (200, 3_000)));
        assertEq(vault.pendingPerformanceFeeBps(), 3_000);
        // a leverage breach (vault leverage 4x > 3x): settle runs normally, charges at the old rate, then switches
        diamond.setTradeSize(address(vault), idx, 4_000, _px(ETH));
        vault.checkRisk();
        assertEq(uint8(vault.breachReason()), uint8(BreachReason.LEVERAGE));
        vm.prank(manager);
        vault.settle();
        assertEq(vault.pendingPerformanceFeeBps(), 0, "raise switched on by the charging settle");
        assertEq(vault.performanceFeeBps(), 3_000);
    }

    // ------------------------------------------------------------------ R3-04 analog: idle needed by redemptions into margin
    /// idleAssets() does not reserve PENDING redemptions (GainsVaultMath.sol:102-106), so outside a breach the manager
    /// can put the USDC redemptions need into a trade; the normal settle then reverts InsufficientLiquidity. Holds as on
    /// HL (bridgeToCore outside a breach): the operator frees it again without the manager (cap = the new shortfall).
    function test_HL_R304_idleOfPendingRedemptionsIntoMarginRecoverableByOperator() public {
        _fundFv(10_000e6);
        uint256 shares = fv.balanceOf(alice) / 2;
        vm.prank(alice);
        fv.requestRedeem(shares, alice, alice);
        assertEq(fv.redemptionShortfall(), 0, "all idle");
        uint32 idx = _openFv(ETH, 9_000e6, 2_000);
        fv.checkRisk();
        vm.prank(keeper);
        vm.expectRevert();
        fv.settle(); // InsufficientLiquidity
        uint256 s = fv.redemptionShortfall();
        assertGt(s, 3_900e6);
        vm.prank(keeper);
        fv.reduceTrade(idx, uint120(operatorReduceCap(s)), 0, _px(ETH));
        _fillLast(fv, _px(ETH));
        vm.prank(keeper);
        fv.settle();
        assertEq(fv.pendingRedeemShares(), 0);
    }

    // ------------------------------------------------------------------ I3-02: insider deposit for a victim controller
    /// GR1-32 (was test_HL_I302_insiderDepositForVictimBlocksItsRedeemUntilSettle, a PoC: cancelling the deferred
    /// deposit kept r.epoch = current + 1, so the victim's redemption stayed RequestPending until the next settle).
    /// Now the cancel resets the request to the current epoch and the redemption goes in at once.
    function test_GR1_32_cancelledDeferredDepositLiftsTheRedeemBlock() public {
        _fundFv(10_000e6);
        usdc.mint(fvManager, 10e6);
        vm.prank(fvManager);
        usdc.approve(address(fv), 10e6);
        vm.prank(fvManager);
        fv.requestDeposit(10e6, alice); // controller = alice, priced next epoch (insider sender)
        assertEq(fv.deferredDepositAssets(), 10e6);
        uint256 sh = fv.balanceOf(alice);
        vm.prank(alice);
        vm.expectRevert(E.RequestPending.selector);
        fv.requestRedeem(sh, alice, alice);
        // alice cancels it (it is her request; the 10 USDC go to her): the request is back in the current epoch
        uint256 bal = usdc.balanceOf(alice);
        vm.prank(alice);
        fv.cancelDepositRequest();
        assertEq(usdc.balanceOf(alice), bal + 10e6);
        assertEq(fv.deferredDepositAssets(), 0);
        (uint256 epoch, uint256 dep,) = fv.requests(alice);
        assertEq(epoch, fv.currentEpoch(), "reset to the current epoch");
        assertEq(dep, 0);
        // the redemption goes in at once, no settle needed, and settles normally
        vm.prank(alice);
        fv.requestRedeem(sh, alice, alice);
        assertEq(fv.pendingRedeemShares(), sh);
        fv.checkRisk();
        vm.prank(keeper);
        fv.settle();
        assertEq(fv.pendingRedeemShares(), 0);
    }

    // ------------------------------------------------------------------ I-06 / I2-05: creator-chosen operator
    /// The factory checks guardian / sentinel / registrar / owner collisions, not the creator-chosen operator, fee
    /// recipient or vault owner: a creator may name a platform hot key (sentinel) its operator. Holds as on HL; the
    /// sentinel then also settles normally and reduces up to the cap on that vault (its own risk-reducing role grows).
    function test_HL_I06_creatorMayNameThePlatformSentinelOperator() public {
        GainsVaultFactory.CreateParams memory p = _cparams(launcher, bytes32(uint256(77)), address(0));
        p.operator = platformSentinel;
        p.owner = platformGuardian;
        vm.prank(launcher);
        (address va,) = platform.create(p, _noPermit());
        assertEq(GainsVault(va).operator(), platformSentinel);
        assertEq(GainsVault(va).owner(), platformGuardian);
    }

    // ------------------------------------------------------------------ M-03: setPairFeed through the vault expires
    function test_HL_M03_rotationExpires() public {
        MockChainlinkFeed f2 = new MockChainlinkFeed(8, 3_000e8);
        vm.prank(platformOwner);
        platform.setAssetCurated(ETH, true, address(f2), BTC_MAX_AGE, 20);
        bytes memory d = abi.encodeCall(GainsVault.setPairFeed, (ETH, address(f2), BTC_MAX_AGE, 20));
        vm.prank(owner);
        vault.queue(d);
        _warp(vault.queuedEta(keccak256(d)) + 14 days + 1); // hl-r2 exit-before-effect: wait for the stored eta
        vm.expectRevert(E.Expired.selector);
        vault.execute(d);
    }

    // ------------------------------------------------------------------ L-06 / I-08 analog: no Gains delegate, revoke is sync
    function test_HL_I08_noVenueSideAuthoritySurvivesARevoke() public {
        _fundFv(10_000e6);
        _openFv(ETH, 1_000e6, 2_000);
        assertEq(diamond.getTradingDelegate(address(fv)), address(0), "the vault never sets a Gains delegate");
        vm.prank(platformSentinel);
        fv.revokeAgent();
        OpenParams memory o = _params(ETH, true, 100e6, 2_000);
        vm.prank(agentA);
        vm.expectRevert(E.Unauthorized.selector);
        fv.openTrade(o);
    }

    // ------------------------------------------------------------------ N-10 / I2-02: guardian stop and stranger settle
    function test_HL_N10_I202_settleGates() public {
        _fundFv(10_000e6);
        vm.prank(platformSentinel);
        fv.triggerBreach();
        vm.prank(keeper);
        vm.expectRevert(E.ReduceOnlyMode.selector);
        fv.settle();
        vm.prank(stranger);
        vm.expectRevert(E.Unauthorized.selector);
        fv.settle();
        vm.prank(alice);
        vm.expectRevert(E.Unauthorized.selector);
        fv.settle();
    }

    // ------------------------------------------------------------------ N-03: tighten / loosen direction of maxNavMoveBps
    function test_HL_N03_navMoveDirectionAndFloor() public {
        GainsVaultPolicy.RiskConfig memory c = _defaultRisk();
        c.maxNavMoveBps = 500; // lower = loosening for liveness: queued
        vm.prank(owner);
        policy.proposeConfig(c);
        assertEq(policy.maxNavMoveBps(), 2_000);
        c.maxNavMoveBps = 499;
        vm.prank(owner);
        vm.expectRevert(GainsVaultPolicy.InvalidConfig.selector);
        policy.proposeConfig(c);
    }
}
