// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {SimBase} from "../async/SimBase.t.sol";

/// @notice hl-r2 fix tests for HLR2-A04 (Low) and the landing signal under the A02 / A08 hold: an EVM -> Core transfer
///         has landed when spot AND spot + perp cash (rawUsd plus the signed entry notional of the listed markets)
///         are up by the amount (fixes/patches/a-series/HLR2-A-SERIES.integrated.patch). CoreSim reports rawUsd as
///         mainnet does (cash minus the signed entry notional, checked on an HLP child account on 2026-10-21) and
///         books a pnlShock as realised (perp cash).
contract HLR2_A03A04_Fix is SimBase {
    function _bobIn(uint256 amount) internal {
        _bootstrap(100_000e6);
        _deposit(bob, amount);
        _warp(1 hours);
        _keeperSettle();
        vault.claim(bob);
        _warp(1 hours);
        vault.checkRisk();
    }

    /// A04 with the patch: the agent's perp -> spot move does not fake the landing; the window stays open until the
    /// late credit lands, and carol's deposit is priced at the fair NAV.
    function test_HLR2_A04_fix_perpToSpotDoesNotFakeTheLanding() public {
        _bobIn(20_000e6);
        sim.setDeposit(100, false);
        vm.prank(operator);
        vault.bridgeToCore(20_000e6);
        sim.agentAct(address(vault), agent, 2, 0, int256(20_000e6));
        _tick(2);
        vault.syncBridge();
        _tick(10);
        assertTrue(vault.bridgePending(), "not latched by the agent's move");
        assertEq(sim.inflightToCore(address(vault)), 20_000e6);

        _tick(100); // the credit lands
        vault.syncBridge();
        assertFalse(vault.bridgePending());
        _deposit(carol, 100_000e6);
        _keeperSettle();
        vault.claim(carol);
        uint256 carolValue = _valueOf(carol);
        emit log_named_uint("carol value for 100k", carolValue);
        assertLt(carolValue, 100_010e6, "no windfall");
        assertGt(carolValue, 99_990e6);
    }

    /// A realised gain larger than the amount (the R301 sensitivity sequence) does not fake the landing either.
    function test_HLR2_A04_fix_realisedGainDoesNotFakeTheLanding() public {
        _bobIn(50_000e6);
        sim.setDeposit(2_000, false);
        vm.prank(operator);
        vault.bridgeToCore(5_000e6);
        sim.shock(address(vault), 8_000e6);
        _tick(15);
        vault.syncBridge();
        assertTrue(vault.bridgePending(), "+8k realised is not the 5k credit");
    }

    /// The entry notional keeps the cash side honest: a 400k long fill in the credit's Core block moves rawUsd by
    /// -400k, and the landing is still seen when the window closes (with rawUsd alone it would wait 300 blocks).
    function test_HLR2_A04_fix_fillDoesNotHideTheLanding() public {
        _bobIn(20_000e6);
        vm.prank(operator);
        vault.bridgeToCore(20_000e6);
        sim.agentAct(address(vault), agent, 3, BTC, 4e5);
        _tick(2);
        assertLt(sim.rawUsd(address(vault)), 0, "rawUsd moved by the fill's notional");
        vault.syncBridge();
        _tick(9);
        assertFalse(vault.bridgePending(), "landed in spite of the fill");
    }

    /// Residual (documented, agent only): a perp -> spot move AND a realised gain of the amount fake the landing.
    /// On an HL proxy vault there is no API wallet to make the move.
    function test_HLR2_A04_residual_moveAndRealisedGainFake() public {
        _bobIn(20_000e6);
        sim.setDeposit(100, false);
        vm.prank(operator);
        vault.bridgeToCore(20_000e6);
        sim.agentAct(address(vault), agent, 2, 0, int256(20_000e6));
        sim.shock(address(vault), 20_000e6);
        _tick(2);
        vault.syncBridge();
        _tick(10);
        assertFalse(vault.bridgePending(), "residual: latched");
    }

    /// A03 stays (Low, liveness): the agent moves the landed USDC on to perp, the window runs to MAX_UNLANDED_BLOCKS,
    /// but after it nothing is held: the NAV is whole.
    function test_HLR2_A03_residual_hiddenLandingHoldsNothingAfterTheCap() public {
        _bobIn(50_000e6);
        vm.prank(operator);
        vault.bridgeToCore(50_000e6);
        sim.agentAct(address(vault), agent, 1, 0, int256(50_000e6));
        _tick(2);
        vault.syncBridge();
        _tick(70);
        assertTrue(vault.bridgePending(), "runs to the cap");
        _tick(MAX_UNLANDED());
        assertFalse(vault.bridgePending());
        assertFalse(vault.bridgeUnresolved(), "the NAV is whole: no hold");
        _deposit(carol, 1_000e6);
        _keeperSettle();
    }
}
