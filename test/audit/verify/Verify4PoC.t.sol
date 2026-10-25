// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {AuditBase} from "../AuditBase.t.sol";
import {HyperVault} from "../../../src/HyperVault.sol";
import {IHyperVaultErrors as E} from "../../../src/VaultTypes.sol";

/// @notice Verification pass 4 (eeb723c). PASS = behaviour demonstrated.
///         Run: forge test --match-path test/audit/verify/Verify4PoC.t.sol -vv
contract Verify4PoC is AuditBase {
    /// @dev X-01 (Low, residual of H-02): once Core is drained, `bridgeToEvm(full available)` is allowed below
    ///      MIN_BRIDGE. A griefer tops the vault's Core spot up with 1e-6 USDC (a Core spot send, outside the EVM)
    ///      and bridges it, re-opening the 10 block window in which settle reverts. To block settlement they must be
    ///      first in the block right after every window, paying a Core send plus an EVM tx each time; any settler
    ///      ordered ahead of them wins. Liveness griefing only, no value moves, no trap without winning every race.
    function test_VERIFY4_X01_strangerCannotReopenTheWindow() public {
        (HyperVault v,) = _malloryVault();
        _fundAndDeploy(v, mallory, 1_000_000e6, 0);
        _setCore(address(v), 0, 0, 1_000_000e6);
        _setWithdrawable(address(v), 0);
        uint256 a = v.balanceOf(alice);
        vm.prank(alice);
        v.requestRedeem(a, alice, alice);
        vm.warp(vm.getBlockTimestamp() + 7 days);
        v.checkRisk();
        vm.prank(stranger);
        v.triggerEmergency();

        vm.prank(sentinel);
        v.bridgeToEvm(1_000_000e6); // rescue: everything comes home
        usdc.mint(address(v), 1_000_000e6);
        _setCore(address(v), 0, 0, 0);

        // Round 4: the griefer cannot re-arm the window any more. A dust bridge from anyone outside the listed roles
        // reverts, so the first settle after the rescue window lands (X-01 closed).
        for (uint256 i; i < 3; ++i) {
            _setCore(address(v), 0, 0, 1); // griefer's Core spot send: 1e-6 USDC
            vm.prank(stranger);
            vm.expectRevert(E.Unauthorized.selector);
            v.bridgeToEvm(1);
        }
        vm.roll(vm.getBlockNumber() + 11);
        vm.prank(sentinel);
        v.settle();
        v.claim(alice);
        assertApproxEqRel(usdc.balanceOf(alice), 1_000_000e6, 2e15, "alice out as soon as one settle lands");
    }
}
