// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {SimBase} from "../async/SimBase.t.sol";
import {HyperCore} from "../../../../src/hypercore/HyperCore.sol";
import {IHyperVaultErrors} from "../../../../src/VaultTypes.sol";

/// @notice hl-r2 fix tests for HLR2-A08 (High), HLR2-A02 (Medium) and HLR2-A05 (Low): while a transfer is missing
///         past MAX_UNLANDED_BLOCKS and the NAV reads short by it, nothing settles or bridges, for at most
///         UNRESOLVED_WAIT_BLOCKS or until it lands or the guardian writes it off
///         (fixes/patches/a-series/HLR2-A-SERIES.integrated.patch, on the integrated stack).
contract HLR2_A08_Fix is SimBase {
    uint256 internal constant UNRESOLVED_WAIT = 86_400;

    function _walkAndSettle(address who) internal {
        vault.checkRisk(); // E01: walk the checkpoint first, then settle at the walked (fair) price
        _settleBy(who);
    }

    /// The A08 PoC with the patch: the exit settle waits for the landing and then pays alice in full.
    function test_HLR2_A08_fix_exitSettleWaitsForTheLandingAndPaysInFull() public {
        _bootstrap(100_000e6);
        _redeem(alice, vault.balanceOf(alice));
        vm.prank(owner);
        vault.triggerEmergency();
        _tick(331); // XF01: the operator's emergency bridge waits out the cooldown after the bootstrap bridge
        sim.setEvm(2_000, false);
        uint256 all = sim.spotUsd(address(vault)) + HyperCore.withdrawable(address(vault));
        vm.prank(operator);
        vault.bridgeToEvm(all);
        _tick(MAX_UNLANDED() + 1);
        assertEq(vault.totalAssets(), 0, "NAV reads 0");
        assertTrue(vault.bridgeUnresolved());

        vm.prank(operator);
        vm.expectRevert(IHyperVaultErrors.TransferUnresolved.selector);
        vault.settle();
        vm.prank(guardian);
        vm.expectRevert(IHyperVaultErrors.TransferUnresolved.selector);
        vault.settle();

        _tick(2_000); // the transfer lands
        assertFalse(vault.bridgeUnresolved());
        _walkAndSettle(operator);
        uint256 a0 = usdc.balanceOf(alice);
        vault.claim(alice);
        uint256 paid = usdc.balanceOf(alice) - a0;
        emit log_named_uint("alice paid for 100,001", paid);
        assertGt(paid, 99_900e6, "alice is paid her value, not ~0");
    }

    /// The A02 PoC with the patch: carol's deposit is not priced at the deflated NAV.
    function test_HLR2_A02_fix_depositNotPricedAtTheShortNav() public {
        _bootstrap(100_000e6);
        _warp(1 hours);
        vault.checkRisk();
        sim.setEvm(400, false);
        vm.prank(operator);
        vault.bridgeToEvm(15_000e6);
        _tick(MAX_UNLANDED() + 1);
        assertEq(vault.totalAssets(), 85_001e6, "NAV reads 15% low");

        _deposit(carol, 85_000e6);
        vm.prank(operator);
        vm.expectRevert(IHyperVaultErrors.TransferUnresolved.selector);
        vault.settle();

        _tick(200); // lands
        _warp(1 hours);
        _walkAndSettle(operator);
        vault.claim(carol);
        uint256 carolValue = _valueOf(carol);
        emit log_named_uint("carol value for 85,000", carolValue);
        assertLt(carolValue, 85_100e6, "carol gets no windfall");
        assertGt(_valueOf(alice), 99_900e6, "alice keeps her 100k");
    }

    /// The A02 full-exit PoC with the patch: alice's exit waits for the landing, the fee holders get nothing of it.
    function test_HLR2_A02_fix_fullExitWaitsAndFeeHoldersGetNothing() public {
        _bootstrap(100_000e6);
        _warp(30 days);
        vault.checkRisk();
        vm.prank(operator);
        vault.bridgeToEvm(85_000e6);
        _tick(2);
        vault.syncBridge();
        _tick(11);
        sim.setEvm(1_000, false);
        vm.prank(operator);
        vault.bridgeToEvm(15_001e6);
        _tick(MAX_UNLANDED() + 1);

        _redeem(alice, vault.balanceOf(alice));
        vm.prank(operator);
        vm.expectRevert(IHyperVaultErrors.TransferUnresolved.selector);
        vault.settle();
        _tick(1_000); // lands
        _walkAndSettle(operator);
        uint256 a0 = usdc.balanceOf(alice);
        vault.claim(alice);
        uint256 alicePaid = usdc.balanceOf(alice) - a0;
        emit log_named_uint("alice paid", alicePaid);
        emit log_named_uint("fee holders' value", _valueOf(feeRecipient) + _valueOf(treasury));
        assertGt(alicePaid, 99_000e6, "alice is paid the late 15k too");
        assertLt(_valueOf(feeRecipient) + _valueOf(treasury), 1_000e6, "the fee holders keep only their fees");
    }

    /// A05 with the patch: no new bridge while the old transfer is unresolved, so its late arrival cannot latch one.
    function test_HLR2_A05_fix_noNewBridgeWhileUnresolved() public {
        _bootstrap(100_000e6);
        sim.setEvm(400, false);
        vm.prank(operator);
        vault.bridgeToEvm(30_000e6);
        _tick(MAX_UNLANDED() + 1);
        vm.prank(operator);
        vm.expectRevert(IHyperVaultErrors.TransferUnresolved.selector);
        vault.bridgeToEvm(15_000e6);
        _tick(100); // the old 30k lands
        vault.syncBridge();
        vm.prank(operator);
        vault.bridgeToEvm(15_000e6);
        assertTrue(vault.bridgePending(), "the new bridge has its own window");
    }

    /// Control: a transfer that never lands stops holding the settles after UNRESOLVED_WAIT_BLOCKS (counted as lost,
    /// as before the patch): exits are delayed, never frozen.
    function test_HLR2_A08_fix_control_holdEndsAfterTheWait() public {
        _bootstrap(100_000e6);
        _warp(1 hours);
        vault.checkRisk();
        sim.setEvm(UNRESOLVED_WAIT + 10_000, false);
        vm.prank(operator);
        vault.bridgeToEvm(15_000e6);
        _tick(MAX_UNLANDED() + 1);
        _deposit(carol, 1_000e6);
        vm.prank(operator);
        vm.expectRevert(IHyperVaultErrors.TransferUnresolved.selector);
        vault.settle();
        _tick(UNRESOLVED_WAIT);
        assertFalse(vault.bridgeUnresolved());
        _walkAndSettle(operator);
    }

    /// The guardian (only) ends the hold early.
    function test_HLR2_A08_fix_guardianWritesOff() public {
        _bootstrap(100_000e6);
        _warp(1 hours);
        vault.checkRisk();
        vm.prank(guardian);
        vm.expectRevert(IHyperVaultErrors.NotUnresolved.selector);
        vault.writeOffBridge();

        sim.setEvm(UNRESOLVED_WAIT + 10_000, false);
        vm.prank(operator);
        vault.bridgeToEvm(15_000e6);
        _tick(MAX_UNLANDED() + 1);
        vm.prank(owner);
        vm.expectRevert(IHyperVaultErrors.Unauthorized.selector);
        vault.writeOffBridge();
        vm.prank(operator);
        vm.expectRevert(IHyperVaultErrors.Unauthorized.selector);
        vault.writeOffBridge();

        vm.prank(guardian);
        vault.writeOffBridge();
        assertFalse(vault.bridgeUnresolved());
        _deposit(carol, 1_000e6);
        _walkAndSettle(operator);
    }

    /// No false hold on a real loss: the agent hides the landing (moves it to perp), so the landing signal misses it,
    /// and later the vault loses 40k unrealised. The NAV reads short against the pre-bridge snapshot, but the credit
    /// was seen in spot + perp cash, so nothing is held.
    function test_HLR2_A08_fix_realLossAfterAHiddenLandingHoldsNothing() public {
        _bootstrap(100_000e6);
        _deposit(bob, 50_000e6);
        _warp(1 hours);
        _keeperSettle();
        vault.claim(bob);
        sim.agentAct(address(vault), agent, 3, BTC, 4e5); // 4 BTC long, 400k notional
        _tick(1);
        vm.prank(operator);
        vault.bridgeToCore(50_000e6);
        sim.agentAct(address(vault), agent, 1, 0, int256(50_000e6)); // hides the landing on perp
        _tick(2);
        _tick(MAX_UNLANDED());
        assertFalse(vault.bridgePending());
        sim.setMark(BTC, 90_000e1); // -10%: -40k unrealised
        assertLt(vault.totalAssets() + 25_000e6, vault.equityAtBridge(), "the NAV reads short against the snapshot");
        assertFalse(vault.bridgeUnresolved(), "the credit was seen in cash: no hold");
        vault.syncBridge();
        assertFalse(vault.bridgeUnresolved());
    }

    /// No false hold: a bridge home that fails at its source (A03, the agent consumed withdrawable) leaves the NAV
    /// whole, so the settles run after MAX_UNLANDED_BLOCKS exactly as before.
    function test_HLR2_A08_fix_failedSendHoldsNothing() public {
        _bootstrap(100_000e6);
        _warp(1 hours);
        vault.checkRisk();
        sim.agentAct(address(vault), agent, 3, BTC, 9e5);
        vm.prank(operator);
        vault.bridgeToEvm(50_000e6);
        _tick(3);
        assertEq(usdc.balanceOf(address(vault)), 0, "nothing came home");
        _tick(MAX_UNLANDED());
        assertFalse(vault.bridgeUnresolved(), "the NAV is whole: no hold");
        _deposit(carol, 1_000e6);
        _walkAndSettle(operator);
    }
}
