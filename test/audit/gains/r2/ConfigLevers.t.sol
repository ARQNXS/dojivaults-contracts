// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {GovBase} from "../gov/GovBase.t.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {GainsVaultFactory} from "../../../../src/gains/GainsVaultFactory.sol";
import {GainsVault} from "../../../../src/gains/GainsVault.sol";
import {GainsVaultPolicy} from "../../../../src/gains/GainsVaultPolicy.sol";
import {GainsPrice} from "../../../../src/gains/GainsPrice.sol";
import {IGainsVaultErrors as E} from "../../../../src/gains/GainsTypes.sol";
import {MockChainlinkFeed} from "../../../gains/mocks/GainsMocks.sol";

/// @notice Gains round 2, domain CFG, questions 3 and 4: what every factory setter does to an EXISTING vault, and the
///         policy's configuration rules (tighten / loosen classification, disallowAsset on open trades, cancel rights,
///         the 14 day windows, independent timelocks).
contract ConfigLeversTest is GovBase {
    // ==================================================================
    // Question 3: factory levers on an existing vault
    // ==================================================================
    /// Every factory owner setter, run against a funded vault with an open trade. Only four things reach it, all
    /// read live: guardian(), sentinel() (instant role rotation), protocolFeeRecipient (who receives the protocol's
    /// fee shares at the next accrual) and lowerProtocolShare (down only). Prices, sequencer feed, protocol share,
    /// deposit cap and allowlist stay what the vault snapshotted; the depositor's exit is unchanged.
    function test_GR2_CFG_factorySettersReachExistingVaultOnlyThroughLiveRoles() public {
        // a hosted vault with fees, alice in, one ETH trade open
        GainsVaultFactory.CreateParams memory c = _cparams(launcher, bytes32(uint256(201)), address(0));
        c.managementFeeBps = 200;
        c.performanceFeeBps = 2_000;
        vm.prank(launcher);
        (address va, address pa) = platform.create(c, _noPermit());
        GainsVault v = GainsVault(va);
        GainsVaultPolicy p = GainsVaultPolicy(pa);
        vm.prank(alice);
        usdc.approve(va, type(uint256).max);
        vm.prank(alice);
        v.requestDeposit(10_000e6, alice);
        _ageEpoch(v);
        v.checkRisk();
        vm.prank(keeper);
        v.settle();
        v.claim(alice);
        uint32 idx = _open(v, ETH, true, 2_000e6, 2_000);

        uint16 shareBefore = v.protocolShareBps();
        GainsPrice.Feed memory ethBefore = p.feedOf(ETH);
        address seqBefore = p.sequencerFeed();
        uint256 capBefore = v.depositCap();
        uint256 navBefore = v.totalAssets();
        assertEq(shareBefore, 3_300, "hosted share locked at create");

        // --- future-vault-only settings
        MockChainlinkFeed seq2 = new MockChainlinkFeed(0, 0);
        seq2.setStatus(0, START - 30 days);
        MockChainlinkFeed eth2 = new MockChainlinkFeed(8, 2_000e8); // a feed that would misprice ETH by a third
        address treasury2 = makeAddr("treasury2");
        vm.startPrank(platformOwner);
        platform.setShares(5_000, 5_000);
        platform.setMinSeedUsdc(1e12);
        platform.setMinAgentGas(1 ether);
        platform.setLauncherAllowed(launcher, false);
        platform.setOpenLaunch(false);
        platform.setSequencerFeed(address(seq2), 2 hours);
        platform.setAssetCurated(ETH, true, address(eth2), BTC_MAX_AGE, 50);
        vm.stopPrank();
        assertEq(v.protocolShareBps(), shareBefore, "setShares: future vaults only");
        assertEq(p.sequencerFeed(), seqBefore, "setSequencerFeed: adopted only through the vault's own queue");
        assertEq(p.feedOf(ETH).feed, ethBefore.feed, "re-curation: the vault keeps the feed it copied");
        assertEq(p.feedOf(ETH).bandBps, ethBefore.bandBps);
        assertEq(v.totalAssets(), navBefore, "NAV unchanged by any curation change");

        // --- de-curation: the vault keeps trading and valuing the pair; only rotation and re-allowing stop
        vm.prank(platformOwner);
        platform.setAssetCurated(ETH, false, address(0), 0, 0);
        assertTrue(p.isAssetAllowed(ETH), "de-curation does not disallow the pair in an existing vault (N-13)");
        assertEq(v.totalAssets(), navBefore, "still valued at the snapshotted feed");
        uint32 idx2 = _open(v, ETH, true, 1_000e6, 2_000); // new risk on a de-curated pair is still accepted
        vm.prank(c.owner);
        vm.expectRevert(abi.encodeWithSelector(GainsVaultPolicy.AssetNotCurated.selector, uint32(ETH)));
        p.queueAllowAsset(ETH);

        // --- platform maximum lowered below the vault's cap: existing cap and deposits unchanged, re-setting it refused
        vm.prank(platformOwner);
        platform.setMaxDepositCap(1);
        assertEq(v.depositCap(), capBefore);
        vm.prank(bob);
        usdc.approve(va, type(uint256).max);
        vm.prank(bob);
        v.requestDeposit(5_000e6, bob);
        assertEq(v.pendingDepositAssets(), 5_000e6, "deposits still accepted up to the old cap");
        vm.prank(c.owner);
        vm.expectRevert(E.CapExceeded.selector);
        v.setDepositCap(capBefore);
        vm.prank(bob);
        v.cancelDepositRequest();

        // --- live reads: guardian, sentinel, protocol fee recipient
        address g2 = makeAddr("guardian2");
        address s2 = makeAddr("sentinel2");
        vm.startPrank(platformOwner);
        platform.setGuardian(g2);
        platform.setSentinel(s2);
        platform.setProtocolFeeRecipient(treasury2);
        vm.stopPrank();
        assertEq(v.guardian(), g2, "guardian rotated for every vault at once");
        assertEq(v.sentinel(), s2, "sentinel rotated for every vault at once");
        vm.prank(platformSentinel);
        vm.expectRevert(E.Unauthorized.selector);
        v.triggerBreach();
        bytes memory d = abi.encodeCall(GainsVault.setManager, (address(0xBEEF)));
        vm.prank(c.owner);
        bytes32 id = v.queue(d);
        vm.prank(platformGuardian);
        vm.expectRevert(E.Unauthorized.selector);
        v.cancel(id);
        vm.prank(g2);
        v.cancel(id);
        uint256 oldTreasury = v.balanceOf(protocolTreasury);
        _skip(30 days);
        v.accrueFees();
        assertGt(v.balanceOf(treasury2), 0, "protocol fee shares follow the new recipient at the next accrual");
        assertEq(v.balanceOf(protocolTreasury), oldTreasury, "nothing more to the old recipient");

        // --- protocol share: down only
        vm.prank(platformOwner);
        platform.lowerProtocolShare(va, 1_000);
        assertEq(v.protocolShareBps(), 1_000);
        vm.prank(platformOwner);
        vm.expectRevert(E.InvalidShare.selector);
        platform.lowerProtocolShare(va, 2_000);

        // --- the exit: alice redeems, the manager closes, the keeper settles normally, alice is paid
        uint256 shares = v.balanceOf(alice);
        vm.prank(alice);
        v.requestRedeem(shares, alice, alice);
        _passHold(); // GR2-KEY-01b: the manager's exit waits out the minimum hold
        _closeFilled(v, idx, _px(ETH));
        _closeFilled(v, idx2, _px(ETH));
        v.checkRisk();
        vm.prank(keeper);
        v.settle();
        uint256 before = usdc.balanceOf(alice);
        v.claim(alice);
        assertGt(usdc.balanceOf(alice) - before, 9_900e6, "exit unaffected by every factory change");
    }

    /// registerPlatformAgent / unregisterPlatformAgent on an existing vault: binding gives no power by itself (the
    /// vault owner must still setAgent through the timelock, which the guardian may cancel); the hot registrar cannot
    /// stop a live agent (LiveAgent), a platform role can, instantly (risk reducing).
    function test_GR2_CFG_agentRegistrationOnExistingVault() public {
        address agentX = makeAddr("agentX");
        vm.prank(registrar);
        platform.registerPlatformAgent(agentX, address(fv));
        assertEq(fv.agent(), agentA, "registration does not touch the vault");
        bytes memory d = abi.encodeCall(GainsVault.setAgent, (agentX));
        vm.prank(fvOwner);
        bytes32 id = fv.queue(d);
        vm.prank(platformGuardian);
        fv.cancel(id); // the platform can veto a vault-queue item
        vm.expectRevert(E.NotQueued.selector);
        fv.execute(d);
        vm.prank(registrar);
        vm.expectRevert(abi.encodeWithSelector(GainsVaultFactory.LiveAgent.selector, agentA, address(fv)));
        platform.unregisterPlatformAgent(agentA);
        vm.prank(platformSentinel);
        platform.unregisterPlatformAgent(agentA);
        assertEq(fv.agent(), address(0), "a platform role revokes the live agent at once");
    }

    // ==================================================================
    // Question 4: policy configuration
    // ==================================================================
    /// _isTighter, one field at a time: the tight direction applies at once, the loose direction queues. Raising
    /// maxNavMoveBps is the tight direction (N-03, known: C-01 residual).
    function test_GR2_CFG_isTighterFieldByField() public {
        for (uint256 f; f < 8; ++f) {
            for (uint256 dir; dir < 2; ++dir) {
                uint256 snap = vm.snapshotState();
                GainsVaultPolicy.RiskConfig memory c = fp.config();
                if (f == 7) {
                    // the default sits at the 3% hard cap: step it down first (instant) so the loose move is valid
                    c.maxFlattenSlippageBps = 200;
                    vm.prank(fvOwner);
                    fp.proposeConfig(c);
                }
                bool tight = dir == 0;
                uint256 notice = fp.noticeEta(); // exit before effect: max(timelock, epoch + 1 day)
                if (f == 0) c.maxLeverageBps = tight ? c.maxLeverageBps - 1 : c.maxLeverageBps + 1;
                if (f == 1) c.maxDailyLossBps = tight ? c.maxDailyLossBps - 1 : c.maxDailyLossBps + 1;
                if (f == 2) c.maxDrawdownBps = tight ? c.maxDrawdownBps - 1 : c.maxDrawdownBps + 1;
                if (f == 3) c.maxSlippageBps = tight ? c.maxSlippageBps - 1 : c.maxSlippageBps + 1;
                if (f == 4) c.maxOrderNotional = tight ? c.maxOrderNotional - 1 : c.maxOrderNotional + 1;
                if (f == 5) c.maxEpochDuration = tight ? c.maxEpochDuration - 1 : c.maxEpochDuration + 1;
                if (f == 6) c.maxNavMoveBps = tight ? c.maxNavMoveBps + 1 : c.maxNavMoveBps - 1; // reversed
                if (f == 7) c.maxFlattenSlippageBps = tight ? c.maxFlattenSlippageBps - 1 : c.maxFlattenSlippageBps + 1;
                vm.prank(fvOwner);
                fp.proposeConfig(c);
                if (tight) {
                    assertFalse(fp.pendingConfig().exists, "tight: applied at once");
                    assertEq(keccak256(abi.encode(fp.config())), keccak256(abi.encode(c)));
                } else {
                    assertTrue(fp.pendingConfig().exists, "loose: queued");
                    assertEq(uint256(fp.pendingConfig().eta), notice);
                    assertGe(notice, vm.getBlockTimestamp() + fp.timelockDelay(), "never shorter than the timelock");
                }
                vm.revertToState(snap);
            }
        }
    }

    /// disallowAsset (instant, owner) with a trade open on the pair: the trade keeps its price and value, exits
    /// work, every new exposure on the pair is refused, adding margin (leverage decrease) is still allowed, and a
    /// queued re-allow is dropped; allowing again takes the policy timelock.
    function test_GR2_CFG_disallowAssetWithOpenTrade() public {
        _fundFv(10_000e6);
        uint32 idx = _openFv(ETH, 2_000e6, 2_000);
        uint256 nav = fv.totalAssets();
        vm.prank(fvOwner);
        fp.disallowAsset(ETH);
        assertEq(fv.totalAssets(), nav, "valued as before (feed kept)");
        vm.prank(fvManager);
        vm.expectRevert(abi.encodeWithSelector(E.OrderRejected.selector, "asset not allowed"));
        fv.increaseTrade(idx, 100e6, 1_000, _px(ETH), SLIP);
        vm.prank(fvManager);
        vm.expectRevert(abi.encodeWithSelector(E.OrderRejected.selector, "asset not allowed"));
        fv.updateLeverage(idx, 3_000);
        vm.prank(fvManager);
        vm.expectRevert(abi.encodeWithSelector(E.OrderRejected.selector, "asset not allowed"));
        fv.openTrade(_params(ETH, true, 1_000e6, 2_000));
        vm.prank(fvManager);
        fv.updateLeverage(idx, 1_500); // more margin: allowed (risk reducing)
        _fillLast(fv, _px(ETH));
        _passHold();
        _closeFilled(fv, idx, _px(ETH));
        // re-allow: timelocked, and a later disallow drops the queued allow
        vm.prank(fvOwner);
        fp.queueAllowAsset(ETH);
        vm.prank(fvOwner);
        fp.disallowAsset(ETH);
        assertEq(fp.assetAllowEta(ETH), 0);
        _skip(2 days);
        vm.expectRevert(GainsVaultPolicy.NothingPending.selector);
        fp.allowAsset(ETH);
    }

    /// Who may cancel what. Vault queue: owner or guardian. Policy: only the owner, for every kind of pending item
    /// (config, allowAsset via disallowAsset, timelock lowering via re-proposing the current value). The platform's
    /// only counter to a queued policy loosening is a full stop (triggerBreach / triggerEmergency).
    function test_GR2_CFG_cancelRights() public {
        GainsVaultPolicy.RiskConfig memory c = fp.config();
        c.maxLeverageBps += 10_000;
        vm.startPrank(fvOwner);
        fp.proposeConfig(c);
        fp.queueAllowAsset(SOL);
        fp.proposeTimelockDelay(1 days);
        vm.stopPrank();
        assertTrue(fp.pendingConfig().exists);
        assertGt(fp.assetAllowEta(SOL), 0);
        assertGt(fp.pendingTimelockEta(), 0);
        address[2] memory platformRoles = [platformGuardian, platformSentinel];
        for (uint256 i; i < 2; ++i) {
            vm.prank(platformRoles[i]);
            vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, platformRoles[i]));
            fp.cancelPendingConfig();
            vm.prank(platformRoles[i]);
            vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, platformRoles[i]));
            fp.disallowAsset(SOL);
            vm.prank(platformRoles[i]);
            vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, platformRoles[i]));
            fp.proposeTimelockDelay(2 days);
        }
        // the owner can drop each one
        vm.startPrank(fvOwner);
        fp.cancelPendingConfig();
        fp.disallowAsset(SOL);
        fp.proposeTimelockDelay(2 days); // >= current: applied at once, clears the pending lowering
        vm.stopPrank();
        assertFalse(fp.pendingConfig().exists);
        assertEq(fp.assetAllowEta(SOL), 0);
        assertEq(fp.pendingTimelockEta(), 0);
        // the platform's counter to a loosening it cannot cancel: a full stop, which the loosening does not lift
        vm.prank(fvOwner);
        fp.proposeConfig(c);
        vm.prank(platformSentinel);
        fv.triggerBreach();
        _warp(fp.pendingConfig().eta);
        fp.applyPendingConfig();
        vm.prank(fvManager);
        vm.expectRevert(E.ReduceOnlyMode.selector);
        fv.openTrade(_params(ETH, true, 1_000e6, 2_000));
    }

    /// GR2-CFG-03 (Info). queueAllowAsset on a pair the policy ALREADY allows is accepted, and its execution copies
    /// the factory's current feed and band: a second feed-rotation path next to setPairFeed. setPairFeed sits in the
    /// vault queue, which the guardian can cancel; this one sits in the policy, which only the owner can cancel.
    function test_GR2_CFG_03_reAllowOfAnAllowedPairRotatesTheFeed_guardianCannotCancel() public {
        _fundFv(10_000e6);
        _openFv(ETH, 3_000e6, 5_000); // 15k notional
        uint256 navBefore = fv.totalAssets();
        MockChainlinkFeed eth2 = new MockChainlinkFeed(8, 3_000e8);
        vm.prank(platformOwner);
        platform.setAssetCurated(ETH, true, address(eth2), BTC_MAX_AGE, 30); // new feed, wider band
        assertTrue(fp.isAssetAllowed(ETH));
        vm.prank(fvOwner);
        fp.queueAllowAsset(ETH); // accepted although ETH is allowed
        vm.prank(platformGuardian);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, platformGuardian));
        fp.disallowAsset(ETH); // the only way to drop the queued allow is the owner's
        _warp(fp.assetAllowEta(ETH));
        eth2.set(3_000e8, vm.getBlockTimestamp());
        vm.prank(stranger);
        fp.allowAsset(ETH);
        assertEq(fp.feedOf(ETH).feed, address(eth2), "feed rotated through allowAsset");
        assertEq(fp.feedOf(ETH).bandBps, 30);
        assertLt(fv.totalAssets(), navBefore, "band 20 -> 30 bps steps NAV down (GR1-35 class)");
    }

    /// The four queues share one 14 day window after their own stored eta, and anyone executes inside it. Exit
    /// before effect: the config and the asset allow wait the notice (epoch + 1 day or more), the timelock lowering
    /// the current timelock, the vault queue its own stored eta.
    function test_GR2_CFG_graceWindowsAllFourQueues() public {
        GainsVaultPolicy.RiskConfig memory c = fp.config();
        c.maxLeverageBps += 10_000;
        bytes memory d = abi.encodeCall(GainsVault.setFeeRecipient, (address(0xFEE)));
        vm.startPrank(fvOwner);
        fp.proposeConfig(c);
        fp.queueAllowAsset(SOL);
        fp.proposeTimelockDelay(1 days);
        fv.queue(d);
        vm.stopPrank();
        uint256[4] memory eta =
            [uint256(fp.pendingConfig().eta), fp.assetAllowEta(SOL), fp.pendingTimelockEta(), fv.queuedEta(keccak256(d))];
        for (uint256 i; i < 4; ++i) {
            assertGt(eta[i], 0);
            uint256 snap = vm.snapshotState();
            _warp(eta[i] + 14 days);
            vm.prank(stranger);
            _runQueue(i, d);
            vm.revertToState(snap);
            snap = vm.snapshotState();
            _warp(eta[i] + 14 days + 1);
            if (i == 3) vm.expectRevert(E.Expired.selector);
            else vm.expectRevert(GainsVaultPolicy.Expired.selector);
            _runQueue(i, d);
            vm.revertToState(snap);
        }
    }

    function _runQueue(uint256 i, bytes memory d) internal {
        if (i == 0) fp.applyPendingConfig();
        else if (i == 1) fp.allowAsset(SOL);
        else if (i == 2) fp.applyTimelockDelay();
        else fv.execute(d);
    }

    /// The vault's timelock and the policy's timelock start equal but are separate: the owner raises the policy's
    /// instantly (to 30 days) while the vault queue stays at 2 days, and raising the vault's is itself queued.
    function test_GR2_CFG_vaultAndPolicyTimelocksAreIndependent() public {
        vm.prank(fvOwner);
        fp.proposeTimelockDelay(30 days);
        assertEq(fp.timelockDelay(), 30 days, "policy: raising is instant");
        assertEq(fv.timelockDelay(), 2 days, "vault queue unchanged");
        bytes memory up = abi.encodeCall(GainsVault.setTimelockDelay, (30 days));
        vm.prank(fvOwner);
        fv.queue(up);
        vm.expectRevert(E.NotReady.selector);
        fv.execute(up);
        assertGe(fv.queuedEta(keccak256(up)), vm.getBlockTimestamp() + 2 days, "at least the vault's own delay");
        _warp(fv.queuedEta(keccak256(up)));
        fv.execute(up);
        assertEq(fv.timelockDelay(), 30 days, "vault: raising waits the old delay");
        // lowering either takes the current (30 day) delay
        vm.prank(fvOwner);
        fp.proposeTimelockDelay(1 days);
        assertEq(fp.pendingTimelockEta(), vm.getBlockTimestamp() + 30 days);
    }
}
