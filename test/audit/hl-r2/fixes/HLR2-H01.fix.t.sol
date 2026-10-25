// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {console2} from "forge-std/console2.sol";

import {HostileBase} from "../hostile/HostileBase.t.sol";
import {EconBase} from "../econ/EconBase.t.sol";
import {HyperVault} from "../../../../src/HyperVault.sol";
import {VaultPolicy} from "../../../../src/VaultPolicy.sol";
import {HyperCore} from "../../../../src/hypercore/HyperCore.sol";
import {IHyperVaultErrors as E} from "../../../../src/VaultTypes.sol";

/// @notice hl-r2 fix proof for HLR2-H01 (with E06b leg C and HLR2-XB01): "exit before effect".
///         Only compiles and passes with fixes/patches/HLR2-H01.patch applied (fixes/verify.sh HLR2-H01).
///         Copied by verify.sh to test/audit/hl-r2/fixes/; it is not part of the audit branch's suite.
contract HLR2_H01_Fix is HostileBase {
    uint32 internal constant DOGE_ = 7;

    function _guardianBringsEverythingHome(HyperVault v, uint256 amount) internal {
        vm.prank(guardian);
        v.bridgeToEvm(amount);
        _setCore(address(v), 0, 0, 0);
        _setWithdrawable(address(v), 0);
        usdc.mint(address(v), amount);
        vm.roll(vm.getBlockNumber() + 11);
        v.syncBridge();
    }

    function _guardianPays(HyperVault v) internal returns (uint256 paid) {
        _guardianBringsEverythingHome(v, 100_002e6);
        vm.prank(guardian);
        v.settle();
        uint256 b0 = usdc.balanceOf(alice);
        v.claim(alice);
        paid = usdc.balanceOf(alice) - b0;
    }

    // ------------------------------------------------------------------
    // The H01 PoC timeline, patched: same block, same hostile loosening, same 100,002 USDC.
    // ------------------------------------------------------------------
    function test_FIX_H01_sameBlockRedeemerForcesTheExitBeforeTheLooseningApplies() public {
        HyperVault v = _platformVaultLike(address(0));
        VaultPolicy pol = v.policy();
        uint256 epochStart = v.epochStartedAt();
        uint256 deadline = v.epochDeadline();
        assertEq(deadline, epochStart + 7 days, "deadline fixed at the epoch start");
        uint256 t0 = vm.getBlockTimestamp(); // epoch start + 1 h
        uint256 shares = v.balanceOf(alice);
        uint256 aliceBefore = v.convertToAssets(shares);

        vm.startPrank(platformVaultOwner);
        v.setOperator(address(0));
        pol.proposeConfig(_loose());
        vm.stopPrank();
        vm.prank(alice);
        v.requestRedeem(shares, alice, alice);

        // The eta is one epoch plus the margin after the queue, not the 2-day policy timelock.
        uint256 eta = pol.pendingConfig().eta;
        assertEq(eta, t0 + 7 days + 1 days, "eta = queue + epoch + EXIT_MARGIN");
        assertGe(eta, deadline + 1 days, "at least EXIT_MARGIN after alice's forced-exit date");

        // At the old 2-day eta nothing applies.
        vm.warp(t0 + 2 days);
        vm.expectRevert(VaultPolicy.NotReady.selector);
        pol.applyPendingConfig();

        // One second before the deadline: not overdue yet. At the deadline alice forces the exit herself.
        vm.warp(deadline - 1);
        vm.prank(alice);
        vm.expectRevert(E.NotOverdue.selector);
        v.triggerEmergency();
        vm.warp(deadline);
        vm.prank(alice);
        v.triggerEmergency();
        assertTrue(v.emergency());
        assertLt(vm.getBlockTimestamp(), eta, "before the loosening can apply");

        // The eta: the loosening applies (epoch 30 d), but the running deadline does not move (E06b leg C) and the
        // vault can only reduce.
        vm.warp(eta);
        pol.applyPendingConfig();
        assertEq(pol.maxEpochDuration(), 30 days);
        assertEq(v.epochDeadline(), deadline, "a raised epoch never moves the running deadline");
        assertTrue(lens.epochOverdue(v), "overdue stays overdue");
        vm.prank(platformVaultOwner);
        vm.expectRevert(E.ReduceOnlyMode.selector);
        v.placeOrder(BTC, true, 100_000e8, 45e8, false, HyperCore.TIF_GTC, 0);

        uint256 paid = _guardianPays(v);
        console2.log("FIX-H01 alice value at request", aliceBefore);
        console2.log("FIX-H01 alice paid at the old risk", paid);
        console2.log("FIX-H01 hours between alice's forced exit and the eta", (eta - deadline) / 1 hours);
        assertApproxEqRel(paid, aliceBefore, 1e15, "paid in full at the old risk");
    }

    // H01b: keeper kept as operator, the NAV in margin. Alice no longer depends on the keeper.
    function test_FIX_H01b_keeperOperatorNoLongerMatters() public {
        HyperVault v = _platformVaultLike(address(0));
        VaultPolicy pol = v.policy();
        _setCore(address(v), 100_002e6, 400_000e6, 0);
        _setWithdrawable(address(v), 0);
        _setPosition(address(v), BTC, 4e5);
        v.checkRisk();
        uint256 t0 = vm.getBlockTimestamp();

        vm.prank(platformVaultOwner);
        pol.proposeConfig(_loose());
        uint256 shares = v.balanceOf(alice);
        vm.prank(alice);
        v.requestRedeem(shares, alice, alice);
        vm.prank(keeper);
        (bool ok, bytes memory ret) = address(v).call(abi.encodeCall(HyperVault.settle, ()));
        assertFalse(ok);
        assertEq(bytes4(ret), E.InsufficientLiquidity.selector, "still true: the keeper cannot pay from margin");

        uint256 eta = pol.pendingConfig().eta;
        assertEq(eta, t0 + 8 days);
        vm.warp(v.epochDeadline());
        vm.prank(alice);
        v.triggerEmergency();
        // In emergency the keeper (operator) may flatten; the loosening at the eta finds a reduce-only vault.
        vm.warp(eta);
        pol.applyPendingConfig();
        assertEq(pol.maxDrawdownBps(), 10_000);
        assertTrue(v.emergency(), "the emergency survives the apply");
        vm.prank(platformVaultOwner);
        vm.expectRevert(E.ReduceOnlyMode.selector);
        v.placeOrder(BTC, true, 100_000e8, 45e8, false, HyperCore.TIF_GTC, 0);
    }

    // XB03 scenario (fix sketch B's hole), patched: the owner settles an empty epoch 1 h after queuing, alice reacts
    // 12 h after the queue. Her new epoch's deadline is still before the eta.
    function test_FIX_H01_lateReactorAfterAnInterveningSettleStillGetsOut() public {
        HyperVault v = _platformVaultLike(address(0));
        VaultPolicy pol = v.policy();
        uint256 t0 = vm.getBlockTimestamp();
        vm.startPrank(platformVaultOwner);
        v.setOperator(address(0));
        pol.proposeConfig(_loose());
        vm.stopPrank();
        uint256 eta = pol.pendingConfig().eta;

        vm.warp(t0 + 1 hours + 1);
        v.checkRisk();
        vm.prank(platformVaultOwner);
        v.settle();
        uint256 deadline = v.epochDeadline();
        assertEq(deadline, t0 + 1 hours + 1 + 7 days, "new epoch at the old length (the loosening is not in force)");

        vm.warp(t0 + 12 hours);
        uint256 shares = v.balanceOf(alice);
        vm.prank(alice);
        v.requestRedeem(shares, alice, alice);

        vm.warp(deadline);
        vm.prank(alice);
        v.triggerEmergency();
        assertLt(vm.getBlockTimestamp(), eta);
        assertGe(eta - deadline, 1 days - 12 hours, "slack >= EXIT_MARGIN - reaction time");
    }

    // Every vault-queued power waits for the same notice: a management fee raise (applies at execute), setManager,
    // and the vault's own delay lowering.
    function test_FIX_H01_vaultQueueWaitsForTheExitWindow() public {
        HyperVault v = _platformVaultLike(address(0));
        uint256 t0 = vm.getBlockTimestamp();
        bytes memory fees = abi.encodeCall(HyperVault.setFees, (uint16(500), uint16(3_000)));
        bytes memory mgr = abi.encodeCall(HyperVault.setManager, (makeAddr("newManager")));
        bytes memory tl = abi.encodeCall(HyperVault.setTimelockDelay, (1 days));
        vm.startPrank(platformVaultOwner);
        v.queue(fees);
        v.queue(mgr);
        v.queue(tl);
        vm.stopPrank();
        assertEq(v.queuedEta(keccak256(fees)), t0 + 8 days, "fee raise: epoch + margin, not the 2-day vault delay");
        assertEq(v.queuedEta(keccak256(mgr)), t0 + 8 days);
        assertEq(v.queuedEta(keccak256(tl)), t0 + 8 days);

        uint256 shares = v.balanceOf(alice);
        vm.prank(alice);
        v.requestRedeem(shares, alice, alice);
        vm.warp(t0 + 2 days);
        vm.expectRevert(E.NotReady.selector);
        v.execute(fees);
        vm.warp(v.epochDeadline());
        vm.prank(alice);
        v.triggerEmergency();
        uint256 paid = _guardianPays(v);
        assertLt(vm.getBlockTimestamp(), t0 + 8 days, "alice paid before any queued item can execute");
        assertApproxEqRel(paid, 100_002e6, 1e15);
        assertTrue(v.managementFeeBps() != 500, "the raise never applied while she was in");
    }

    // A pending loosening that raises the epoch also lengthens the notice of changes queued beside it.
    function test_FIX_H01_pendingLongerEpochLengthensLaterNotices() public {
        HyperVault v = _platformVaultLike(address(0));
        VaultPolicy pol = v.policy();
        vm.prank(platformVaultOwner);
        pol.proposeConfig(_loose()); // epoch 30 d pending, eta now + 8 d
        uint256 t1 = vm.getBlockTimestamp();
        bytes memory fees = abi.encodeCall(HyperVault.setFees, (uint16(500), uint16(3_000)));
        vm.prank(platformVaultOwner);
        v.queue(fees);
        assertEq(v.queuedEta(keccak256(fees)), t1 + 30 days + 1 days, "pending 30 d epoch + margin");
        assertEq(pol.noticeEta(), t1 + 31 days);
    }

    // allowAsset (a new perp) is a widening change too.
    function test_FIX_H01_allowAssetWaitsForTheExitWindow() public {
        VaultPolicy pol = _platformVaultLike(address(0)).policy();
        vm.prank(owner);
        factory.setAssetCurated(DOGE_, true);
        uint256 t0 = vm.getBlockTimestamp();
        vm.prank(platformVaultOwner);
        pol.queueAllowAsset(DOGE_);
        assertEq(pol.assetAllowEta(DOGE_), t0 + 8 days);
        vm.warp(t0 + 2 days);
        vm.expectRevert(VaultPolicy.NotReady.selector);
        pol.allowAsset(DOGE_);
        vm.warp(t0 + 8 days);
        pol.allowAsset(DOGE_);
        assertTrue(pol.isAssetAllowed(DOGE_));
    }

    // An instant epoch tightening mid-epoch leaves the running deadline alone; the ceiling keeps the notice of a
    // later loosening past that deadline (without it the eta would be queue + 1 h + 1 d, before alice's exit).
    function test_FIX_H01_tightenThenLoosenStillWaitsForTheRunningDeadline() public {
        HyperVault v = _platformVaultLike(address(0));
        VaultPolicy pol = v.policy();
        uint256 deadline = v.epochDeadline();
        uint256 t0 = vm.getBlockTimestamp();
        VaultPolicy.RiskConfig memory tight = _platformVaultRisk();
        tight.maxEpochDuration = 1 hours;
        vm.startPrank(platformVaultOwner);
        pol.proposeConfig(tight); // instant
        assertEq(pol.maxEpochDuration(), 1 hours);
        assertEq(v.epochDeadline(), deadline, "running deadline unchanged");
        assertEq(pol.epochDeadlineCeiling(), t0 + 7 days);
        pol.proposeConfig(_loose());
        vm.stopPrank();
        uint256 eta = pol.pendingConfig().eta;
        assertEq(eta, t0 + 7 days + 1 days, "ceiling + margin");
        uint256 shares = v.balanceOf(alice);
        vm.prank(alice);
        v.requestRedeem(shares, alice, alice);
        vm.warp(deadline);
        vm.prank(alice);
        v.triggerEmergency();
        assertLt(vm.getBlockTimestamp(), eta);
    }

    // Controls ----------------------------------------------------------

    // An honest loosening still works, after the longer notice; a delay above the epoch keeps its own length.
    function test_FIX_H01_control_honestLooseningAppliesAfterTheNotice() public {
        HyperVault v = _platformVaultLike(address(0));
        VaultPolicy pol = v.policy();
        VaultPolicy.RiskConfig memory c = _platformVaultRisk();
        c.maxLeverageBps = 60_000;
        uint256 t0 = vm.getBlockTimestamp();
        vm.prank(platformVaultOwner);
        pol.proposeConfig(c);
        assertEq(pol.pendingConfig().eta, t0 + 8 days);
        vm.warp(t0 + 8 days);
        pol.applyPendingConfig();
        assertEq(pol.maxLeverageBps(), 60_000);
        assertFalse(v.emergency());

        // A 9-day delay (the ALERT mitigation) dominates the epoch notice.
        vm.prank(platformVaultOwner);
        pol.proposeTimelockDelay(9 days);
        c.maxLeverageBps = 70_000;
        uint256 t1 = vm.getBlockTimestamp();
        vm.prank(platformVaultOwner);
        pol.proposeConfig(c);
        assertEq(pol.pendingConfig().eta, t1 + 9 days);
        // Lowering the delay itself is not gated by the notice (it shortens no exit window): it waits the old delay.
        vm.prank(platformVaultOwner);
        pol.proposeTimelockDelay(1 days);
        assertEq(pol.pendingTimelockEta(), t1 + 9 days);
    }

    // CFG-02 on HL: nobody acts in the window, the epoch raise applies, the epoch stays overdue and anyone can still
    // force the exit.
    function test_FIX_H01_control_overdueStaysOverdueAfterAnEpochRaise() public {
        HyperVault v = _platformVaultLike(address(0));
        VaultPolicy pol = v.policy();
        vm.startPrank(platformVaultOwner);
        v.setOperator(address(0));
        pol.proposeConfig(_loose());
        vm.stopPrank();
        uint256 shares = v.balanceOf(alice);
        vm.prank(alice);
        v.requestRedeem(shares, alice, alice);
        vm.warp(pol.pendingConfig().eta);
        pol.applyPendingConfig();
        assertEq(pol.maxEpochDuration(), 30 days);
        assertTrue(lens.epochOverdue(v), "still overdue under the 30-day policy");
        vm.prank(stranger);
        v.triggerEmergency();
        assertTrue(v.emergency());
    }
}

/// @notice HLR2-XB01, patched: an instant maxEpochDuration tightening applies from the next epoch only, so it no
///         longer opens the exit-only price in the running one.
contract HLR2_XB01_Fix is EconBase {
    function test_FIX_XB01_instantEpochTighteningDoesNotOpenTheExitOnlyPrice() public {
        vm.prank(owner);
        vault.lowerFees(0, 0);
        _fundTwo(100_000e6, 100_000e6);
        _hours(20);
        _setCoreValue(260_000e6);
        uint256 aliceShares = vault.balanceOf(alice);
        _redeem(alice, aliceShares);
        _toEvm(140_000e6);
        uint256 deadline = vault.epochDeadline();

        VaultPolicy.RiskConfig memory c = _defaultRisk();
        c.maxEpochDuration = 1 hours;
        vm.startPrank(owner);
        policy.proposeConfig(c);
        assertFalse(policy.pendingConfig().exists, "still instant");
        assertEq(vault.epochDeadline(), deadline, "the running deadline does not move");
        assertFalse(lens.epochOverdue(vault));
        vm.expectRevert(E.Unauthorized.selector); // exit-only needs an overdue epoch or an emergency
        vault.settle();
        vm.stopPrank();

        // The next epoch starts under the shorter length: the manager's normal settle pays alice at the walked NAV.
        vault.checkRisk(); // ratchet within maxNavMoveBps
        _hours(1);
        vault.checkRisk();
        _settleAs(manager);
        assertEq(vault.epochDeadline(), vm.getBlockTimestamp() + 1 hours, "1 h epochs from the next epoch on");
        uint256 b0 = usdc.balanceOf(alice);
        vault.claim(alice);
        uint256 paid = usdc.balanceOf(alice) - b0;
        console2.log("FIX-XB01 alice paid", paid);
        assertApproxEqAbs(paid, 130_000e6, 1e6, "fair value, not the stale 100k checkpoint");
    }
}
