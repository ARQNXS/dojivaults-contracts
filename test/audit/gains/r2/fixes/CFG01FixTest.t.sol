// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {GovBase} from "../../gov/GovBase.t.sol";
import {GainsVaultFactory} from "../../../../../src/gains/GainsVaultFactory.sol";
import {GainsVault} from "../../../../../src/gains/GainsVault.sol";
import {GainsVaultPolicy} from "../../../../../src/gains/GainsVaultPolicy.sol";
import {InitParams} from "../../../../../src/gains/GainsTypes.sol";

/// @notice GR2-CFG-01 fix test (contracts/audit/gains/r2/fixes/GR2-CFG-01), adapted in fix round WP2 to the shared
///         exit-before-effect rule that WP1 put in (the same code as Hyperliquid H01), which replaced the review's own
///         CFG-01 patch. Same five scenarios; the review's version asserted its mechanism (a timelock below
///         maxEpochDuration + 1 day is refused), which the shared rule does not use, so each `expectRevert` failed
///         (contracts/audit/fix-round/wp2-logs). The shared rule accepts those shapes and instead makes every change that
///         widens exposure wait max(timelock, the running epoch's deadline + 1 day), the deadline fixed when the epoch
///         started. What both versions protect, asserted here: a redeemer waiting when a change is queued reaches an
///         overdue epoch (anyone's triggerEmergency, exit-only settles) at least EXIT_MARGIN before it can apply.
contract CFG01FixTest is GovBase {
    address internal mallory = makeAddr("cfg.mallory");
    uint256 internal constant MARGIN = 1 days; // EXIT_MARGIN

    function _cp(uint256 tl, uint64 ep, bytes32 salt) internal view returns (GainsVaultFactory.CreateParams memory c) {
        c = _cparams(launcher, salt, address(0));
        c.owner = mallory;
        c.manager = mallory;
        c.feeRecipient = mallory;
        c.timelockDelay = tl;
        c.risk.maxEpochDuration = ep;
    }

    function _create(uint256 tl, uint64 ep, bytes32 salt) internal returns (GainsVault v, GainsVaultPolicy p) {
        GainsVaultFactory.CreateParams memory c = _cp(tl, ep, salt);
        vm.prank(launcher);
        (address va, address pa) = platform.create(c, _noPermit());
        v = GainsVault(va);
        p = GainsVaultPolicy(pa);
    }

    /// @dev The owner queues a leverage loosening now: it may apply only a margin after the running epoch's deadline.
    function _loosenWaitsForTheExit(GainsVault v, GainsVaultPolicy p) internal {
        GainsVaultPolicy.RiskConfig memory c = p.config();
        c.maxLeverageBps = c.maxLeverageBps * 2;
        vm.prank(p.owner());
        p.proposeConfig(c);
        assertGe(p.pendingConfig().eta, uint256(v.epochDeadline()) + MARGIN, "loosening after the overdue epoch + margin");
        bytes memory data = abi.encodeCall(GainsVault.setFeeRecipient, (makeAddr("cfg.fr")));
        vm.prank(v.owner());
        bytes32 id = v.queue(data);
        assertGe(v.queuedEta(id), uint256(v.epochDeadline()) + MARGIN, "vault queue after the overdue epoch + margin");
    }

    /// @notice The ConfigTimelock PoC's launch (timelock 1 day, epoch 30 days) and every T < E + 1 day shape of its
    ///         table: accepted, and a loosening queued right after launch waits for the epoch deadline + 1 day, not the
    ///         timelock (the PoC's trap: a redeemer exposed for E - T).
    function test_CFG01_fix_factoryRefusesTimelockBelowEpochPlusMargin() public {
        uint256[5] memory tl = [uint256(1 days), 2 days, 2 days, 1 days, 30 days];
        uint64[5] memory ep = [uint64(30 days), 7 days, 2 days, 1 hours, 30 days];
        for (uint256 i; i < 5; ++i) {
            (GainsVault v, GainsVaultPolicy p) = _create(tl[i], ep[i], bytes32(uint256(101 + i)));
            assertEq(v.epochDeadline(), vm.getBlockTimestamp() + ep[i], "deadline fixed at launch");
            _loosenWaitsForTheExit(v, p);
        }
        (GainsVault v2, GainsVaultPolicy p2) = _create(2 days, 1 days, bytes32(uint256(106))); // live shape
        assertEq(p2.timelockDelay(), 2 days);
        assertEq(v2.timelockDelay(), 2 days);
    }

    /// @notice The live shape raising maxEpochDuration to 30 days with a 2 day timelock: the raise waits the running
    ///         epoch + 1 day, the running epoch keeps its deadline after it applies (CFG-02), and the next loosening
    ///         waits the new epoch length + 1 day.
    function test_CFG01_fix_liveShapeCannotRaiseTheEpochAboveTheTimelock() public {
        (GainsVault v, GainsVaultPolicy p) = _create(2 days, 1 days, bytes32(uint256(201)));
        uint64 deadline = v.epochDeadline();
        GainsVaultPolicy.RiskConfig memory c = p.config();
        c.maxEpochDuration = 30 days;
        vm.prank(mallory);
        p.proposeConfig(c);
        assertGe(p.pendingConfig().eta, uint256(deadline) + MARGIN, "the raise waits for the overdue epoch");
        _warp(p.pendingConfig().eta);
        p.applyPendingConfig();
        assertEq(v.epochDeadline(), deadline, "the running epoch keeps its deadline (overdue stays overdue)");
        c = p.config();
        c.maxLeverageBps = 120_000;
        vm.prank(mallory);
        p.proposeConfig(c);
        assertGe(p.pendingConfig().eta, vm.getBlockTimestamp() + 30 days + MARGIN, "next loosening: new epoch + 1 day");
    }

    /// @notice Lowering the policy timelock below the epoch shortens nothing: a loosening still waits the epoch deadline
    ///         + 1 day.
    function test_CFG01_fix_policyTimelockChangesKeepTheMargin() public {
        (GainsVault v, GainsVaultPolicy p) = _create(10 days, 7 days, bytes32(uint256(301)));
        vm.prank(mallory);
        p.proposeTimelockDelay(1 days);
        _warp(p.pendingTimelockEta());
        p.applyTimelockDelay();
        assertEq(p.timelockDelay(), 1 days);
        _loosenWaitsForTheExit(v, p);
    }

    /// @notice An epoch raise queued beside a timelock lowering: whichever applies first, everything queued while the
    ///         raise is pending waits the longer epoch + 1 day.
    function test_CFG01_fix_queuedEpochRaiseRecheckedAtApply() public {
        (GainsVault v, GainsVaultPolicy p) = _create(10 days, 7 days, bytes32(uint256(401)));
        vm.prank(mallory);
        p.proposeTimelockDelay(8 days);
        GainsVaultPolicy.RiskConfig memory c = p.config();
        c.maxEpochDuration = 9 days;
        vm.prank(mallory);
        p.proposeConfig(c);
        assertGe(p.noticeEta(), vm.getBlockTimestamp() + 9 days + MARGIN, "notice covers the pending longer epoch");
        bytes memory data = abi.encodeCall(GainsVault.setFeeRecipient, (makeAddr("cfg.fr")));
        vm.prank(mallory);
        bytes32 id = v.queue(data);
        assertGe(v.queuedEta(id), vm.getBlockTimestamp() + 9 days + MARGIN, "vault queue beside the raise");
        _warp(p.pendingTimelockEta());
        p.applyTimelockDelay();
        _warp(p.pendingConfig().eta);
        p.applyPendingConfig();
        assertEq(p.maxEpochDuration(), 9 days);
        _loosenWaitsForTheExit(v, p);
    }

    /// @notice The vault's own timelock below the policy's epoch: accepted at initialization and at setTimelockDelay,
    ///         and every vault queue still waits the epoch deadline + 1 day.
    function test_CFG01_fix_vaultTimelockKeepsTheMargin() public {
        uint32[] memory assets = new uint32[](1);
        assets[0] = ETH;
        GainsVault v = GainsVault(Clones.clone(address(vaultImpl)));
        GainsVaultPolicy p = GainsVaultPolicy(Clones.clone(address(policyImpl)));
        GainsVaultPolicy.RiskConfig memory r = _defaultRisk();
        r.maxEpochDuration = 7 days;
        p.initialize(owner, r, assets, 10 days, address(platform), address(v));
        InitParams memory ip = _standaloneParams(p);
        ip.timelockDelay = 2 days;
        v.initialize(ip);
        assertEq(v.timelockDelay(), 2 days);
        _loosenWaitsForTheExit(v, p);
    }
}
