// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {GainsBase} from "./GainsBase.t.sol";
import {GainsVaultPolicy} from "../../src/gains/GainsVaultPolicy.sol";
import {GainsPrice} from "../../src/gains/GainsPrice.sol";
import {IGainsVaultErrors as E, OpenParams, MIN_HOLD_L2_BLOCKS} from "../../src/gains/GainsTypes.sol";
import {MockChainlinkFeed} from "./mocks/GainsMocks.sol";

/// @notice flatten(pairIndex, slippageBps, expectedPrice, maxTrades): a flatten split across transactions (Stage 3).
///         Each call acts on at most maxTrades trades / resting orders of the pair and reports how many it left;
///         the trades it closed are in flight, so the next call continues with the rest. Still an exit: no NAV or
///         price read, the round 4 roles.
contract GainsFlattenBatchTest is GainsBase {
    uint32[] internal ethTrades;
    uint32 internal btcTrade;
    uint32 internal ethLimit;

    function setUp() public override {
        super.setUp();
        _deposit(alice, 100_000e6);
        _settle();
        _claim(alice);
        for (uint256 i; i < 5; ++i) {
            ethTrades.push(_open(vault, ETH, i % 2 == 0, 2_000e6, 3_000));
        }
        btcTrade = _open(vault, BTC, true, 2_000e6, 3_000);
        OpenParams memory lp = _params(ETH, true, 1_000e6, 2_000);
        lp.tradeType = 1;
        lp.expectedPrice = _px(ETH) * 95 / 100;
        vm.prank(manager);
        vault.openTrade(lp);
        ethLimit = 6;
        assertTrue(diamond.getTrade(address(vault), ethLimit).isOpen, "resting ETH limit");
    }

    function _flatten(address who, uint256 maxTrades) internal returns (uint256 sent, uint256 remaining) {
        vm.prank(who);
        return vault.flatten(ETH, 0, _px(ETH), maxTrades);
    }

    function test_FlattenInBatches() public {
        // 5 ETH trades + 1 resting ETH limit = 6 actions; the BTC trade is another pair
        _passHold(); // GR2-KEY-01b: the manager's flatten waits out the minimum hold
        (uint256 sent, uint256 remaining) = _flatten(manager, 2);
        assertEq(sent, 2, "batch 1 sent");
        assertEq(remaining, 4, "batch 1 left");
        assertEq(diamond.getPendingOrders(address(vault)).length, 2, "2 closes in flight");

        // the in-flight closes are skipped: the next batch continues with the rest
        (sent, remaining) = _flatten(manager, 3);
        assertEq(sent, 3, "batch 2 sent");
        assertEq(remaining, 1, "batch 2 left");
        assertEq(diamond.getPendingOrders(address(vault)).length, 5, "every ETH trade closing");

        (sent, remaining) = _flatten(manager, 3);
        assertEq(sent, 1, "batch 3: the resting limit");
        assertEq(remaining, 0, "nothing left");
        assertFalse(diamond.getTrade(address(vault), ethLimit).isOpen, "limit cancelled");

        // nothing left to send: a further call is a no-op, not a revert
        (sent, remaining) = _flatten(manager, 3);
        assertEq(sent, 0);
        assertEq(remaining, 0);
        assertTrue(diamond.getTrade(address(vault), btcTrade).isOpen, "the other pair is untouched");
    }

    function test_FlattenAllInOneCall() public {
        _passHold();
        (uint256 sent, uint256 remaining) = _flatten(manager, type(uint256).max);
        assertEq(sent, 6);
        assertEq(remaining, 0);
    }

    function test_FlattenZeroBatchReverts() public {
        vm.prank(manager);
        vm.expectRevert(E.ZeroAmount.selector);
        vault.flatten(ETH, 0, _px(ETH), 0);
    }

    function test_FlattenBatchesKeepTheRoles() public {
        // outside a breach: the owner, operator and sentinel may not flatten, a stranger never
        vm.prank(stranger);
        vm.expectRevert(E.Unauthorized.selector);
        vault.flatten(ETH, 0, _px(ETH), 1);
        vm.prank(owner);
        vm.expectRevert(E.Unauthorized.selector);
        vault.flatten(ETH, 0, _px(ETH), 1);
        // the guardian at any time, in batches
        (uint256 sent, uint256 remaining) = _flatten(guardian, 1);
        assertEq(sent, 1);
        assertEq(remaining, 5);
        // breached: the owner too
        vm.prank(guardian);
        vault.triggerBreach();
        // GR1-16: the full stop already cancelled the resting ETH limit, so 4 trades are all that is left
        assertFalse(diamond.getTrade(address(vault), ethLimit).isOpen, "limit cancelled by the full stop");
        (sent, remaining) = _flatten(owner, 4);
        assertEq(sent, 4);
        assertEq(remaining, 0);
    }

    /// @dev The exit rule: batches work with every feed stale and the sequencer down, and read no price.
    function test_FlattenBatchesWithoutPrices() public {
        vm.warp(vm.getBlockTimestamp() + 7 days); // also past the minimum hold's time part
        vm.roll(vm.getBlockNumber() + MIN_HOLD_L2_BLOCKS); // and its block part (no feed refresh: prices stay down)
        sequencer.setStatus(1, vm.getBlockTimestamp());
        ethFeed.setReverts(true);
        uint64 px = _px(ETH);
        vm.expectRevert(GainsPrice.SequencerDown.selector);
        vault.totalAssets();
        vm.expectCall(address(ethFeed), abi.encodeWithSelector(MockChainlinkFeed.latestRoundData.selector), 0);
        vm.expectCall(address(sequencer), abi.encodeWithSelector(MockChainlinkFeed.latestRoundData.selector), 0);
        vm.expectCall(address(policy), abi.encodeWithSelector(GainsVaultPolicy.price.selector), 0);
        vm.expectCall(address(policy), abi.encodeWithSelector(GainsVaultPolicy.navPrice.selector), 0);
        vm.startPrank(manager);
        (uint256 s1, uint256 r1) = vault.flatten(ETH, 0, px, 3);
        (uint256 s2, uint256 r2) = vault.flatten(ETH, 0, px, 3);
        vm.stopPrank();
        assertEq(s1 + s2, 6);
        assertEq(r1, 3);
        assertEq(r2, 0);
    }

    /// @dev Batches fill like a single flatten: every trade of the pair closes, the USDC comes back.
    function test_FlattenBatchesFillAndPay() public {
        _passHold();
        uint256 idleBefore = vault.idleAssets();
        _flatten(manager, 3);
        _flatten(manager, 3);
        uint256 paid;
        uint32 n = diamond.orderCount(address(vault));
        for (uint32 i; i < n; ++i) {
            if (diamond.getPendingOrder(address(vault), i).isOpen) {
                (, uint256 p) = diamond.fill(address(vault), i, _px(ETH));
                paid += p;
            }
        }
        assertEq(diamond.getPendingOrders(address(vault)).length, 0);
        for (uint256 i; i < ethTrades.length; ++i) {
            assertFalse(diamond.getTrade(address(vault), ethTrades[i]).isOpen, "closed");
        }
        assertEq(vault.idleAssets(), idleBefore + paid + 1_000e6, "closes paid, limit collateral back");
    }
}
