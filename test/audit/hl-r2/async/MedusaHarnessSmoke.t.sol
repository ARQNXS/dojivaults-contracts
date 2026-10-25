// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {MedusaConservation} from "./MedusaConservation.sol";
import {PrecompileForwarderS, CoreWriterForwarderS, SimHypeSink} from "./CoreSim.sol";

/// @notice The Medusa harness deploys and its properties hold after a few calls (run under forge, no Medusa needed).
contract MedusaHarnessSmoke is Test {
    function test_medusaHarnessDeploysAndHolds() public {
        // what medusa.json predeployedContracts does
        bytes memory pc = address(new PrecompileForwarderS()).code;
        address[9] memory a = [address(0x801), address(0x803), address(0x806), address(0x807), address(0x809), address(0x80a), address(0x80F), address(0x810), address(0x813)];
        for (uint256 i; i < a.length; ++i) vm.etch(a[i], pc);
        vm.etch(address(0x3333333333333333333333333333333333333333), address(new CoreWriterForwarderS()).code);
        vm.etch(address(0x2222222222222222222222222222222222222222), address(new SimHypeSink()).code);
        MedusaConservation m = new MedusaConservation();
        m.deposit(1, 20_000e6);
        m.roll(5);
        m.keeperCycleProxy();
        m.settle(1);
        m.redeem(0, 5_000);
        m.bridgeToEvm(2, 30_000e6);
        m.roll(30);
        m.syncBridge();
        assertTrue(m.property_C1_conservation());
        assertTrue(m.property_C2_reserveBacked());
        assertTrue(m.property_C3_owedCovered());
        assertTrue(m.property_F_fairness());
        assertTrue(m.property_F_fees());
        assertTrue(m.property_F_claims());
    }
}
