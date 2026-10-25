// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {GainsBase} from "./GainsBase.t.sol";
import {GainsVault} from "../../src/gains/GainsVault.sol";
import {GainsPrice} from "../../src/gains/GainsPrice.sol";
import {IGainsVaultErrors as E, MAX_POSITIONS, OpenParams} from "../../src/gains/GainsTypes.sol";

/// @notice MAX_POSITIONS = 20 is a gas-safety ceiling, not a strategy limit: at the ceiling only new exposure
///         (openTrade, increaseTrade, new limit / stop orders) is refused; closeTrade, reduceTrade, cancelOrder,
///         cancelTimedOut and flatten never are. The lens exposes the ceiling and the count without a price read.
contract GainsPositionsTest is GainsBase {
    uint32 internal limitOrder;
    uint32 internal stuckOrder;

    function setUp() public override {
        super.setUp();
        _deposit(alice, 1_000_000e6);
        _settle();
        _claim(alice);
        // 17 trades over both allowed pairs, 2 resting limit orders and 1 market open never filled: 20 positions.
        for (uint256 i; i < 17; ++i) {
            _open(vault, i % 2 == 0 ? BTC : ETH, i % 3 == 0, 1_000e6, 2_000);
        }
        for (uint256 i; i < 2; ++i) {
            OpenParams memory lp = _params(ETH, true, 1_000e6, 2_000);
            lp.tradeType = uint8(1 + i); // a limit and a stop
            lp.expectedPrice = i == 0 ? _px(ETH) * 95 / 100 : _px(ETH) * 105 / 100;
            vm.prank(manager);
            vault.openTrade(lp);
        }
        limitOrder = 17;
        stuckOrder = _request(vault, BTC, true, 1_000e6, 2_000);
        assertEq(lens.openPositions(vault), MAX_POSITIONS);
    }

    function _tooMany() internal pure returns (bytes memory) {
        return abi.encodeWithSelector(E.TooManyPositions.selector, MAX_POSITIONS, MAX_POSITIONS);
    }

    function test_CeilingIsTwentyAndTheLensShowsIt() public view {
        assertEq(MAX_POSITIONS, 20);
        assertEq(vault.MAX_POSITIONS(), 20);
        assertEq(lens.maxPositions(vault), 20);
        assertEq(lens.openPositions(vault), vault.venue().orders);
        assertEq(lens.status(vault).openPositions, 20);
        assertEq(lens.status(vault).maxPositions, 20);
    }

    function test_NewExposureRefusedAtTheCeiling() public {
        OpenParams memory p = _params(BTC, true, 1_000e6, 2_000);
        vm.prank(manager);
        vm.expectRevert(_tooMany());
        vault.openTrade(p);
        OpenParams memory lp = _params(ETH, true, 1_000e6, 2_000);
        lp.tradeType = 1;
        lp.expectedPrice = _px(ETH) * 90 / 100;
        vm.prank(manager);
        vm.expectRevert(_tooMany());
        vault.openTrade(lp);
        uint64 px = _px(BTC);
        vm.prank(manager);
        vm.expectRevert(_tooMany());
        vault.increaseTrade(0, 100e6, 1_000, px, SLIP);
    }

    function test_ExitsAreNeverRefusedAtTheCeiling() public {
        _passHold(); // GR2-KEY-01b: the manager's exits wait out the minimum hold
        uint64 btc = _px(BTC);
        uint64 eth = _px(ETH);
        vm.startPrank(manager);
        vault.closeTrade(0, btc); // 21 with the close in flight
        vault.reduceTrade(1, 500e6, 0, eth);
        vault.cancelOrder(limitOrder);
        vm.stopPrank();
        vm.roll(vm.getBlockNumber() + 200);
        vm.prank(stranger);
        vault.cancelTimedOut(stuckOrder);
        vm.prank(guardian);
        vault.flatten(BTC, 0, btc, type(uint256).max);
        assertGt(lens.openPositions(vault), 0);
    }

    function test_OpensAgainBelowTheCeiling() public {
        vm.prank(manager);
        vault.cancelOrder(limitOrder);
        OpenParams memory p = _params(BTC, true, 1_000e6, 2_000);
        vm.prank(manager);
        vault.openTrade(p);
        assertEq(lens.openPositions(vault), 20);
    }

    function test_LensCountsWithoutAPrice() public {
        vm.warp(vm.getBlockTimestamp() + 7 days);
        sequencer.setStatus(1, vm.getBlockTimestamp());
        vm.expectRevert(GainsPrice.SequencerDown.selector);
        vault.totalAssets();
        assertEq(lens.openPositions(vault), 20);
        assertEq(lens.maxPositions(vault), 20);
    }
}
