// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Base} from "../../../Base.t.sol";
import {HyperVault} from "../../../../src/HyperVault.sol";

/// @notice hl-r2 economics / liveness helpers on the standalone Base vault (factory = 0, guardian = sentinel).
///         HyperCore is driven directly: `_core` is the perp account value the precompiles report. A "bridge back"
///         is modelled as an atomic move (Core value down, EVM USDC up) so NAV is unchanged and no bridge window is
///         opened; bridge windows are covered by other reviews and by the dedicated liveness tests here.
abstract contract EconBase is Base {
    int64 internal _core; // perp account value, 6 decimals
    address internal operatorK = makeAddr("operatorK");
    address internal mallory = makeAddr("mallory"); // the manager's sybil (not an insider address)

    function setUp() public virtual override {
        super.setUp();
        vm.prank(owner);
        vault.setOperator(operatorK);
        usdc.mint(mallory, 10_000_000e6);
        vm.prank(mallory);
        usdc.approve(address(vault), type(uint256).max);
        usdc.mint(manager, 10_000_000e6);
        vm.prank(manager);
        usdc.approve(address(vault), type(uint256).max);
        // First checkpoint (a fresh vault's first settle needs one, I2-04).
        vault.checkRisk();
    }

    function _setCoreValue(int64 v) internal {
        _core = v;
        _setCore(address(vault), v, 0, 0);
    }

    /// @dev Moves `amount` of idle EVM USDC to the Core perp account, NAV unchanged.
    function _toCore(uint256 amount) internal {
        usdc.burnFrom(address(vault), amount);
        _setCoreValue(_core + int64(int256(amount)));
    }

    /// @dev Moves `amount` from Core back to the vault's EVM balance, NAV unchanged.
    function _toEvm(uint256 amount) internal {
        _setCoreValue(_core - int64(int256(amount)));
        usdc.mint(address(vault), amount);
    }

    function _hours(uint256 h) internal {
        vm.warp(vm.getBlockTimestamp() + h * 1 hours);
        vm.roll(vm.getBlockNumber() + h * 3600);
    }

    function _settleAs(address who) internal {
        vm.prank(who);
        vault.settle();
    }

    function _value(address who) internal view returns (uint256) {
        return vault.convertToAssets(vault.balanceOf(who));
    }

    /// @dev alice and mallory deposit `a` and `m`, settled, everything moved to Core.
    function _fundTwo(uint256 a, uint256 m) internal {
        _deposit(alice, a);
        vm.prank(mallory);
        vault.requestDeposit(m, mallory);
        _settleAs(manager);
        vault.claim(alice);
        vault.claim(mallory);
        _toCore(a + m);
    }
}
