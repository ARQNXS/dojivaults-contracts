// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {HloBase} from "../../hl-open/HloBase.t.sol";
import {HyperVault} from "../../../../src/HyperVault.sol";
import {HyperVaultFactory} from "../../../../src/HyperVaultFactory.sol";

/// @title hl-r2 mutation kill tests on the factory (the live round 4 configuration from HloBase)
contract HLR2MutFactoryTest is HloBase {
    /// Past fix N2-04 reverted in create(): `if (agentOfVault[predicted] != address(0)) revert VaultAlreadyHasAgent`
    /// deleted. test_REAUDIT2_N204_oneAgentPerPredictedVault only covers registerPlatformAgent, so the create()
    /// half of the fix had no test: a registrar-signed launch could bind a second agent to a vault the owner had
    /// already pre-bound (two "platform" agents for one vault, the N2-04 class).
    function test_HLR2_M08_kills_createBindsASecondAgentToAPreBoundVault() public {
        address who = makeAddr("launcher");
        _fundLauncher(who, 1);
        bytes32 salt = bytes32(uint256(42));
        address predicted = factory.predictVaultAddress(who, salt);
        address a1 = makeAddr("a1");
        address a2 = makeAddr("a2");
        vm.prank(owner);
        factory.registerPlatformAgent(a1, predicted); // the cold owner pre-binds a1

        HyperVaultFactory.CreateParams memory p = _params(who, salt);
        p.agent = a2;
        p.agentDeadline = vm.getBlockTimestamp() + 1 hours;
        p.agentSig = _agentSig(a2, predicted, p.agentDeadline);
        vm.prank(who);
        vm.expectRevert(abi.encodeWithSelector(HyperVaultFactory.VaultAlreadyHasAgent.selector, predicted, a1));
        factory.create{value: 0.01 ether}(p, _noPermit());
        assertEq(factory.agentOfVault(predicted), a1);
        assertEq(factory.platformAgentFor(a2), address(0));
    }

    /// Past fix V-03 (second half) reverted: `_checkRoles(newOwner, ...)` deleted from transferOwnership. The V-03
    /// test covers renounce and the setters against the pending owner, not a transfer to a hot key: the factory
    /// could be handed to the sentinel (or the registrar), merging the hot role with the cold one.
    function test_HLR2_M09_kills_ownershipToAHotRole() public {
        vm.startPrank(owner);
        vm.expectRevert(HyperVaultFactory.RolesCollide.selector);
        factory.transferOwnership(sentinel);
        vm.expectRevert(HyperVaultFactory.RolesCollide.selector);
        factory.transferOwnership(registrar);
        factory.transferOwnership(guardian); // owner == guardian is the intended cold setup
        vm.stopPrank();
        assertEq(factory.pendingOwner(), guardian);
    }

    function _hosted(address who) internal returns (HyperVault v) {
        _fundLauncher(who, 1);
        HyperVaultFactory.CreateParams memory p = _params(who, bytes32(uint256(7)));
        p.hosted = true;
        v = _launch(who, p);
    }

    /// Mutant: HyperVault.lowerProtocolShare `if (newBps < baseShareBps) baseShareBps = newBps` -> `>=`: lowering a
    /// hosted vault's share above the base must not raise the base (leaveHosted then drops to the original base).
    function test_HLR2_M46_kills_lowerProtocolShareRaisesTheBase() public {
        address who = makeAddr("hostedOwner");
        HyperVault v = _hosted(who);
        assertEq(v.protocolShareBps(), 3_300);
        assertEq(v.baseShareBps(), 1_000);
        vm.prank(owner);
        factory.lowerProtocolShare(address(v), 2_000);
        assertEq(v.baseShareBps(), 1_000, "base unchanged");
        vm.prank(who);
        v.leaveHosted();
        assertEq(v.protocolShareBps(), 1_000, "leaving drops to the original base");
    }

    /// Mutant: `_accrueFees` `protocolShareBps > 0` -> `> 1`: a 1 bps protocol share is paid.
    function test_HLR2_M47_kills_oneBpsProtocolShare() public {
        vm.prank(owner);
        factory.setShares(1, 1);
        address who = makeAddr("oneBps");
        _fundLauncher(who, 1);
        HyperVault v = _launch(who, _params(who, bytes32(uint256(8))));
        assertEq(v.protocolShareBps(), 1);
        _skipBridgeWindow();
        vm.prank(alice);
        usdc.approve(address(v), type(uint256).max);
        vm.prank(alice);
        v.requestDeposit(1_000_000e6, alice);
        v.checkRisk();
        vm.prank(who);
        v.settle();
        vm.warp(vm.getBlockTimestamp() + 365 days);
        v.accrueFees(); // 2% management fee on 1M for a year, 1 bps of it to the treasury
        assertGt(v.balanceOf(treasury), 0);
    }

    /// Mutant: create `block.timestamp > p.agentDeadline` -> `>=`: a registrar signature is valid through its
    /// deadline second.
    function test_HLR2_M73_kills_agentDeadlineEdge() public {
        address who = makeAddr("edge");
        _fundLauncher(who, 1);
        bytes32 salt = bytes32(uint256(43));
        address predicted = factory.predictVaultAddress(who, salt);
        address a = makeAddr("edgeAgent");
        HyperVaultFactory.CreateParams memory p = _params(who, salt);
        p.agent = a;
        p.agentDeadline = vm.getBlockTimestamp(); // expires now: still valid this second
        p.agentSig = _agentSig(a, predicted, p.agentDeadline);
        HyperVault v = _launch(who, p);
        assertEq(v.agent(), a);
    }

    /// Mutants: factory admin guards that no test reached: registerPlatformAgent zero arguments, the protocol fee
    /// recipient zero check, setShares caps, setGuardian / setSentinel zero checks and their role checks.
    function test_HLR2_M74_kills_factoryAdminGuards() public {
        HyperVault v = _hosted(makeAddr("adm"));
        vm.startPrank(owner);
        vm.expectRevert(HyperVaultFactory.ZeroAddress.selector);
        factory.registerPlatformAgent(address(0), address(v));
        vm.expectRevert(HyperVaultFactory.ZeroAddress.selector);
        factory.registerPlatformAgent(makeAddr("ag"), address(0));
        factory.registerPlatformAgent(address(1), address(v)); // address(1) is an address
        vm.expectRevert(HyperVaultFactory.ZeroAddress.selector);
        factory.setProtocolFeeRecipient(address(0));
        factory.setProtocolFeeRecipient(address(1));
        vm.expectRevert(HyperVaultFactory.InvalidShare.selector);
        factory.setShares(5_001, 1_000);
        vm.expectRevert(HyperVaultFactory.InvalidShare.selector);
        factory.setShares(10_000, 1_000);
        vm.expectRevert(HyperVaultFactory.InvalidShare.selector);
        factory.setShares(1_000, 5_001);
        factory.setShares(5_000, 5_000); // the cap itself
        assertEq(factory.baseShareBps(), 5_000);
        vm.expectRevert(HyperVaultFactory.ZeroAddress.selector);
        factory.setGuardian(address(0));
        vm.expectRevert(HyperVaultFactory.RolesCollide.selector);
        factory.setGuardian(sentinel);
        vm.expectRevert(HyperVaultFactory.RolesCollide.selector);
        factory.setGuardian(registrar);
        factory.setGuardian(address(1));
        assertEq(factory.guardian(), address(1));
        vm.expectRevert(HyperVaultFactory.ZeroAddress.selector);
        factory.setSentinel(address(0));
        vm.expectRevert(HyperVaultFactory.RolesCollide.selector);
        factory.setSentinel(owner);
        vm.expectRevert(HyperVaultFactory.RolesCollide.selector);
        factory.setSentinel(address(1)); // the guardian now
        vm.expectRevert(HyperVaultFactory.RolesCollide.selector);
        factory.setSentinel(registrar);
        factory.setSentinel(address(2));
        assertEq(factory.sentinel(), address(2));
        vm.stopPrank();
    }

    /// Mutant: `_checkRoles` registrar rule `registrar == guardian || registrar == sentinel` -> `&&` (full branch).
    /// With a pending owner both checks take the full branch: the registrar still may not be the guardian.
    function test_HLR2_M76_kills_registrarRuleWithAPendingOwner() public {
        vm.startPrank(owner);
        factory.transferOwnership(makeAddr("nextOwner"));
        vm.expectRevert(HyperVaultFactory.RolesCollide.selector);
        factory.setAgentRegistrar(guardian);
        vm.expectRevert(HyperVaultFactory.RolesCollide.selector);
        factory.setAgentRegistrar(sentinel);
        factory.setAgentRegistrar(makeAddr("reg2"));
        vm.stopPrank();
    }
}
