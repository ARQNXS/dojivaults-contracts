// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {MutBase} from "./MutBase.t.sol";
import {IHyperVaultErrors as E} from "../../../../src/VaultTypes.sol";
import {HyperCore} from "../../../../src/hypercore/HyperCore.sol";

/// @title hl-r2 mutation kill tests: treasury actions (bridgeToCore, bridgeToEvm, moveUsd) and their CoreWriter
///        encodings, which the earlier tests drove only on the happy path of the manager.
contract HLR2MutTreasuryTest is MutBase {
    function _actions() internal view returns (uint256) {
        return writer.count();
    }

    /// Mutants: bridgeToCore / moveUsd `if (!_treasury($)) revert Unauthorized()` deleted. Only the manager and the
    /// operator move USDC between HyperEVM, Core spot and perp; a stranger could otherwise push the idle USDC that
    /// pays redemptions to Core (settlement then needs a bridge back) or shuffle margin.
    function test_HLR2_M30_kills_treasuryAuth() public {
        _deposit(alice, 1_000e6);
        _settle();
        _claim(alice);
        address[4] memory who = [stranger, owner, guardian, sentinel];
        for (uint256 i; i < 4; ++i) {
            vm.prank(who[i]);
            vm.expectRevert(E.Unauthorized.selector);
            vault.bridgeToCore(1_000e6);
            vm.prank(who[i]);
            vm.expectRevert(E.Unauthorized.selector);
            vault.moveUsd(100e6, true);
        }
        address op = makeAddr("operator");
        vm.prank(owner);
        vault.setOperator(op);
        vm.prank(op);
        vault.moveUsd(100e6, true);
        vm.prank(op);
        vault.bridgeToCore(1_000e6);
    }

    /// Mutants: bridgeToCore `if (amount > idle) revert InsufficientIdle` deleted, `coreUserExists` guard
    /// deleted, `amount == 0` guard deleted / `== 1`. Reserved USDC (queued deposits, claimable payouts) never
    /// leaves for Core; nothing bridges before the Core account exists; a zero bridge would open a window.
    function test_HLR2_M31_kills_bridgeToCoreGuards() public {
        _deposit(alice, 1_000e6);
        _settle();
        _claim(alice);
        _deposit(bob, 500e6); // reserved
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(E.InsufficientIdle.selector, 1_000e6, 1_500e6));
        vault.bridgeToCore(1_500e6);
        vm.prank(manager);
        vm.expectRevert(E.ZeroAmount.selector);
        vault.bridgeToCore(0);
        _setCoreUser(address(vault), false);
        vm.prank(manager);
        vm.expectRevert(E.CoreAccountInactive.selector);
        vault.bridgeToCore(1_000e6);
        _setCoreUser(address(vault), true);
        // with no idle at all, a zero "full amount" bridge still reverts
        vm.prank(manager);
        vault.bridgeToCore(1_000e6);
        _skipBridgeWindow();
        vm.prank(manager);
        vm.expectRevert(E.ZeroAmount.selector);
        vault.bridgeToCore(0);
        assertEq(usdc.balanceOf(address(vault)), 500e6, "bob's deposit stayed");
    }

    /// Mutants: bridgeToEvm liquidity check deleted / its error data / the full-amount exception `spot + perp`
    /// -> `spot - perp`, the perp leg `usdClassTransfer(amount - spot, false)` deleted / `+` / `true` / `>=`,
    /// and `amount == 0` deleted. The Core actions must be exactly: perp -> spot for the part spot does not cover,
    /// then spot -> HyperEVM for the whole amount.
    function test_HLR2_M32_kills_bridgeToEvmLegs() public {
        _setCore(address(vault), 30e6, 0, 20e6);
        _setWithdrawable(address(vault), 30e6);
        vm.startPrank(manager);
        vm.expectRevert(E.ZeroAmount.selector);
        vault.bridgeToEvm(0);
        vm.expectRevert(abi.encodeWithSelector(E.InsufficientLiquidity.selector, 50e6, 60e6));
        vault.bridgeToEvm(60e6);
        uint256 n = _actions();
        vault.bridgeToEvm(50e6); // below MIN_BRIDGE but the full available amount
        vm.stopPrank();
        assertEq(_actions(), n + 2, "perp -> spot, then spot -> EVM");
        (, uint24 id, bytes memory body) = _decode(writer.at(n));
        assertEq(id, 7);
        (uint64 ntl, bool toPerp) = abi.decode(body, (uint64, bool));
        assertEq(ntl, 30e6, "only what spot does not cover");
        assertFalse(toPerp);
        (, id, body) = _decode(writer.at(n + 1));
        assertEq(id, 13);
        (address dest, address sub, uint32 src, uint32 dst, uint64 token, uint64 wei_) =
            abi.decode(body, (address, address, uint32, uint32, uint64, uint64));
        assertEq(dest, HyperCore.USDC_SYSTEM_ADDRESS);
        assertEq(sub, address(0), "no sub-account");
        assertEq(src, HyperCore.SPOT_DEX);
        assertEq(dst, HyperCore.SPOT_DEX);
        assertEq(token, 0);
        assertEq(wei_, 50e8, "8 decimal spot wei");
    }

    /// Same: when spot covers the amount exactly there is no perp leg (`amount > spot` -> `>=` sends a zero one).
    function test_HLR2_M33_kills_bridgeToEvmNoZeroPerpLeg() public {
        _setCore(address(vault), 0, 0, 200e6);
        _setWithdrawable(address(vault), 0);
        uint256 n = _actions();
        vm.prank(manager);
        vault.bridgeToEvm(200e6);
        assertEq(_actions(), n + 1, "spot -> EVM only");
        (, uint24 id,) = _decode(writer.at(n));
        assertEq(id, 13);
    }

    /// Mutants: moveUsd's `usdClassTransfer` deleted, `amount == 0` guard deleted / `== 1`. The action carries
    /// the amount and the direction.
    function test_HLR2_M34_kills_moveUsdAction() public {
        vm.prank(manager);
        vm.expectRevert(E.ZeroAmount.selector);
        vault.moveUsd(0, true);
        uint256 n = _actions();
        vm.prank(manager);
        vault.moveUsd(1, false); // 1 wei is a valid amount
        assertEq(_actions(), n + 1);
        (, uint24 id, bytes memory body) = _decode(writer.last());
        assertEq(id, 7);
        (uint64 ntl, bool toPerp) = abi.decode(body, (uint64, bool));
        assertEq(ntl, 1);
        assertFalse(toPerp);
        vm.prank(manager);
        vault.moveUsd(123e6, true);
        (, id, body) = _decode(writer.last());
        (ntl, toPerp) = abi.decode(body, (uint64, bool));
        assertEq(ntl, 123e6);
        assertTrue(toPerp);
    }

    /// Mutants: bridgeInFlight `block.number <= last + BRIDGE_SETTLE_BLOCKS` -> `<` / constant 0, and
    /// bridgeUnlanded `> last + MAX_UNLANDED_BLOCKS` -> `>=`. The window is exactly BRIDGE_SETTLE_BLOCKS blocks
    /// even when the transfer lands at once, and an unlanded transfer is carried through block last + 300.
    function test_HLR2_M35_kills_windowBoundaries() public {
        _setCore(address(vault), 0, 0, 200e6);
        _setWithdrawable(address(vault), 0);
        vm.prank(manager);
        vault.bridgeToEvm(200e6);
        uint256 last = vault.lastBridgeBlock();
        usdc.mint(address(vault), 200e6); // lands in the same block
        _setCore(address(vault), 0, 0, 0);
        vm.roll(last + 10);
        assertTrue(vault.bridgeInFlight(), "the window lasts 10 blocks even when landed");
        vm.roll(last + 11);
        assertFalse(vault.bridgeInFlight());

        // an unlanded transfer: pending through last + 300, not after
        _setCore(address(vault), 0, 0, 200e6);
        vm.prank(manager);
        vault.bridgeToEvm(200e6);
        last = vault.lastBridgeBlock();
        _setCore(address(vault), 0, 0, 0); // left Core, never arrives
        vm.roll(last + 300);
        assertTrue(vault.bridgePending(), "carried through the cap");
        vm.roll(last + 301);
        assertFalse(vault.bridgePending());
    }

    /// Mutants: `_depositToCore` approves exactly the amount (`type(uint256).max` would leave the deposit wallet a
    /// standing allowance over the vault's USDC), and placeOrder forwards `reduceOnly` (dropping it would turn a
    /// de-risking order into an opening one in a breach).
    function test_HLR2_M75_kills_exactApprovalAndReduceOnlyFlag() public {
        _deposit(alice, 1_000e6);
        _settle();
        _claim(alice);
        vm.prank(manager);
        vault.bridgeToCore(1_000e6);
        assertEq(usdc.allowance(address(vault), address(depositWallet)), 0, "no standing allowance");
        _skipBridgeWindow();
        _setCore(address(vault), 10_000e6, 0, 0);
        vm.prank(manager);
        vault.placeOrder(BTC, false, 100_000e8, 0.01e8, true, 3, 0);
        (, uint24 id, bytes memory body) = _decode(writer.last());
        assertEq(id, 1);
        (,,,, bool ro,,) = abi.decode(body, (uint32, bool, uint64, uint64, bool, uint8, uint128));
        assertTrue(ro);
    }
}
