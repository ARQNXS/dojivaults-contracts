// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {GovBase} from "../gains/gov/GovBase.t.sol";
import {GainsVaultFactory} from "../../../src/gains/GainsVaultFactory.sol";
import {GainsVault} from "../../../src/gains/GainsVault.sol";
import {GainsVaultPolicy} from "../../../src/gains/GainsVaultPolicy.sol";

/// @notice WP5 (release verification), GR2-CFG-01 on the shared exit-before-effect rule: two risk-adding paths that the
///         CFG01FixTest scenarios do not reach. CFG01FixTest checks proposeConfig and the vault queue; it never queues a
///         new pair (queueAllowAsset) and never lowers maxEpochDuration inside a running epoch (epochDeadlineCeiling).
///         Property asserted: a change that adds risk, queued while a redeemer is waiting, cannot take effect before
///         that redeemer's epoch deadline + EXIT_MARGIN (1 day), and the apply reverts until then.
contract WP5GfixCFG01Test is GovBase {
    address internal mallory = makeAddr("wp5.cfg.mallory");
    uint256 internal constant MARGIN = 1 days; // EXIT_MARGIN

    function _create(uint256 tl, uint64 ep, bytes32 salt) internal returns (GainsVault v, GainsVaultPolicy p) {
        GainsVaultFactory.CreateParams memory c = _cparams(launcher, salt, address(0));
        c.owner = mallory;
        c.manager = mallory;
        c.feeRecipient = mallory;
        c.timelockDelay = tl;
        c.risk.maxEpochDuration = ep;
        vm.prank(launcher);
        (address va, address pa) = platform.create(c, _noPermit());
        v = GainsVault(va);
        p = GainsVaultPolicy(pa);
    }

    /// @notice A new pair is new exposure. Timelock 1 day, epoch 7 days, queued 3 days into the epoch: the allow waits
    ///         for the epoch deadline + 1 day (not queue + 1 day), and allowAsset reverts at the deadline.
    function test_WP5_CFG01_newPairWaitsTheRunningEpochPlusMargin() public {
        (GainsVault v, GainsVaultPolicy p) = _create(1 days, 7 days, bytes32(uint256(901)));
        uint256 deadline = v.epochDeadline();
        _skip(3 days);
        vm.prank(mallory);
        p.queueAllowAsset(SOL);
        uint256 eta = p.assetAllowEta(SOL);
        assertGe(eta, deadline + MARGIN, "new pair: eta >= epoch deadline + 1 day");
        _warp(deadline + MARGIN - 1);
        vm.expectRevert(GainsVaultPolicy.NotReady.selector);
        p.allowAsset(SOL);
        _warp(eta);
        p.allowAsset(SOL);
        assertTrue(p.isAssetAllowed(SOL));
    }

    /// @notice maxEpochDuration lowered inside a running epoch (instant: a tightening). The running epoch keeps its
    ///         7-day deadline, so a loosening and a new pair queued right after must still wait for that deadline
    ///         + 1 day (epochDeadlineCeiling), not for the new 1-hour epoch length or the 1-day timelock.
    function test_WP5_CFG01_epochLoweredMidEpochStillWaitsTheRunningDeadline() public {
        (GainsVault v, GainsVaultPolicy p) = _create(1 days, 7 days, bytes32(uint256(902)));
        uint256 deadline = v.epochDeadline();
        _skip(1 hours);
        GainsVaultPolicy.RiskConfig memory c = p.config();
        c.maxEpochDuration = 1 hours;
        vm.prank(mallory);
        p.proposeConfig(c); // tighter: applied at once
        assertEq(p.maxEpochDuration(), 1 hours);
        assertEq(uint256(v.epochDeadline()), deadline, "the running epoch keeps its deadline");

        c = p.config();
        c.maxLeverageBps = c.maxLeverageBps * 2;
        vm.prank(mallory);
        p.proposeConfig(c);
        uint256 eta = p.pendingConfig().eta;
        assertGe(eta, deadline + MARGIN, "loosening after a lowered epoch: eta >= running deadline + 1 day");
        vm.prank(mallory);
        p.queueAllowAsset(SOL);
        assertGe(p.assetAllowEta(SOL), deadline + MARGIN, "new pair after a lowered epoch: eta >= running deadline + 1 day");

        _warp(deadline + MARGIN - 1);
        vm.expectRevert(GainsVaultPolicy.NotReady.selector);
        p.applyPendingConfig();
        _warp(eta);
        p.applyPendingConfig();
    }

    /// @notice Stronger form of CFG01FixTest.policyTimelockChangesKeepTheMargin, which queues only once the epoch is
    ///         already overdue (it passes with the shared rule removed). Timelock 10 days lowered to 1 day while a
    ///         20-day epoch still runs: a loosening and a vault queue item still wait for that epoch's deadline + 1 day.
    function test_WP5_CFG01_timelockLoweredInsideARunningEpoch() public {
        (GainsVault v, GainsVaultPolicy p) = _create(10 days, 20 days, bytes32(uint256(903)));
        uint256 deadline = v.epochDeadline();
        vm.prank(mallory);
        p.proposeTimelockDelay(1 days);
        _warp(p.pendingTimelockEta());
        p.applyTimelockDelay();
        assertEq(p.timelockDelay(), 1 days);
        assertLt(vm.getBlockTimestamp(), deadline, "the epoch still runs");
        GainsVaultPolicy.RiskConfig memory c = p.config();
        c.maxLeverageBps = c.maxLeverageBps * 2;
        vm.prank(mallory);
        p.proposeConfig(c);
        assertGe(p.pendingConfig().eta, deadline + MARGIN, "loosening: eta >= running deadline + 1 day");
        bytes memory data = abi.encodeCall(GainsVault.setFeeRecipient, (makeAddr("wp5.cfg.fr")));
        vm.prank(mallory);
        bytes32 id = v.queue(data);
        assertGe(v.queuedEta(id), deadline + MARGIN, "vault queue: eta >= running deadline + 1 day");
    }

    /// @notice Stronger form of CFG01FixTest.queuedEpochRaiseRecheckedAtApply (its 10-day timelock already covers the
    ///         raised 9-day epoch + 1 day, so its vault-queue assert holds without the rule): with a 1-day timelock, a
    ///         vault item and a new pair queued beside a pending epoch raise (7 -> 9 days) wait the longer epoch + 1 day.
    function test_WP5_CFG01_queuedBesideAPendingEpochRaise() public {
        (GainsVault v, GainsVaultPolicy p) = _create(1 days, 7 days, bytes32(uint256(904)));
        GainsVaultPolicy.RiskConfig memory c = p.config();
        c.maxEpochDuration = 9 days;
        vm.prank(mallory);
        p.proposeConfig(c);
        assertGe(p.pendingConfig().eta, uint256(v.epochDeadline()) + MARGIN, "the raise waits the running epoch");
        bytes memory data = abi.encodeCall(GainsVault.setFeeRecipient, (makeAddr("wp5.cfg.fr")));
        vm.prank(mallory);
        bytes32 id = v.queue(data);
        assertGe(v.queuedEta(id), vm.getBlockTimestamp() + 9 days + MARGIN, "vault queue beside the raise: 9 d + 1 d");
        vm.prank(mallory);
        p.queueAllowAsset(SOL);
        assertGe(p.assetAllowEta(SOL), vm.getBlockTimestamp() + 9 days + MARGIN, "new pair beside the raise: 9 d + 1 d");
    }
}
