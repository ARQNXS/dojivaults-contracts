// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {GovBase} from "../gov/GovBase.t.sol";
import {console2} from "forge-std/Test.sol";
import {GainsVault} from "../../../../src/gains/GainsVault.sol";
import {GainsPrice} from "../../../../src/gains/GainsPrice.sol";
import {GainsNav} from "../../../../src/gains/GainsNav.sol";
import {IGainsDiamond} from "../../../../src/gains/IGainsDiamond.sol";
import {IGainsVaultErrors as E} from "../../../../src/gains/GainsTypes.sol";
import {BreachReason} from "../../../../src/VaultTypes.sol";

/// @notice Round 2, domain LIVE (3.7): the exit state machine on the mock diamond, one test per row of the scenario
///         table in contracts/audit/gains/r2/LIVENESS.md. Each test walks a depositor from requestRedeem to the USDC
///         in their wallet (or shows exactly where and why it stops), names who must act, and counts the transactions.
///         Factory vault `fv` (GovBase): owner fvOwner, manager fvManager, agent agentA, operator keeper; platform
///         guardian platformGuardian, sentinel platformSentinel; maxEpochDuration 7 days.
contract LivenessStateMachineTest is GovBase {
    uint256 internal constant EPOCH = 7 days;

    function _redeemFv(address who, uint256 shares) internal {
        vm.prank(who);
        fv.requestRedeem(shares, who, who);
    }

    function _paid(uint256 epoch) internal view returns (uint256 shares, uint256 paid, uint256 burned) {
        (,, shares, paid, burned,,,) = fv.epochs(epoch);
    }

    /// @dev 10k from alice, one ETH trade holding `onVenue` of it.
    function _setup(uint120 onVenue) internal returns (uint32 idx) {
        _fundFv(10_000e6);
        idx = _openFv(ETH, onVenue, 1_000);
    }

    // ==================================================================
    // Row H1: hostile owner full-stops the vault (triggerBreach). Every settle mode reverts ReduceOnlyMode outside
    // emergency, for every role. The guardian's clear can be undone by the owner in the next transaction; the way out
    // is emergency: the guardian at once, or ANY depositor once the epoch is overdue with their redemption pending.
    // ==================================================================
    function test_LIVE_SM_H1_hostileOwnerBreach_blocksSettle_depositorTriggersEmergencyAtOverdue() public {
        _setup(4_000e6);
        uint256 shares = fv.balanceOf(alice) / 2;
        uint64 t0 = fv.epochStartedAt();
        _redeemFv(alice, shares); // tx 1 (depositor)
        vm.prank(fvOwner);
        fv.triggerBreach();
        fv.checkRisk();
        vm.prank(keeper);
        vm.expectRevert(E.ReduceOnlyMode.selector);
        fv.settle();
        vm.prank(fvManager);
        vm.expectRevert(E.ReduceOnlyMode.selector);
        fv.settle();
        vm.prank(platformSentinel);
        vm.expectRevert(E.ReduceOnlyMode.selector);
        fv.settle();
        // the guardian clears; the owner stops it again in the next transaction (no cooldown on triggerBreach)
        vm.prank(platformGuardian);
        fv.clearBreach();
        vm.prank(fvOwner);
        fv.triggerBreach();
        assertTrue(fv.breached());
        // before the epoch is overdue a depositor cannot force anything
        vm.prank(alice);
        vm.expectRevert(E.NotOverdue.selector);
        fv.triggerEmergency();
        _warp(uint256(t0) + EPOCH);
        vm.prank(alice);
        fv.triggerEmergency(); // tx 2 (depositor)
        // the owner cannot undo an emergency (only the guardian exits it); its triggerBreach keeps EMERGENCY
        vm.prank(fvOwner);
        fv.triggerBreach();
        assertEq(uint8(fv.breachReason()), uint8(BreachReason.EMERGENCY));
        vm.prank(fvOwner);
        vm.expectRevert(E.Unauthorized.selector);
        fv.exitEmergency();
        // the owner and manager refuse to settle; the platform sentinel does (exit-only)
        vm.prank(platformSentinel);
        fv.settle();
        uint256 before = usdc.balanceOf(alice);
        fv.claim(alice); // tx 3 (anyone)
        assertGt(usdc.balanceOf(alice), before, "paid");
        (uint256 rs,, uint256 rb) = _paid(fv.currentEpoch() - 1);
        assertEq(rb, rs, "idle (6k) covered the 5k redemption in full");
        console2.log("H1: worst time = maxEpochDuration after the last settle; depositor txs = 3; needs sentinel/guardian/operator to settle");
    }

    // ==================================================================
    // Row H2: owner removes the operator and the manager refuses to settle. Nobody but a platform role can settle,
    // and only once the epoch is overdue (or in emergency). A full-liquidity exit-only settle runs without emergency;
    // a short one needs emergency (partial fill), which the depositor can trigger.
    // ==================================================================
    function test_LIVE_SM_H2_operatorRemoved_managerRefuses_platformSettlesAtOverdue() public {
        uint32 idx = _setup(8_000e6); // idle ~2k
        uint64 t0 = fv.epochStartedAt();
        vm.prank(fvOwner);
        fv.setOperator(address(0));
        uint256 small = fv.balanceOf(alice) / 10; // ~1k, idle covers it
        _redeemFv(alice, small);
        fv.checkRisk();
        vm.prank(keeper);
        vm.expectRevert(E.Unauthorized.selector);
        fv.settle();
        vm.prank(platformSentinel);
        vm.expectRevert(E.Unauthorized.selector); // not overdue: the platform has no normal settle
        fv.settle();
        _warp(uint256(t0) + EPOCH);
        vm.prank(platformSentinel);
        fv.settle(); // exit-only, no emergency, paid in full
        fv.claim(alice);
        // a redemption above idle: the overdue exit-only settle reverts outside emergency
        uint64 t1 = fv.epochStartedAt();
        uint256 big = fv.balanceOf(alice) / 2; // ~4.5k > idle ~1k
        _redeemFv(alice, big);
        _warp(uint256(t1) + EPOCH);
        fv.checkRisk();
        vm.prank(platformSentinel);
        vm.expectPartialRevert(E.InsufficientLiquidity.selector);
        fv.settle();
        // the sentinel cannot close outside a breach; the depositor triggers emergency, then the sentinel unwinds
        vm.prank(platformSentinel);
        vm.expectRevert(E.Unauthorized.selector);
        fv.closeTrade(idx, _px(ETH));
        vm.prank(alice);
        fv.triggerEmergency();
        vm.prank(platformSentinel);
        fv.closeTrade(idx, _px(ETH));
        _fillLast(fv, _px(ETH));
        vm.prank(platformSentinel);
        fv.settle();
        (uint256 rs,, uint256 rb) = _paid(fv.currentEpoch() - 1);
        assertEq(rb, rs, "paid in full after the sentinel's close");
        fv.claim(alice);
    }

    // ==================================================================
    // Row L1: loss breach (drawdown) with deposits carried. Redemption-only settles pay in full or revert
    // (InsufficientLiquidity), carry the deposit queue, and are open to every role incl. the sentinel. The overdue
    // exit-only branch does NOT apply in a loss breach (the role takes the redemption-only branch): a redemption larger
    // than idle needs a close first (sentinel / owner / operator may close while breached) or emergency.
    // ==================================================================
    function test_LIVE_SM_L1_lossBreach_carriedDeposits() public {
        uint32 idx = _setup(9_000e6); // idle ~1k
        vm.prank(bob);
        fv.requestDeposit(2_000e6, bob); // queued before the breach
        _setVenueValue(fv, idx, 7_000e6); // NAV 10k -> 8k: drawdown 20% > 15%
        fv.checkRisk();
        assertEq(uint8(fv.breachReason()), uint8(BreachReason.DRAWDOWN));
        uint256 shares = fv.balanceOf(alice) / 2; // ~4k > idle ~1k
        _redeemFv(alice, shares);
        vm.prank(platformSentinel);
        vm.expectPartialRevert(E.InsufficientLiquidity.selector);
        fv.settle();
        _warp(uint256(fv.epochStartedAt()) + EPOCH); // overdue changes nothing in a loss breach
        fv.checkRisk();
        vm.prank(platformSentinel);
        vm.expectPartialRevert(E.InsufficientLiquidity.selector);
        fv.settle();
        // the sentinel may close while breached; the close fills; the redemption-only settle pays and carries bob
        vm.prank(platformSentinel);
        fv.closeTrade(idx, _px(ETH));
        _fillLast(fv, _px(ETH));
        fv.checkRisk();
        vm.prank(platformSentinel);
        fv.settle();
        (uint256 rs,, uint256 rb) = _paid(fv.currentEpoch() - 1);
        assertEq(rb, rs);
        fv.claim(alice);
        (,, bool carried) = _carried(bob);
        assertTrue(carried, "bob's deposit is carried, not minted");
        // bob may cancel the carried deposit (no price read) or wait; emergency refunds it
        vm.prank(platformGuardian);
        fv.triggerEmergency();
        vm.prank(platformSentinel);
        fv.settle();
        uint256 b0 = usdc.balanceOf(bob);
        fv.claim(bob);
        assertEq(usdc.balanceOf(bob) - b0, 2_000e6, "carried deposit refunded by the emergency settle");
    }

    function _carried(address who) internal view returns (uint256, uint256, bool) {
        (uint256 epoch,,) = fv.requests(who);
        (uint256 cf, uint256 pi) = fv.carry(epoch);
        return (cf, pi, cf != 0 && pi == 0);
    }

    // ==================================================================
    // Row E1: emergency partial fill + return when trades cannot be closed (a pair Gains no longer serves). Each
    // round pays the idle USDC pro rata and returns the rest; with no new idle, further rounds pay nothing and the
    // guardian cannot exit the emergency. Two redeemers get the same price.
    // ==================================================================
    function test_LIVE_SM_E1_partialFillRounds_tradeUnclosable() public {
        uint32 idx = _setup(6_000e6); // idle ~4k
        vm.prank(bob);
        fv.requestDeposit(10_000e6, bob);
        _ageEpoch(fv);
        fv.checkRisk();
        vm.prank(keeper);
        fv.settle();
        fv.claim(bob); // now idle ~14k, venue 6k, supply alice 10k / bob 10k
        uint256 sa = fv.balanceOf(alice);
        uint256 sb = fv.balanceOf(bob);
        _redeemFv(alice, sa);
        _redeemFv(bob, sb);
        vm.prank(platformGuardian);
        fv.triggerEmergency();
        vm.mockCallRevert(address(diamond), abi.encodeWithSelector(IGainsDiamond.closeTradeMarket.selector), "pair not served");
        vm.prank(platformGuardian);
        vm.expectRevert();
        fv.closeTrade(idx, _px(ETH));
        vm.prank(platformSentinel);
        fv.settle(); // round 1
        uint256 a0 = usdc.balanceOf(alice);
        uint256 b0 = usdc.balanceOf(bob);
        fv.claim(alice);
        fv.claim(bob);
        uint256 pa = usdc.balanceOf(alice) - a0;
        uint256 pb = usdc.balanceOf(bob) - b0;
        console2.log("round 1 paid alice / bob", pa, pb);
        assertApproxEqRel((pa * 1e30) / sa, (pb * 1e30) / sb, 1e9, "same USDC per share for both redeemers");
        assertGt(fv.balanceOf(alice), 0, "unpaid shares returned");
        // round 2: nothing new is idle, the returned shares are re-requested, the settle pays ~0
        _redeemFv(alice, fv.balanceOf(alice));
        vm.prank(platformSentinel);
        fv.settle();
        (uint256 rs, uint256 ra, uint256 rb) = _paid(fv.currentEpoch() - 1);
        console2.log("round 2 paid / burned", ra, rb);
        assertLt(rb, rs);
        fv.claim(alice);
        vm.prank(platformGuardian);
        vm.expectRevert(E.RedemptionsPending.selector);
        fv.exitEmergency();
        // the trade's value stays on the venue until Gains serves the pair again
        assertTrue(diamond.getTrade(address(fv), idx).isOpen);
    }

    // ==================================================================
    // Row P1: a stale feed on one pair / all pairs / the sequencer down or in its grace period. Every settle mode
    // reverts while a trade of an affected pair is open (GR1-09); the exits read no price, so the platform flattens and
    // the flat vault settles with the feeds still dead. requestRedeem / cancelRedeemRequest / claim read no price.
    // ==================================================================
    function test_LIVE_SM_P1_staleFeedsAndSequencer_flattenThenSettle() public {
        uint32 e = _setup(3_000e6);
        uint32 b = _openFv(BTC, 3_000e6, 1_000);
        uint256 shares = fv.balanceOf(alice) / 2;
        _redeemFv(alice, shares);
        vm.prank(platformGuardian);
        fv.triggerEmergency();
        // every price source dead: sequencer down, both feeds stale
        sequencer.setStatus(1, vm.getBlockTimestamp());
        uint256 t = vm.getBlockTimestamp();
        ethFeed.set(ethFeed.answer(), t - 10 days);
        btcFeed.set(btcFeed.answer(), t - 10 days);
        vm.prank(platformSentinel);
        vm.expectRevert(GainsPrice.SequencerDown.selector);
        fv.settle();
        // depositor calls read no price
        vm.prank(alice);
        fv.cancelRedeemRequest();
        _redeemFv(alice, shares);
        // the guardian flattens both pairs (no price read); Gains fills with its own oracle
        vm.prank(platformGuardian);
        fv.flatten(ETH, 0, _px(ETH), type(uint256).max);
        diamond.fill(address(fv), diamond.orderCount(address(fv)) - 1, _px(ETH));
        vm.prank(platformGuardian);
        fv.flatten(BTC, 0, _px(BTC), type(uint256).max);
        diamond.fill(address(fv), diamond.orderCount(address(fv)) - 1, _px(BTC));
        assertFalse(diamond.getTrade(address(fv), e).isOpen);
        assertFalse(diamond.getTrade(address(fv), b).isOpen);
        // the flat vault settles with the sequencer still down and every feed stale: no price is read
        vm.prank(platformSentinel);
        fv.settle();
        (uint256 rs,, uint256 rb) = _paid(fv.currentEpoch() - 1);
        assertEq(rb, rs);
        fv.claim(alice);
    }

    /// @dev Only one pair stale: the other pair's trades may stay open; flattening the stale pair is enough.
    function test_LIVE_SM_P2_oneStalePair_flattenThatPairOnly() public {
        _setup(3_000e6);
        uint32 b = _openFv(BTC, 3_000e6, 1_000);
        b;
        uint256 shares = fv.balanceOf(alice) / 4;
        _redeemFv(alice, shares);
        vm.prank(platformGuardian);
        fv.triggerEmergency();
        ethFeed.set(ethFeed.answer(), vm.getBlockTimestamp() - 10 days);
        vm.prank(platformSentinel);
        vm.expectRevert(abi.encodeWithSelector(GainsPrice.PriceStale.selector, uint256(ETH)));
        fv.settle();
        vm.prank(platformSentinel);
        fv.flatten(ETH, 0, _px(ETH), type(uint256).max);
        diamond.fill(address(fv), diamond.orderCount(address(fv)) - 1, _px(ETH));
        vm.prank(platformSentinel);
        fv.settle();
        fv.claim(alice);
    }

    // ==================================================================
    // Row D1: a layout the vault cannot read (GR1-08). Every NAV path and flatten revert DiamondLayoutChanged; the
    // guardian closes by index (flattenIndices decodes nothing); once the trade is closed the next sync drops it and the
    // settle runs. Ported in fix round WP2 to GR2-LIVE-01's per-index reads: the vault no longer calls getTrades, so the
    // unreadable answer is the trade's own getTrade (odd trailing bytes), as XRLive01Ports does.
    // ==================================================================
    function test_LIVE_SM_D1_unreadableLayout_flattenIndicesThenSettle() public {
        uint32 idx = _setup(5_000e6);
        uint256 shares = fv.balanceOf(alice) / 2;
        _redeemFv(alice, shares);
        vm.prank(platformGuardian);
        fv.triggerEmergency();
        // a getTrade answer the vault cannot decode
        vm.mockCall(address(diamond), abi.encodeCall(IGainsDiamond.getTrade, (address(fv), idx)), abi.encodePacked(new bytes(65)));
        vm.prank(platformSentinel);
        vm.expectRevert(GainsNav.DiamondLayoutChanged.selector);
        fv.settle();
        vm.prank(platformGuardian);
        vm.expectRevert(GainsNav.DiamondLayoutChanged.selector);
        fv.flatten(ETH, 0, _px(ETH), type(uint256).max);
        uint32[] memory ix = new uint32[](1);
        ix[0] = idx;
        vm.prank(platformGuardian);
        assertEq(fv.flattenIndices(ix, 0, _px(ETH)), 1);
        _fillLast(fv, _px(ETH));
        vm.clearMockedCalls(); // flat: Gains returns an empty list, which decodes under any layout
        vm.prank(platformSentinel);
        fv.settle();
        fv.claim(alice);
    }

    // ==================================================================
    // Row O1: an order that holds collateral (a market open sent before the epoch went overdue) holds every settle
    // until Gains fills it or its timeout passes, then ANYONE cancels it. Gains PAUSED (every trading call refused,
    // cancelOrderAfterTimeout included): the hold lasts as long as the pause, even in emergency, and no redemption
    // is paid, not even from idle.
    // ==================================================================
    function test_LIVE_SM_O1_holdingOrder_oneTimeout_thenPausedUnbounded() public {
        _setup(2_000e6);
        uint64 t0 = fv.epochStartedAt();
        uint256 shares = fv.balanceOf(alice) / 4;
        _redeemFv(alice, shares);
        _warp(uint256(t0) + EPOCH - 60);
        uint32 o = _request(fv, ETH, true, 1_000e6, 2_000); // just before overdue
        _warp(uint256(t0) + EPOCH);
        vm.prank(fvManager);
        vm.expectRevert(E.EpochOverdue.selector);
        fv.openTrade(_params(ETH, true, 1_000e6, 2_000));
        fv.checkRisk();
        vm.prank(platformSentinel);
        vm.expectRevert(E.OrdersPending.selector);
        fv.settle();
        uint256 snap = vm.snapshotState();
        // normal Gains: one timeout, then anyone
        vm.roll(vm.getBlockNumber() + diamond.getMarketOrdersTimeoutBlocks());
        vm.prank(stranger);
        fv.cancelTimedOut(o);
        vm.prank(platformSentinel);
        fv.settle();
        fv.claim(alice);
        vm.revertToState(snap);
        // Gains PAUSED: the timed-out cancel reverts, every settle waits, emergency included
        vm.mockCallRevert(address(diamond), abi.encodeWithSelector(IGainsDiamond.cancelOrderAfterTimeout.selector), "Paused");
        vm.roll(vm.getBlockNumber() + 10 * uint256(diamond.getMarketOrdersTimeoutBlocks()));
        vm.prank(stranger);
        vm.expectRevert();
        fv.cancelTimedOut(o);
        vm.prank(alice);
        fv.triggerEmergency();
        _skip(30 days);
        vm.prank(platformGuardian);
        vm.expectRevert(E.OrdersPending.selector);
        fv.settle();
        assertGt(fv.idleAssets(), fv.claimableRedeemAssets(), "idle USDC is there, but nothing pays the redemption");
    }

    // ==================================================================
    // Row M1 (GR1-04 residual): in emergency the manager is still an exit caller (_mayExit: the trader at any time) and
    // no platform role can remove it (setManager is owner-timelocked). A decoy close (an expected price Gains' callback
    // refuses) keeps each trade's market-order slot taken: the guardian's close reverts and flatten skips the trade.
    // Since the GR1-04 fix the settle runs, but it can only pay idle USDC: the trades' value reaches redeemers only
    // when the guardian wins a race after a callback.
    // ==================================================================
    function test_LIVE_SM_M1_decoyClosesHoldTheUnwind_settlePaysIdleOnly() public {
        uint32 idx = _setup(8_000e6); // idle ~2k
        uint256 shares = fv.balanceOf(alice) / 2; // ~5k
        _redeemFv(alice, shares);
        vm.prank(platformGuardian);
        fv.triggerEmergency();
        for (uint256 round; round < 3; ++round) {
            vm.prank(fvManager);
            fv.closeTrade(idx, 1); // decoy: Gains' callback will refuse it on slippage
            uint32 decoy = diamond.orderCount(address(fv)) - 1;
            vm.prank(platformGuardian);
            vm.expectRevert(); // one market order per trade
            fv.closeTrade(idx, _px(ETH));
            vm.prank(platformGuardian);
            (uint256 sent,) = fv.flatten(ETH, 0, _px(ETH), type(uint256).max);
            assertEq(sent, 0, "flatten skips the trade");
            diamond.cancelInCallback(address(fv), decoy); // the oracle refuses the decoy; the manager re-sends next round
        }
        vm.prank(platformSentinel);
        fv.settle();
        (uint256 rs, uint256 ra, uint256 rb) = _paid(fv.currentEpoch() - 1);
        console2.log("decoy rounds: paid / owed-share burned of shares", ra, rb);
        assertLt(rb, rs, "only idle paid while the manager holds the close slot");
        assertTrue(diamond.getTrade(address(fv), idx).isOpen);
        // no platform path removes the manager
        vm.prank(platformGuardian);
        vm.expectRevert(E.Unauthorized.selector);
        fv.setManager(platformGuardian);
    }

    // ==================================================================
    // Row A1: revoked agent / revoked operator: exits do not depend on either.
    // ==================================================================
    function test_LIVE_SM_A1_revokedAgentAndOperator_exitsUnaffected() public {
        uint32 idx = _setup(8_000e6);
        vm.prank(platformSentinel);
        fv.revokeAgent();
        vm.prank(platformSentinel);
        fv.revokeOperator();
        uint256 shares = fv.balanceOf(alice) / 2;
        _redeemFv(alice, shares);
        vm.prank(platformGuardian);
        fv.closeTrade(idx, _px(ETH)); // the guardian closes at any time, no breach needed
        _fillLast(fv, _px(ETH));
        fv.checkRisk();
        vm.prank(fvManager); // the manager still settles normally
        fv.settle();
        fv.claim(alice);
    }

    // ==================================================================
    // Row X1: a holder can keep the vault in emergency (exitEmergency needs no pending redemption and a full last
    // settle): a 1-unit request before each exitEmergency. Exits are unaffected (the vault stays exit-only).
    // ==================================================================
    function test_LIVE_SM_X1_dustRequestKeepsEmergency_exitsUnaffected() public {
        _setup(1_000e6);
        vm.prank(platformGuardian);
        fv.triggerEmergency();
        vm.prank(platformSentinel);
        fv.settle(); // nothing pending: a full settle
        _redeemFv(alice, 1);
        vm.prank(platformGuardian);
        vm.expectRevert(E.RedemptionsPending.selector);
        fv.exitEmergency();
        vm.prank(platformSentinel);
        fv.settle();
        fv.claim(alice);
        vm.prank(platformGuardian);
        fv.exitEmergency();
        assertFalse(fv.emergency());
    }

}
