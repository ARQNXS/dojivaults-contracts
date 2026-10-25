// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IGainsDiamondSpike} from "./IGainsDiamondSpike.sol";
import {GainsSpikeTrader} from "./GainsSpikeTrader.sol";

contract SpikeToken is ERC20 {
    constructor() ERC20("Spike USDC", "sUSDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @notice Pre-deploy check for the Stage 0 Arbitrum One run: every token unit the spike holds can only go back to
///         its owner, and only the owner can move it.
contract GainsSpikeTraderTest is Test {
    address internal constant OWNER = address(0xA11CE);
    SpikeToken internal token;
    GainsSpikeTrader internal spike;

    function setUp() public {
        token = new SpikeToken();
        spike = new GainsSpikeTrader(IGainsDiamondSpike(address(0xD1A)), IERC20(address(token)), OWNER);
        token.mint(address(spike), 7_123_456);
    }

    function test_withdrawSendsWholeBalanceToOwner() public {
        vm.prank(OWNER);
        spike.withdraw(IERC20(address(token)));
        assertEq(token.balanceOf(OWNER), 7_123_456);
        assertEq(token.balanceOf(address(spike)), 0);
    }

    function test_withdrawAnyTokenToOwner() public {
        SpikeToken other = new SpikeToken();
        other.mint(address(spike), 5);
        vm.prank(OWNER);
        spike.withdraw(IERC20(address(other)));
        assertEq(other.balanceOf(OWNER), 5);
    }

    function test_onlyOwnerCanMoveFunds(address caller) public {
        vm.assume(caller != OWNER);
        vm.startPrank(caller);
        vm.expectRevert(GainsSpikeTrader.NotOwner.selector);
        spike.withdraw(IERC20(address(token)));
        vm.expectRevert(GainsSpikeTrader.NotOwner.selector);
        spike.sweep(IERC20(address(token)), caller, 1);
        vm.expectRevert(GainsSpikeTrader.NotOwner.selector);
        spike.openTrade(_t(), 1000);
        vm.stopPrank();
        assertEq(token.balanceOf(address(spike)), 7_123_456);
    }

    function test_cannotReceiveEth() public {
        vm.deal(address(this), 1 ether);
        (bool ok,) = address(spike).call{value: 1}("");
        assertFalse(ok);
    }

    function _t() internal pure returns (IGainsDiamondSpike.Trade memory t) {
        t.collateralAmount = 1;
    }
}
