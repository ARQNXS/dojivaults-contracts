// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {MutBase} from "./MutBase.t.sol";

/// @title hl-r2 mutation kill tests: the Core -> EVM landing signal (VaultMath.bridgeArrived, EVM side)
/// @notice The EVM-side landing check is `balance + evmOutSinceBridge >= evmAtBridge + evmInSinceBridge + want`.
///         Depositor USDC that moves during the window (requestDeposit in, cancelDepositRequest / claim out) must
///         not be read as the bridge landing (a false landing closes the window with the transfer in transit and
///         reads the NAV short by the bridged amount) nor hide a real landing. No earlier test moved depositor
///         USDC inside a Core -> EVM window, so deleting any of the three trackers survived the existing suite.
contract HLR2MutBridgeTest is MutBase {
    /// Mutants: VaultLogic.requestDeposit `$.evmInSinceBridge += assets` deleted / turned into `-=`.
    /// A deposit made while 5,000 USDC are in flight from Core is not the landing.
    function test_HLR2_M01_kills_requestDepositEvmInNotTracked() public {
        _fund(10_000e6);
        _bridgeHome(5_000e6, 5_000e6, false); // left Core, not on HyperEVM yet
        _deposit(bob, 5_000e6); // same size as the bridge, inside the window
        vm.roll(vm.getBlockNumber() + 11); // past BRIDGE_SETTLE_BLOCKS
        vault.syncBridge();
        assertTrue(vault.bridgePending(), "a deposit is not the landing");
        assertEq(vault.totalAssets(), 10_000e6, "NAV is the pre-bridge snapshot, not 5,000 short");
        // the real landing then closes it
        usdc.mint(address(vault), 5_000e6);
        vault.syncBridge();
        assertFalse(vault.bridgePending(), "landed");
        assertEq(vault.totalAssets(), 10_000e6, "bob's queued deposit is not NAV");
    }

    /// Mutants: VaultLogic.cancelDepositRequest `$.evmOutSinceBridge += assets` deleted / turned into `-=`.
    /// A deposit cancelled inside the window must not hide the landing (settlement would wait up to 300 blocks).
    function test_HLR2_M02_kills_cancelDepositEvmOutNotTracked() public {
        _fund(10_000e6);
        _deposit(bob, 5_000e6);
        _bridgeHome(5_000e6, 5_000e6, false);
        vm.prank(bob);
        vault.cancelDepositRequest(); // 5,000 USDC leave inside the window
        usdc.mint(address(vault), 5_000e6); // the bridge lands
        vm.roll(vm.getBlockNumber() + 11);
        vault.syncBridge();
        assertFalse(vault.bridgePending(), "the landing is seen despite the cancel");
        assertEq(vault.totalAssets(), 10_000e6);
    }

    /// Mutants: VaultLogic._claimIfSettled `$.evmOutSinceBridge += assets` deleted / turned into `-=`.
    function test_HLR2_M03_kills_claimEvmOutNotTracked() public {
        _fund(10_000e6);
        _redeem(alice, vault.balanceOf(alice) / 2);
        _bridgeHome(5_000e6, 5_000e6, true);
        vault.syncBridge();
        _skipBridgeWindow();
        _settle(); // pays ~5,000 to alice's claim reserve
        uint256 reserved = vault.claimableRedeemAssets();
        assertGt(reserved, 4_900e6);
        _bridgeHome(2_000e6, 3_000e6, false);
        _claim(alice); // ~5,000 USDC leave inside the window
        usdc.mint(address(vault), 2_000e6); // the bridge lands
        vm.roll(vm.getBlockNumber() + 11);
        vault.syncBridge();
        assertFalse(vault.bridgePending(), "the landing is seen despite the claim");
    }

    /// Mutant: VaultLogic._arm `$.spotAtBridge = VaultMath.coreSpotUsd()` deleted (stale snapshot from the last
    /// bridge). USDC already sitting on Core spot must not be read as the landing of a new EVM -> Core bridge.
    function test_HLR2_M04_kills_spotSnapshotNotRefreshed() public {
        _fund(10_000e6); // first bridge: spot snapshot 0
        _setCore(address(vault), 5_000e6, 0, 5_000e6); // 5,000 moved back to spot by the treasury
        _deposit(bob, 5_000e6);
        vm.warp(vm.getBlockTimestamp() + 2 hours);
        _settle();
        _claim(bob);
        vm.prank(manager);
        vault.bridgeToCore(5_000e6); // in transit: spot still 5,000
        vm.roll(vm.getBlockNumber() + 11);
        vault.syncBridge();
        assertTrue(vault.bridgePending(), "spot that was already there is not the landing");
        assertEq(vault.totalAssets(), 15_000e6, "NAV is the snapshot, not 5,000 short");
    }

    /// Mutant: VaultLogic._arm `$.evmInSinceBridge = 0` deleted: a deposit of the last window would make the next
    /// landing invisible (settlement and treasury actions wait up to MAX_UNLANDED_BLOCKS for nothing).
    function test_HLR2_M05_kills_evmInNotReset() public {
        _fund(10_000e6);
        _bridgeHome(2_000e6, 8_000e6, false);
        _deposit(bob, 5_000e6); // evmIn = 5,000 in window 1
        usdc.mint(address(vault), 2_000e6);
        vm.roll(vm.getBlockNumber() + 11);
        vault.syncBridge();
        assertFalse(vault.bridgePending(), "window 1 landed");
        _bridgeHome(2_000e6, 6_000e6, true); // window 2 lands at once
        vm.roll(vm.getBlockNumber() + 11);
        vault.syncBridge();
        assertFalse(vault.bridgePending(), "window 2 landed");
        assertEq(vault.totalAssets(), 10_000e6);
    }

    /// Mutant: VaultLogic._arm `$.evmOutSinceBridge = 0` deleted: a cancel of the last window would make the next
    /// bridge look landed while its USDC is still in transit (NAV read short by the bridged amount).
    function test_HLR2_M06_kills_evmOutNotReset() public {
        _fund(10_000e6);
        _deposit(bob, 5_000e6);
        _bridgeHome(2_000e6, 8_000e6, false);
        vm.prank(bob);
        vault.cancelDepositRequest(); // evmOut = 5,000 in window 1
        usdc.mint(address(vault), 2_000e6);
        vm.roll(vm.getBlockNumber() + 11);
        vault.syncBridge();
        assertFalse(vault.bridgePending(), "window 1 landed");
        _bridgeHome(2_000e6, 6_000e6, false); // window 2 in transit
        vm.roll(vm.getBlockNumber() + 11);
        vault.syncBridge();
        assertTrue(vault.bridgePending(), "window 2 has not landed");
        assertEq(vault.totalAssets(), 10_000e6, "NAV is the snapshot, not 2,000 short");
    }

    /// Past fix M-01 (second half) reverted: VaultGovernance._check rolls the day inside a bridge window
    /// (`&& !inFlight` deleted). test_AUDIT_M01b_* no longer catches it: since R-01 / N-01b the in-window equity is
    /// min(snapshot, live + in flight), which no longer double counts. But it understates an in-window gain, and a
    /// day started from it masks the next loss of up to that gain. Here: +10% in the window, then -9.1%: the daily
    /// loss limit (5%) must fire.
    function test_HLR2_M10_kills_dayRollInsideTheWindow() public {
        _deposit(alice, 1_000_000e6);
        _settle();
        _claim(alice);
        vault.checkRisk();
        vm.warp((vm.getBlockTimestamp() / 1 days + 1) * 1 days + 60); // a new UTC day, not yet rolled
        vm.prank(manager);
        vault.bridgeToCore(400_000e6);
        _setCore(address(vault), 100_000e6, 0, 400_000e6); // landed on spot, and +100k of PnL on perp
        vm.prank(stranger);
        vault.checkRisk(); // inside the window
        vm.roll(vm.getBlockNumber() + 11);
        vm.prank(stranger);
        vault.checkRisk(); // out of the window: the day starts here
        assertApproxEqRel(vault.dayStartSharePrice(), 1.1e6, 1e15, "the day starts from the real price");
        _setCore(address(vault), 0, 0, 400_000e6); // the gain is lost again: -9.1% on the day
        vm.prank(stranger);
        (, uint256 daily,) = vault.checkRisk();
        assertGt(daily, 500);
        assertTrue(vault.breached(), "daily loss breach");
    }

    /// Past fix R-02 (latch) reverted: VaultLogic._syncBridge never latches the landing. Once a landed transfer is
    /// moved on (moveUsd to perp) the landing signal reads false again and, inside MAX_BRIDGE_WAIT_BLOCKS, the window
    /// reopens: NAV falls back to the stale snapshot (a 2,000 loss is masked) and settlement is blocked again.
    function test_HLR2_M11_kills_landingNeverLatched() public {
        _fund(10_000e6);
        _deposit(bob, 5_000e6);
        vm.warp(vm.getBlockTimestamp() + 2 hours);
        _settle();
        _claim(bob);
        vm.prank(manager);
        vault.bridgeToCore(5_000e6);
        _setCore(address(vault), 10_000e6, 0, 5_000e6); // landed on spot
        vm.roll(vm.getBlockNumber() + 1);
        vault.syncBridge();
        vm.roll(vm.getBlockNumber() + 11);
        vm.prank(manager);
        vault.moveUsd(5_000e6, true); // the treasury funds perp margin with it
        _setCore(address(vault), 13_000e6, 0, 0); // and the perp account then loses 2,000
        assertFalse(vault.bridgePending(), "a landed bridge never reopens");
        assertEq(vault.totalAssets(), 13_000e6, "the loss is visible");
    }

    /// Mutant: moveUsd's leading `_syncBridge($)` deleted. moveUsd is often the first call after a landing: it must
    /// latch the landing before it moves the landed USDC on, or the window reopens (stale NAV, settle blocked).
    function test_HLR2_M45_kills_moveUsdDoesNotLatch() public {
        _fund(10_000e6);
        _deposit(bob, 5_000e6);
        vm.warp(vm.getBlockTimestamp() + 2 hours);
        _settle();
        _claim(bob);
        vm.prank(manager);
        vault.bridgeToCore(5_000e6);
        _setCore(address(vault), 10_000e6, 0, 5_000e6); // landed on spot
        vm.roll(vm.getBlockNumber() + 11);
        vm.prank(manager);
        vault.moveUsd(5_000e6, true); // first call after the landing
        _setCore(address(vault), 13_000e6, 0, 0);
        assertFalse(vault.bridgePending(), "latched by moveUsd");
        assertEq(vault.totalAssets(), 13_000e6);
    }

    /// Mutants: VaultMath.bridgeArrived tolerance (`BRIDGE_LANDING_TOLERANCE` doubled, removed from the `>` test so
    /// a bridge below 1 USDC underflows, `want` 0 -> 1) and coreSpotUsd's `/ 100` -> `* 100`. A transfer is landed
    /// when it shows up within 1 USDC (the activation fee), not when it is 1.5 USDC short; a full-amount bridge
    /// below 1 USDC must not break the NAV views; a 1% landing on spot is not a landing.
    function test_HLR2_M49_kills_landingTolerance() public {
        _setCore(address(vault), 0, 0, 200e6);
        vm.prank(manager);
        vault.bridgeToEvm(200e6);
        _setCore(address(vault), 0, 0, 0);
        usdc.mint(address(vault), 198_500_000); // 1.5 USDC short
        vm.roll(vm.getBlockNumber() + 11);
        assertTrue(vault.bridgePending(), "1.5 USDC short is not landed");
        usdc.mint(address(vault), 600_000); // 0.9 USDC short: within the tolerance
        assertFalse(vault.bridgePending(), "landed within 1 USDC");

        // a full-amount bridge of 0.5 USDC
        _setCore(address(vault), 0, 0, 500_000);
        vm.prank(manager);
        vault.bridgeToEvm(500_000);
        _setCore(address(vault), 0, 0, 0);
        assertEq(vault.totalAssets(), 199_100_000 + 500_000, "views work (the snapshot)");
        vm.roll(vm.getBlockNumber() + 11);
        vault.syncBridge();
        assertFalse(vault.bridgePending(), "nothing to wait for below the tolerance");

        // EVM -> Core: 1% of the amount on spot is not the landing
        _deposit(alice, 1_000e6);
        _settle();
        _claim(alice);
        vm.prank(manager);
        vault.bridgeToCore(1_000e6);
        _setCore(address(vault), 0, 0, 10e6);
        vm.roll(vm.getBlockNumber() + 11);
        assertTrue(vault.bridgePending(), "10 of 1,000 USDC is not landed");
    }
}
