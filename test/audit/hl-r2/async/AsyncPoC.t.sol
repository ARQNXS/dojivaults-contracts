// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {SimBase} from "./SimBase.t.sol";
import {HyperVault} from "../../../../src/HyperVault.sol";
import {HyperCore} from "../../../../src/hypercore/HyperCore.sol";
import {IHyperVaultErrors} from "../../../../src/VaultTypes.sol";

/// @notice hl-r2 async PoCs on CoreSim. Each test passes while the behaviour it documents exists.
/// Run: forge test --match-path test/audit/hl-r2/async/AsyncPoC.t.sol -vv
contract AsyncPoC is SimBase {

    // ==================================================================
    // HLR2-A03: the agent hides a landing (spot -> perp) or makes a bridge fail (consumes withdrawable): settle,
    // bridges and moveUsd wait 300 blocks and checkRisk masks a loss up to the bridged amount for that time.
    // ==================================================================
    function test_HLR2_A03_agentHidesLandingFreezesSettleAndMasksLoss() public {
        _bootstrap(100_000e6);
        _deposit(bob, 50_000e6);
        _warp(1 hours);
        _keeperSettle();
        vault.claim(bob);

        vm.prank(operator);
        vault.bridgeToCore(50_000e6);
        // Same Core block as the credit: the agent moves the landed USDC on to perp.
        sim.agentAct(address(vault), agent, 1, 0, int256(50_000e6));
        _tick(2);
        assertEq(sim.spotUsd(address(vault)), 1e6, "landing never visible on spot");
        assertEq(sim.cash(address(vault)), 150_000e6);
        vault.syncBridge();
        assertTrue(vault.bridgePending());

        // A 45k loss (30% of NAV, over the 20% daily limit) is masked: min(snapshot, live + amount) = snapshot.
        sim.shock(address(vault), -45_000e6);
        _tick(70);
        (, uint256 daily,) = vault.checkRisk();
        assertEq(daily, 0, "30% loss reads 0");
        assertFalse(vault.breached());
        _deposit(carol, 10_000e6);
        vm.prank(operator);
        vm.expectRevert(IHyperVaultErrors.BridgeInFlight.selector);
        vault.settle();
        vm.prank(operator);
        vm.expectRevert(IHyperVaultErrors.BridgeInFlight.selector);
        vault.moveUsd(1e6, false);

        _tick(MAX_UNLANDED() - 70);
        (, daily,) = vault.checkRisk();
        assertGt(daily, 2_000, "seen only after 300 blocks");
        assertTrue(vault.breached());
    }

    function test_HLR2_A03_agentMakesBridgeHomeFail() public {
        _bootstrap(100_000e6);
        uint256 w = HyperCore.withdrawable(address(vault));
        // In the same Core block, ahead of the vault's CoreWriter actions, the agent opens 9x notional: withdrawable
        // drops below what the class transfer needs. The EVM tx still reads the pre-block state (100k withdrawable).
        sim.agentAct(address(vault), agent, 3, BTC, 9e5);
        vm.prank(operator);
        vault.bridgeToEvm(50_000e6);
        _tick(3);
        assertLt(HyperCore.withdrawable(address(vault)), w - 50_000e6);
        assertEq(usdc.balanceOf(address(vault)), 0, "nothing came home");
        assertGt(sim.failedActions(), 0);
        assertTrue(vault.bridgePending(), "pending for 300 blocks");
        _tick(MAX_UNLANDED());
        assertFalse(vault.bridgePending());
    }

    // ==================================================================
    // HLR2-A06 (Info): a negative perp account value (liquidation shortfall transient) is netted against spot USDC
    // in coreEquity (one-sum floor, L-05). Moving the spot home removes the netting: NAV jumps by the shortfall.
    // ==================================================================
    function test_HLR2_A06_negativePerpNettedAgainstSpot() public {
        _bootstrap(100_000e6);
        // 50k back on spot, then the remaining 50k perp margin is wiped and 10k more (a shortfall before the backstop).
        vm.prank(operator);
        vault.moveUsd(50_000e6, false);
        _tick(2);
        sim.shock(address(vault), -60_000e6);
        assertEq(sim.accountValue(address(vault)), -10_000e6);
        assertEq(vault.totalAssets(), 40_001e6, "spot 50,001 netted against -10k perp");
        // The full spot can still be bridged home (spot is not perp collateral outside unified / portfolio margin).
        vm.prank(operator);
        vault.bridgeToEvm(50_001e6);
        _tick(MAX_UNLANDED() + 1);
        vault.syncBridge();
        assertEq(usdc.balanceOf(address(vault)), 50_001e6);
        assertEq(vault.totalAssets(), 50_001e6, "netting gone: +25% NAV without any PnL");
    }
}
