// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Base} from "../../../Base.t.sol";

/// @notice hl-r2 mutation kill tests: shared helpers (standalone vault from Base).
abstract contract MutBase is Base {
    /// @dev alice deposits `amount`, it settles, she claims, and the USDC is bridged to Core (landed on perp).
    function _fund(uint256 amount) internal {
        _deposit(alice, amount);
        _settle();
        _claim(alice);
        vm.prank(manager);
        vault.bridgeToCore(amount);
        _setCore(address(vault), int64(uint64(amount)), 0, 0);
        vault.syncBridge();
        _skipBridgeWindow();
        vault.checkRisk();
    }

    /// @dev Bridges `amount` home from perp; `land` mints it on HyperEVM (the landing), else it stays in transit.
    function _bridgeHome(uint256 amount, int64 perpLeft, bool land) internal {
        _setWithdrawable(address(vault), uint64(amount));
        vm.prank(manager);
        vault.bridgeToEvm(amount);
        _setCore(address(vault), perpLeft, 0, 0);
        _setWithdrawable(address(vault), 0);
        if (land) usdc.mint(address(vault), amount);
    }
}
