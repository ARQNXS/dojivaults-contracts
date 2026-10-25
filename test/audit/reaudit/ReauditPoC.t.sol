// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {AuditBase} from "../AuditBase.t.sol";
import {HyperVault} from "../../../src/HyperVault.sol";
import {IHyperVaultErrors} from "../../../src/VaultTypes.sol";
import {VaultPolicy} from "../../../src/VaultPolicy.sol";
import {HyperVaultFactory} from "../../../src/HyperVaultFactory.sol";

/// @notice Re-audit regression tests (findings N-01 .. N-08 of contracts/audit/REAUDIT.md). Every test started as a
///         proof of concept that PASSED on e68666c; the assertions are inverted so a regression fails the suite.
///         Run: forge test --match-path test/audit/reaudit/ReauditPoC.t.sol -vv
contract ReauditPoC is AuditBase {
    // Core model for the vault under test (6 decimals), mirrored into the precompile mocks.
    int64 internal perp;
    uint64 internal spot;

    function _core(HyperVault v) internal {
        _setCore(address(v), perp, 0, spot);
        _setWithdrawable(address(v), perp > 0 ? uint64(perp) : 0);
    }

    /// @dev `caller` bridges MIN_BRIDGE back to EVM; modelled as arriving immediately. Real NAV is unchanged.
    function _pingEvm(HyperVault v, address caller) internal {
        vm.prank(caller);
        v.bridgeToEvm(100e6);
        perp -= 100e6;
        usdc.mint(address(v), 100e6);
        _core(v);
    }

    function _roll(uint256 n) internal {
        vm.roll(vm.getBlockNumber() + n);
    }

    // ==================================================================
    // N-01  A bridge window could be held open forever and settle() priced inside it at a frozen snapshot.
    //       Fixed by one rule: nothing bridges, settles or accrues while a window is open; it closes by itself.
    // ==================================================================
    function test_REAUDIT_N01_windowCannotBeHeldOrSettledInside() public {
        (HyperVault v,) = _malloryVault();
        _fundAndDeploy(v, mallory, 10_000e6, 0);
        perp = 10_000e6;
        spot = 0;
        _core(v);

        vm.prank(bob);
        v.requestDeposit(40_000e6, bob); // honest depositor

        _pingEvm(v, mallory); // opens the window (snapshot 10k)
        assertTrue(v.bridgeInFlight());
        vm.prank(mallory);
        vm.expectRevert(IHyperVaultErrors.BridgeInFlight.selector);
        v.bridgeToEvm(100e6); // cannot be extended
        vm.prank(mallory);
        vm.expectRevert(IHyperVaultErrors.BridgeInFlight.selector);
        v.settle(); // cannot be settled inside
        for (uint256 i; i < 5; ++i) {
            _roll(10);
            if (!v.bridgeInFlight()) break;
        }
        assertFalse(v.bridgeInFlight(), "closes by itself");

        v.checkRisk();
        vm.prank(mallory);
        v.settle(); // bob priced at the real 10k NAV
        v.claim(bob);
        assertApproxEqRel(v.totalAssets(), 50_000e6, 1e15, "flows are visible right away");

        vm.prank(mallory2);
        v.requestDeposit(40_000e6, mallory2);
        _pingEvm(v, mallory);
        _roll(11);
        v.checkRisk();
        vm.prank(mallory);
        v.settle(); // sybil priced at the real 50k NAV
        v.claim(mallory2);

        assertApproxEqRel(v.totalAssets(), 90_000e6, 1e15);
        assertApproxEqRel(_value(v, mallory2), 40_000e6, 1e14, "sybil gets what it paid");
        assertApproxEqRel(_value(v, bob), 40_000e6, 1e14, "bob keeps what he paid");
        assertApproxEqRel(_value(v, alice), 10_000e6, 1e14);
    }

    /// @dev N-01b: inside a window checkRisk() sees min(snapshot, live + amount in flight), so a real loss breaches
    ///      immediately; a window can hide at most the amount it moves, and only until it closes.
    function test_REAUDIT_N01b_windowCannotMaskBreach() public {
        (HyperVault v,) = _malloryVault();
        _fundAndDeploy(v, mallory, 1_000_000e6, 0);
        perp = 1_000_000e6;
        _core(v);
        v.checkRisk();

        _pingEvm(v, mallory);
        perp = 400_000e6; // 60% loss on Core (limits: 5% daily, 15% drawdown)
        _core(v);
        assertTrue(v.bridgeInFlight());
        assertEq(v.totalAssets(), 1_000_000e6, "the snapshot is still the accounting NAV in flight");
        v.checkRisk();
        assertTrue(v.breached(), "the loss breaches inside the window");
        assertEq(uint8(v.breachReason()), 3, "drawdown (round 4: reduce only, agent kept)");
    }

    // ==================================================================
    // N-02  One emergency bridge per epoch plus an all-or-nothing settle deadlocked the exit for good.
    //       Fixed by: anyone bridges in emergency whenever no window is open; emergency settles pay pro rata.
    // ==================================================================
    function test_REAUDIT_N02_emergencyExitCannotDeadlock() public {
        (HyperVault v,) = _malloryVault();
        vm.prank(mallory2);
        v.requestDeposit(100_000e6, mallory2);
        _fundAndDeploy(v, mallory, 1_000_000e6, 0); // settles alice + mallory2 together, bridges alice's 1M
        v.claim(mallory2);
        vm.prank(mallory);
        v.bridgeToCore(100_000e6);
        perp = 1_100_000e6;
        _core(v);
        _roll(301); // round 4: perp is not a landing signal (spot only): wait the window's cap

        uint256 a = v.balanceOf(alice);
        uint256 m2 = v.balanceOf(mallory2);
        vm.prank(alice);
        v.requestRedeem(a, alice, alice);
        vm.prank(mallory2);
        v.requestRedeem(m2, mallory2, mallory2);
        vm.warp(vm.getBlockTimestamp() + 7 days);
        v.checkRisk();
        vm.prank(stranger);
        v.triggerEmergency();

        // Round 4: a depositor (the old griefer) cannot bridge at all; the sentinel's minimum rescue opens a
        // 10 block window, and that is its only effect.
        vm.prank(mallory2);
        vm.expectRevert(IHyperVaultErrors.Unauthorized.selector);
        v.bridgeToEvm(100e6);
        _pingEvm(v, sentinel);
        vm.prank(sentinel);
        vm.expectRevert(IHyperVaultErrors.BridgeInFlight.selector);
        v.bridgeToEvm(1_099_900e6);
        _roll(11);

        // Even with only 100 USDC on hand the epoch settles: paid pro rata, the unpaid shares go back to the
        // redeemers (partial fill + return, audit V-01), who queue them again.
        v.checkRisk();
        vm.prank(sentinel);
        v.settle();
        assertEq(v.currentEpoch(), 2, "epoch advanced");
        (,, uint256 R, uint256 paid, uint256 burned,,,) = v.epochs(1);
        assertEq(paid, 100e6);
        assertGt(burned, 0);
        assertLt(burned, R);
        assertEq(v.pendingRedeemShares(), 0, "nothing rolls over");
        (uint256 aBack,) = lens.claimable(v, alice);
        (uint256 mBack,) = lens.claimable(v, mallory2);
        assertGt(aBack, 0);
        vm.prank(alice);
        v.requestRedeem(aBack, alice, alice);
        vm.prank(mallory2);
        v.requestRedeem(mBack, mallory2, mallory2);
        assertEq(v.pendingRedeemShares(), aBack + mBack, "remainder queued again");

        // The rescuer brings the rest home and the next settle pays everyone.
        vm.prank(sentinel);
        v.bridgeToEvm(1_099_900e6);
        perp = 0;
        usdc.mint(address(v), 1_099_900e6);
        _core(v);
        _roll(11);
        v.checkRisk();
        vm.prank(sentinel);
        v.settle();
        v.claim(alice);
        v.claim(mallory2);
        assertEq(v.pendingRedeemShares(), 0);
        assertGt(usdc.balanceOf(alice), 1_000_000e6 - 1_000e6, "alice is out, minus a week of fees");
        assertGt(usdc.balanceOf(mallory2), 10_000_000e6 - 1_000e6);
    }

    // ==================================================================
    // N-03  Lowering maxNavMoveBps counted as tightening and froze all settlement for weeks.
    //       Fixed by: floor of 500 bps, lowering is timelocked, and exit-only settles never use the bound.
    // ==================================================================
    function test_REAUDIT_N03_navBoundNeverBlocksExits() public {
        (HyperVault v, VaultPolicy p) = _malloryVault();
        _fundAndDeploy(v, mallory, 1_000_000e6, 0);
        perp = 1_000_000e6;
        _core(v);
        v.checkRisk();

        VaultPolicy.RiskConfig memory c = p.config();
        c.maxNavMoveBps = 1;
        vm.prank(mallory);
        vm.expectRevert(VaultPolicy.InvalidConfig.selector);
        p.proposeConfig(c); // below the floor
        c.maxNavMoveBps = 500;
        vm.prank(mallory);
        p.proposeConfig(c); // a narrower band is a loosening for liveness: timelocked
        assertEq(p.maxNavMoveBps(), 2_000, "not applied");

        perp = 955_000e6; // 4.5% market loss: below every breach limit
        _core(v);
        uint256 a = v.balanceOf(alice);
        vm.prank(alice);
        v.requestRedeem(a, alice, alice);
        vm.warp(vm.getBlockTimestamp() + 7 days);
        v.checkRisk();
        vm.prank(stranger);
        v.triggerEmergency();
        vm.prank(sentinel);
        v.bridgeToEvm(955_000e6);
        perp = 0;
        usdc.mint(address(v), 955_000e6);
        _core(v);
        _roll(11);
        // Days without a keeper: the checkpoint is stale and far from NAV; an exit-only settle still goes through,
        // priced at min(NAV, checkpoint).
        vm.warp(vm.getBlockTimestamp() + 3 days);
        vm.prank(sentinel);
        v.settle();
        v.claim(alice);
        assertEq(v.pendingRedeemShares(), 0);
        assertGt(usdc.balanceOf(alice), 1_000_000e6 - 45_000e6 - 2_000e6, "alice out at the 955k NAV minus fees");
    }

    // ==================================================================
    // N-04  Pre-queued and byte-padded clearBreach items defeated the breach timelock.
    //       Fixed by: exact calldata length per selector; a clear only counts when queued after the breach.
    // ==================================================================
    function test_REAUDIT_N04_prequeuedClearBreachRejected() public {
        (HyperVault v,) = _malloryVault();
        _fundAndDeploy(v, mallory, 1_000_000e6, 0);
        perp = 1_000_000e6;
        _core(v);
        v.checkRisk();

        bytes memory c1 = abi.encodeCall(HyperVault.clearBreach, ());
        bytes memory c2 = abi.encodePacked(c1, uint256(1)); // padded: same call, would be a new id
        vm.startPrank(mallory);
        v.queue(c1);
        vm.expectRevert(IHyperVaultErrors.Unauthorized.selector);
        v.queue(c2);
        vm.stopPrank();
        vm.warp(v.queuedEta(keccak256(c1)));
        v.checkRisk(); // new day baseline

        perp = 940_000e6; // -6% vs a 5% daily limit
        _core(v);
        v.checkRisk();
        assertTrue(v.breached());
        vm.expectRevert(IHyperVaultErrors.NotReady.selector);
        v.execute(c1); // queued before the breach: never
        assertTrue(v.breached());

        // Queued after the breach: the delay runs from the breach, nothing clears it sooner.
        vm.warp(vm.getBlockTimestamp() + 1);
        vm.prank(mallory);
        v.queue(c1);
        vm.expectRevert(IHyperVaultErrors.NotReady.selector);
        v.execute(c1);
        vm.warp(v.queuedEta(keccak256(c1)));
        v.execute(c1);
        assertFalse(v.breached());
    }

    // ==================================================================
    // N-05  lowerFees() with unchanged values crystallised the performance fee at any transient high.
    //       Fixed by: at least one fee must strictly drop, and a fee change crystallises the management fee only.
    // ==================================================================
    function test_REAUDIT_N05_lowerFeesCannotCrystalliseASpike() public {
        _deposit(alice, 1_000_000e6);
        _settle();
        _claim(alice);
        vm.prank(manager);
        vault.bridgeToCore(1_000_000e6);
        _setCore(address(vault), 1_000_000e6, 0, 0);
        _skipBridgeWindow();

        _setCore(address(vault), 1_500_000e6, 0, 0); // one-block spike
        (uint16 mg, uint16 pf) = (vault.managementFeeBps(), vault.performanceFeeBps());
        vm.prank(owner);
        vm.expectRevert(IHyperVaultErrors.InvalidFee.selector);
        vault.lowerFees(mg, pf);
        vm.prank(owner);
        vault.lowerFees(mg, pf - 1); // a real lowering at the spike
        _setCore(address(vault), 1_000_000e6, 0, 0);

        assertLt(_value(vault, feeRecipient), 100e6, "no performance fee outside settle");
        assertGt(_value(vault, alice), 999_000e6);
        assertEq(vault.highWaterMark(), 1_000_000, "HWM untouched");
    }

    // ==================================================================
    // N-06  The platform guardian was copied into each vault forever. Fixed by: vaults read the guardian and the
    //       sentinel from the factory, so the factory owner rotates them for every vault at once.
    // ==================================================================
    function test_REAUDIT_N06_rolesRotateForExistingVaults() public {
        (HyperVault v,) = _malloryVault();
        _fundAndDeploy(v, mallory, 1_000_000e6, 0);
        address newGuardian = makeAddr("newGuardian");
        address newSentinel = makeAddr("newSentinel");
        vm.prank(owner);
        factory.setGuardian(newGuardian); // platform rotates after a leak
        vm.prank(owner);
        factory.setSentinel(newSentinel);
        assertEq(v.guardian(), newGuardian, "existing vault follows the factory");
        assertEq(v.sentinel(), newSentinel);

        // The leaked key has no power left.
        vm.prank(guardian);
        vm.expectRevert(IHyperVaultErrors.NotOverdue.selector);
        v.triggerEmergency();
        bytes memory recover = abi.encodeCall(HyperVault.setManager, (mallory));
        vm.prank(mallory);
        bytes32 id = v.queue(recover);
        vm.prank(guardian);
        vm.expectRevert(IHyperVaultErrors.Unauthorized.selector);
        v.cancel(id);
        vm.prank(sentinel);
        vm.expectRevert(IHyperVaultErrors.Unauthorized.selector);
        v.triggerBreach();
        vm.prank(newSentinel);
        v.triggerBreach();
        vm.prank(newGuardian);
        v.clearBreach();
        assertFalse(v.breached());
    }

    // ==================================================================
    // N-07  Platform agents were a global set. Fixed by: an agent is bound to one vault at registration; setAgent
    //       checks the binding; unregistering revokes the agent on its vault.
    // ==================================================================
    function test_REAUDIT_N07_agentBoundToOneVault() public {
        (HyperVault v,) = _malloryVault(); // uses platformAgent, bound to this vault
        address otherTenantAgent = makeAddr("otherTenantAgent");
        vm.prank(owner);
        factory.registerPlatformAgent(otherTenantAgent, makeAddr("otherTenantVault"));

        bytes memory data = abi.encodeCall(HyperVault.setAgent, (otherTenantAgent));
        vm.prank(mallory);
        v.queue(data);
        vm.warp(v.queuedEta(keccak256(data)));
        vm.expectRevert(_callFailed(IHyperVaultErrors.NotPlatformAgent.selector));
        v.execute(data);
        assertEq(v.agent(), platformAgent);

        vm.prank(owner);
        factory.unregisterPlatformAgent(platformAgent);
        assertEq(v.agent(), address(0), "revoked on the vault by the factory");
        assertFalse(factory.isPlatformAgent(platformAgent));
    }

    // ==================================================================
    // N-08  Management-only accruals ratcheted the HWM without charging the fee. Fixed by: the HWM only moves
    //       when the performance fee is charged (settle).
    // ==================================================================
    function test_REAUDIT_N08_hwmOnlyMovesWithTheFee() public {
        _deposit(alice, 1_000_000e6);
        _settle();
        _claim(alice);
        vm.prank(manager);
        vault.bridgeToCore(1_000_000e6);
        _setCore(address(vault), 1_000_000e6, 0, 0);
        _skipBridgeWindow();

        _setCore(address(vault), 1_500_000e6, 0, 0); // real, lasting 50% gain
        _keeperHours(vault, 3); // checkpoint ratchets 1.0 -> 1.2 -> 1.44 -> 1.5
        uint256 snap = vm.snapshotState();
        _settle();
        uint256 honest = _value(vault, feeRecipient);
        vm.revertToState(snap);

        vm.prank(stranger);
        vault.accrueFees(); // management fee only, and the HWM stays put
        assertEq(vault.highWaterMark(), 1_000_000);
        _settle();
        assertApproxEqAbs(_value(vault, feeRecipient), honest, 5e6, "performance fee intact");
        assertGt(honest, 99_000e6);
    }
}
