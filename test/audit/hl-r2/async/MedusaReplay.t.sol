// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {MedusaConservation} from "./MedusaConservation.sol";
import {CoreSim, PrecompileForwarderS, CoreWriterForwarderS, SimHypeSink} from "./CoreSim.sol";
import {HyperVault} from "../../../../src/HyperVault.sol";

/// @notice Replays the call sequence of the Medusa property failure (INVARIANTS.md section 7) under forge. It was an
///         HLR2-A04 fake landing (agent perp -> spot queued in the same block as a to-Core bridge) that the classifier
///         missed; after the classifier fix the property holds on this sequence.
contract MedusaReplay is Test {
    function test_medusaReplay_F_fairness() public {
        bytes memory pc = address(new PrecompileForwarderS()).code;
        address[9] memory a = [address(0x801), address(0x803), address(0x806), address(0x807), address(0x809), address(0x80a), address(0x80F), address(0x810), address(0x813)];
        for (uint256 i; i < a.length; ++i) vm.etch(a[i], pc);
        vm.etch(address(0x3333333333333333333333333333333333333333), address(new CoreWriterForwarderS()).code);
        vm.etch(address(0x2222222222222222222222222222222222222222), address(new SimHypeSink()).code);
        MedusaConservation m = new MedusaConservation();
        HyperVault v = m.vault();
        CoreSim s = m.sim();
        _at(1000325);
        m.bridgeToEvm(7237226433215359512014384475230594365342443486412054855553789112425234109934, 445609843490597037393606653530399820430404054601736331271259923504329801910);
        _log(m, v, s, "bridgeToEvm");
        _at(1000336);
        m.faults(1865790547548338493557468507675236645084368735625246740983981762788296430068);
        m.agentAction(57896044618658097711785492503950033563664357598931024920586931779518240842985, 61070588306602370621419018510967578185293423878743163186905309796383965);
        _log(m, v, s, "agent");
        m.bridgeToCore(6264760401288176943941026639140412010522032589264381534823763031, 1089642749249368603892664880946450698078817615902748427853675689247);
        _log(m, v, s, "bridgeToCore");
        _at(1000347);
        m.executeQueued(146249360655951665045104512559379022976684337285769797840298043242459489665);
        _log(m, v, s, "pre-keeper");
        m.keeperCycle(24493009254615869468975336803746157249856998392719015568656141542011343064);
        _log(m, v, s, "post");
        console.log("violation code", m.handler().lastViolationCode());
        assertTrue(m.property_F_fairness(), "HLR2-A04 timing now classified as documented");
    }

    function _at(uint256 b) internal {
        vm.roll(b);
        vm.warp(1790000000 + (b - 1000000));
    }

    function _log(MedusaConservation m, HyperVault v, CoreSim s, string memory t) internal view {
        console.log(t);
        console.log("  blk/lastBridge", vm.getBlockNumber(), v.lastBridgeBlock(), v.bridgeAmount());
        console.log("  nav/true", v.totalAssets(), m.handler().trueNav());
        console.log("  inflight evm/core", s.inflightToEvm(address(v)), s.inflightToCore(address(v)));
        console.log("  spot/cash", s.spotUsd(address(v)), uint256(s.cash(address(v))));
        console.log("  pending", v.bridgePending());
    }
}
