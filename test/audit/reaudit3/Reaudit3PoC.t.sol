// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Base} from "../../Base.t.sol";
import {HyperVault} from "../../../src/HyperVault.sol";
import {BreachReason, IHyperVaultErrors as E} from "../../../src/VaultTypes.sol";

/// @notice Fourth audit pass (round 4 diff). PASS = the issue described in contracts/audit/REAUDIT3.md is present,
///         except the OK_* tests, which verify a property holds.
contract Reaudit3PoC is Base {
    address internal carol = makeAddr("carol");

    function setUp() public override {
        super.setUp();
        usdc.mint(carol, 1_000_000e6);
        vm.prank(carol);
        usdc.approve(address(vault), type(uint256).max);
        usdc.mint(manager, 1_000_000e6);
        vm.prank(manager);
        usdc.approve(address(vault), type(uint256).max);
    }

    // ------------------------------------------------------------------
    // helpers (same shape as Round4.t.sol)
    // ------------------------------------------------------------------
    function _fund(uint256 amount) internal {
        _deposit(alice, amount);
        _settle();
        _claim(alice);
        vm.prank(manager);
        vault.bridgeToCore(amount);
        _setCore(address(vault), int64(uint64(amount)), 0, 0);
        vault.syncBridge();
        _skipBridgeWindow();
        vault.checkRisk();
    }

    function _hourlyChecks(uint256 n) internal {
        for (uint256 i; i < n; ++i) {
            vm.warp(vm.getBlockTimestamp() + 1 hours);
            vault.checkRisk();
        }
    }

    function _drawdownBreach(int64 navAfter) internal {
        vm.warp((vm.getBlockTimestamp() / 1 days + 1) * 1 days + 60);
        _setCore(address(vault), navAfter, 0, 0);
        _hourlyChecks(3);
        assertEq(uint8(vault.breachReason()), uint8(BreachReason.DRAWDOWN));
    }

    /// @dev Idle USDC on HyperEVM: bob deposits `amount`, the epoch settles at an early hour of a fresh UTC day.
    function _idle(uint256 amount) internal {
        vm.warp((vm.getBlockTimestamp() / 1 days + 1) * 1 days + 60);
        vault.checkRisk(); // first check of the day: day start reference
        _deposit(bob, amount);
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        vault.checkRisk();
        vm.prank(manager);
        vault.settle();
        _claim(bob);
    }

    // ==================================================================
    // R3-01 (Medium): the EVM->Core landing signal reads Core equity, which moves with PnL
    // ==================================================================
    /// @dev A bridge to Core that has not landed after 10 blocks is "landed" as soon as unrealised PnL lifts Core
    ///      equity by the bridged amount. The window closes with the USDC still in transit; when the PnL reverts the
    ///      vault reads a false 5.7% loss and breaches (daily loss), with no real loss at all.
    function test_REAUDIT3_R301_pnlLatchesAnUnlandedBridge_falseDailyLossBreach() public {
        // FIXED (inverted): PnL no longer counts as a landing; the window waits for spot, no false breach.
        _fund(100_000e6);
        _idle(6_000e6);
        assertEq(vault.totalAssets(), 106_000e6);

        vm.prank(manager);
        vault.bridgeToCore(6_000e6); // not on Core yet
        _setCore(address(vault), 106_000e6, 300_000e6, 0); // +6,000 PnL, more than the bridged amount
        vault.syncBridge();
        vm.roll(vm.getBlockNumber() + 11);
        assertTrue(vault.bridgeInFlight(), "PnL does not land a bridge: the window stays open");
        assertEq(vault.totalAssets(), 106_000e6, "the pre-bridge snapshot");

        _setCore(address(vault), 100_000e6, 300_000e6, 0); // the move reverts
        (, uint256 daily,) = vault.checkRisk();
        assertEq(daily, 0, "no false daily loss: the in-flight amount is counted");
        assertFalse(vault.breached());

        _setCore(address(vault), 100_000e6, 300_000e6, 6_000e6); // lands on spot
        assertFalse(vault.bridgeInFlight());
        assertEq(vault.totalAssets(), 106_000e6);
    }

    function test_REAUDIT3_R301_settleRunsWithUsdcUnaccounted() public {
        // FIXED (inverted): no settle while the bridged USDC is unaccounted, whatever PnL does.
        _fund(100_000e6);
        _idle(6_000e6);
        vm.prank(manager);
        vault.bridgeToCore(6_000e6);
        _setCore(address(vault), 106_000e6, 300_000e6, 0); // +6,000 PnL, transfer still in transit
        vm.roll(vm.getBlockNumber() + 11);
        assertTrue(vault.bridgeInFlight());

        _deposit(carol, 50_000e6);
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        vault.checkRisk();
        vm.prank(manager);
        vm.expectRevert(E.BridgeInFlight.selector);
        vault.settle();

        _setCore(address(vault), 106_000e6, 300_000e6, 6_000e6); // lands: true NAV 112,000 is visible
        vm.prank(manager);
        vault.settle();
        _claim(carol);
        uint256 carolValue = vault.convertToAssets(vault.balanceOf(carol));
        assertApproxEqRel(carolValue, 50_000e6, 1e15, "carol priced at the true NAV");
    }

    // ==================================================================
    // R3-02 (Low): insider deferral is defeated by two settles in the same block
    // ==================================================================
    /// @dev The manager deposits during a 4% dip (within every limit), settles the running epoch and the next one in
    ///      the same block: the "next epoch" price is the dip price. After the recovery the manager is up ~4%.
    function test_REAUDIT3_R302_insiderDeferralBypassedByBackToBackSettles() public {
        // FIXED (inverted): the settle that would price the insider's deposit waits INSIDER_MIN_EPOCH_AGE (1 h).
        _fund(100_000e6);
        vm.warp(vm.getBlockTimestamp() + 2 hours);
        _setCore(address(vault), 96_000e6, 0, 0); // a 4% dip (daily limit 5%)
        vault.checkRisk();
        assertFalse(vault.breached());

        vm.prank(manager);
        uint256 e = vault.requestDeposit(40_000e6, manager);
        assertEq(e, vault.currentEpoch() + 1, "deferred to the next epoch");
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        vault.checkRisk();
        vm.startPrank(manager);
        vault.settle(); // epoch e-1: the manager's deposit becomes the next queue
        vm.expectRevert(E.EpochTooYoung.selector);
        vault.settle(); // epoch e in the same block: refused
        vm.stopPrank();

        // An hour later the dip is over; the deposit is priced at that NAV, no free gain.
        _setCore(address(vault), 100_000e6, 0, 0);
        vm.warp(vm.getBlockTimestamp() + vault.INSIDER_MIN_EPOCH_AGE());
        vault.checkRisk();
        vm.prank(manager);
        vault.settle();
        vault.claim(manager);
        uint256 value = vault.convertToAssets(vault.balanceOf(manager));
        assertApproxEqRel(value, 40_000e6, 1e15, "priced at the later NAV: the insider did not buy the dip");
    }

    // ==================================================================
    // R3-03 (Low): N-04 variant, a second emergency does not restart breachedAt
    // ==================================================================
    function test_REAUDIT3_R303_ownerClearQueuedBetweenTwoEmergenciesStillCounts() public {
        // FIXED (inverted): every triggerEmergency restarts breachedAt; a clear queued before it no longer counts.
        _fund(10_000e6);
        vm.prank(guardian);
        vault.triggerEmergency(); // emergency #1
        uint64 t0 = vault.breachedAt();
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        vm.prank(guardian);
        vault.exitEmergency();
        assertTrue(vault.breached());

        vm.warp(vm.getBlockTimestamp() + 1 hours);
        bytes memory data = abi.encodeCall(HyperVault.clearBreach, ());
        vm.prank(owner);
        vault.queue(data);

        vm.warp(vm.getBlockTimestamp() + 1 hours);
        vm.prank(guardian);
        vault.triggerEmergency(); // emergency #2 AFTER the queue
        assertGt(vault.breachedAt(), t0, "breachedAt restarted by the second emergency");
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        vm.prank(guardian);
        vault.exitEmergency();

        vm.warp(vm.getBlockTimestamp() + vault.timelockDelay());
        vm.expectRevert(E.NotReady.selector);
        vault.execute(data); // queued before the latest breach: refused (N-04)
        assertTrue(vault.breached());
    }

    // ==================================================================
    // R3-04 (Low): treasury may add margin in a daily loss / drawdown breach
    // ==================================================================
    function test_REAUDIT3_R304_bridgeToCoreInDrawdownBreachStarvesRedemptions() public {
        // FIXED (inverted): no added margin in a drawdown breach; the idle USDC pays bob in a redemption-only settle.
        _fund(100_000e6);
        _idle(10_000e6);
        _drawdownBreach(80_000e6);
        _redeem(bob, vault.balanceOf(bob));

        vm.prank(manager);
        vm.expectRevert(E.ReduceOnlyMode.selector);
        vault.bridgeToCore(10_000e6);
        vm.prank(manager);
        vm.expectRevert(E.ReduceOnlyMode.selector);
        vault.moveUsd(10_000e6, true);
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        vault.checkRisk();
        uint256 before = usdc.balanceOf(bob);
        vm.prank(guardian);
        vault.settle(); // redemption-only, paid from the idle USDC
        _claim(bob);
        assertGt(usdc.balanceOf(bob), before, "bob paid");
    }

    // ==================================================================
    // R3-05 (Low): an unlanded EVM-bound bridge held the window 300 blocks (now 60) and masked a loss up to its amount
    // ==================================================================
    function test_REAUDIT3_R305_unlandedBridgeMasksALossFor300Blocks() public {
        // MITIGATED (bounded, rewritten for R3-08 after STOP 3): the NAV snapshot is capped at 60 blocks; past it the
        // risk check carries an unlanded transfer as in transit for at most MAX_UNLANDED_BLOCKS (300), so a slow but
        // real landing never breaches. Only a loss up to the bridged amount is masked, and only until block 300; a
        // larger loss shows at once. The sentinel alerts on any pending window older than 30 blocks (executor).
        assertEq(vault.MAX_BRIDGE_WAIT_BLOCKS(), 60);
        assertEq(vault.MAX_UNLANDED_BLOCKS(), 300);
        _fund(100_000e6);
        vm.warp(vm.getBlockTimestamp() + 2 hours);
        vault.checkRisk();
        _setWithdrawable(address(vault), 50_000e6);
        vm.prank(manager);
        vault.bridgeToEvm(50_000e6); // the Core action never executes
        vm.roll(vm.getBlockNumber() + 61);
        _setCore(address(vault), 55_000e6, 0, 0); // a real 45% loss, under the 50k in "transit"
        assertFalse(vault.bridgeInFlight(), "the NAV snapshot is gone after 60 blocks");
        assertTrue(vault.bridgePending(), "the transfer is still carried for the risk check");
        uint256 snap = vm.snapshotState();
        vault.checkRisk();
        assertFalse(vault.breached(), "masked up to the bridged amount, at most 300 blocks");
        vm.roll(vm.getBlockNumber() + vault.MAX_UNLANDED_BLOCKS());
        vault.checkRisk();
        assertTrue(vault.breached(), "the loss is seen after at most 300 blocks");

        vm.revertToState(snap);
        _setCore(address(vault), 40_000e6, 0, 0); // a 60% loss: more than the bridged amount
        vault.checkRisk();
        assertTrue(vault.breached(), "a loss beyond the bridged amount shows at once");
    }

    // ==================================================================
    // OK: the late _rejoinCarry change resolves a rejoined request exactly like the rest of its carry run
    // ==================================================================
    function test_REAUDIT3_OK_rejoinedCarryIsPricedWithItsRun() public {
        _fund(100_000e6);
        usdc.mint(address(vault), 2_000e6); // some idle USDC for the redemption below
        _deposit(alice, 10_000e6); // alice holds shares and queues a deposit
        _deposit(bob, 5_000e6);
        _drawdownBreach(82_000e6);
        vm.prank(manager);
        vault.settle(); // redemption-only: both deposits carried
        (uint256 cf,) = vault.carry(vault.currentEpoch() - 1);
        assertGt(cf, 0);

        // alice redeems a little: her carried deposit rejoins the current epoch instead of blocking the exit
        _redeem(alice, vault.balanceOf(alice) / 100);
        (uint256 re,,) = vault.requests(alice);
        assertEq(re, vault.currentEpoch(), "rejoined");
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        vault.checkRisk();
        vm.prank(manager);
        vault.settle(); // redemption-only again: alice's redemption paid, deposit carried in the same run
        (uint256 cf2,) = vault.carry(vault.currentEpoch() - 1);
        assertEq(cf2, cf, "same carry run");
        _claim(alice); // delivers the redemption only
        (, uint256 depLeft,) = vault.requests(alice);
        assertEq(depLeft, 10_000e6);

        _setCore(address(vault), 100_000e6, 0, 0);
        vm.warp(vm.getBlockTimestamp() + 24 hours);
        vm.prank(owner);
        vault.resume();
        _hourlyChecks(2);
        uint256 aliceBefore = vault.balanceOf(alice);
        vm.prank(manager);
        vault.settle();
        _claim(alice);
        _claim(bob);
        uint256 aliceMinted = vault.balanceOf(alice) - aliceBefore;
        // same price per USDC for alice (rejoined) and bob (not rejoined)
        assertApproxEqRel(aliceMinted, vault.balanceOf(bob) * 2, 1e12, "rejoined deposit priced with its run");
        assertEq(vault.pendingDepositAssets(), 0);
    }
}
