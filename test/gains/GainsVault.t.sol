// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {GainsBase} from "./GainsBase.t.sol";
import {GainsVault} from "../../src/gains/GainsVault.sol";
import {GainsVaultPolicy} from "../../src/gains/GainsVaultPolicy.sol";
import {IGainsDiamond} from "../../src/gains/IGainsDiamond.sol";
import {IGainsVaultErrors, IGainsVaultEvents, OpenParams} from "../../src/gains/GainsTypes.sol";

/// @notice Mirrors test/HyperVault.t.sol for GainsVault. Same test names where the behavior is the same; the
///         bridge tests become pending-order tests (the Gains analog of the bridge window), CoreWriter encoding
///         becomes the diamond request.
contract GainsVaultTest is GainsBase {
    // ------------------------------------------------------------------
    // Deposits and redemptions
    // ------------------------------------------------------------------
    function test_DepositSettleClaim() public {
        _deposit(alice, 1_000e6);
        assertEq(vault.pendingDepositAssets(), 1_000e6);
        assertEq(vault.totalAssets(), 0, "pending deposits are not NAV");

        _settle();
        _claim(alice);

        assertEq(vault.totalAssets(), 1_000e6);
        assertEq(vault.balanceOf(alice), 1_000e6 * 1e6, "1 USDC = 1e12 share units at launch");
        assertEq(vault.sharePrice(), 1e6);
        assertEq(vault.currentEpoch(), 1);
    }

    function test_SyncEntrypointsAbsent() public {
        vm.prank(alice);
        (bool ok,) = address(vault).call(abi.encodeWithSignature("deposit(uint256,address)", 1e6, alice));
        assertFalse(ok);
        (ok,) = address(vault).call(abi.encodeWithSignature("redeem(uint256,address,address)", 1, alice, alice));
        assertFalse(ok);
        assertEq(vault.decimals(), 12);
    }

    function test_RedeemFlow() public {
        _deposit(alice, 1_000e6);
        _settle();
        _claim(alice);

        uint256 shares = vault.balanceOf(alice);
        _redeem(alice, shares / 2);
        assertEq(vault.balanceOf(address(vault)), shares / 2);

        _settle();
        uint256 before = usdc.balanceOf(alice);
        _claim(alice);
        assertApproxEqAbs(usdc.balanceOf(alice) - before, 500e6, 1);
        assertApproxEqAbs(vault.totalAssets(), 500e6, 1);
    }

    function test_DepositsFundRedemptionsInSameEpoch() public {
        _fundVenue(1_000e6); // all of alice's USDC is in a trade

        // Bob's deposit covers alice's exit, no trade needs to be reduced.
        _redeem(alice, vault.balanceOf(alice) / 4);
        _deposit(bob, 500e6);
        _settle();
        _claim(alice);
        _claim(bob);
        // the settle runs an hour into the epoch (GR1-02): one hour of the 2% management fee (~0.0006 USDC on her part)
        assertApproxEqAbs(usdc.balanceOf(alice), 1_000_000e6 - 1_000e6 + 250e6, 1e3);
        assertLe(usdc.balanceOf(alice), 1_000_000e6 - 1_000e6 + 250e6);
        assertGt(vault.balanceOf(bob), 0);
    }

    function test_SettleRevertsWithoutLiquidity() public {
        _fundVenue(1_000e6);
        _redeem(alice, vault.balanceOf(alice));
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(IGainsVaultErrors.InsufficientLiquidity.selector, 0, 1_000e6));
        vault.settle();
    }

    function test_CancelRequests() public {
        _deposit(alice, 1_000e6);
        uint256 bal = usdc.balanceOf(alice);
        vm.prank(alice);
        vault.cancelDepositRequest();
        assertEq(usdc.balanceOf(alice), bal + 1_000e6);
        assertEq(vault.pendingDepositAssets(), 0);

        _deposit(alice, 1_000e6);
        _settle();
        _claim(alice);
        uint256 shares = vault.balanceOf(alice);
        _redeem(alice, shares);
        vm.prank(alice);
        vault.cancelRedeemRequest();
        assertEq(vault.balanceOf(alice), shares);
    }

    function test_RequestAutoClaimsPreviousEpoch() public {
        _deposit(alice, 1_000e6);
        _settle();
        _deposit(alice, 500e6); // claims epoch 0 shares first
        assertEq(vault.balanceOf(alice), 1_000e6 * 1e6);
        (uint256 dep,) = lens.pendingRequest(vault, alice);
        assertEq(dep, 500e6);
    }

    function test_DepositCap() public {
        vm.prank(owner);
        vault.setDepositCap(1_500e6);
        _deposit(alice, 1_000e6);
        vm.prank(bob);
        vm.expectRevert(IGainsVaultErrors.CapExceeded.selector);
        vault.requestDeposit(600e6, bob);
    }

    function test_InsiderDepositsArePricedInTheNextEpoch() public {
        usdc.mint(manager, 10e6);
        vm.prank(manager);
        usdc.approve(address(vault), 10e6);
        vm.prank(manager);
        uint256 epoch = vault.requestDeposit(10e6, manager);
        assertEq(epoch, vault.currentEpoch() + 1, "manager deposit waits a full epoch");
        vm.prank(alice);
        assertEq(vault.requestDeposit(10e6, owner), vault.currentEpoch() + 1, "deposit for the owner too");
        assertEq(vault.deferredDepositAssets(), 20e6);
        assertEq(vault.pendingDepositAssets(), 0);
        assertEq(vault.idleAssets(), 0, "deferred USDC is not NAV");

        _deposit(alice, 100e6);
        _settle();
        assertEq(vault.pendingDepositAssets(), 20e6, "the insiders' deposits are now the queue");
        assertEq(vault.deferredDepositAssets(), 0);
        (uint256 sh,) = lens.claimable(vault, manager);
        assertEq(sh, 0, "not priced yet");
        vm.expectRevert(IGainsVaultErrors.RequestNotSettled.selector);
        vault.claim(manager);

        _skip(1 hours);
        _settle();
        _claim(manager);
        assertGt(vault.balanceOf(manager), 0);

        uint256 held = vault.balanceOf(manager);
        vm.prank(manager);
        vault.requestRedeem(held, manager, manager);
    }

    function test_InsiderNextEpochDepositCannotMixWithACurrentRequest() public {
        _deposit(alice, 100e6);
        _settle();
        _claim(alice);
        vm.prank(alice);
        vault.transfer(feeRecipient, 1e12);
        vm.prank(feeRecipient);
        vault.requestRedeem(1e12, feeRecipient, feeRecipient);
        usdc.mint(feeRecipient, 10e6);
        vm.prank(feeRecipient);
        usdc.approve(address(vault), 10e6);
        vm.prank(feeRecipient);
        vm.expectRevert(IGainsVaultErrors.RequestPending.selector);
        vault.requestDeposit(10e6, feeRecipient);
        usdc.mint(manager, 10e6);
        vm.prank(manager);
        usdc.approve(address(vault), 10e6);
        vm.prank(manager);
        vault.requestDeposit(10e6, manager);
        vm.prank(manager);
        vm.expectRevert(IGainsVaultErrors.RequestPending.selector);
        vault.requestRedeem(1, manager, manager);
        uint256 before = usdc.balanceOf(manager);
        vm.prank(manager);
        vault.cancelDepositRequest();
        assertEq(usdc.balanceOf(manager), before + 10e6);
        assertEq(vault.deferredDepositAssets(), 0);
    }

    function test_RedeemOnBehalfNeedsAllowance() public {
        _deposit(alice, 1_000e6);
        _settle();
        _claim(alice);
        vm.prank(bob);
        vm.expectRevert();
        vault.requestRedeem(1, bob, alice);
    }

    function test_DonationDoesNotStealFromDepositors() public {
        _deposit(alice, 10e6);
        usdc.mint(address(vault), 1_000e6); // donation before settle
        _deposit(bob, 1_000e6);
        _settle();
        _claim(alice);
        _claim(bob);
        uint256 aliceValue = vault.convertToAssets(vault.balanceOf(alice));
        uint256 bobValue = vault.convertToAssets(vault.balanceOf(bob));
        assertGe(bobValue, 999e6, "bob not diluted");
        assertLe(aliceValue, 20e6, "alice does not capture the donation");
    }

    // ------------------------------------------------------------------
    // NAV and pending orders (the Gains analog of the bridge window)
    // ------------------------------------------------------------------
    function test_PendingOrderCollateralIsNavAndBlocksSettle() public {
        _deposit(alice, 1_000e6);
        _settle();
        _claim(alice);

        _request(vault, ETH, true, 600e6, 2_000);
        assertEq(usdc.balanceOf(address(vault)), 400e6, "collateral pulled at request (STAGE0.md A2)");
        assertEq(vault.totalAssets(), 1_000e6, "collateral in flight is valued, never lost");
        assertTrue(vault.ordersPending());
        assertEq(vault.venue().pending, 1);

        vm.prank(manager);
        vm.expectRevert(IGainsVaultErrors.OrdersPending.selector);
        vault.settle();

        _fillLast(vault, _px(ETH));
        assertFalse(vault.ordersPending());
        _settle();
    }

    function test_TimedOutOrderStaysPendingUntilCancelled() public {
        _deposit(alice, 1_000e6);
        _settle();
        _claim(alice);
        uint32 order = _request(vault, ETH, true, 500e6, 2_000);

        vm.expectRevert(bytes("WaitTimeout"));
        vault.cancelTimedOut(order);

        // Past Gains' timeout the order can still fill until cancelled: it stays pending and blocks settle.
        vm.roll(vm.getBlockNumber() + 200);
        assertEq(lens.timedOutOrders(vault).length, 1);
        assertEq(lens.timedOutOrders(vault)[0], order);
        vm.prank(manager);
        vm.expectRevert(IGainsVaultErrors.OrdersPending.selector);
        vault.settle();
        assertEq(vault.totalAssets(), 1_000e6);

        // Anyone (the keeper) cancels it; the collateral comes back in full.
        vm.expectEmit(address(vault));
        emit IGainsVaultEvents.TimeoutCancelled(order, stranger);
        vm.prank(stranger);
        vault.cancelTimedOut(order);
        assertEq(usdc.balanceOf(address(vault)), 1_000e6);
        assertFalse(vault.ordersPending());
        assertEq(lens.timedOutOrders(vault).length, 0);
        _settle();
    }

    function test_CallbackCancelledOpenIsValuedNetOfTheGovFee() public {
        diamond.setPair(ETH, 3.5e8, 285.7e18, 0.1e18, 0); // 0.035% per side
        _deposit(alice, 1_000e6);
        _settle();
        _claim(alice);
        _request(vault, ETH, true, 600e6, 2_000);
        uint256 fee = diamond.minGovFee(ETH);
        assertGt(fee, 0);
        assertEq(vault.totalAssets(), 1_000e6 - fee, "pending open counts collateral minus the cancel gov fee");
        diamond.cancelInCallback(address(vault), diamond.orderCount(address(vault)) - 1);
        assertEq(vault.totalAssets(), 1_000e6 - fee, "exactly what came back");
        assertEq(usdc.balanceOf(address(vault)), 1_000e6 - fee);
    }

    function test_NavIsConservativeAgainstThePayout() public {
        diamond.setPair(ETH, 3.5e8, 285.7e18, 0.1e18, 0);
        _deposit(alice, 10_000e6);
        _settle();
        _claim(alice);
        uint32 idx = _open(vault, ETH, true, 2_000e6, 5_000);
        _passHold(); // GR2-KEY-01b: the manager's exit waits out the minimum hold (before the NAV read)
        _setPrice(ETH, _px(ETH) * 101 / 100);
        uint256 nav = vault.totalAssets();
        uint256 notional = vault.venue().notional;
        uint256 idle = vault.idleAssets();
        uint256 paid = _closeFilled(vault, idx, _px(ETH));
        assertLe(nav, idle + paid, "NAV never above what Gains pays at the oracle price");
        // 2 x band x notional bounds the gap (PLAN.md 4.3); here the oracle price equals Chainlink, so one band.
        assertLe(idle + paid - nav, (notional * 2 * 20) / 10_000 + 1);
        assertEq(vault.totalAssets(), idle + paid);
    }

    // ------------------------------------------------------------------
    // Fees
    // ------------------------------------------------------------------
    function test_PerformanceFeeAboveHighWaterMark() public {
        vm.prank(owner);
        vault.lowerFees(0, 2_000);
        uint32 idx = _fundVenue(1_000e6);
        _setVenueValue(vault, idx, 1_100e6); // +100 profit

        _settle();
        uint256 feeValue = vault.convertToAssets(vault.balanceOf(feeRecipient));
        assertApproxEqAbs(feeValue, 20e6, 1e4, "20% of 100");
        assertApproxEqAbs(vault.convertToAssets(vault.balanceOf(alice)), 1_080e6, 1e4);

        uint256 feeShares = vault.balanceOf(feeRecipient);
        _setVenueValue(vault, idx, 1_050e6);
        _settle();
        assertEq(vault.balanceOf(feeRecipient), feeShares);
    }

    function test_ManagementFeeOverOneYear() public {
        vm.prank(owner);
        vault.lowerFees(200, 0);
        _deposit(alice, 1_000e6);
        _settle();
        _claim(alice);
        _skip(365 days);
        _settle();
        uint256 feeValue = vault.convertToAssets(vault.balanceOf(feeRecipient));
        assertApproxEqRel(feeValue, 20e6, 0.001e18, "2% of 1000");
    }

    function test_ProtocolFeeShare() public view {
        assertEq(vault.factory(), address(0));
        assertEq(vault.protocolShareBps(), 0);
    }

    function test_LowerFeesOnlyDown() public {
        vm.prank(owner);
        vm.expectRevert(IGainsVaultErrors.InvalidFee.selector);
        vault.lowerFees(300, 2_000);
        vm.prank(owner);
        vm.expectRevert(IGainsVaultErrors.InvalidFee.selector);
        vault.lowerFees(200, 2_000);
        vm.prank(owner);
        vault.lowerFees(200, 1_999);
        assertEq(vault.performanceFeeBps(), 1_999);
    }

    // ------------------------------------------------------------------
    // Trading via the diamond
    // ------------------------------------------------------------------
    function test_OpenTradeRequest() public {
        _deposit(alice, 10_000e6);
        _settle();
        OpenParams memory p = _params(BTC, true, 1_000e6, 5_000);
        p.tp = _px(BTC) * 110 / 100;
        p.sl = _px(BTC) * 95 / 100;
        vm.expectEmit(address(vault));
        emit IGainsVaultEvents.TradeRequested(BTC, true, 1_000e6, 5_000, p.expectedPrice, 0, manager);
        vm.prank(manager);
        vault.openTrade(p);

        IGainsDiamond.PendingOrder[] memory orders = diamond.getPendingOrders(address(vault));
        assertEq(orders.length, 1);
        IGainsDiamond.Trade memory t = orders[0].trade;
        assertEq(orders[0].orderType, 0, "MARKET_OPEN");
        assertEq(orders[0].maxSlippageP, SLIP);
        assertEq(t.user, address(vault), "the vault is the trader");
        assertEq(t.pairIndex, BTC);
        assertTrue(t.long);
        assertEq(t.collateralAmount, 1_000e6);
        assertEq(t.leverage, 5_000);
        assertEq(t.collateralIndex, 3);
        assertEq(t.openPrice, p.expectedPrice);
        assertEq(t.tp, p.tp);
        assertEq(t.sl, p.sl);
        assertEq(usdc.allowance(address(vault), address(diamond)), 0, "exact approval, consumed");

        (uint32 idx,) = _fillLast(vault, _px(BTC));
        assertTrue(diamond.getTrade(address(vault), idx).isOpen);
    }

    function test_LimitOrderRestsAndCancels() public {
        _deposit(alice, 10_000e6);
        _settle();
        OpenParams memory p = _params(ETH, true, 1_000e6, 5_000);
        p.tradeType = 1;
        p.expectedPrice = _px(ETH) * 90 / 100; // far from the mark: limit triggers are not banded
        vm.prank(manager);
        vault.openTrade(p);
        assertFalse(vault.ordersPending(), "a limit order rests, it is not a pending request");
        assertEq(vault.venue().value, 1_000e6, "resting collateral counts in full");
        assertEq(vault.venue().notional, 5_000e6);
        vm.prank(stranger);
        vm.expectRevert(IGainsVaultErrors.Unauthorized.selector);
        vault.cancelOrder(0);
        vm.prank(manager);
        vault.cancelOrder(0);
        assertEq(vault.idleAssets(), 10_000e6);
    }

    function test_OpenTradePolicyRejections() public {
        _deposit(alice, 100_000e6);
        _settle();
        vm.startPrank(manager);
        vm.expectRevert(abi.encodeWithSelector(IGainsVaultErrors.OrderRejected.selector, "asset not allowed"));
        vault.openTrade(_params(SOL, true, 1_000e6, 2_000));

        OpenParams memory p = _params(BTC, true, 1_000e6, 2_000);
        p.expectedPrice = _px(BTC) * 102 / 100;
        vm.expectRevert(abi.encodeWithSelector(IGainsVaultErrors.OrderRejected.selector, "price above band"));
        vault.openTrade(p);

        p = _params(BTC, false, 1_000e6, 2_000);
        p.expectedPrice = _px(BTC) * 98 / 100;
        vm.expectRevert(abi.encodeWithSelector(IGainsVaultErrors.OrderRejected.selector, "price below band"));
        vault.openTrade(p);

        p = _params(BTC, true, 1_000e6, 2_000);
        p.maxSlippageP = 2_000; // 2% > the 1% policy band
        vm.expectRevert(abi.encodeWithSelector(IGainsVaultErrors.OrderRejected.selector, "slippage"));
        vault.openTrade(p);

        vm.expectRevert(abi.encodeWithSelector(IGainsVaultErrors.OrderRejected.selector, "notional too large"));
        vault.openTrade(_params(BTC, true, 20_000e6, 100_000)); // 2M notional

        vault.openTrade(_params(BTC, true, 100e6, 2_000)); // 200 USD < the 285.7 USD fee basis: accepted, not a floor
        vm.stopPrank();

        // Projected vault leverage (audit M-04): NAV 100k, 3x limit; per-trade leverage is Gains' business.
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(IGainsVaultErrors.OrderRejected.selector, "leverage"));
        vault.openTrade(_params(BTC, true, 10_000e6, 40_000)); // 400k notional on 100k
        _open(vault, BTC, true, 5_000e6, 50_000); // 50x trade, 2.5x vault leverage: fine
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(IGainsVaultErrors.OrderRejected.selector, "leverage"));
        vault.openTrade(_params(ETH, false, 10_000e6, 10_000)); // +1x on 2.5x

        vm.prank(stranger);
        vm.expectRevert(IGainsVaultErrors.Unauthorized.selector);
        vault.openTrade(_params(BTC, true, 1_000e6, 2_000));
    }

    function test_CollateralBoundedByIdleNetOfReserves() public {
        _deposit(alice, 1_000e6);
        _settle();
        _claim(alice);
        _deposit(bob, 5_000e6); // queued: not NAV, not tradable
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(IGainsVaultErrors.InsufficientIdle.selector, 1_000e6, 1_001e6));
        vault.openTrade(_params(ETH, true, 1_001e6, 1_000));
    }

    function test_ExitsMayCloseANoLongerAllowedPair() public {
        _deposit(alice, 10_000e6);
        _settle();
        uint32 idx = _open(vault, ETH, true, 1_000e6, 2_000);
        vm.prank(owner);
        policy.disallowAsset(ETH);
        assertGt(vault.totalAssets(), 0, "a disallowed pair keeps its price config for valuation");
        _passHold();
        _closeFilled(vault, idx, _px(ETH));
        assertEq(diamond.getTrades(address(vault)).length, 0);
    }

    function test_TradingPausedBlocksNewRisk() public {
        _deposit(alice, 10_000e6);
        _settle();
        uint32 idx = _open(vault, ETH, true, 1_000e6, 2_000);
        vm.prank(guardian);
        vault.setTradingPaused(true);
        vm.prank(manager);
        vm.expectRevert(IGainsVaultErrors.TradingIsPaused.selector);
        vault.openTrade(_params(BTC, true, 1_000e6, 2_000));
        vm.prank(manager);
        vm.expectRevert(IGainsVaultErrors.TradingIsPaused.selector);
        vault.increaseTrade(idx, 100e6, 2_000, _px(ETH), SLIP);
        _passHold();
        vm.prank(manager);
        vault.closeTrade(idx, _px(ETH)); // exits are never paused
    }

    function test_IncreaseAndLeverageUpdates() public {
        _deposit(alice, 10_000e6);
        _settle();
        uint32 idx = _open(vault, ETH, true, 1_000e6, 2_000);
        vm.prank(manager);
        vault.increaseTrade(idx, 500e6, 2_000, _px(ETH), SLIP);
        assertEq(usdc.allowance(address(vault), address(diamond)), 0);
        _fillLast(vault, _px(ETH));
        assertEq(diamond.getTrade(address(vault), idx).collateralAmount, 1_500e6);

        // Lowering leverage pulls collateral at constant size (exact approval, checked against idle).
        uint256 idleBefore = vault.idleAssets();
        uint256 navBefore = vault.totalAssets();
        vm.prank(manager);
        vault.updateLeverage(idx, 1_000);
        assertEq(idleBefore - vault.idleAssets(), 1_500e6);
        assertEq(usdc.allowance(address(vault), address(diamond)), 0);
        assertEq(vault.totalAssets(), navBefore, "the pulled collateral is a pending order, valued");
        _fillLast(vault, _px(ETH));
        assertEq(diamond.getTrade(address(vault), idx).collateralAmount, 3_000e6);

        // Raising returns collateral and runs the leverage check.
        vm.prank(manager);
        vault.updateLeverage(idx, 3_000);
        _fillLast(vault, _px(ETH));
        assertEq(diamond.getTrade(address(vault), idx).collateralAmount, 1_000e6);
        assertEq(vault.idleAssets(), 9_000e6);
    }

    function test_SetSlTp() public {
        _deposit(alice, 10_000e6);
        _settle();
        uint32 idx = _open(vault, ETH, true, 1_000e6, 2_000);
        uint64 p = _px(ETH);
        vm.prank(manager);
        vault.setSlTp(idx, p * 95 / 100, p * 110 / 100);
        assertEq(diamond.getTrade(address(vault), idx).sl, p * 95 / 100);
        assertEq(diamond.getTrade(address(vault), idx).tp, p * 110 / 100);
        vm.prank(guardian); // standalone: the guardian is the sentinel, and only acts while breached
        vm.expectRevert(IGainsVaultErrors.Unauthorized.selector);
        vault.setSlTp(idx, p * 96 / 100, p * 110 / 100);

        vm.prank(guardian);
        vault.triggerBreach();
        // While breached the stop loss only tightens: never removed, never widened.
        vm.prank(manager);
        vm.expectRevert(IGainsVaultErrors.SlNotTighter.selector);
        vault.setSlTp(idx, 0, p * 110 / 100);
        vm.prank(manager);
        vm.expectRevert(IGainsVaultErrors.SlNotTighter.selector);
        vault.setSlTp(idx, p * 90 / 100, p * 110 / 100);
        vm.prank(guardian);
        vm.expectRevert(IGainsVaultErrors.Unauthorized.selector);
        vault.setSlTp(idx, p * 97 / 100, p * 120 / 100); // the sentinel may not move the TP
        vm.prank(guardian);
        vault.setSlTp(idx, p * 97 / 100, p * 110 / 100);
        assertEq(diamond.getTrade(address(vault), idx).sl, p * 97 / 100);
    }

    // ------------------------------------------------------------------
    // Agent
    // ------------------------------------------------------------------
    function test_SetAndRevokeAgent() public {
        address bot = makeAddr("bot");
        _setAgent(vault, bot); // timelocked (audit H-01)
        assertEq(vault.agent(), bot);
        _deposit(alice, 10_000e6);
        _settle();
        vm.prank(bot);
        vault.openTrade(_params(ETH, true, 1_000e6, 2_000)); // decision D1: the agent trades through the vault

        vm.prank(guardian);
        vault.revokeAgent(); // instant
        assertEq(vault.agent(), address(0));
        vm.prank(bot);
        vm.expectRevert(IGainsVaultErrors.Unauthorized.selector);
        vault.openTrade(_params(ETH, true, 1_000e6, 2_000));
    }

    function test_SwitchingAgentOverwritesSlot() public {
        _setAgent(vault, makeAddr("a1"));
        _setAgent(vault, makeAddr("a2"));
        assertEq(vault.agent(), makeAddr("a2"));
        vm.prank(makeAddr("a1"));
        vm.expectRevert(IGainsVaultErrors.Unauthorized.selector);
        vault.openTrade(_params(ETH, true, 1_000e6, 2_000));
    }

    function test_SetAgentOnlyViaTimelock() public {
        vm.prank(owner);
        vm.expectRevert(IGainsVaultErrors.Unauthorized.selector);
        vault.setAgent(makeAddr("bot"));
        vm.prank(manager);
        vm.expectRevert(IGainsVaultErrors.Unauthorized.selector);
        vault.setAgent(manager);
    }

    function test_SetAgentRejectedWhileBreached() public {
        vm.prank(guardian);
        vault.triggerBreach();
        bytes memory data = abi.encodeCall(GainsVault.setAgent, (makeAddr("bot")));
        vm.prank(owner);
        vault.queue(data);
        _warp(vault.queuedEta(keccak256(data))); // hl-r2 exit-before-effect: wait for the stored eta
        vm.expectRevert(
            abi.encodeWithSelector(IGainsVaultErrors.CallFailed.selector, abi.encodeWithSelector(IGainsVaultErrors.ReduceOnlyMode.selector))
        );
        vault.execute(data);
    }

    // ------------------------------------------------------------------
    // Risk
    // ------------------------------------------------------------------
    function test_DailyLossBreachKeepsAgentAndGoesReduceOnlyForTheDay() public {
        address bot = makeAddr("bot");
        _setAgent(vault, bot);
        uint32 idx = _fundVenue(10_000e6);

        _setVenueValue(vault, idx, 9_400e6); // -6% today
        vm.prank(stranger);
        (, uint256 dailyLoss,) = vault.checkRisk();
        assertEq(dailyLoss, 600);
        assertTrue(vault.breached());
        assertEq(uint8(vault.breachReason()), 2, "daily loss");
        assertEq(vault.agent(), bot, "round 4: a risk breach derisks, the agent stays");

        vm.prank(manager);
        vm.expectRevert(IGainsVaultErrors.ReduceOnlyMode.selector);
        vault.openTrade(_params(BTC, true, 1_000e6, 2_000));

        vm.prank(alice);
        vm.expectRevert(IGainsVaultErrors.DepositsClosed.selector);
        vault.requestDeposit(10e6, alice);

        _redeem(alice, 1);
        vm.prank(bot);
        vault.closeTrade(idx, _px(ETH)); // the agent may still exit

        _warp((vm.getBlockTimestamp() / 1 days + 1) * 1 days + 1);
        vault.checkRisk();
        assertFalse(vault.breached(), "daily loss breach lasts until the daily reset");
        assertEq(vault.agent(), bot);
    }

    function test_LeverageBreach() public {
        uint32 idx = _fundVenue(10_000e6);
        diamond.setTradeSize(address(vault), idx, 4_000, _px(ETH)); // 4x > 3x
        _setVenueValue(vault, idx, 10_000e6);
        (uint256 lev,,) = vault.checkRisk();
        assertApproxEqAbs(lev, 40_000, 1);
        assertTrue(vault.breached());
        assertEq(uint8(vault.breachReason()), 1);
    }

    function test_DrawdownBreachAcrossDays() public {
        uint32 idx = _fundVenue(10_000e6);
        uint256 eq = 10_000e6;
        for (uint256 i; i < 5; ++i) {
            _skip(1 days);
            vault.checkRisk();
            eq = (eq * 96) / 100;
            _setVenueValue(vault, idx, eq);
            vault.checkRisk();
        }
        assertTrue(vault.breached());
    }

    function test_NoFalseBreachWhileAnOrderIsPending() public {
        _fundVenue(10_000e6);
        _passHold();
        vm.prank(manager);
        vault.reduceTrade(0, 5_000e6, 0, _px(ETH)); // the partial close is in flight
        vault.checkRisk();
        assertFalse(vault.breached(), "a pending close never reads as a loss: the trade stays valued");
    }

    function test_BreachFlattenIsForListedRolesOnly() public {
        uint32 idx = _fundVenue(10_000e6);
        uint64 p = _px(ETH);
        vm.prank(stranger);
        vm.expectRevert(IGainsVaultErrors.Unauthorized.selector);
        vault.flatten(ETH, 0, p, type(uint256).max);

        vm.prank(guardian);
        vault.triggerBreach();
        vm.prank(stranger);
        vm.expectRevert(IGainsVaultErrors.Unauthorized.selector);
        vault.flatten(ETH, 0, p, type(uint256).max);
        vm.prank(alice);
        vm.expectRevert(IGainsVaultErrors.Unauthorized.selector);
        vault.flatten(ETH, 0, p, type(uint256).max);

        vm.expectEmit(address(vault));
        emit IGainsVaultEvents.Flattened(ETH, idx, p, guardian);
        vm.prank(guardian);
        vault.flatten(ETH, 0, p, type(uint256).max);
        IGainsDiamond.PendingOrder[] memory orders = diamond.getPendingOrders(address(vault));
        assertEq(orders.length, 1);
        assertEq(orders[0].orderType, 1, "MARKET_CLOSE");
        assertEq(orders[0].trade.index, idx);
        assertEq(orders[0].trade.openPrice, p, "expected price passed through");
        assertEq(diamond.getTradeInfo(address(vault), idx).maxSlippageP, 1_000, "policy band: 100 bps");

        // A second flatten skips the trade whose close is in flight instead of reverting.
        vm.prank(guardian);
        vault.flatten(ETH, 0, p, type(uint256).max);
        assertEq(diamond.getPendingOrders(address(vault)).length, 1);
    }

    function test_ClearBreachGuardianInstantOwnerQueuedAfterBreach() public {
        uint32 idx = _fundVenue(10_000e6);
        bytes memory clear = abi.encodeCall(GainsVault.clearBreach, ());
        vm.prank(owner);
        vault.queue(clear);
        _warp(vault.queuedEta(keccak256(clear))); // hl-r2 exit-before-effect: wait for the stored eta
        vault.checkRisk();
        vm.prank(guardian);
        vault.triggerBreach();
        vm.expectRevert(IGainsVaultErrors.NotReady.selector);
        vault.execute(clear);
        vm.prank(owner);
        vm.expectRevert(IGainsVaultErrors.Unauthorized.selector);
        vault.clearBreach();
        vm.prank(stranger);
        vm.expectRevert(IGainsVaultErrors.Unauthorized.selector);
        vault.clearBreach();

        uint256 peak = vault.peakSharePrice();
        _setVenueValue(vault, idx, 9_000e6); // -10%
        _skip(1);
        vm.prank(owner);
        vault.queue(clear);
        _warp(vault.queuedEta(keccak256(clear))); // hl-r2 exit-before-effect: wait for the stored eta
        vault.execute(clear);
        assertFalse(vault.breached());
        assertEq(vault.peakSharePrice(), peak, "lifetime peak survives clearBreach");
        assertEq(vault.dayStartSharePrice(), vault.sharePrice(), "daily reference restarts");

        _setVenueValue(vault, idx, 8_460e6);
        vault.checkRisk();
        assertTrue(vault.breached(), "drawdown measured from the lifetime peak");

        vm.prank(guardian);
        vault.clearBreach();
        assertFalse(vault.breached());
    }

    function test_PaddedQueueCalldataRejected() public {
        bytes memory padded = abi.encodePacked(abi.encodeCall(GainsVault.clearBreach, ()), uint256(1));
        vm.prank(owner);
        vm.expectRevert(IGainsVaultErrors.Unauthorized.selector);
        vault.queue(padded);
        bytes memory shortData = abi.encodePacked(GainsVault.setManager.selector, uint128(1));
        vm.prank(owner);
        vm.expectRevert(IGainsVaultErrors.Unauthorized.selector);
        vault.queue(shortData);
    }

    function test_RenounceOwnershipDisabled() public {
        vm.prank(owner);
        vm.expectRevert(IGainsVaultErrors.Unauthorized.selector);
        vault.renounceOwnership();
    }

    // ------------------------------------------------------------------
    // Emergency: depositors can always get out
    // ------------------------------------------------------------------
    function test_EmergencyUnwindWithoutManager() public {
        uint32 idx = _fundVenue(10_000e6);
        _redeem(alice, vault.balanceOf(alice));

        vm.prank(stranger);
        vm.expectRevert(IGainsVaultErrors.NotOverdue.selector);
        vault.triggerEmergency();

        _skip(7 days);
        vm.prank(stranger);
        vault.triggerEmergency();
        assertTrue(vault.emergency());
        assertTrue(vault.breached());
        vm.prank(stranger);
        vm.expectRevert(IGainsVaultErrors.Unauthorized.selector);
        vault.flatten(ETH, 0, _px(ETH), type(uint256).max);

        vm.prank(guardian);
        vault.flatten(ETH, 0, _px(ETH), type(uint256).max);
        (, uint256 paid) = _fillLast(vault, _px(ETH));
        assertFalse(diamond.getTrade(address(vault), idx).isOpen);
        assertEq(usdc.balanceOf(address(vault)), paid, "every payout comes back to the vault");

        vault.checkRisk();
        vm.prank(guardian);
        vault.settle();
        _claim(alice);
        uint256 weekFee = (paid * 200 * 7 days) / (10_000 * 365 days);
        assertApproxEqAbs(usdc.balanceOf(alice), 1_000_000e6 - 10_000e6 + paid - weekFee, 1e4);
    }

    function test_OverdueSettleIsForListedRolesOnly() public {
        _deposit(alice, 1_000e6);
        vm.prank(stranger);
        vm.expectRevert(IGainsVaultErrors.Unauthorized.selector);
        vault.settle();
        _skip(7 days);
        vm.prank(stranger);
        vm.expectRevert(IGainsVaultErrors.Unauthorized.selector);
        vault.settle();
        vm.prank(alice);
        vm.expectRevert(IGainsVaultErrors.Unauthorized.selector);
        vault.settle();
        vm.prank(guardian);
        vault.settle();
    }

    function test_SettleBlockedWhileBreached() public {
        _deposit(alice, 1_000e6);
        vm.prank(guardian);
        vault.triggerBreach();
        vm.prank(manager);
        vm.expectRevert(IGainsVaultErrors.ReduceOnlyMode.selector);
        vault.settle();
    }

    function test_ExitEmergencyIsTheGuardiansAndNotWithRedemptionsPending() public {
        _fundVenue(10_000e6);
        _redeem(alice, 1e12);
        vm.prank(guardian);
        vault.triggerEmergency();
        vm.prank(owner);
        vm.expectRevert(IGainsVaultErrors.Unauthorized.selector);
        vault.exitEmergency();
        bytes memory data = abi.encodeCall(GainsVault.exitEmergency, ());
        vm.prank(owner);
        vm.expectRevert(IGainsVaultErrors.Unauthorized.selector);
        vault.queue(data);
        vm.prank(guardian);
        vm.expectRevert(IGainsVaultErrors.RedemptionsPending.selector);
        vault.exitEmergency();
        vm.prank(alice);
        vault.cancelRedeemRequest();
        vm.prank(guardian);
        vault.exitEmergency();
        assertFalse(vault.emergency());
    }

    function test_EmergencyUnwindOnlyByListedRoles() public {
        uint32 idx = _fundVenue(10_000e6);
        vm.prank(stranger);
        vm.expectRevert(IGainsVaultErrors.Unauthorized.selector);
        vault.reduceTrade(idx, 1_000e6, 0, _px(ETH));
        vm.prank(guardian);
        vault.triggerEmergency();
        vm.prank(guardian);
        vault.reduceTrade(idx, 1_000e6, 0, _px(ETH));
        _fillLast(vault, _px(ETH));
        vm.prank(stranger);
        vm.expectRevert(IGainsVaultErrors.Unauthorized.selector);
        vault.reduceTrade(idx, 1_000e6, 0, _px(ETH));
        vm.prank(stranger);
        vm.expectRevert(IGainsVaultErrors.Unauthorized.selector);
        vault.closeTrade(idx, _px(ETH));
    }

    function test_EmergencySettlePaysProRataAndRefundsDeposits() public {
        vm.prank(owner);
        vault.lowerFees(0, 0);
        uint32 idx = _fundVenue(10_000e6);
        _deposit(bob, 500e6);
        _redeem(alice, vault.balanceOf(alice));
        vm.prank(guardian);
        vault.triggerEmergency();
        // A rescuer frees 4k of the trade's collateral.
        vm.prank(guardian);
        vault.reduceTrade(idx, 4_000e6, 0, _px(ETH));
        (, uint256 paid1) = _fillLast(vault, _px(ETH));
        _skip(1 hours); // the keeper's checkpoint follows the NAV (exit-only settles price at min(NAV, checkpoint))
        vault.checkRisk();
        vm.prank(guardian);
        vault.settle();
        (, uint256 depShares,,, uint256 burned,,,) = vault.epochs(1);
        assertEq(depShares, 0);
        _claim(bob);
        assertEq(usdc.balanceOf(bob), 1_000_000e6, "deposit refunded");
        (uint256 cs, uint256 ca) = lens.claimable(vault, alice);
        assertGt(cs, 0, "unpaid shares come back");
        assertApproxEqAbs(ca, paid1, 2);
        assertEq(vault.balanceOf(address(vault)), cs, "the unpaid shares wait in the vault for the claim");
        assertApproxEqAbs(burned + cs, 10_000e6 * 1e6, 1);
        (uint256 fillShares, uint256 fillPaid, uint256 fillEpoch) = lens.partialFill(vault, alice);
        assertEq(fillShares, cs);
        assertEq(fillPaid, ca);
        assertEq(fillEpoch, 1);
        _claim(alice);
        assertEq(vault.balanceOf(alice), cs);

        _redeem(alice, cs);
        vm.prank(guardian);
        vault.closeTrade(idx, _px(ETH));
        (, uint256 paid2) = _fillLast(vault, _px(ETH));
        _skip(1 hours);
        vault.checkRisk();
        vm.prank(guardian);
        vault.settle();
        _claim(alice);
        assertApproxEqAbs(usdc.balanceOf(alice), 1_000_000e6 - 10_000e6 + paid1 + paid2, 3, "fully paid over two settlements");
        assertEq(vault.pendingRedeemShares(), 0);
        assertEq(vault.balanceOf(alice), 0);
    }

    // ------------------------------------------------------------------
    // Admin and timelock
    // ------------------------------------------------------------------
    function test_TimelockedManagerChange() public {
        address newManager = makeAddr("newManager");
        bytes memory data = abi.encodeCall(GainsVault.setManager, (newManager));
        vm.prank(owner);
        vault.queue(data);
        vm.expectRevert(IGainsVaultErrors.NotReady.selector);
        vault.execute(data);
        _warp(vault.queuedEta(keccak256(data))); // hl-r2 exit-before-effect: wait for the stored eta
        vault.execute(data);
        assertEq(vault.manager(), newManager);
    }

    function test_QueuedChangeExpiresAfterGrace() public {
        bytes memory data = abi.encodeCall(GainsVault.setManager, (makeAddr("newManager")));
        vm.prank(owner);
        vault.queue(data);
        _warp(vault.queuedEta(keccak256(data)) + vault.GRACE_PERIOD() + 1); // hl-r2 exit-before-effect: wait for the stored eta
        vm.expectRevert(IGainsVaultErrors.Expired.selector);
        vault.execute(data);
    }

    function test_GuardianCannotBeQueued() public {
        bytes memory data = abi.encodeWithSignature("setGuardian(address)", makeAddr("g2"));
        vm.prank(owner);
        vm.expectRevert(IGainsVaultErrors.Unauthorized.selector);
        vault.queue(data);
        assertEq(vault.guardian(), guardian);
        assertEq(vault.sentinel(), guardian, "standalone vault: the guardian is also the sentinel");
    }

    // ------------------------------------------------------------------
    // Fuzz
    // ------------------------------------------------------------------
    function testFuzz_RoundTripNeverProfitsWithoutPnl(uint256 a, uint256 b) public {
        vm.prank(owner);
        vault.lowerFees(0, 0);
        a = bound(a, 10e6, 500_000e6);
        b = bound(b, 10e6, 500_000e6);
        _deposit(alice, a);
        _deposit(bob, b);
        _settle();
        _claim(alice);
        _claim(bob);
        _redeem(alice, vault.balanceOf(alice));
        _redeem(bob, vault.balanceOf(bob));
        _settle();
        _claim(alice);
        _claim(bob);
        assertLe(usdc.balanceOf(alice), 1_000_000e6);
        assertLe(usdc.balanceOf(bob), 1_000_000e6);
        assertApproxEqAbs(usdc.balanceOf(alice), 1_000_000e6, 2);
        assertApproxEqAbs(usdc.balanceOf(bob), 1_000_000e6, 2);
    }

    function testFuzz_ProfitSharedProRata(uint256 a, uint256 b, uint64 pnl) public {
        vm.prank(owner);
        vault.lowerFees(0, 0);
        a = bound(a, 300e6, 400_000e6);
        b = bound(b, 10e6, 400_000e6);
        pnl = uint64(bound(pnl, 0, 100_000e6));
        _deposit(alice, a);
        _deposit(bob, b);
        _settle();
        _claim(alice);
        _claim(bob);
        uint32 idx = _open(vault, ETH, true, uint120(a + b), 1_000);
        _setVenueValue(vault, idx, a + b + pnl);

        uint256 aliceVal = vault.convertToAssets(vault.balanceOf(alice));
        uint256 expected = a + (uint256(pnl) * a) / (a + b);
        assertApproxEqAbs(aliceVal, expected, uint256(pnl) / 1e5 + 2);
    }
}
