// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

import {HloBase} from "../../hl-open/HloBase.t.sol";
import {HyperVault} from "../../../../src/HyperVault.sol";
import {HyperVaultFactory} from "../../../../src/HyperVaultFactory.sol";
import {IHyperVaultErrors as E} from "../../../../src/VaultTypes.sol";

/// @notice Fix test for HLO-07: a factory vault launched with an agent is inert for AGENT_WARMUP (1 day): no deposit,
///         no HyperCore approval of the agent. The guardian or the sentinel vetoes a binding the platform does not
///         hold in that window with the existing factory.unregisterPlatformAgent. Runs with patches/HLO-07.patch.
contract HLO07_Fix is HloBase {
    address internal mallory = makeAddr("mallory");

    /// The hl-open PoC's launch: mallory holds the agent key, the binding is signed with the leaked registrar key.
    function _leakedLaunch() internal returns (HyperVault v, address heldAgent) {
        (heldAgent,) = makeAddrAndKey("mallory.agent");
        address predicted = factory.predictVaultAddress(mallory, bytes32(0));
        uint256 deadline = vm.getBlockTimestamp() + 1 hours;
        bytes memory sig = _agentSig(heldAgent, predicted, deadline);
        _fundLauncher(mallory, 1);
        HyperVaultFactory.CreateParams memory p = _params(mallory, bytes32(0));
        (p.agent, p.agentSig, p.agentDeadline) = (heldAgent, sig, deadline);
        p.name = "Famous BTC Trend";
        v = _launch(mallory, p);
        vm.prank(alice);
        usdc.approve(address(v), type(uint256).max);
        vm.roll(vm.getBlockNumber() + 400);
    }

    /// HLO-07 inverted: the deposit the theft needs reverts during the warm-up, and the agent cannot be approved on
    /// HyperCore; the sentinel's veto then leaves a vault with no agent at all.
    function test_HLO07_fix_leakedRegistrarLaunchIsInertUntilVetoed() public {
        (HyperVault v, address heldAgent) = _leakedLaunch();
        uint256 activeAt = v.agentActiveAt();
        assertEq(activeAt, vm.getBlockTimestamp() + 1 days, "one day from launch");
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(E.AgentWarmingUp.selector, activeAt));
        v.requestDeposit(1_000_000e6, alice);
        // HL-PROXY: the agent's only power is placeOrder / cancelOrder through the vault, refused in the window
        vm.prank(heldAgent);
        vm.expectRevert(abi.encodeWithSelector(E.AgentWarmingUp.selector, activeAt));
        v.placeOrder(BTC, false, 99_000e8, 1e6, true, 3, 1);

        // the monitor sees a binding absent from the reservation store: the sentinel vetoes
        vm.prank(sentinel);
        factory.unregisterPlatformAgent(heldAgent);
        assertEq(v.agent(), address(0), "revoked on the vault");
        assertFalse(factory.isPlatformAgent(heldAgent));

        // after the window the vault is a manual vault: the held key has no power over it
        vm.warp(activeAt);
        vm.prank(heldAgent);
        vm.expectRevert(E.Unauthorized.selector);
        v.placeOrder(BTC, false, 99_000e8, 1e6, true, 3, 1);
    }

    /// The owner-key leg (test_HLO07_r2_factoryOwnerKeyAlsoBindsASelfHeldAgent) gets the same window.
    function test_HLO07_fix_ownerKeyBindingGetsTheSameWindow() public {
        (address ownerK, uint256 ownerKey) = makeAddrAndKey("factory.owner.eoa");
        vm.prank(owner);
        factory.transferOwnership(ownerK);
        vm.prank(ownerK);
        factory.acceptOwnership();
        (address heldAgent,) = makeAddrAndKey("attacker.agent");
        address predicted = factory.predictVaultAddress(mallory, bytes32(0));
        uint256 deadline = vm.getBlockTimestamp() + 1 hours;
        bytes32 digest = MessageHashUtils.toEthSignedMessageHash(factory.agentDigest(heldAgent, predicted, deadline));
        (uint8 v8, bytes32 r, bytes32 s) = vm.sign(ownerKey, digest);
        _fundLauncher(mallory, 1);
        HyperVaultFactory.CreateParams memory p = _params(mallory, bytes32(0));
        (p.agent, p.agentSig, p.agentDeadline) = (heldAgent, abi.encodePacked(r, s, v8), deadline);
        HyperVault v = _launch(mallory, p);
        vm.prank(alice);
        usdc.approve(address(v), type(uint256).max);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(E.AgentWarmingUp.selector, v.agentActiveAt()));
        v.requestDeposit(1_000e6, alice);
        vm.prank(guardian); // the cold guardian may veto too
        factory.unregisterPlatformAgent(heldAgent);
        assertEq(v.agent(), address(0));
    }

    /// The honest path: after the window the platform's agent is approved and deposits open.
    function test_HLO07_fix_honestLaunchOpensAfterTheWindow() public {
        (HyperVault v,) = _leakedLaunch();
        vm.warp(v.agentActiveAt());
        v.syncAgent();
        vm.prank(alice);
        v.requestDeposit(1_000e6, alice);
        assertEq(v.pendingDepositAssets(), 1_000e6);
    }

    /// A launch without an agent is unaffected (manual vaults take deposits at once).
    function test_HLO07_fix_manualLaunchUnaffected() public {
        _fundLauncher(mallory, 1);
        HyperVault v = _launch(mallory, _params(mallory, bytes32(uint256(7))));
        assertEq(v.agentActiveAt(), 0);
        vm.prank(alice);
        usdc.approve(address(v), type(uint256).max);
        vm.prank(alice);
        v.requestDeposit(1_000e6, alice);
    }

}
