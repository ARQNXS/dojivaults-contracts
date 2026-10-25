// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {SimBase} from "./SimBase.t.sol";
import {HyperCore} from "../../../../src/hypercore/HyperCore.sol";

/// @notice Self tests of the simulator: the vault's normal flows behave on CoreSim as on HyperCore.
contract CoreSimSelfTest is SimBase {
    function test_sim_seedLandsAndAgentSynced() public view {
        assertTrue(sim.exists(address(vault)));
        assertEq(sim.spotUsd(address(vault)), 1e6, "seed minus activation fee");
        assertEq(vault.totalAssets(), 1e6);
        assertEq(sim.agentOf(address(vault)), agent);
    }

    function test_sim_bridgeRoundTrip() public {
        _bootstrap(100_000e6);
        assertEq(sim.cash(address(vault)), 100_000e6, "on perp");
        assertEq(vault.totalAssets(), 100_001e6);
        assertEq(_trueNav(), 100_001e6);

        // Core -> EVM: the class transfer + sendAsset execute after the block, the USDC is delivered a block later.
        vm.prank(operator);
        vault.bridgeToEvm(40_000e6);
        assertEq(vault.totalAssets(), 100_001e6, "snapshot");
        sim.setEvm(1, false); // delivered one block after the Core debit
        _tick(1);
        assertEq(sim.inflightToEvm(address(vault)), 40_000e6, "debited on Core, in flight");
        assertEq(vault.totalAssets(), 100_001e6, "snapshot while in flight");
        _tick(1);
        assertEq(usdc.balanceOf(address(vault)), 40_000e6, "delivered");
        _tick(10);
        vault.syncBridge();
        assertFalse(vault.bridgePending());
        assertEq(vault.totalAssets(), 100_001e6);
    }

    function test_sim_ordersAndPnl() public {
        _bootstrap(100_000e6);
        // manager buys 1 BTC at mark (100k notional, 1x)
        vm.prank(manager);
        vault.placeOrder(BTC, true, 101_000e8, 1e8, false, HyperCore.TIF_IOC, 0);
        _tick(1);
        (int64 szi,) = sim.position(address(vault), BTC);
        assertEq(szi, 1e5);
        sim.setMark(BTC, 110_000e1);
        assertEq(vault.totalAssets(), 110_001e6, "+10k unrealised");
        assertEq(sim.ghostPnl(address(vault)), 10_000e6);
        // flatten closes at mark
        vm.prank(manager);
        vault.flatten(BTC, 0);
        _tick(1);
        (szi,) = sim.position(address(vault), BTC);
        assertEq(szi, 0);
        assertEq(sim.cash(address(vault)), 110_000e6);
    }

    function test_sim_droppedActionDoesNotRevert() public {
        _bootstrap(100_000e6);
        sim.setDropNext(HyperCore.ACTION_SEND_ASSET, 1);
        vm.prank(operator);
        vault.bridgeToEvm(40_000e6);
        _tick(2);
        assertEq(sim.droppedActions(), 1);
        assertEq(sim.spotUsd(address(vault)), 40_000e6, "class transfer applied, send dropped");
        assertEq(usdc.balanceOf(address(vault)), 0);
    }
}
