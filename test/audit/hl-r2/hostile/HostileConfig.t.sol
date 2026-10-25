// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {console2} from "forge-std/console2.sol";

import {HostileBase} from "./HostileBase.t.sol";
import {HyperVault} from "../../../../src/HyperVault.sol";
import {HyperVaultFactory} from "../../../../src/HyperVaultFactory.sol";
import {VaultPolicy} from "../../../../src/VaultPolicy.sol";
import {HyperCore} from "../../../../src/hypercore/HyperCore.sol";
import {IHyperVaultErrors as E} from "../../../../src/VaultTypes.sol";

/// @notice hl-r2 sections 3.5 (open launch, hostile vaults) and 3.6 (upgrades, timelock, configuration).
///         Every test passes while the behaviour it documents exists.
///         Run: forge test --match-path "test/audit/hl-r2/hostile/*" -vv
contract HostileConfigTest is HostileBase {
    address internal mallory = makeAddr("mallory");

    function _sel(address target, bytes memory data) internal returns (bytes4 sel) {
        (bool ok, bytes memory ret) = target.call(data);
        assertFalse(ok, "expected a revert");
        if (ret.length >= 4) sel = bytes4(ret);
    }

    // ==================================================================
    // HLR2-H02: the factory cannot de-list an asset on existing vaults (setAssetCurated(false) is future-only).
    // ==================================================================
    function test_HLR2_H02_decuratedAssetStaysTradableOnExistingVaults() public {
        HyperVault v = _platformVaultLike(address(0));
        vm.prank(owner);
        factory.setAssetCurated(SOL, false);
        assertFalse(factory.isAssetCurated(SOL));
        assertTrue(v.policy().isAssetAllowed(SOL), "existing allowlist unchanged");
        // the manager still opens SOL (raw mark 100_000, szDecimals 2 -> px1e8 1e9), 100 USDC notional
        vm.prank(platformVaultOwner);
        v.placeOrder(SOL, true, 1e9, 10e8, false, HyperCore.TIF_GTC, 0);
        // a new vault can no longer list it, and the owner can no longer re-allow it once disallowed
        _fundLauncher(mallory, 1);
        vm.prank(mallory);
        vm.expectRevert(abi.encodeWithSelector(HyperVaultFactory.AssetNotCurated.selector, SOL));
        factory.create{value: 0.01 ether}(_params(mallory, bytes32(0)), _noPermit());
    }

    // ==================================================================
    // HLR2-H03: a guardian stop is undone by the owner's timelocked clearBreach after >= 1 day unless the cold
    // guardian cancels or re-triggers in time (N-04 design, restated for the EOA guardian).
    // ==================================================================
    function test_HLR2_H03_ownerTimelockedClearUndoesAGuardianStop() public {
        address agentA = makeAddr("platformVault.agent");
        HyperVault v = _platformVaultLike(agentA);
        vm.prank(guardian);
        v.triggerBreach();
        assertEq(v.agent(), address(0));
        vm.warp(vm.getBlockTimestamp() + 1);
        vm.prank(platformVaultOwner);
        v.queue(abi.encodeCall(HyperVault.clearBreach, ()));
        vm.warp(v.queuedEta(keccak256(abi.encodeCall(HyperVault.clearBreach, ()))));
        vm.prank(stranger); // anyone executes
        v.execute(abi.encodeCall(HyperVault.clearBreach, ()));
        assertFalse(v.breached(), "the platform stop is gone");
        vm.prank(platformVaultOwner);
        v.placeOrder(BTC, true, 100_000e8, 1e8, false, HyperCore.TIF_GTC, 0); // the manager trades again
    }

    // ==================================================================
    // Section 3.5: what a hostile launch can and cannot do to real vaults and the platform
    // ==================================================================
    function test_HLR2_C_hostileLaunchCannotTakeARealVaultsAgent() public {
        address agentA = makeAddr("platformVault.agent");
        HyperVault real = _platformVaultLike(agentA);
        _fundLauncher(mallory, 3);
        HyperVaultFactory.CreateParams memory p = _params(mallory, bytes32(0));
        p.name = "Platform";
        p.symbol = "POL";
        p.agent = agentA; // the real vault's platform agent
        vm.prank(mallory);
        vm.expectRevert(abi.encodeWithSelector(HyperVaultFactory.NotPlatformAgent.selector, agentA));
        factory.create{value: 0.01 ether}(p, _noPermit());
        // with a fresh registrar signature for her own predicted address it is still bound elsewhere
        uint256 deadline = vm.getBlockTimestamp() + 1 hours;
        p.agentSig = _agentSig(agentA, factory.predictVaultAddress(mallory, bytes32(0)), deadline);
        p.agentDeadline = deadline;
        vm.prank(mallory);
        vm.expectRevert(abi.encodeWithSelector(HyperVaultFactory.AgentAlreadyBound.selector, agentA, address(real)));
        factory.create{value: 0.01 ether}(p, _noPermit());
        // her vault cannot queue it either: setAgent checks the factory binding at execution
        p.agent = address(0);
        p.agentSig = "";
        HyperVault mine = _launch(mallory, p);
        vm.prank(mallory);
        mine.queue(abi.encodeCall(HyperVault.setAgent, (agentA)));
        vm.warp(vm.getBlockTimestamp() + 2 days);
        vm.expectRevert(); // CallFailed(NotPlatformAgent)
        mine.execute(abi.encodeCall(HyperVault.setAgent, (agentA)));
        assertEq(real.agent(), agentA);
        assertEq(mine.name(), real.name(), "the name is free (HLO-02)");
    }

    /// @dev Anyone may call syncAgent, fundCoreGas, checkRisk, accrueFees, syncBridge and claim on a real vault. None
    ///      changes a role or the agent. HL-PROXY: syncAgent only pins the account mode (action 16, the vault's own
    ///      address, Standard), a stranger at most once per MODE_PIN_INTERVAL (the H06 cost question is bounded).
    function test_HLR2_C_strangerCallsOnARealVault() public {
        address agentA = makeAddr("platformVault.agent");
        HyperVault v = _platformVaultLike(agentA);
        vm.warp(vm.getBlockTimestamp() + 10 minutes); // MODE_PIN_INTERVAL since any earlier pin
        uint256 before = writer.count();
        vm.deal(stranger, 1 ether);
        vm.startPrank(stranger);
        v.syncAgent();
        vm.expectRevert(E.NotReady.selector);
        v.syncAgent();
        v.fundCoreGas{value: 0.01 ether}();
        v.checkRisk();
        v.accrueFees();
        v.syncBridge();
        v.claim(alice);
        vm.stopPrank();
        assertEq(writer.count() - before, 1, "one mode pin sent by a stranger");
        (, uint24 id, bytes memory body) = _decode(writer.last());
        assertEq(id, 16);
        (address user, uint8 mode) = abi.decode(body, (address, uint8));
        assertEq(user, address(v));
        assertEq(mode, 1);
        assertEq(v.agent(), agentA);
        assertEq(v.operator(), keeper);
        assertEq(v.owner(), platformVaultOwner);
    }

    // ==================================================================
    // Section 3.6: factory changes reach existing vaults instantly (owner key = guardian key, an EOA, HLO-08)
    // ==================================================================
    function test_HLR2_D_factoryOwnerRedirectsProtocolFeesOfExistingVaultsInstantly() public {
        HyperVault v = _platformVaultLike(address(0));
        address thief = makeAddr("thief");
        vm.prank(owner);
        factory.setProtocolFeeRecipient(thief);
        vm.warp(vm.getBlockTimestamp() + 30 days);
        v.accrueFees();
        assertGt(v.balanceOf(thief), 0, "protocol fee shares of an existing vault go to the new recipient at once");
        assertEq(v.balanceOf(treasury), 0);
    }

    function test_HLR2_D_newGuardianActsOnEveryExistingVaultAtOnce() public {
        address agentA = makeAddr("platformVault.agent");
        HyperVault v = _platformVaultLike(agentA);
        vm.prank(sentinel);
        v.triggerBreach(); // the platform's sentinel stops the vault
        address newGuardian = makeAddr("attacker.guardian");
        vm.prank(owner);
        factory.setGuardian(newGuardian);
        assertEq(v.guardian(), newGuardian, "read live: no per-vault delay or consent");
        vm.prank(newGuardian);
        v.clearBreach(); // instant clear of the platform stop
        assertFalse(v.breached());
        // and unregisterPlatformAgent by any platform role revokes a live agent at once (DoS lever)
        _setAgentBack(v, agentA);
    }

    function _setAgentBack(HyperVault v, address agentA) internal {
        // the revoked agent is still bound on the factory: the owner restores it through the timelock
        _timelocked(v, abi.encodeCall(HyperVault.setAgent, (agentA)));
        assertEq(v.agent(), agentA);
        vm.prank(sentinel);
        factory.unregisterPlatformAgent(agentA);
        assertEq(v.agent(), address(0), "the hot sentinel key alone revokes any vault's agent");
        assertFalse(factory.isPlatformAgent(agentA), "and it can never be re-bound to that vault by setAgent alone");
    }

    /// @dev The hot registrar may register a replacement agent for ANY existing vault (stranger vaults included) at
    ///      any time; it only takes effect through that vault owner's timelock. agentOfVault is overwritten while
    ///      the live agent stays bound.
    function test_HLR2_D_registrarRebindsAgentOfVaultOnAnExistingVault() public {
        address agentA = makeAddr("platformVault.agent");
        address agentB = makeAddr("replacement");
        HyperVault v = _platformVaultLike(agentA);
        vm.prank(registrar);
        factory.registerPlatformAgent(agentB, address(v));
        assertEq(factory.agentOfVault(address(v)), agentB);
        assertEq(factory.platformAgentFor(agentA), address(v));
        assertEq(v.agent(), agentA, "nothing changes on the vault until its owner's timelock runs");
    }
}
