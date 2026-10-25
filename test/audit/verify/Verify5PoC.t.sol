// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {AuditBase} from "../AuditBase.t.sol";
import {HyperVault} from "../../../src/HyperVault.sol";
import {HyperVaultFactory} from "../../../src/HyperVaultFactory.sol";
import {IHyperVaultErrors as E} from "../../../src/VaultTypes.sol";

/// @notice Verification pass 5 (A-13, f11359d): syncAgent() bypass attempts. PASS = the fix holds.
///         HL-PROXY (round 2 fix round): the vault never approves its agent on HyperCore, so syncAgent() is now the
///         account-mode pin (action 16 for the vault itself, Standard). These tests assert that no path ever sends an
///         approval naming the agent, and that strangers pin at most once per MODE_PIN_INTERVAL.
///         Run: forge test --match-path test/audit/verify/Verify5PoC.t.sol -vv
contract Verify5PoC is AuditBase {
    /// @dev Every action 9 since `from` names a burn (never `agent_`); returns the number of action 16 (pins).
    function _noApproval(uint256 from, address agent_) internal view returns (uint256 pins) {
        for (uint256 i = from; i < writer.count(); ++i) {
            (, uint24 id, bytes memory body) = _decode(writer.at(i));
            if (id == 9) {
                (address w,) = abi.decode(body, (address, string));
                assertTrue(w != agent_ && w != address(0), "action 9 only for the revoke's burn");
            }
            if (id == 16) ++pins;
        }
    }

    function _lastIsPin(HyperVault v) internal view {
        (, uint24 id, bytes memory body) = _decode(writer.last());
        assertEq(id, 16, "setAbstraction");
        (address user, uint8 mode) = abi.decode(body, (address, uint8));
        assertEq(user, address(v));
        assertEq(mode, 1, "Standard (disabled)");
    }

    /// @dev Neither the creating transaction nor syncAgent ever approves the stored agent; syncAgent pins the mode.
    function test_VERIFY5_syncSendsOnlyTheStoredAgent() public {
        uint256 before = writer.count();
        (HyperVault v,) = _malloryVault();
        assertEq(v.agent(), platformAgent);
        vm.warp(vm.getBlockTimestamp() + 10 minutes);
        vm.prank(stranger);
        v.syncAgent();
        _lastIsPin(v);
        assertEq(_noApproval(before, platformAgent), 1);
    }

    /// @dev Revoked (sentinel / owner / guardian), unregistered, or left hosted: agent == 0 and no approval ever
    ///      names it; syncAgent stays a harmless pin.
    function test_VERIFY5_noSyncAfterAnyRevoke() public {
        uint256 before = writer.count();
        (HyperVault v,) = _malloryVault();
        vm.prank(v.sentinel());
        v.revokeAgent();
        assertEq(v.agent(), address(0));
        vm.prank(v.sentinel());
        v.syncAgent(); // a role pins at any time
        _lastIsPin(v);

        (HyperVault v2,) = _secondVault(true, bytes32(uint256(2)));
        address a2 = v2.agent();
        address fo = factory.owner();
        vm.prank(fo);
        factory.unregisterPlatformAgent(a2);
        assertEq(v2.agent(), address(0));

        (HyperVault v3,) = _secondVault(true, bytes32(uint256(3)));
        address a3 = v3.agent();
        vm.prank(mallory);
        v3.leaveHosted();
        assertEq(v3.agent(), address(0));
        _noApproval(before, platformAgent);
        _noApproval(before, a2);
        _noApproval(before, a3);
    }

    /// @dev Breach and emergency revoke; a guardian clear does not bring the agent back. The pin is safe in every
    ///      state (it only re-asserts the vault's own account mode).
    function test_VERIFY5_breachAndEmergencyGate() public {
        uint256 before = writer.count();
        (HyperVault v,) = _malloryVault();
        vm.prank(v.guardian());
        v.triggerBreach();
        assertEq(v.agent(), address(0));
        vm.prank(v.guardian());
        v.syncAgent();
        _lastIsPin(v);
        vm.prank(v.guardian());
        v.clearBreach();
        assertEq(v.agent(), address(0), "cleared, but the agent was revoked: nothing to resurrect");
        vm.prank(v.guardian());
        v.triggerEmergency();
        vm.prank(v.guardian());
        v.syncAgent();
        _lastIsPin(v);
        _noApproval(before, platformAgent);
    }

    /// @dev Same block, pin before revoke: CoreWriter actions keep EVM order, the burn lands last.
    function test_VERIFY5_syncThenRevokeSameBlock() public {
        (HyperVault v,) = _malloryVault();
        vm.warp(vm.getBlockTimestamp() + 10 minutes);
        vm.prank(stranger);
        v.syncAgent();
        uint256 n = writer.count();
        vm.prank(v.sentinel());
        v.revokeAgent();
        // WP5-D14: the revoke is EVM-only; the agent is never a HyperCore API wallet (HL-PROXY), so a sync in the
        // same block leaves nothing on HyperCore for it to undo, and the revoke sends no action of its own
        assertEq(writer.count(), n, "revoke sends no CoreWriter action");
        assertEq(v.agent(), address(0));
    }

    /// @dev Griefing bound: a stranger pins at most once per MODE_PIN_INTERVAL (10 minutes), no state change.
    function test_VERIFY5_repeatedSyncCost() public {
        (HyperVault v,) = _malloryVault();
        vm.warp(vm.getBlockTimestamp() + 10 minutes);
        uint256 n0 = writer.count();
        uint256 g = gasleft();
        vm.prank(stranger);
        v.syncAgent();
        emit log_named_uint("gas per syncAgent pin (mock CoreWriter)", g - gasleft());
        for (uint256 i; i < 5; ++i) {
            vm.prank(stranger);
            vm.expectRevert(E.NotReady.selector);
            v.syncAgent();
        }
        assertEq(writer.count() - n0, 1);
        vm.warp(vm.getBlockTimestamp() + 10 minutes);
        vm.prank(stranger);
        v.syncAgent();
        assertEq(writer.count() - n0, 2, "144 a day at most");
        assertEq(v.agent(), platformAgent, "state unchanged");
    }

    function _secondVault(bool hosted, bytes32 salt) internal returns (HyperVault v, address agent_) {
        agent_ = makeAddr(string(abi.encodePacked("agent", salt)));
        address predicted = factory.predictVaultAddress(mallory, salt);
        address fo = factory.owner();
        vm.prank(fo);
        factory.registerPlatformAgent(agent_, predicted);
        HyperVaultFactory.CreateParams memory cp = _malloryParams(agent_);
        cp.hosted = hosted;
        cp.salt = salt;
        vm.startPrank(mallory);
        usdc.approve(address(factory), 2e6);
        (address va,) = factory.create{value: 0.01 ether}(cp, _noPermit());
        vm.stopPrank();
        v = HyperVault(va);
        _setCoreUser(va, true);
        _setCore(va, 0, 0, 1e6);
    }
}
