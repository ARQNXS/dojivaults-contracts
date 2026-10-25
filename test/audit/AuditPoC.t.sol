// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Vm} from "forge-std/Vm.sol";
import {AuditBase} from "./AuditBase.t.sol";
import {HyperVault} from "../../src/HyperVault.sol";
import {IHyperVaultErrors, IHyperVaultEvents} from "../../src/VaultTypes.sol";
import {VaultPolicy} from "../../src/VaultPolicy.sol";
import {HyperVaultFactory} from "../../src/HyperVaultFactory.sol";
import {HyperCore} from "../../src/hypercore/HyperCore.sol";

/// @notice Regression tests for contracts/audit/REPORT.md. Every test here started life as a proof of concept
///         that PASSED while the finding was exploitable; after the fix its final assertions are inverted (or the
///         exploit step is an expectRevert), so a regression makes the test fail again.
///         Run: forge test --match-path test/audit/AuditPoC.t.sol -vv
contract AuditPoC is AuditBase {
    // ==================================================================
    // C-01  NAV deflation: value disappears from coreEquity() (funds parked where the view does not look), a
    //       queued deposit settles at the depressed price, NAV is reflated afterwards.
    //       Fixed by: insider deposits rejected; settle() blocked while breached; NAV checkpoint ratchet
    //       (VaultPolicy.nextCheckpoint) so a large move cannot be settled before the monitor reacts; only
    //       platform agents (never a manager key) can trade; clearBreach / setAgent timelocked (H-01).
    // ==================================================================
    function test_AUDIT_C01_navDeflationCannotBeSettled() public {
        (HyperVault v,) = _malloryVault();
        _fundAndDeploy(v, mallory, 1_000_000e6, 1e6);
        uint256 aliceStart = _value(v, alice);
        assertApproxEqRel(aliceStart, 1_000_000e6, 1e15);

        // Mallory (manager, owner, fee recipient) cannot get a deposit priced in the current epoch, as sender or
        // controller (round 4: it is accepted for the NEXT epoch instead of rejected).
        uint256 cur = v.currentEpoch();
        vm.prank(mallory);
        assertEq(v.requestDeposit(1_000_000e6, mallory), cur + 1, "insider deposit waits an epoch");
        vm.prank(mallory2);
        assertEq(v.requestDeposit(1_000_000e6, mallory), cur + 1, "deposit for an insider waits an epoch");
        // Her sybil can.
        vm.prank(mallory2);
        v.requestDeposit(1_000_000e6, mallory2);

        // 900k USDC vanish from the perp account view.
        _setCore(address(v), 100_000e6, 0, 1e6);

        // (a) Straight away: NAV is 90% below the checkpoint the last settle recorded.
        uint256 snap = vm.snapshotState();
        vm.prank(mallory);
        vm.expectRevert(abi.encodeWithSelector(VaultPolicy.NavMoved.selector, 100_001e6, 1_000_001e6));
        v.settle();

        // (b) With the keeper ratcheting the checkpoint every hour it still takes many hours, and the first
        //     checkRisk() breaches the vault (90% drawdown), which closes settle() for good.
        _keeperHours(v, 1);
        assertTrue(v.breached(), "breach fires");
        // Round 4: a risk breach keeps the (platform's) agent. In a drawdown breach a settle is redemption-only
        // (mints nothing) and still bound to the checkpoint: at a 90% deflated NAV it does not run at all.
        assertEq(uint8(v.breachReason()), 3, "drawdown breach");
        assertEq(v.agent(), platformAgent, "agent kept, reduce only");
        uint256 supplyBefore = v.totalSupply();
        vm.prank(mallory);
        vm.expectRevert(abi.encodeWithSelector(VaultPolicy.NavMoved.selector, 100_001e6, 800_000_800_000));
        v.settle();
        assertEq(v.totalSupply(), supplyBefore, "nothing minted");

        // (c) Nothing is instant for the owner any more.
        vm.prank(mallory);
        vm.expectRevert(IHyperVaultErrors.Unauthorized.selector);
        v.clearBreach();
        vm.prank(mallory);
        vm.expectRevert(IHyperVaultErrors.Unauthorized.selector);
        v.setAgent(malloryAgent);

        // (d) The timelocked path only ever accepts a platform agent (test_OnlyPlatformAgents, test_AUDIT_A13).
        //     Round 4: a risk breach no longer blocks setAgent (only a full stop does); mallory's own key is still
        //     refused by the platform-agent check.
        bytes memory data = abi.encodeCall(HyperVault.setAgent, (malloryAgent));
        vm.prank(mallory);
        v.queue(data);
        vm.warp(v.queuedEta(keccak256(data)));
        vm.expectRevert(_callFailed(IHyperVaultErrors.NotPlatformAgent.selector));
        v.execute(data);
        vm.revertToState(snap);

        // Funds come back: nobody bought shares cheaply, alice is whole, the sybil can take its USDC back.
        _setCore(address(v), 1_000_000e6, 0, 1e6);
        assertEq(_value(v, alice), aliceStart, "alice untouched");
        assertEq(v.balanceOf(mallory2), 0);
        vm.prank(mallory2);
        v.cancelDepositRequest();
        // Round 4: the 1M the sybil sent FOR mallory sits in mallory's next-epoch request, never priced here.
        assertEq(usdc.balanceOf(mallory2), 9_000_000e6);
        assertEq(v.deferredDepositAssets(), 2_000_000e6, "both insider deposits still wait for the next epoch");
        assertEq(v.balanceOf(mallory), 0, "no shares for the insider");
    }

    /// @dev C-01 companion: honest NAV moves settle. A 10% move passes immediately, a 50% gain needs the keeper's
    ///      checkpoint to ratchet twice (20% per hour) before it can be settled.
    function test_AUDIT_C01b_legitimateMovesSettleThroughTheRatchet() public {
        (HyperVault v,) = _malloryVault();
        _fundAndDeploy(v, mallory, 1_000_000e6, 1e6);
        vm.prank(bob);
        v.requestDeposit(100_000e6, bob);

        _setCore(address(v), 1_100_000e6, 0, 1e6); // +10%
        vm.prank(mallory);
        v.settle();
        assertEq(v.currentEpoch(), 2);

        _setCore(address(v), 1_800_000e6, 0, 1e6); // +50% (true NAV 1,800,001 incl. bob's 100k)
        vm.prank(mallory);
        vm.expectPartialRevert(VaultPolicy.NavMoved.selector);
        v.settle();
        _keeperHours(v, 1); // checkpoint 1,200,001 -> 1,440,001.2
        vm.prank(mallory);
        vm.expectPartialRevert(VaultPolicy.NavMoved.selector);
        v.settle();
        _keeperHours(v, 1); // -> 1,728,001.44; 1,800,001 is within 20% of it
        vm.prank(mallory);
        v.settle();
        assertEq(v.currentEpoch(), 3);
        assertEq(v.checkpointNav(), v.totalAssets(), "settle re-anchors the checkpoint");
    }

    // ==================================================================
    // H-01  Owner could instantly disarm every risk control (clearBreach + setAgent, peak reset).
    //       Fixed by: both timelocked (queue + execute), peak never reset, platform guardian only for instant clears.
    // ==================================================================
    function test_AUDIT_H01_ownerCannotResetBreachOrRearmInstantly() public {
        (HyperVault v,) = _malloryVault();
        _fundAndDeploy(v, mallory, 1_000_000e6, 0);
        v.checkRisk(); // records the peak
        uint256 peak = v.peakSharePrice();

        _setCore(address(v), 700_000e6, 0, 0); // 30% loss, drawdown limit is 15%
        v.checkRisk();
        assertTrue(v.breached());
        // Round 4: a risk breach derisks (reduce only, agent kept) instead of shutting the vault.
        assertEq(uint8(v.breachReason()), 3, "drawdown");
        assertEq(v.agent(), platformAgent);

        vm.startPrank(mallory);
        vm.expectRevert(IHyperVaultErrors.Unauthorized.selector);
        v.clearBreach();
        vm.expectRevert(IHyperVaultErrors.Unauthorized.selector);
        v.setAgent(platformAgent);
        vm.stopPrank();

        // Timelocked clear (queued after the breach): works, but the lifetime peak stays, so the same equity
        // breaches again right away.
        bytes memory clear = abi.encodeCall(HyperVault.clearBreach, ());
        bytes memory rearm = abi.encodeCall(HyperVault.setAgent, (platformAgent));
        vm.warp(vm.getBlockTimestamp() + 1);
        vm.startPrank(mallory);
        v.queue(clear);
        v.queue(rearm);
        vm.stopPrank();
        vm.warp(v.queuedEta(keccak256(rearm)));
        v.execute(clear);
        assertFalse(v.breached());
        assertEq(v.peakSharePrice(), peak, "peak is not reset");
        (,, uint256 dd) = v.checkRisk();
        assertEq(dd, 3_000, "drawdown still measured from the lifetime peak");
        assertTrue(v.breached(), "breached again at the same equity");
        // The agent was never revoked in a risk breach; re-setting the same platform agent changes nothing.
        v.execute(rearm);
        assertEq(v.agent(), platformAgent);

        // Round 4 (by design): the OWNER ends a drawdown breach with resume(), at once, and the peak restarts from
        // the current share price, so the same NAV does not breach again. Nobody else can.
        vm.prank(stranger);
        vm.expectRevert(IHyperVaultErrors.Unauthorized.selector);
        v.resume();
        // Decision 2: not before RESUME_COOLDOWN (24h) after the breach.
        vm.prank(mallory);
        vm.expectRevert(IHyperVaultErrors.NotReady.selector);
        v.resume();
        vm.warp(vm.getBlockTimestamp() + 24 hours);
        _setCore(address(v), 700_000e6, 0, 0); // same NAV (the keeper's hourly checks kept the checkpoint close)
        vm.prank(mallory);
        v.resume();
        assertEq(v.lastResumeAt(), vm.getBlockTimestamp());
        assertFalse(v.breached());
        assertEq(v.peakSharePrice(), v.sharePrice(), "peak reset to the current price");
        (,, dd) = v.checkRisk();
        assertEq(dd, 0);
        assertFalse(v.breached());
    }

    /// @dev H-01b: emergency is the depositors' last resort. The owner cannot exit it at all (audit W-01b: only the
    ///      cold guardian can, and only once every redeemer has been paid).
    function test_AUDIT_H01b_ownerCannotExitEmergencyWithRedeemersWaiting() public {
        (HyperVault v,) = _malloryVault();
        _fundAndDeploy(v, mallory, 1_000_000e6, 0);
        _setCore(address(v), 0, 0, 1_000_000e6); // all on Core spot, freely bridgeable
        _setWithdrawable(address(v), 0);

        uint256 aliceShares = v.balanceOf(alice);
        vm.prank(alice);
        v.requestRedeem(aliceShares, alice, alice);
        vm.warp(vm.getBlockTimestamp() + 7 days);

        vm.prank(stranger);
        v.triggerEmergency();
        assertTrue(v.emergency());

        vm.prank(mallory);
        vm.expectRevert(IHyperVaultErrors.Unauthorized.selector);
        v.exitEmergency();
        bytes memory data = abi.encodeCall(HyperVault.exitEmergency, ());
        vm.prank(mallory);
        vm.expectRevert(IHyperVaultErrors.Unauthorized.selector);
        v.queue(data); // not a queueable selector any more
        vm.prank(guardian);
        vm.expectRevert(IHyperVaultErrors.RedemptionsPending.selector);
        v.exitEmergency();
        assertTrue(v.emergency(), "still in emergency");

        // The permissionless unwind completes.
        vm.prank(sentinel);
        v.bridgeToEvm(1_000_000e6);
        usdc.mint(address(v), 1_000_000e6);
        _setCore(address(v), 0, 0, 0);
        vm.roll(vm.getBlockNumber() + 11);
        v.checkRisk();
        vm.prank(sentinel);
        v.settle();
        v.claim(alice);
        assertEq(v.pendingRedeemShares(), 0);
        assertGt(usdc.balanceOf(alice), 1_000_000e6 - 1_000e6, "alice out, minus nine days of management fee");
        vm.prank(guardian);
        v.exitEmergency(); // every redeemer paid: the guardian ends it
        assertFalse(v.emergency());
    }

    // ==================================================================
    // H-02  Bridge window re-arm (1e-6 USDC every 11 blocks) kept settle() reverting forever.
    //       Fixed by: MIN_BRIDGE unless the full balance, and one window rule: nothing bridges while a window
    //       is open, so it can never be extended and closes by itself after BRIDGE_SETTLE_BLOCKS (audit N-01).
    //       Non-manager emergency bridges are only gated by that window (audit N-02).
    // ==================================================================
    function test_AUDIT_H02_bridgeWindowCannotBlockEmergencySettle() public {
        (HyperVault v,) = _malloryVault();
        _fundAndDeploy(v, mallory, 1_000_000e6, 1e6);
        _setCore(address(v), 0, 0, 1_000_001e6);
        _setWithdrawable(address(v), 0);

        uint256 aliceShares = v.balanceOf(alice);
        vm.prank(alice);
        v.requestRedeem(aliceShares, alice, alice);
        vm.warp(vm.getBlockTimestamp() + 7 days);
        vm.prank(bob);
        v.triggerEmergency();

        // Dust bridges are rejected outright.
        vm.prank(sentinel);
        vm.expectRevert(IHyperVaultErrors.BridgeTooSmall.selector);
        v.bridgeToEvm(1);

        // Rescuer bridges everything back; it arrives.
        vm.prank(sentinel);
        v.bridgeToEvm(1_000_000e6);
        uint256 opened = vm.getBlockNumber();
        usdc.mint(address(v), 1_000_000e6);
        _setCore(address(v), 0, 0, 1e6);
        // Nobody, not even the manager with a full-balance bridge, can touch the window while it is open.
        vm.prank(mallory); // hl-r2 XF01: in emergency the manager waits EMERGENCY_BRIDGE_COOLDOWN after the last bridge
        vm.expectRevert(IHyperVaultErrors.BridgeInFlight.selector);
        v.bridgeToEvm(1e6);
        vm.prank(sentinel);
        vm.expectRevert(IHyperVaultErrors.BridgeInFlight.selector);
        v.bridgeToEvm(1e6);
        vm.prank(sentinel);
        vm.expectRevert(IHyperVaultErrors.BridgeInFlight.selector);
        v.settle();
        vm.roll(opened + v.BRIDGE_SETTLE_BLOCKS() + 1);
        assertFalse(v.bridgeInFlight(), "closed by itself");
        v.checkRisk();
        vm.prank(sentinel);
        v.settle();
        v.claim(alice);
        assertEq(v.pendingRedeemShares(), 0, "alice is out");
        assertGt(usdc.balanceOf(alice), 1_000_000e6 - 1_000e6);
    }

    // ==================================================================
    // M-01  checkRisk() double counted in-flight bridges (masked a 30% drawdown; forced a false daily-loss breach).
    //       Fixed by: NAV snapshot at bridge time used inside the window; no day rollover in flight.
    // ==================================================================
    function test_AUDIT_M01a_bridgePingPongDoesNotMaskBreach() public {
        _deposit(alice, 1_000_000e6);
        _settle();
        _claim(alice);
        vm.prank(manager);
        vault.bridgeToCore(500_000e6);
        _setCore(address(vault), 500_000e6, 0, 0);
        _setWithdrawable(address(vault), 0);
        _skipBridgeWindow();
        vault.checkRisk();

        // 300k loss on Core: true equity 700k, 30% drawdown vs 15% limit.
        _setCore(address(vault), 200_000e6, 0, 0);
        vm.prank(manager);
        vault.bridgeToCore(500_000e6); // credited on Core spot immediately
        _setCore(address(vault), 200_000e6, 0, 500_000e6);
        assertEq(vault.totalAssets(), 700_000e6, "window NAV is the pre-bridge snapshot");
        vault.checkRisk();
        assertTrue(vault.breached(), "breach fires inside the window");
    }

    function test_AUDIT_M01b_dayRollInsideBridgeWindowIsDeferred() public {
        _deposit(alice, 1_000_000e6);
        _settle();
        _claim(alice);
        vault.checkRisk();

        vm.warp((vm.getBlockTimestamp() / 1 days + 1) * 1 days + 60);
        vm.prank(manager);
        vault.bridgeToCore(400_000e6);
        _setCore(address(vault), 0, 0, 400_000e6);

        vm.prank(stranger);
        vault.checkRisk();
        assertEq(vault.dayStartSharePrice(), 1e6, "no double counted baseline (round 4: share price reference)");
        assertFalse(vault.breached());

        vm.roll(vm.getBlockNumber() + 11);
        vm.prank(stranger);
        (, uint256 dailyLoss,) = vault.checkRisk();
        assertEq(dailyLoss, 0);
        assertFalse(vault.breached(), "no phantom loss");
        assertEq(vault.totalAssets(), 1_000_000e6);
    }

    // ==================================================================
    // M-02  A fee raise executed inside a bridge window skipped crystallisation and applied retroactively.
    //       Fixed by: setFees reverts in the window; a fee change crystallises the management fee at the old rate,
    //       the performance fee only ever crystallises in settle() (audit N-05).
    // ==================================================================
    function test_AUDIT_M02_feeRaiseInBridgeWindowReverts() public {
        _deposit(alice, 1_000_000e6);
        _settle();
        _claim(alice);
        vm.prank(manager);
        vault.bridgeToCore(999_999e6); // keep 1 USDC idle for the trigger bridge
        _setCore(address(vault), 999_999e6, 0, 0);
        _skipBridgeWindow();

        bytes memory data = abi.encodeCall(HyperVault.setFees, (200, 3_000));
        vm.prank(owner);
        vault.queue(data);
        vm.warp(vault.queuedEta(keccak256(data)));
        _setCore(address(vault), 1_499_999e6, 0, 0); // +50% gain earned while perf fee was 20%

        uint256 snap = vm.snapshotState();
        vault.execute(data); // honest: crystallises the management fee; the performance fee waits for settle (N-05)
        uint256 honest = _value(vault, feeRecipient);
        // hl-r2 H01 fix: the raise executes at the notice eta (epoch 7 d + 1 d), not after the 2-day delay.
        assertApproxEqAbs(honest, 657_534e3, 2e6, "eight days of management fee only");
        vm.revertToState(snap);

        vm.prank(manager);
        vault.bridgeToCore(1e6); // open a window
        vm.expectRevert(_callFailed(IHyperVaultErrors.BridgeInFlight.selector));
        vault.execute(data);
        assertEq(vault.performanceFeeBps(), 2_000, "unchanged");
        _skipBridgeWindow();
        _setCore(address(vault), 1_500_000e6, 0, 0);
        vault.execute(data);
        assertApproxEqAbs(_value(vault, feeRecipient), honest, 2e6, "same crystallisation after the window");
    }

    // ==================================================================
    // M-03  Timelocked items never expired. Fixed by: 14 day grace period on vault and policy.
    // ==================================================================
    function test_AUDIT_M03_queuedChangesExpire() public {
        bytes memory data = abi.encodeCall(HyperVault.setFees, (500, 3_000));
        vm.startPrank(owner);
        vault.queue(data);
        VaultPolicy.RiskConfig memory loose = _defaultRisk();
        loose.maxLeverageBps = 500_000;
        loose.maxDailyLossBps = 10_000;
        loose.maxDrawdownBps = 10_000;
        policy.proposeConfig(loose);
        policy.queueAllowAsset(DOGE);
        vm.stopPrank();

        vm.warp(vm.getBlockTimestamp() + 365 days);

        vm.expectRevert(IHyperVaultErrors.Expired.selector);
        vault.execute(data);
        vm.expectRevert(VaultPolicy.Expired.selector);
        policy.applyPendingConfig();
        vm.expectRevert(VaultPolicy.Expired.selector);
        policy.allowAsset(DOGE);
        assertEq(vault.managementFeeBps(), 200);
        assertEq(policy.maxLeverageBps(), 30_000);
        assertFalse(policy.isAssetAllowed(DOGE));
    }

    // ==================================================================
    // M-04  flatten() allowed 20% slippage regardless of policy; placeOrder() never checked leverage.
    //       Fixed by: policy.maxFlattenSlippageBps (tighten-only) and a projected leverage check in checkOrder.
    // ==================================================================
    function test_AUDIT_M04a_flattenSlippageCappedByPolicy() public {
        _setPosition(address(vault), BTC, int64(1_000_000)); // 10 BTC long
        assertEq(policy.maxFlattenSlippageBps(), 300);
        vm.prank(manager);
        vm.expectRevert(VaultPolicy.SlippageTooHigh.selector);
        vault.flatten(BTC, 2_000);

        vm.prank(manager);
        vault.flatten(BTC, 300);
        (,, bytes memory body) = _decode(writer.last());
        (, bool isBuy, uint64 px,,,,) = abi.decode(body, (uint32, bool, uint64, uint64, bool, uint8, uint128));
        assertFalse(isBuy);
        assertEq(px, 97_000e8, "at most 3% under a 100,000 mark");
    }

    function test_AUDIT_M04b_placeOrderChecksProjectedLeverage() public {
        _deposit(alice, 1_000e6);
        _settle();
        _setCore(address(vault), 1_000e6, 0, 0); // 1k equity, 3x policy limit
        // HL-PROXY: the settle and the pre-trade checkRisk pin the account mode (action 16): count orders only
        uint256 n = writer.count();
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(IHyperVaultErrors.OrderRejected.selector, "leverage"));
        vault.placeOrder(BTC, true, 100_000e8, 10e8, false, HyperCore.TIF_GTC, 0); // 1M notional
        vm.prank(manager);
        vault.placeOrder(BTC, true, 100_000e8, 0.03e8, false, HyperCore.TIF_GTC, 0); // 3k = 3x passes
        uint256 orders;
        for (uint256 i; i < writer.count(); ++i) {
            (, uint24 id,) = _decode(writer.at(i));
            if (id == 1) ++orders;
        }
        assertEq(orders, 1, "only the 3x order was sent");
        assertLe(writer.count() - n, 2, "the order and at most one pin");
    }

    // ==================================================================
    // M-05  Performance fees crystallised on any transient NAV high through permissionless accrueFees().
    //       Fixed by: accrueFees() mints the management fee only; the performance fee only in settle().
    // ==================================================================
    function test_AUDIT_M05_noPerfFeeOnTransientSpike() public {
        _deposit(alice, 1_000_000e6);
        _settle();
        _claim(alice);
        vm.prank(manager);
        vault.bridgeToCore(1_000_000e6);
        _setCore(address(vault), 1_000_000e6, 0, 0);
        _skipBridgeWindow();

        _setCore(address(vault), 1_500_000e6, 0, 0); // one-block mark spike
        vm.prank(stranger);
        vault.accrueFees();
        assertEq(vault.balanceOf(feeRecipient), 0, "no fee shares from the spike");
        _setCore(address(vault), 1_000_000e6, 0, 0); // back to where it was

        _settle();
        assertEq(vault.balanceOf(feeRecipient), 0, "no gain at settlement, no performance fee");
        assertEq(_value(vault, alice), 1_000_000e6);
    }

    // ==================================================================
    // Lows
    // ==================================================================
    /// L-01: notional is measured at max(limitPx, mark), so a resting buy far below mark cannot carry 10x the cap.
    function test_AUDIT_L01_notionalCapUsesMark() public view {
        (bool ok, string memory reason) =
            policy.checkOrder(BTC, true, 10_000e8, 100e8, false, 100_000e8, int64(100_000_000e6), 0);
        assertFalse(ok);
        assertEq(reason, "notional too large");
    }

    /// L-02: the lens previews include the fee shares settle() mints first, so they match the settlement.
    function test_AUDIT_L02_lensPreviewMatchesSettle() public {
        _deposit(alice, 1_000_000e6);
        _settle();
        vm.warp(vm.getBlockTimestamp() + 365 days);
        _deposit(bob, 1_000_000e6);
        uint256 preview = lens.previewDeposit(vault, 1_000_000e6);
        assertGt(preview, vault.previewDeposit(1_000_000e6), "vault previews are fee unaware");
        _settle();
        (, uint256 depShares,,,,,,) = vault.epochs(1);
        assertEq(preview, depShares, "lens preview == settle result");
    }

    /// L-03: fee dilution is not a drawdown: the peak scales with the fee mint.
    function test_AUDIT_L03_feeAccrualDoesNotTriggerDrawdownBreach() public {
        VaultPolicy.RiskConfig memory c = _defaultRisk();
        c.maxDrawdownBps = 500;
        vm.prank(owner);
        policy.proposeConfig(c); // tighter, immediate
        _deposit(alice, 1_000_000e6);
        _settle();
        vm.prank(manager);
        vault.bridgeToCore(1_000_000e6);
        _skipBridgeWindow();
        _setCore(address(vault), 1_500_000e6, 0, 0);
        _keeperHours(vault, 3); // checkpoint ratchets up to the new NAV
        uint256 peak = vault.peakSharePrice();

        _settle(); // mints the 20% performance fee: 100k on 500k, a 6.7% dilution against a 5% limit
        assertGt(vault.balanceOf(feeRecipient), 0);
        assertLt(vault.peakSharePrice(), peak, "peak scaled by the dilution");
        vm.prank(stranger);
        (,, uint256 dd) = vault.checkRisk();
        assertEq(dd, 0);
        assertFalse(vault.breached(), "no breach without a loss");
    }

    /// L-04: inside a bridge window totalAssets() is the pre-bridge snapshot, never a double count.
    function test_AUDIT_L04_viewsDoNotDoubleCountInWindow() public {
        _deposit(alice, 1_000_000e6);
        _settle();
        vm.prank(manager);
        vault.bridgeToCore(500_000e6);
        _setCore(address(vault), 0, 0, 500_000e6); // already credited
        assertEq(vault.totalAssets(), 1_000_000e6);
        assertEq(vault.convertToAssets(vault.balanceOf(address(vault))), 1_000_000e6);
    }

    /// L-05: a negative perp accountValue nets against spot before the floor.
    function test_AUDIT_L05_negativePerpEquityNetted() public {
        _setCore(address(vault), -100_000e6, 0, 300_000e6);
        assertEq(vault.coreEquity(), 200_000e6);
        _setCore(address(vault), -400_000e6, 0, 300_000e6);
        assertEq(vault.coreEquity(), 0);
    }

    /// L-06: initialize approves the agent only after the USDC deposit that creates the Core account.
    /// @dev L-06 / A-13: HyperCore drops any action sent in the transaction that creates the Core account, so the
    ///      creating transaction sends no agent approval at all; syncAgent() sends it once the account exists.
    function test_AUDIT_L06_agentApprovedAfterCoreAccountExists() public {
        vm.recordLogs();
        (HyperVault v,) = _malloryVault();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 rawAction = keccak256("RawAction(address,bytes)");
        bytes32 transfer = keccak256("Transfer(address,address,uint256)");
        bool deposit;
        for (uint256 i; i < logs.length; ++i) {
            assertTrue(logs[i].topics[0] != rawAction, "no HyperCore action inside the creating transaction");
            if (
                logs[i].topics[0] == transfer && logs[i].emitter == address(usdc)
                    && address(uint160(uint256(logs[i].topics[2]))) == address(depositWallet)
            ) deposit = true;
        }
        assertTrue(deposit, "the seed deposit activates the account");
        assertEq(v.agent(), platformAgent, "agent recorded");
        uint256 n = writer.count();
        vm.prank(stranger);
        v.syncAgent(); // a later transaction: the account exists now
        assertEq(writer.count(), n + 1, "one addApiWallet after activation");
    }

    // ==================================================================
    // Platform design (A-13 / I-06): only platform agents, platform guardian, curated assets, capped deposits.
    // ==================================================================
    function test_AUDIT_A13_managerKeyIsNeverAnAgent() public {
        vm.startPrank(mallory);
        usdc.approve(address(factory), 2e6);
        vm.expectRevert(abi.encodeWithSelector(HyperVaultFactory.NotPlatformAgent.selector, malloryAgent));
        factory.create{value: 0.01 ether}(_malloryParams(malloryAgent), _noPermit());
        vm.stopPrank();

        (HyperVault v,) = _malloryVault();
        assertEq(v.agent(), platformAgent);
        assertEq(v.guardian(), guardian, "platform guardian, not mallory");
        assertEq(v.depositCap(), CAP);

        // Mallory cannot swap the guardian for herself: there is no such call, the factory holds the roles.
        bytes memory data = abi.encodeWithSignature("setGuardian(address)", mallory);
        vm.prank(mallory);
        vm.expectRevert(IHyperVaultErrors.Unauthorized.selector);
        v.queue(data);
        assertEq(v.sentinel(), sentinel);

        // The platform guardian revokes instantly and clears instantly; Mallory can do neither.
        vm.prank(guardian);
        v.revokeAgent();
        assertEq(v.agent(), address(0));
        vm.prank(guardian);
        v.triggerBreach();
        vm.prank(guardian);
        v.clearBreach();
        assertFalse(v.breached());
    }
}
