// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {SimBase} from "../async/SimBase.t.sol";
import {Vm} from "forge-std/Vm.sol";

/// @notice HLR2-A01 (Medium, a dropped burn approval) is superseded by WP5-D14 (HL testnet): on the release code the
///         agent is never approved on HyperCore (HL-PROXY), so the revoke is EVM-only and sends no CoreWriter action
///         at all; there is no burn to drop or to retry. The earlier burn created a 90-day "dojipad" API wallet
///         entry on an account that had none (testnet record, extraAgents after the revoke).
///         SimBase still gives the agent a legacy API wallet on Core (the A-series' worst case, an approval only the
///         older implementation could make): these tests use it to show the revoke no longer writes that slot.
contract HLR2_A01_Fix is SimBase {
    /// Every revoke path (sentinel, guardian stop, repeated call) queues nothing on HyperCore, and a revoke with no
    /// agent does nothing (no action, no event).
    function test_WP5_D14_revokeSendsNothingToHyperCore() public {
        _bootstrap(100_000e6);
        address legacy = sim.agentOf(address(vault));

        uint256 before = sim.pendingItems();
        vm.prank(sentinel);
        vault.revokeAgent();
        assertEq(vault.agent(), address(0), "EVM side: revoked, its placeOrder path ends here");
        assertEq(sim.pendingItems(), before, "no CoreWriter action queued");
        _tick(1);
        assertEq(sim.agentOf(address(vault)), legacy, "the revoke wrote nothing into the named slot");

        vm.recordLogs();
        vm.prank(sentinel);
        vault.revokeAgent();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 0, "a revoke with no agent emits nothing");
        assertEq(sim.pendingItems(), before, "and sends nothing");
    }

    /// The full stops revoke too (guardian stop, then an emergency): neither writes the named slot, and the revoke
    /// stays role gated.
    function test_WP5_D14_fullStopsSendNoApiWalletAction() public {
        _bootstrap(100_000e6);
        address legacy = sim.agentOf(address(vault));

        vm.prank(carol);
        vm.expectRevert();
        vault.revokeAgent();

        vm.prank(guardian);
        vault.triggerBreach();
        _tick(1);
        assertEq(vault.agent(), address(0));
        assertEq(sim.agentOf(address(vault)), legacy, "the guardian stop sent no action 9");

        vm.prank(guardian);
        vault.triggerEmergency();
        _tick(1);
        assertEq(sim.agentOf(address(vault)), legacy, "the emergency sent no action 9");
    }

    /// The D14 testnet finding, reproduced: the older implementation's burn at the D14 vault and the revoke block
    /// is the wallet HL showed in extraAgents (keccak256(vault, block.number), low 20 bytes: a hash output, not a
    /// public key's).
    function test_WP5_D14_testnetBurnDerivation() public pure {
        address d14Vault = 0xD1A129121b35271793661a96870D7B8576A9885f;
        uint256 revokeBlock = 67_708_586;
        assertEq(
            address(uint160(uint256(keccak256(abi.encodePacked(d14Vault, revokeBlock))))),
            0x6F4AA6343B4dF8C4d5e03005037Ec2e1BcC4F921
        );
    }
}
