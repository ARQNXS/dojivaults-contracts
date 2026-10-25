// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {MutBase} from "./MutBase.t.sol";
import {MockUSDC} from "../../../mocks/Mocks.sol";
import {IHyperVaultErrors as E} from "../../../../src/VaultTypes.sol";

/// @title hl-r2 mutation kill tests: owner-only and value-guard lines no earlier test exercised
contract HLR2MutAccessTest is MutBase {
    /// Mutants: HyperVault.rescueToken guard deleted / `||` -> `&&` / `==` -> `!=`, and the transfer deleted.
    /// No earlier test called rescueToken: deleting the guard (the owner sweeps the depositors' USDC or the shares
    /// held for pending redemptions) survived the whole suite.
    function test_HLR2_M07_kills_rescueTokenGuard() public {
        _deposit(alice, 1_000e6);
        _settle();
        _claim(alice);
        _redeem(alice, vault.balanceOf(alice) / 2); // the vault holds alice's shares for the redemption
        _deposit(bob, 500e6); // and bob's queued USDC

        vm.prank(owner);
        vm.expectRevert(E.UnsupportedAsset.selector);
        vault.rescueToken(IERC20(address(usdc)), owner);

        vm.prank(owner);
        vm.expectRevert(E.UnsupportedAsset.selector);
        vault.rescueToken(IERC20(address(vault)), owner);

        // a stray token is recoverable, by the owner only
        MockUSDC stray = new MockUSDC();
        stray.mint(address(vault), 123);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        vault.rescueToken(IERC20(address(stray)), stranger);
        vm.prank(owner);
        vault.rescueToken(IERC20(address(stray)), owner);
        assertEq(stray.balanceOf(owner), 123);
        assertEq(stray.balanceOf(address(vault)), 0);
        assertEq(usdc.balanceOf(address(vault)), 1_500e6, "depositor USDC untouched");
    }
}
