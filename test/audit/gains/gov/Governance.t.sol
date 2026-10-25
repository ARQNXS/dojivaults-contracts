// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {GovBase} from "./GovBase.t.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IGainsDiamond} from "../../../../src/gains/IGainsDiamond.sol";
import {GainsVaultFactory} from "../../../../src/gains/GainsVaultFactory.sol";
import {GainsVault} from "../../../../src/gains/GainsVault.sol";
import {GainsVaultPolicy} from "../../../../src/gains/GainsVaultPolicy.sol";
import {GainsPrice} from "../../../../src/gains/GainsPrice.sol";
import {IGainsVaultErrors as E} from "../../../../src/gains/GainsTypes.sol";
import {BreachReason} from "../../../../src/VaultTypes.sol";
import {MockChainlinkFeed} from "../../../gains/mocks/GainsMocks.sol";

/// @notice Owner timelock (queue / execute / cancel / expiry / exact lengths / dirty bits / duplicate ids), breach
///         clear rules (N-04 class), resume, feed rotation, policy loosening, and the policy's separate ownership.
contract GovGovernanceTest is GovBase {
    function _mgr() internal pure returns (bytes memory) {
        return abi.encodeCall(GainsVault.setManager, (address(0xBEEF)));
    }

    // ==================================================================
    // queue
    // ==================================================================
    function test_GOV_TL_queue_ownerOnly_exactSelectorsAndLengths() public {
        address[5] memory nope = [stranger, manager, guardian, feeRecipient, alice];
        for (uint256 i; i < nope.length; ++i) {
            vm.prank(nope[i]);
            vm.expectRevert(E.Unauthorized.selector);
            vault.queue(_mgr());
        }
        bytes[8] memory ok = [
            abi.encodeCall(GainsVault.setManager, (address(1))),
            abi.encodeCall(GainsVault.setFeeRecipient, (address(1))),
            abi.encodeCall(GainsVault.setTimelockDelay, (3 days)),
            abi.encodeCall(GainsVault.setAgent, (address(1))),
            abi.encodeCall(GainsVault.setFees, (100, 100)),
            abi.encodeCall(GainsVault.clearBreach, ()),
            abi.encodeCall(GainsVault.setPairFeed, (ETH, address(1), 1, 1)),
            abi.encodeCall(GainsVault.setSequencerFeed, (address(sequencer), SEQ_GRACE)) // GR1-10, GV-03
        ];
        uint256[8] memory len = [uint256(36), 36, 36, 36, 68, 4, 132, 68];
        for (uint256 i; i < ok.length; ++i) {
            assertEq(ok[i].length, len[i]);
            vm.prank(owner);
            vault.queue(ok[i]);
            // one byte more, one byte less, a padding word: refused
            vm.prank(owner);
            vm.expectRevert(E.Unauthorized.selector);
            vault.queue(abi.encodePacked(ok[i], bytes1(0)));
            vm.prank(owner);
            vm.expectRevert(E.Unauthorized.selector);
            vault.queue(abi.encodePacked(ok[i], bytes32(0)));
            if (len[i] > 4) {
                bytes memory shorter = new bytes(len[i] - 1);
                for (uint256 j; j < shorter.length; ++j) {
                    shorter[j] = ok[i][j];
                }
                vm.prank(owner);
                vm.expectRevert(E.Unauthorized.selector);
                vault.queue(shorter);
            }
        }
        // selectors outside the six: refused (exitEmergency, setOperator, rescueToken, lowerFees, upgrade-like calls)
        bytes[5] memory bad = [
            abi.encodeCall(GainsVault.exitEmergency, ()),
            abi.encodeCall(GainsVault.setOperator, (address(1))),
            abi.encodeCall(GainsVault.setDepositCap, (1)),
            abi.encodeCall(GainsVault.resume, ()),
            abi.encodeWithSignature("setGuardian(address)", address(1))
        ];
        for (uint256 i; i < bad.length; ++i) {
            vm.prank(owner);
            vm.expectRevert(E.Unauthorized.selector);
            vault.queue(bad[i]);
        }
        vm.prank(owner);
        vm.expectRevert(E.NotQueued.selector);
        vault.queue(hex"aabbcc");
    }

    /// Dirty upper bits give a new id for "the same call", but the vault's ABI decoder rejects them at execute: no
    /// queued item can execute a call that differs from what its canonical encoding says.
    function test_GOV_TL_dirtyBitsNeverExecute() public {
        bytes memory dirtyMgr = abi.encodePacked(GainsVault.setManager.selector, bytes32(uint256(uint160(stranger)) | (uint256(1) << 200)));
        bytes memory dirtyFees = abi.encodePacked(GainsVault.setFees.selector, bytes32(uint256(100) | (uint256(1) << 100)), bytes32(uint256(100)));
        bytes memory dirtyFeed = abi.encodePacked(
            GainsVault.setPairFeed.selector, bytes32(uint256(ETH) | (uint256(1) << 64)), bytes32(uint256(uint160(address(ethFeed)))), bytes32(uint256(BTC_MAX_AGE)), bytes32(uint256(20))
        );
        bytes[3] memory items = [dirtyMgr, dirtyFees, dirtyFeed];
        for (uint256 i; i < items.length; ++i) {
            vm.prank(owner);
            vault.queue(items[i]);
        }
        _warp(vault.queuedEta(keccak256(items[2]))); // hl-r2 exit-before-effect: wait for the stored eta
        for (uint256 i; i < items.length; ++i) {
            vm.expectRevert(abi.encodeWithSelector(E.CallFailed.selector, bytes("")));
            vault.execute(items[i]);
        }
        assertEq(vault.manager(), manager);
        assertEq(vault.managementFeeBps(), 200);
    }

    function test_GOV_TL_duplicateIdRequeueResetsEta_executeWindow_cancel() public {
        bytes memory d = _mgr();
        bytes32 id = keccak256(d);
        vm.prank(owner);
        vault.queue(d);
        uint256 eta1 = vault.queuedEta(id);
        _skip(1 days);
        vm.prank(owner);
        vault.queue(d); // same id: eta and queuedAt move to now + delay (one entry, never two)
        assertEq(vault.queuedEta(id), eta1 + 1 days);
        _warp(eta1);
        vm.expectRevert(E.NotReady.selector);
        vault.execute(d);
        // cancel: owner or guardian only
        address[3] memory nope = [stranger, manager, feeRecipient];
        for (uint256 i; i < nope.length; ++i) {
            vm.prank(nope[i]);
            vm.expectRevert(E.Unauthorized.selector);
            vault.cancel(id);
        }
        vm.prank(guardian);
        vault.cancel(id);
        vm.prank(guardian);
        vm.expectRevert(E.NotQueued.selector);
        vault.cancel(id);
        vm.expectRevert(E.NotQueued.selector);
        vault.execute(d);
        // re-queue, execute by a stranger at exactly eta + 14 days; a second execute finds nothing
        vm.prank(owner);
        vault.queue(d);
        _warp(vault.queuedEta(keccak256(d)) + 14 days); // hl-r2 exit-before-effect: wait for the stored eta
        vm.prank(stranger);
        vault.execute(d);
        assertEq(vault.manager(), address(0xBEEF));
        vm.expectRevert(E.NotQueued.selector);
        vault.execute(d);
        // expired one second later; an expired item can still be cancelled
        bytes memory d2 = abi.encodeCall(GainsVault.setFeeRecipient, (address(0xF00D)));
        vm.prank(owner);
        vault.queue(d2);
        _warp(vault.queuedEta(keccak256(d2)) + 14 days + 1); // hl-r2 exit-before-effect: wait for the stored eta
        vm.expectRevert(E.Expired.selector);
        vault.execute(d2);
        vm.prank(owner);
        vault.cancel(keccak256(d2));
    }

    /// A failing target keeps the item queued (the whole execute reverts): it can be retried inside the window.
    function test_GOV_TL_failedExecuteKeepsTheItem() public {
        _fundVenue(10_000e6);
        bytes memory d = abi.encodeCall(GainsVault.setFees, (300, 2_000));
        vm.prank(owner);
        vault.queue(d);
        _warp(vault.queuedEta(keccak256(d))); // hl-r2 exit-before-effect: wait for the stored eta
        // the ETH feed goes stale: setFees accrues the management fee at the old rate first and reverts (M-02: never
        // skipped, never applied retroactively)
        _warp(vm.getBlockTimestamp());
        vm.warp(vm.getBlockTimestamp() + BTC_MAX_AGE + 1);
        btcFeed.set(btcFeed.answer(), vm.getBlockTimestamp());
        vm.expectRevert(
            abi.encodeWithSelector(E.CallFailed.selector, abi.encodeWithSelector(GainsPrice.PriceStale.selector, uint256(ETH)))
        );
        vault.execute(d);
        assertGt(vault.queuedEta(keccak256(d)), 0, "still queued");
        _skip(0);
        vault.execute(d);
        assertEq(vault.managementFeeBps(), 300);
    }

    // ==================================================================
    // breach clear rules (N-04 class)
    // ==================================================================
    function test_GOV_CB_queuedClearMustPostdateTheBreach() public {
        bytes memory c = abi.encodeCall(GainsVault.clearBreach, ());
        // queued before any breach
        vm.prank(owner);
        vault.queue(c);
        _skip(1 hours);
        vm.prank(guardian);
        vault.triggerBreach();
        _warp(vault.queuedEta(keccak256(c))); // hl-r2 exit-before-effect: wait for the stored eta
        vm.expectRevert(E.NotReady.selector);
        vault.execute(c);
        // queued in the breach's own block (queuedAt == breachedAt): still refused
        vm.prank(guardian);
        vault.triggerBreach();
        vm.prank(owner);
        vault.queue(c);
        assertEq(vault.queuedAt(keccak256(c)), vault.breachedAt());
        _warp(vault.queuedEta(keccak256(c))); // hl-r2 exit-before-effect: wait for the stored eta
        vm.expectRevert(E.NotReady.selector);
        vault.execute(c);
        // queued one second after: works after the delay
        _skip(1);
        vm.prank(owner);
        vault.queue(c);
        _warp(vault.queuedEta(keccak256(c))); // hl-r2 exit-before-effect: wait for the stored eta
        vault.execute(c);
        assertFalse(vault.breached());
    }

    /// I2-01: every sentinel / guardian triggerBreach restarts breachedAt, so a hot sentinel can keep invalidating
    /// owner clears (documented in HL as a known issue; holds on Gains).
    function test_GOV_CB_I201_rebreachInvalidatesOwnerClear() public {
        bytes memory c = abi.encodeCall(GainsVault.clearBreach, ());
        vm.prank(guardian); // standalone: guardian == sentinel
        vault.triggerBreach();
        _skip(1);
        vm.prank(owner);
        vault.queue(c);
        _skip(2 days - 1 hours);
        vm.prank(guardian);
        vault.triggerBreach();
        _skip(1 hours);
        vm.expectRevert(E.NotReady.selector);
        vault.execute(c);
    }

    /// The daily-loss auto clear at the UTC day roll does not touch breachedAt; every later breach sets it again, so a
    /// clear queued in between never pre-clears the later breach.
    function test_GOV_CB_dailyAutoClearThenNewBreach() public {
        uint32 idx = _fundVenue(10_000e6);
        _setVenueValue(vault, idx, 9_400e6); // -6% > 5% daily
        vault.checkRisk();
        assertEq(uint8(vault.breachReason()), uint8(BreachReason.DAILY_LOSS));
        uint64 at = vault.breachedAt();
        _warp((vm.getBlockTimestamp() / 1 days + 1) * 1 days + 1);
        vault.checkRisk();
        assertFalse(vault.breached(), "auto cleared at the day roll");
        assertEq(vault.breachedAt(), at, "breachedAt not refreshed by the auto clear");
        bytes memory c = abi.encodeCall(GainsVault.clearBreach, ());
        vm.prank(owner);
        vault.queue(c); // queued while not breached
        _skip(1 hours);
        _setVenueValue(vault, idx, 8_000e6); // -15% from the 9,400 day start
        vault.checkRisk();
        assertTrue(vault.breached());
        _skip(2 days);
        vm.expectRevert(E.NotReady.selector);
        vault.execute(c);
    }

    function test_GOV_CB_queuedClearNeverInEmergency() public {
        bytes memory c = abi.encodeCall(GainsVault.clearBreach, ());
        vm.prank(owner);
        vault.triggerEmergency();
        _skip(1);
        vm.prank(owner);
        vault.queue(c);
        _warp(vault.queuedEta(keccak256(c))); // hl-r2 exit-before-effect: wait for the stored eta
        vm.expectRevert(abi.encodeWithSelector(E.CallFailed.selector, abi.encodeWithSelector(E.InEmergency.selector)));
        vault.execute(c);
        vm.prank(guardian);
        vm.expectRevert(E.InEmergency.selector);
        vault.clearBreach();
    }

    /// Owner-queued clearBreach vs resume() on a DRAWDOWN breach. Both need >= 24 h (MIN_TIMELOCK == RESUME_COOLDOWN).
    /// clearBreach skips resume's limit checks but also keeps the peak, so the next checkRisk re-breaches at once:
    /// it is strictly weaker than resume (no bypass). Verdict: holds.
    function test_GOV_CB_ownerClearVsResumeOnDrawdown() public {
        uint32 idx = _fundVenue(10_000e6);
        _setVenueValue(vault, idx, 8_000e6); // -20%: drawdown (15%) and daily (5%)
        vault.checkRisk();
        assertEq(uint8(vault.breachReason()), uint8(BreachReason.DRAWDOWN));
        bytes memory c = abi.encodeCall(GainsVault.clearBreach, ());
        _skip(1);
        vm.prank(owner);
        vault.queue(c);
        _warp(vault.queuedEta(keccak256(c))); // hl-r2 exit-before-effect: wait for the stored eta
        // resume: the daily loss is measured from the new day's first check, so it passes; peak reset
        uint256 snap = vm.snapshotState();
        vm.prank(owner);
        vault.resume();
        assertFalse(vault.breached());
        vault.checkRisk();
        assertFalse(vault.breached(), "resume resets the peak");
        vm.revertToState(snap);
        // owner clear: cleared, but the peak is kept and the next permissionless check re-breaches
        vault.execute(c);
        assertFalse(vault.breached());
        vault.checkRisk();
        assertEq(uint8(vault.breachReason()), uint8(BreachReason.DRAWDOWN), "re-breached immediately");
    }

    // ==================================================================
    // feed rotation (setPairFeed): only the factory's current curation; can it be blocked for good?
    // ==================================================================
    function test_GOV_FR_queuedRotationFollowsTheCurationAtExecute() public {
        MockChainlinkFeed f2 = new MockChainlinkFeed(8, 3_000e8);
        MockChainlinkFeed f3 = new MockChainlinkFeed(8, 3_000e8);
        vm.prank(platformOwner);
        platform.setAssetCurated(ETH, true, address(f2), BTC_MAX_AGE, 20);
        bytes memory d = abi.encodeCall(GainsVault.setPairFeed, (ETH, address(f2), BTC_MAX_AGE, 20));
        vm.prank(owner);
        vault.queue(d);
        // the factory re-curates before eta: the queued combination is no longer the current one
        vm.prank(platformOwner);
        platform.setAssetCurated(ETH, true, address(f3), BTC_MAX_AGE, 20);
        _warp(vault.queuedEta(keccak256(d))); // hl-r2 exit-before-effect: wait for the stored eta
        vm.expectRevert(
            abi.encodeWithSelector(E.CallFailed.selector, abi.encodeWithSelector(GainsVaultPolicy.FeedNotCurated.selector, uint32(ETH)))
        );
        vault.execute(d);
        // de-curated: no rotation at all while the factory does not curate the pair
        vm.prank(platformOwner);
        platform.setAssetCurated(ETH, false, address(0), 0, 0);
        bytes memory d3 = abi.encodeCall(GainsVault.setPairFeed, (ETH, address(f3), BTC_MAX_AGE, 20));
        vm.prank(owner);
        vault.queue(d3);
        _warp(vault.queuedEta(keccak256(d3))); // hl-r2 exit-before-effect: wait for the stored eta
        vm.expectRevert(
            abi.encodeWithSelector(E.CallFailed.selector, abi.encodeWithSelector(GainsVaultPolicy.AssetNotCurated.selector, uint32(ETH)))
        );
        vault.execute(d3);
        // the factory curates it again: the same queued item now executes (still inside its window)
        vm.prank(platformOwner);
        platform.setAssetCurated(ETH, true, address(f3), BTC_MAX_AGE, 20);
        vault.execute(d3);
        assertEq(policy.feedOf(ETH).feed, address(f3));
        // a pair this policy never listed cannot be rotated in (rotation is not an allowlisting)
        bytes memory d4 = abi.encodeCall(GainsVault.setPairFeed, (SOL, address(solFeed), SOL_MAX_AGE, 25));
        vm.prank(owner);
        vault.queue(d4);
        _warp(vault.queuedEta(keccak256(d4))); // hl-r2 exit-before-effect: wait for the stored eta
        vm.expectRevert(
            abi.encodeWithSelector(E.CallFailed.selector, abi.encodeWithSelector(GainsVaultPolicy.AssetNotCurated.selector, uint32(SOL)))
        );
        vault.execute(d4);
    }

    /// GR1-31 (was GOV-05, a PoC: a leverage raise skipped a listed-but-disallowed pair, whose feed rotation then
    /// reverted LeverageAboveNavBound). Now the NAV bound covers every listed pair: the raise itself is refused while
    /// the disallowed pair is listed, and the pair's feed rotation stays open.
    function test_GR1_31_navBoundCoversDisallowedPairs_rotationStaysOpen() public {
        // allow SOL (band 25: bound 10x at maxNavMoveBps 2000), open a SOL trade, then disallow SOL
        vm.prank(owner);
        policy.queueAllowAsset(SOL);
        _warp(policy.assetAllowEta(SOL)); // hl-r2 exit-before-effect: wait for the stored eta
        policy.allowAsset(SOL);
        _deposit(alice, 10_000e6);
        _settle();
        _claim(alice);
        _open(vault, SOL, true, 1_000e6, 2_000);
        vm.prank(owner);
        policy.disallowAsset(SOL);
        assertFalse(policy.isAssetAllowed(SOL));
        assertLt(policy.navBoundLeverageBps(SOL, 2_000), 120_000, "12x is above SOL's NAV bound");
        // raising vault leverage to 12x (within BTC / ETH, above SOL): refused for the disallowed SOL as well
        GainsVaultPolicy.RiskConfig memory c = _defaultRisk();
        c.maxLeverageBps = 120_000;
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(GainsVaultPolicy.LeverageAboveNavBound.selector, uint32(SOL)));
        policy.proposeConfig(c);
        assertEq(policy.maxLeverageBps(), 30_000);
        // Chainlink deprecates the SOL feed; the platform curates the replacement; the rotation executes
        MockChainlinkFeed sol2 = new MockChainlinkFeed(8, 150e8);
        vm.prank(platformOwner);
        platform.setAssetCurated(SOL, true, address(sol2), SOL_MAX_AGE, 25);
        bytes memory d = abi.encodeCall(GainsVault.setPairFeed, (SOL, address(sol2), SOL_MAX_AGE, 25));
        vm.prank(owner);
        vault.queue(d);
        _warp(vault.queuedEta(keccak256(d))); // hl-r2 exit-before-effect: wait for the stored eta
        sol2.set(150e8, vm.getBlockTimestamp());
        vault.execute(d);
        assertEq(policy.feedOf(SOL).feed, address(sol2));
    }

    /// GR1-10 (was GOV-06, a PoC: the sequencer uptime feed was immutable on the factory and copied into each policy
    /// with no setter, so a replaced or dead uptime feed froze every vault with an open trade). Now the factory owner
    /// rotates it (never to zero, not in the constructor either) and each vault adopts it through its own timelock.
    function test_GR1_10_sequencerFeedRotatesThroughTheTimelock_zeroRefused() public {
        // the constructor refuses a zero feed
        vm.expectRevert(GainsVaultFactory.ZeroAddress.selector);
        new GainsVaultFactory(
            platformOwner,
            address(vaultImpl),
            address(policyImpl),
            IERC20(address(usdc)),
            IGainsDiamond(address(diamond)),
            address(0),
            SEQ_GRACE,
            protocolTreasury,
            platformGuardian,
            platformSentinel
        );
        _fundFv(10_000e6);
        _openFv(ETH, 5_000e6, 2_000);
        uint256 shares = fv.balanceOf(alice) / 2;
        vm.prank(alice);
        fv.requestRedeem(shares, alice, alice);
        sequencer.setReverts(true);
        vm.prank(keeper);
        vm.expectRevert(GainsPrice.SequencerDown.selector);
        fv.settle();
        // the platform curates a new uptime feed: owner only, never zero
        MockChainlinkFeed seq2 = new MockChainlinkFeed(0, 0);
        seq2.setStatus(0, vm.getBlockTimestamp() - 30 days);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        platform.setSequencerFeed(address(seq2), SEQ_GRACE);
        vm.prank(platformOwner);
        vm.expectRevert(GainsVaultFactory.ZeroAddress.selector);
        platform.setSequencerFeed(address(0), SEQ_GRACE);
        vm.prank(platformOwner);
        platform.setSequencerFeed(address(seq2), 7_200);
        assertEq(platform.sequencerFeed(), address(seq2));
        assertEq(fp.sequencerFeed(), address(sequencer), "an existing vault adopts it only through its timelock");
        // neither the vault nor the policy setter is callable directly
        vm.prank(fvOwner);
        vm.expectRevert(E.Unauthorized.selector);
        fv.setSequencerFeed(address(seq2), 7_200);
        vm.prank(fvOwner);
        vm.expectRevert(GainsVaultPolicy.NotVault.selector);
        fp.setSequencerFeed(address(seq2), 7_200);
        // queue (exact length 68: the feed and grace snapshotted, GV-03), wait the delay, execute
        bytes memory d = abi.encodeCall(GainsVault.setSequencerFeed, (address(seq2), 7_200));
        assertEq(d.length, 68);
        vm.prank(fvOwner);
        vm.expectRevert(E.Unauthorized.selector);
        fv.queue(abi.encodePacked(d, bytes32(0)));
        vm.prank(fvOwner);
        fv.queue(d);
        _warp(fv.queuedEta(keccak256(d))); // hl-r2 exit-before-effect: wait for the stored eta
        fv.execute(d);
        assertEq(fp.sequencerFeed(), address(seq2));
        assertEq(fp.sequencerGracePeriod(), 7_200);
        // the vault prices again: checkRisk and a normal settle pay the redemption
        fv.checkRisk();
        vm.prank(keeper);
        fv.settle();
        assertEq(fv.pendingRedeemShares(), 0);
    }

    // ==================================================================
    // policy loosening: timelock, expiry, cancel, NAV bound at both stages
    // ==================================================================
    function test_GOV_PL_loosening_boundAtApply_tighteningCancelsPending_guardianCannotCancel() public {
        GainsVaultPolicy.RiskConfig memory c = _defaultRisk();
        c.maxLeverageBps = 110_000; // 11x: within BTC / ETH (12.5x), above SOL (10x)
        vm.prank(owner);
        policy.proposeConfig(c);
        assertTrue(policy.pendingConfig().exists);
        // SOL gets allowed in the meantime under the current 3x
        vm.prank(owner);
        policy.queueAllowAsset(SOL);
        _warp(policy.assetAllowEta(SOL)); // hl-r2 exit-before-effect: wait for the stored eta
        policy.allowAsset(SOL);
        // the queued loosening is re-checked at apply against the pairs allowed now
        vm.expectRevert(abi.encodeWithSelector(GainsVaultPolicy.LeverageAboveNavBound.selector, uint32(SOL)));
        policy.applyPendingConfig();
        // the cold guardian has no veto on the policy (owner only)
        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, guardian));
        policy.cancelPendingConfig();
        // a tightening applies at once and drops the pending loosening
        GainsVaultPolicy.RiskConfig memory t = _defaultRisk();
        t.maxDailyLossBps = 400;
        vm.prank(owner);
        policy.proposeConfig(t);
        assertFalse(policy.pendingConfig().exists, "tightening deletes the pending loosening");
        vm.expectRevert(GainsVaultPolicy.NothingPending.selector);
        policy.applyPendingConfig();
    }

    /// H-01 retest: what the owner changes INSTANTLY. Raising maxNavMoveBps (to 100%) counts as a tightening (N-03),
    /// so the per-settle NAV bound of C-01 can be switched off without a timelock; lowering maxEpochDuration makes an
    /// epoch overdue at once. Both as on HL round 4 (same _isTighter).
    function test_GOV_PL_instantLevers() public {
        GainsVaultPolicy.RiskConfig memory c = _defaultRisk();
        c.maxNavMoveBps = 10_000;
        c.maxEpochDuration = 1 hours;
        c.maxLeverageBps = 1;
        c.maxDailyLossBps = 1;
        c.maxDrawdownBps = 1;
        c.maxSlippageBps = 1;
        c.maxFlattenSlippageBps = 1;
        vm.prank(owner);
        policy.proposeConfig(c);
        assertEq(policy.maxNavMoveBps(), 10_000, "settle NAV bound 100%, instant");
        assertEq(policy.maxEpochDuration(), 1 hours, "instant");
        assertEq(policy.maxLeverageBps(), 1, "instant");
        // policy timelock raised to the 30 day maximum, instant
        vm.prank(owner);
        policy.proposeTimelockDelay(30 days);
        assertEq(policy.timelockDelay(), 30 days);
    }

    // ==================================================================
    // GR1-12 / GR1-30: the policy is owned by whoever owns the vault
    // ==================================================================
    /// GR1-12 (was GOV-03, a PoC: the policy kept its own owner, so after a vault transfer the previous owner could
    /// still tighten the policy into a permanent leverage breach and an emergency). Now policy.owner() is the vault's
    /// owner: the old owner loses the policy the moment the new one accepts the vault, and the new owner has it.
    function test_GR1_12_policyOwnershipFollowsAVaultTransfer() public {
        address newOwner = makeAddr("newVaultOwner");
        _fundFv(10_000e6);
        _openFv(ETH, 5_000e6, 2_000);
        vm.prank(fvOwner);
        fv.transferOwnership(newOwner);
        assertEq(fp.owner(), fvOwner, "two step: not moved before accept");
        vm.prank(newOwner);
        fv.acceptOwnership();
        assertEq(fv.owner(), newOwner);
        assertEq(fp.owner(), newOwner, "the policy follows the vault");
        // the previous owner can no longer touch the policy
        GainsVaultPolicy.RiskConfig memory c = _defaultRisk();
        c.maxLeverageBps = 1;
        c.maxEpochDuration = 1 hours;
        bytes memory err = abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, fvOwner);
        vm.startPrank(fvOwner);
        vm.expectRevert(err);
        fp.proposeConfig(c);
        vm.expectRevert(err);
        fp.disallowAsset(BTC);
        vm.expectRevert(err);
        fp.proposeTimelockDelay(30 days);
        vm.stopPrank();
        assertEq(fp.maxLeverageBps(), 30_000);
        fv.checkRisk();
        assertFalse(fv.breached(), "no leverage breach");
        // the new owner can, instantly for a tightening
        GainsVaultPolicy.RiskConfig memory t = _defaultRisk();
        t.maxDailyLossBps = 100;
        vm.startPrank(newOwner);
        fp.proposeConfig(t);
        fp.disallowAsset(BTC);
        vm.stopPrank();
        assertEq(fp.maxDailyLossBps(), 100);
        assertFalse(fp.isAssetAllowed(BTC));
        // the policy's own ownership functions are gone: it moves with the vault only
        vm.startPrank(newOwner);
        vm.expectRevert(GainsVaultPolicy.OwnershipFollowsVault.selector);
        fp.transferOwnership(fvOwner);
        vm.expectRevert(GainsVaultPolicy.OwnershipFollowsVault.selector);
        fp.acceptOwnership();
        vm.stopPrank();
    }

    /// GR1-30 (was GOV-04, a PoC: renounceOwnership was live on the policy, freezing the config while a pending
    /// loosening still applied at its eta). Now renounce reverts OwnershipFollowsVault and the owner keeps the veto.
    function test_GR1_30_policyRenounceRevertsOwnerKeepsTheVeto() public {
        GainsVaultPolicy.RiskConfig memory c = _defaultRisk();
        c.maxDailyLossBps = 10_000;
        c.maxDrawdownBps = 10_000;
        c.maxLeverageBps = 120_000;
        c.maxSlippageBps = 2_000;
        vm.startPrank(fvOwner);
        fp.proposeConfig(c);
        vm.expectRevert(GainsVaultPolicy.OwnershipFollowsVault.selector);
        fp.renounceOwnership();
        vm.stopPrank();
        vm.prank(stranger);
        vm.expectRevert(GainsVaultPolicy.OwnershipFollowsVault.selector);
        fp.renounceOwnership();
        assertEq(fp.owner(), fvOwner);
        // the owner still cancels the pending loosening; nothing is left for a stranger to apply
        vm.prank(fvOwner);
        fp.cancelPendingConfig();
        _skip(2 days);
        vm.prank(stranger);
        vm.expectRevert(GainsVaultPolicy.NothingPending.selector);
        fp.applyPendingConfig();
        assertEq(fp.maxDailyLossBps(), 500);
    }
}
