// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {console2} from "forge-std/Test.sol";
import {R1Base} from "../../R1Base.t.sol";
import {OpenParams} from "../../../../../src/gains/GainsTypes.sol";

/// @notice GR2-KEY-01b gas: openTrade (first and second on a pair), increaseTrade, closeTrade, reduceTrade by the manager on
///         the mock diamond, the same sequence on the KEY-01 tree and the KEY-01b tree (waits included on both). Logs
///         only. The mock's reads are cheaper than the real diamond's (the real getTrade / getTradeInfo read several
///         cold slots): the fork figure for the extra reads is in run-fork.txt.
contract KEY01bGasTest is R1Base {
    function test_KEY01b_gas() public {
        _deposit(alice, 100_000e6);
        _settle();
        _claim(alice);
        OpenParams memory p = _params(ETH, true, 10_000e6, 10_000);
        vm.prank(manager);
        uint256 g = gasleft();
        vault.openTrade(p);
        console2.log("openTrade, first on the pair", g - gasleft());
        (uint32 a,) = _fillLast(vault, _px(ETH));
        vm.prank(manager);
        g = gasleft();
        vault.openTrade(p);
        console2.log("openTrade, second on the pair", g - gasleft());
        (uint32 b,) = _fillLast(vault, _px(ETH));
        vm.prank(manager);
        g = gasleft();
        vault.increaseTrade(a, 2_000e6, 10_000, _px(ETH), SLIP);
        console2.log("increaseTrade", g - gasleft());
        _fillLast(vault, _px(ETH));
        _skip(10 minutes);
        vm.roll(vm.getBlockNumber() + 2_400);
        vm.prank(manager);
        g = gasleft();
        vault.closeTrade(a, _px(ETH));
        console2.log("closeTrade (manager)", g - gasleft());
        _fillLast(vault, _px(ETH));
        vm.prank(manager);
        g = gasleft();
        vault.reduceTrade(b, 5_000e6, 0, _px(ETH));
        console2.log("reduceTrade (manager)", g - gasleft());
        _fillLast(vault, _px(ETH));
        vm.prank(guardian);
        g = gasleft();
        vault.closeTrade(b, _px(ETH));
        console2.log("closeTrade (guardian, never held)", g - gasleft());
    }
}
