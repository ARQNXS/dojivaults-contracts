// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {GainsBase} from "./GainsBase.t.sol";
import {GainsVaultPolicy} from "../../src/gains/GainsVaultPolicy.sol";
import {GainsPrice} from "../../src/gains/GainsPrice.sol";
import {IGainsVaultErrors as E, OpenParams, MIN_HOLD_L2_BLOCKS} from "../../src/gains/GainsTypes.sol";
import {MockChainlinkFeed} from "./mocks/GainsMocks.sol";

/// @notice PLAN.md section 1 exit rule: closeTrade, reduceTrade, cancelOrder, cancelTimedOut and flatten never read
///         GainsNav or GainsPrice, so they work with every feed stale and the sequencer down, while deposits, settle,
///         NAV and new risk stop with a named error.
contract GainsExitsTest is GainsBase {
    uint32 internal ethTrade;
    uint32 internal btcTrade;
    uint32 internal ethTrade2;
    uint32 internal limitOrder;
    uint32 internal stuckOrder;

    function setUp() public override {
        super.setUp();
        _deposit(alice, 100_000e6);
        _settle();
        _claim(alice);
        ethTrade = _open(vault, ETH, true, 10_000e6, 5_000);
        ethTrade2 = _open(vault, ETH, false, 5_000e6, 3_000);
        btcTrade = _open(vault, BTC, true, 10_000e6, 10_000);
        OpenParams memory lp = _params(BTC, true, 2_000e6, 2_000);
        lp.tradeType = 1;
        lp.expectedPrice = _px(BTC) * 95 / 100;
        vm.prank(manager);
        vault.openTrade(lp);
        limitOrder = 3;
        stuckOrder = _request(vault, ETH, true, 1_000e6, 2_000); // never filled
        vm.roll(vm.getBlockNumber() + 200);

        // Everything that prices is down: every feed far past its heartbeat, and the sequencer is down.
        vm.warp(vm.getBlockTimestamp() + 7 days);
        sequencer.setStatus(1, vm.getBlockTimestamp());
        ethFeed.setReverts(true);
    }

    function _noPriceRead() internal {
        // A price read would revert anyway; this also proves none is attempted.
        vm.expectCall(address(ethFeed), abi.encodeWithSelector(MockChainlinkFeed.latestRoundData.selector), 0);
        vm.expectCall(address(btcFeed), abi.encodeWithSelector(MockChainlinkFeed.latestRoundData.selector), 0);
        vm.expectCall(address(sequencer), abi.encodeWithSelector(MockChainlinkFeed.latestRoundData.selector), 0);
        vm.expectCall(address(policy), abi.encodeWithSelector(GainsVaultPolicy.price.selector), 0);
        vm.expectCall(address(policy), abi.encodeWithSelector(GainsVaultPolicy.navPrice.selector), 0);
    }

    function test_PricedPathsStopWithNamedErrors() public {
        vm.expectRevert(GainsPrice.SequencerDown.selector);
        vault.totalAssets();
        vm.expectRevert(GainsPrice.SequencerDown.selector);
        vault.checkRisk();
        // A deposit request only queues USDC (no NAV read, as in round 4) unless a cap has to be checked; it is priced
        // by a settle, which cannot run without prices.
        vm.prank(bob);
        vault.requestDeposit(1_000e6, bob);
        vm.prank(owner);
        vault.setDepositCap(1_000_000e6);
        vm.prank(bob);
        vm.expectRevert(GainsPrice.SequencerDown.selector);
        vault.requestDeposit(1_000e6, bob);
        // New risk stops before any price read once the epoch is overdue (setUp warps 7 days, GR1-04)
        OpenParams memory p = _params(BTC, true, 1_000e6, 2_000);
        vm.prank(manager);
        vm.expectRevert(E.EpochOverdue.selector);
        vault.openTrade(p);
        // Sequencer back (past the grace period) but the feeds still stale: PriceStale(pair).
        sequencer.setStatus(0, vm.getBlockTimestamp() - SEQ_GRACE - 1);
        vm.expectRevert(abi.encodeWithSelector(GainsPrice.PriceStale.selector, uint256(ETH)));
        vault.totalAssets();
        // Settle waits for the stuck order first (no price read needed to refuse).
        vm.prank(manager);
        vm.expectRevert(E.OrdersPending.selector);
        vault.settle();
    }

    function test_ExitsWorkWithEveryFeedStaleAndTheSequencerDown() public {
        // GR2-KEY-01b: the manager's exits wait out the minimum hold. setUp's 7 days already pass the time hold; roll
        // past the block hold only (no warp, no feed refresh: every feed stays stale and the sequencer down)
        vm.roll(vm.getBlockNumber() + MIN_HOLD_L2_BLOCKS);
        uint64 px = _px(ETH);
        _noPriceRead();
        vm.startPrank(manager);
        vault.closeTrade(ethTrade, px);
        vault.reduceTrade(btcTrade, 4_000e6, 0, _px(BTC));
        vault.cancelOrder(limitOrder);
        vm.stopPrank();
        vm.prank(stranger);
        vault.cancelTimedOut(stuckOrder);
        vm.prank(manager);
        vault.flatten(ETH, 0, px, type(uint256).max); // closes the short, skips the long whose close is in flight
        assertEq(diamond.getPendingOrders(address(vault)).length, 3, "close, reduce, flatten close");
        assertEq(usdc.allowance(address(vault), address(diamond)), 0);
    }

    function test_BreachUnwindWorksWithoutPrices() public {
        vm.prank(guardian);
        vault.triggerEmergency();
        assertFalse(diamond.getTrade(address(vault), limitOrder).isOpen, "GR1-16: the full stop cancelled the resting limit");
        uint64 px = _px(ETH);
        _noPriceRead();
        vm.prank(guardian);
        vault.flatten(ETH, 300, px, type(uint256).max); // custom slippage: the guardian's, in emergency
        vm.prank(guardian);
        vault.closeTrade(btcTrade, _px(BTC));
        vm.prank(guardian);
        vault.cancelTimedOut(stuckOrder);
        assertEq(diamond.getTradeInfo(address(vault), ethTrade).maxSlippageP, 3_000, "flatten slippage applied");
    }

    /// @dev A bot's TP / SL / limit trigger in flight (invisible to the vault) makes Gains refuse the slippage update
    ///      and the limit cancel: flatten still sends every close.
    function test_FlattenClosesWhileATriggerIsInFlight() public {
        diamond.setTriggerInFlight(true);
        vm.prank(guardian);
        vault.triggerEmergency();
        uint64 px = _px(ETH);
        vm.prank(guardian);
        vault.flatten(ETH, 300, px, type(uint256).max); // the slippage update is refused, the closes go out at the stored slippage
        vm.prank(guardian);
        vault.flatten(BTC, 0, _px(BTC), type(uint256).max); // the limit cancel is refused, the BTC close goes out
        assertEq(diamond.getPendingOrders(address(vault)).length, 1 + 3, "stuck open + 3 closes");
        assertEq(diamond.getTradeInfo(address(vault), ethTrade).maxSlippageP, SLIP, "stored slippage kept");
        assertTrue(diamond.getTrade(address(vault), limitOrder).isOpen, "the resting order waits for the next cancel");
    }

    function test_SlTightenAndDepositorExitsWorkWithoutPrices() public {
        vm.prank(guardian);
        vault.triggerBreach();
        _noPriceRead();
        vm.prank(guardian);
        vault.setSlTp(btcTrade, _px(BTC) * 95 / 100, 0);
        _redeem(alice, vault.balanceOf(alice) / 2);
        vm.prank(alice);
        vault.cancelRedeemRequest();
    }

    function test_FilledExitsBringTheUsdcHomeAndPricedPathsResume() public {
        vm.roll(vm.getBlockNumber() + MIN_HOLD_L2_BLOCKS); // past the block hold; the time hold is behind setUp's 7 days
        uint64 px = _px(ETH);
        vm.startPrank(manager);
        vault.closeTrade(ethTrade, px);
        vault.closeTrade(ethTrade2, px);
        vault.closeTrade(btcTrade, _px(BTC));
        vault.cancelOrder(limitOrder);
        vm.stopPrank();
        vault.cancelTimedOut(stuckOrder);
        uint32 n = diamond.orderCount(address(vault));
        for (uint32 i = n - 3; i < n; ++i) {
            diamond.fill(address(vault), i, i == n - 1 ? _px(BTC) : px);
        }
        assertEq(diamond.getTrades(address(vault)).length, 0);
        assertEq(diamond.getPendingOrders(address(vault)).length, 0);
        // Prices back: NAV is all idle again, and settle runs.
        sequencer.setStatus(0, vm.getBlockTimestamp() - SEQ_GRACE - 1);
        ethFeed.setReverts(false);
        _warp(vm.getBlockTimestamp());
        assertEq(vault.totalAssets(), usdc.balanceOf(address(vault)));
        _skip(1 hours);
        _settle();
    }
}
