// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Base} from "./Base.t.sol";
import {HyperVault} from "../src/HyperVault.sol";
import {IHyperVaultErrors, IHyperVaultEvents} from "../src/VaultTypes.sol";
import {HyperCore} from "../src/hypercore/HyperCore.sol";

contract HyperVaultTest is Base {
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
        // No ERC-4626 deposit/mint/withdraw/redeem selectors exist on the vault: only epoch requests move funds.
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
        _deposit(alice, 1_000e6);
        _settle();
        _claim(alice);

        // All of alice's USDC goes to HyperCore.
        vm.prank(manager);
        vault.bridgeToCore(1_000e6);
        _skipBridgeWindow();
        _setCore(address(vault), 1_000e6, 0, 0);

        // Bob's deposit covers alice's exit, no bridge back needed.
        _redeem(alice, vault.balanceOf(alice) / 4);
        _deposit(bob, 500e6);
        _settle();
        _claim(alice);
        _claim(bob);
        assertApproxEqAbs(usdc.balanceOf(alice), 1_000_000e6 - 1_000e6 + 250e6, 1);
        assertGt(vault.balanceOf(bob), 0);
    }

    function test_SettleRevertsWithoutLiquidity() public {
        _deposit(alice, 1_000e6);
        _settle();
        _claim(alice);
        vm.prank(manager);
        vault.bridgeToCore(1_000e6);
        _skipBridgeWindow();
        _setCore(address(vault), 1_000e6, 0, 0);

        _redeem(alice, vault.balanceOf(alice));
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(IHyperVaultErrors.InsufficientLiquidity.selector, 0, 1_000e6));
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
        vm.expectRevert(IHyperVaultErrors.CapExceeded.selector);
        vault.requestDeposit(600e6, bob);
    }

    function test_InsiderDepositsArePricedInTheNextEpoch() public {
        // Manager, owner and fee recipient may deposit, but never at a price they can influence in the current
        // epoch (round 4, replaces the hard InsiderDeposit block of audit C-01): the request belongs to the next one.
        usdc.mint(manager, 10e6);
        vm.prank(manager);
        usdc.approve(address(vault), 10e6);
        vm.prank(manager);
        uint256 epoch = vault.requestDeposit(10e6, manager); // MIN_DEPOSIT
        assertEq(epoch, vault.currentEpoch() + 1, "manager deposit waits a full epoch");
        vm.prank(alice);
        assertEq(vault.requestDeposit(10e6, owner), vault.currentEpoch() + 1, "deposit for the owner too");
        assertEq(vault.deferredDepositAssets(), 20e6);
        assertEq(vault.pendingDepositAssets(), 0);
        assertEq(vault.idleAssets(), 0, "deferred USDC is not NAV");

        _deposit(alice, 100e6);
        _settle(); // epoch 0: only alice
        assertEq(vault.pendingDepositAssets(), 20e6, "the insiders' deposits are now the queue");
        assertEq(vault.deferredDepositAssets(), 0);
        (uint256 sh,) = lens.claimable(vault, manager);
        assertEq(sh, 0, "not priced yet");
        vm.expectRevert(IHyperVaultErrors.RequestNotSettled.selector);
        vault.claim(manager);

        vm.warp(vm.getBlockTimestamp() + 1 hours);
        _settle(); // epoch 1: priced at that NAV
        _claim(manager);
        assertGt(vault.balanceOf(manager), 0);

        // They still hold and redeem shares as anyone else.
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
        vm.expectRevert(IHyperVaultErrors.RequestPending.selector);
        vault.requestDeposit(10e6, feeRecipient);
        // and the other way round: a next-epoch deposit blocks a redemption until it settles
        usdc.mint(manager, 10e6);
        vm.prank(manager);
        usdc.approve(address(vault), 10e6);
        vm.prank(manager);
        vault.requestDeposit(10e6, manager); // MIN_DEPOSIT
        vm.prank(manager);
        vm.expectRevert(IHyperVaultErrors.RequestPending.selector);
        vault.requestRedeem(1, manager, manager);
        // a next-epoch deposit can be cancelled
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
        _deposit(alice, 10e6); // MIN_DEPOSIT
        usdc.mint(address(vault), 1_000e6); // donation before settle
        _deposit(bob, 1_000e6);
        _settle();
        _claim(alice);
        _claim(bob);
        // Both priced at the same NAV, donation shared pro rata to existing supply (none), so virtual shares absorb it.
        uint256 aliceValue = vault.convertToAssets(vault.balanceOf(alice));
        uint256 bobValue = vault.convertToAssets(vault.balanceOf(bob));
        assertGe(bobValue, 999e6, "bob not diluted");
        assertLe(aliceValue, 20e6, "alice does not capture the donation");
    }

    // ------------------------------------------------------------------
    // NAV and bridging
    // ------------------------------------------------------------------
    function test_BridgeToCoreAccounting() public {
        _deposit(alice, 1_000e6);
        _settle();
        _claim(alice);

        vm.prank(manager);
        vault.bridgeToCore(600e6);
        assertEq(depositWallet.totalDeposited(), 600e6);
        assertTrue(vault.bridgeInFlight());
        assertEq(vault.equityAtBridge(), 1_000e6, "NAV snapshotted before the transfer");
        _setCore(address(vault), 600e6, 0, 0); // already credited on Core
        assertEq(vault.totalAssets(), 1_000e6, "in-window NAV is the snapshot, never double counted");

        vm.prank(manager);
        vm.expectRevert(IHyperVaultErrors.BridgeInFlight.selector);
        vault.settle();

        _skipBridgeWindow();
        assertEq(vault.totalAssets(), 1_000e6);
        _settle();
    }

    function test_MinBridgeUnlessFullAmount() public {
        _deposit(alice, 150e6);
        _settle();
        _claim(alice);
        vm.prank(manager);
        vm.expectRevert(IHyperVaultErrors.BridgeTooSmall.selector);
        vault.bridgeToCore(50e6);
        vm.prank(manager);
        vault.bridgeToCore(150e6); // everything idle is always allowed
        // HLR2-A02 / A08 (a-series patch): the 150 lands, then 120 of it is used; a credit never seen would hold.
        _setCore(address(vault), 0, 0, 150e6);
        vault.syncBridge();
        _skipBridgeWindow();
        _setCore(address(vault), 0, 0, 30e6);
        _setWithdrawable(address(vault), 0);
        vm.prank(manager);
        vm.expectRevert(IHyperVaultErrors.BridgeTooSmall.selector);
        vault.bridgeToEvm(10e6);
        vm.prank(manager);
        vault.bridgeToEvm(30e6); // everything available is always allowed
    }

    function test_BridgeWindowIsNeverExtended() public {
        _deposit(alice, 1_000e6);
        _settle();
        _claim(alice);
        vm.prank(manager);
        vault.bridgeToCore(500e6);
        assertEq(vault.bridgeAmount(), 500e6);
        // Nothing bridges, settles or accrues inside the window; it closes by itself (audit N-01).
        vm.prank(manager);
        vm.expectRevert(IHyperVaultErrors.BridgeInFlight.selector);
        vault.bridgeToCore(100e6);
        _setCore(address(vault), 0, 0, 500e6);
        _setWithdrawable(address(vault), 0);
        vm.prank(manager);
        vm.expectRevert(IHyperVaultErrors.BridgeInFlight.selector);
        vault.bridgeToEvm(500e6);
        vm.prank(manager);
        vm.expectRevert(IHyperVaultErrors.BridgeInFlight.selector);
        vault.settle();
        vm.expectRevert(IHyperVaultErrors.BridgeInFlight.selector);
        vault.accrueFees();
        _skipBridgeWindow();
        vm.prank(manager);
        vault.bridgeToCore(100e6);
        _skipBridgeWindow();
        _setCore(address(vault), 0, 0, 600e6);
        _settle();
    }

    // ------------------------------------------------------------------
    // Fees
    // ------------------------------------------------------------------
    function test_PerformanceFeeAboveHighWaterMark() public {
        vm.prank(owner);
        vault.lowerFees(0, 2_000); // isolate the performance fee
        _deposit(alice, 1_000e6);
        _settle();
        _claim(alice);

        vm.prank(manager);
        vault.bridgeToCore(1_000e6);
        _skipBridgeWindow();
        _setCore(address(vault), 1_100e6, 0, 0); // +100 profit

        _settle();
        uint256 feeValue = vault.convertToAssets(vault.balanceOf(feeRecipient));
        assertApproxEqAbs(feeValue, 20e6, 1e4, "20% of 100");
        assertApproxEqAbs(vault.convertToAssets(vault.balanceOf(alice)), 1_080e6, 1e4);

        // No new fee without new highs.
        uint256 feeShares = vault.balanceOf(feeRecipient);
        _setCore(address(vault), 1_050e6, 0, 0);
        _settle();
        assertEq(vault.balanceOf(feeRecipient), feeShares);
    }

    function test_ManagementFeeOverOneYear() public {
        vm.prank(owner);
        vault.lowerFees(200, 0);
        _deposit(alice, 1_000e6);
        _settle();
        _claim(alice);
        vm.warp(vm.getBlockTimestamp() + 365 days);
        _settle();
        uint256 feeValue = vault.convertToAssets(vault.balanceOf(feeRecipient));
        assertApproxEqRel(feeValue, 20e6, 0.001e18, "2% of 1000");
    }

    function test_ProtocolFeeShare() public view {
        // Factory-less vault mints everything to feeRecipient; per vault shares are covered in the factory tests.
        assertEq(vault.factory(), address(0));
        assertEq(vault.protocolShareBps(), 0);
    }

    function test_LowerFeesOnlyDown() public {
        vm.prank(owner);
        vm.expectRevert(IHyperVaultErrors.InvalidFee.selector);
        vault.lowerFees(300, 2_000);
        vm.prank(owner);
        vm.expectRevert(IHyperVaultErrors.InvalidFee.selector);
        vault.lowerFees(200, 2_000); // unchanged values are not a lowering (audit N-05)
        vm.prank(owner);
        vault.lowerFees(200, 1_999);
        assertEq(vault.performanceFeeBps(), 1_999);
    }

    // ------------------------------------------------------------------
    // Trading via CoreWriter
    // ------------------------------------------------------------------
    function test_PlaceOrderEncoding() public {
        _setCore(address(vault), 10_000e6, 0, 0);
        // Buy 0.01 BTC at 100,500 (within 1% band)
        uint64 px = 100_500e8;
        uint64 sz = 0.01e8;
        vm.prank(manager);
        vault.placeOrder(BTC, true, px, sz, false, HyperCore.TIF_GTC, 42);

        (uint8 v, uint24 id, bytes memory body) = _decode(writer.last());
        assertEq(v, 1);
        assertEq(id, 1);
        (uint32 asset, bool isBuy, uint64 limitPx, uint64 size, bool ro, uint8 tif, uint128 cloid) =
            abi.decode(body, (uint32, bool, uint64, uint64, bool, uint8, uint128));
        assertEq(asset, BTC);
        assertTrue(isBuy);
        assertEq(limitPx, px);
        assertEq(size, sz);
        assertFalse(ro);
        assertEq(tif, 2);
        assertEq(cloid, 42);
    }

    function test_PlaceOrderPolicyRejections() public {
        _setCore(address(vault), 1_000_000e6, 0, 0);
        vm.startPrank(manager);
        vm.expectRevert(abi.encodeWithSelector(IHyperVaultErrors.OrderRejected.selector, "asset not allowed"));
        vault.placeOrder(DOGE, true, 0.2e8, 100e8, false, 2, 0);

        vm.expectRevert(abi.encodeWithSelector(IHyperVaultErrors.OrderRejected.selector, "price above band"));
        vault.placeOrder(BTC, true, 102_000e8, 0.01e8, false, 2, 0);

        vm.expectRevert(abi.encodeWithSelector(IHyperVaultErrors.OrderRejected.selector, "price below band"));
        vault.placeOrder(BTC, false, 98_000e8, 0.01e8, false, 2, 0);

        vm.expectRevert(abi.encodeWithSelector(IHyperVaultErrors.OrderRejected.selector, "notional too large"));
        vault.placeOrder(BTC, true, 100_000e8, 20e8, false, 2, 0); // 2M notional

        vm.expectRevert(abi.encodeWithSelector(IHyperVaultErrors.OrderRejected.selector, "spot not supported"));
        vault.placeOrder(10_107, true, 1e8, 1e8, false, 2, 0);
        vm.stopPrank();

        // Projected leverage: 1k equity, 3x limit (audit M-04).
        _setCore(address(vault), 1_000e6, 0, 0);
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(IHyperVaultErrors.OrderRejected.selector, "leverage"));
        vault.placeOrder(BTC, true, 100_000e8, 0.05e8, false, 2, 0); // 5k notional on 1k
        vm.prank(manager);
        vault.placeOrder(BTC, true, 100_000e8, 0.02e8, false, 2, 0); // 2x is fine
        _setCore(address(vault), 1_000e6, 2_500e6, 0); // already 2.5x open
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(IHyperVaultErrors.OrderRejected.selector, "leverage"));
        vault.placeOrder(BTC, true, 100_000e8, 0.01e8, false, 2, 0);
        vm.prank(manager);
        vault.placeOrder(BTC, false, 100_000e8, 0.01e8, true, 3, 0); // reduce only never checks leverage

        vm.prank(stranger);
        vm.expectRevert(IHyperVaultErrors.Unauthorized.selector);
        vault.placeOrder(BTC, true, 100_000e8, 0.01e8, false, 2, 0);
    }

    function test_ReduceOnlyMayCloseNonAllowlistedAsset() public {
        vm.prank(manager);
        vault.placeOrder(DOGE, false, 0.2e8, 100e8, true, 3, 0);
    }

    function test_TradingPausedBlocksNewRisk() public {
        vm.prank(guardian);
        vault.setTradingPaused(true);
        vm.prank(manager);
        vm.expectRevert(IHyperVaultErrors.TradingIsPaused.selector);
        vault.placeOrder(BTC, true, 100_000e8, 0.01e8, false, 2, 0);
        vm.prank(manager);
        vault.placeOrder(BTC, false, 100_000e8, 0.01e8, true, 3, 0);
    }

    // ------------------------------------------------------------------
    // Agent
    // ------------------------------------------------------------------
    function test_SetAndRevokeAgent() public {
        address bot = makeAddr("bot");
        uint256 n = writer.count();
        _setAgent(vault, bot); // timelocked (audit H-01)
        assertEq(vault.agent(), bot);
        // HL-PROXY: the agent is never approved on HyperCore; setAgent sends at most the account-mode pin
        for (uint256 i = n; i < writer.count(); ++i) {
            (, uint24 sent,) = _decode(writer.at(i));
            assertEq(sent, 16, "only the mode pin");
        }
        n = writer.count();
        vm.prank(guardian);
        vault.revokeAgent(); // instant
        // WP5-D14: the revoke is EVM-only, nothing goes to HyperCore (no action 9 burn)
        assertEq(writer.count(), n, "revoke sends no CoreWriter action");
        assertEq(vault.agent(), address(0));
    }

    function test_SwitchingAgentOverwritesSlot() public {
        _setAgent(vault, makeAddr("a1"));
        uint256 n = writer.count();
        _setAgent(vault, makeAddr("a2"));
        assertEq(writer.count(), n + 1, "same named slot: one approval replaces the previous agent");
        assertEq(vault.agent(), makeAddr("a2"));
    }

    function test_SetAgentOnlyViaTimelock() public {
        vm.prank(owner);
        vm.expectRevert(IHyperVaultErrors.Unauthorized.selector);
        vault.setAgent(makeAddr("bot"));
        vm.prank(manager);
        vm.expectRevert(IHyperVaultErrors.Unauthorized.selector);
        vault.setAgent(manager);
    }

    function test_SetAgentRejectedWhileBreached() public {
        vm.prank(guardian);
        vault.triggerBreach();
        bytes memory data = abi.encodeCall(HyperVault.setAgent, (makeAddr("bot")));
        vm.prank(owner);
        vault.queue(data);
        vm.warp(vault.queuedEta(keccak256(data)));
        vm.expectRevert(
            abi.encodeWithSelector(IHyperVaultErrors.CallFailed.selector, abi.encodeWithSelector(IHyperVaultErrors.ReduceOnlyMode.selector))
        );
        vault.execute(data);
    }

    // ------------------------------------------------------------------
    // Risk
    // ------------------------------------------------------------------
    function _fundCore(uint256 amount) internal {
        _deposit(alice, amount);
        _settle();
        _claim(alice);
        vm.prank(manager);
        vault.bridgeToCore(amount);
        _skipBridgeWindow();
        _setCore(address(vault), int64(uint64(amount)), 0, 0);
        vault.checkRisk(); // set day baseline
    }

    function test_DailyLossBreachKeepsAgentAndGoesReduceOnlyForTheDay() public {
        address bot = makeAddr("bot");
        _setAgent(vault, bot);
        _fundCore(10_000e6);

        _setCore(address(vault), 9_400e6, 10_000e6, 0); // -6% today
        vm.prank(stranger);
        (, uint256 dailyLoss,) = vault.checkRisk();
        assertEq(dailyLoss, 600);
        assertTrue(vault.breached());
        assertEq(uint8(vault.breachReason()), 2, "daily loss");
        assertEq(vault.agent(), bot, "round 4: a risk breach derisks, the agent stays");

        vm.prank(manager);
        vm.expectRevert(IHyperVaultErrors.ReduceOnlyMode.selector);
        vault.placeOrder(BTC, true, 100_000e8, 0.01e8, false, 2, 0);

        vm.prank(alice);
        vm.expectRevert(IHyperVaultErrors.DepositsClosed.selector);
        vault.requestDeposit(10e6, alice);

        // Exits stay open.
        _redeem(alice, 1);

        // Next UTC day: the first check clears it.
        vm.warp((vm.getBlockTimestamp() / 1 days + 1) * 1 days + 1);
        vault.checkRisk();
        assertFalse(vault.breached(), "daily loss breach lasts until the daily reset");
        assertEq(vault.agent(), bot);
    }

    function test_LeverageBreach() public {
        _fundCore(10_000e6);
        _setCore(address(vault), 10_000e6, 40_000e6, 0); // 4x > 3x
        (uint256 lev,,) = vault.checkRisk();
        assertEq(lev, 40_000);
        assertTrue(vault.breached());
    }

    function test_DrawdownBreachAcrossDays() public {
        _fundCore(10_000e6);
        // Lose 4% per day for 4 days: each day under the 5% daily limit, total over 15% drawdown.
        uint64 eq = 10_000e6;
        for (uint256 i; i < 5; ++i) {
            vm.warp(vm.getBlockTimestamp() + 1 days);
            vault.checkRisk();
            eq = (eq * 96) / 100;
            _setCore(address(vault), int64(eq), 0, 0);
            vault.checkRisk();
        }
        assertTrue(vault.breached());
    }

    function test_NoFalseBreachDuringBridge() public {
        _fundCore(10_000e6);
        // Manager bridges 5k back; core already shows the debit but EVM not yet credited.
        _setWithdrawable(address(vault), 10_000e6);
        vm.prank(manager);
        vault.bridgeToEvm(5_000e6);
        _setCore(address(vault), 5_000e6, 0, 0);
        vault.checkRisk();
        assertFalse(vault.breached());
    }

    function test_BreachFlattenIsForListedRolesOnly() public {
        _fundCore(10_000e6);
        _setPosition(address(vault), BTC, -12_345); // short 0.12345 BTC (szDecimals 5)
        vm.prank(stranger);
        vm.expectRevert(IHyperVaultErrors.Unauthorized.selector);
        vault.flatten(BTC, 0);

        vm.prank(guardian);
        vault.triggerBreach();
        // Round 4: a breach does not open flatten to strangers or depositors.
        vm.prank(stranger);
        vm.expectRevert(IHyperVaultErrors.Unauthorized.selector);
        vault.flatten(BTC, 0);
        vm.prank(alice);
        vm.expectRevert(IHyperVaultErrors.Unauthorized.selector);
        vault.flatten(BTC, 0);

        vm.prank(guardian);
        vault.flatten(BTC, 0);
        (, uint24 id, bytes memory body) = _decode(writer.last());
        assertEq(id, 1);
        (uint32 asset, bool isBuy, uint64 px, uint64 sz, bool ro, uint8 tif,) =
            abi.decode(body, (uint32, bool, uint64, uint64, bool, uint8, uint128));
        assertEq(asset, BTC);
        assertTrue(isBuy, "short closes with buy");
        // mark 100,000.0 raw 1,000,000 ; +1% = 1,010,000 -> 5 sig figs 1,010,000 ; 1e8 scale = raw * 1e7
        assertEq(px, 101_000e8);
        assertEq(sz, 0.12345e8);
        assertTrue(ro);
        assertEq(tif, 3);
    }

    function test_ClearBreachGuardianInstantOwnerQueuedAfterBreach() public {
        _fundCore(10_000e6);
        // An item queued before the breach never clears it (audit N-04).
        bytes memory clear = abi.encodeCall(HyperVault.clearBreach, ());
        vm.prank(owner);
        vault.queue(clear);
        vm.warp(vault.queuedEta(keccak256(clear)));
        vault.checkRisk();
        vm.prank(guardian);
        vault.triggerBreach();
        vm.expectRevert(IHyperVaultErrors.NotReady.selector);
        vault.execute(clear);
        vm.prank(owner);
        vm.expectRevert(IHyperVaultErrors.Unauthorized.selector);
        vault.clearBreach(); // never instant for the owner
        vm.prank(stranger);
        vm.expectRevert(IHyperVaultErrors.Unauthorized.selector);
        vault.clearBreach();

        // Queued after the breach: the timelock runs from the breach.
        uint256 peak = vault.peakSharePrice();
        _setCore(address(vault), 9_000e6, 0, 0); // -10%
        vm.warp(vm.getBlockTimestamp() + 1);
        vm.prank(owner);
        vault.queue(clear);
        vm.warp(vault.queuedEta(keccak256(clear)));
        vault.execute(clear);
        assertFalse(vault.breached());
        assertEq(vault.peakSharePrice(), peak, "lifetime peak survives clearBreach");
        assertEq(vault.dayStartSharePrice(), vault.sharePrice(), "daily reference restarts");

        // The drawdown limit stays cumulative: another 6% from here is >15% from the peak.
        _setCore(address(vault), 8_460e6, 0, 0);
        vault.checkRisk();
        assertTrue(vault.breached(), "drawdown measured from the lifetime peak");

        // The cold guardian clears instantly.
        vm.prank(guardian);
        vault.clearBreach();
        assertFalse(vault.breached());
    }

    function test_PaddedQueueCalldataRejected() public {
        bytes memory padded = abi.encodePacked(abi.encodeCall(HyperVault.clearBreach, ()), uint256(1));
        vm.prank(owner);
        vm.expectRevert(IHyperVaultErrors.Unauthorized.selector);
        vault.queue(padded);
        bytes memory shortData = abi.encodePacked(HyperVault.setManager.selector, uint128(1));
        vm.prank(owner);
        vm.expectRevert(IHyperVaultErrors.Unauthorized.selector);
        vault.queue(shortData);
    }

    function test_RenounceOwnershipDisabled() public {
        vm.prank(owner);
        vm.expectRevert(IHyperVaultErrors.Unauthorized.selector);
        vault.renounceOwnership();
    }

    // ------------------------------------------------------------------
    // Emergency: depositors can always get out
    // ------------------------------------------------------------------
    function test_EmergencyUnwindWithoutManager() public {
        _fundCore(10_000e6);
        _setPosition(address(vault), ETH, 5_0000); // long 5 ETH
        _redeem(alice, vault.balanceOf(alice));

        // Manager disappears. Before overdue nobody can force anything.
        vm.prank(stranger);
        vm.expectRevert(IHyperVaultErrors.NotOverdue.selector);
        vault.triggerEmergency();

        vm.warp(vm.getBlockTimestamp() + 7 days);
        vm.prank(stranger);
        vault.triggerEmergency();
        assertTrue(vault.emergency());
        assertTrue(vault.breached());
        // The trigger stays open to anyone (the depositors' lever); the unwind does not.
        vm.prank(stranger);
        vm.expectRevert(IHyperVaultErrors.Unauthorized.selector);
        vault.flatten(ETH, 0);

        vm.prank(guardian);
        vault.flatten(ETH, 0);

        // Position closed on core, funds withdrawable.
        _setPosition(address(vault), ETH, 0);
        _setCore(address(vault), 10_000e6, 0, 0);
        _setWithdrawable(address(vault), 10_000e6);
        vm.prank(guardian);
        vault.bridgeToEvm(10_000e6);

        // Simulate HyperCore delivering the USDC to the vault on HyperEVM.
        _skipBridgeWindow();
        usdc.mint(address(vault), 10_000e6);
        _setCore(address(vault), 0, 0, 0);

        vault.checkRisk(); // refresh the NAV checkpoint (a day passed)
        vm.prank(guardian);
        vault.settle();
        _claim(alice);
        // Alice gets everything back minus one week of 2% management fee.
        uint256 principal = 10_000e6;
        uint256 weekFee = (principal * 200 * 7 days) / (10_000 * 365 days);
        assertApproxEqAbs(usdc.balanceOf(alice), 1_000_000e6 - weekFee, 1e4);
    }

    function test_OverdueSettleIsForListedRolesOnly() public {
        _deposit(alice, 1_000e6);
        vm.prank(stranger);
        vm.expectRevert(IHyperVaultErrors.Unauthorized.selector);
        vault.settle();
        vm.warp(vm.getBlockTimestamp() + 7 days);
        // Round 4: overdue does not open settlement to strangers or depositors.
        vm.prank(stranger);
        vm.expectRevert(IHyperVaultErrors.Unauthorized.selector);
        vault.settle();
        vm.prank(alice);
        vm.expectRevert(IHyperVaultErrors.Unauthorized.selector);
        vault.settle();
        vm.prank(guardian);
        vault.settle();
    }

    function test_SettleBlockedWhileBreached() public {
        _deposit(alice, 1_000e6);
        vm.prank(guardian);
        vault.triggerBreach();
        vm.prank(manager);
        vm.expectRevert(IHyperVaultErrors.ReduceOnlyMode.selector);
        vault.settle();
    }

    function test_ExitEmergencyIsTheGuardiansAndNotWithRedemptionsPending() public {
        _fundCore(10_000e6);
        _redeem(alice, 1e12);
        vm.prank(guardian);
        vault.triggerEmergency();
        // The owner has no path: not directly, not through the queue (audit W-01b).
        vm.prank(owner);
        vm.expectRevert(IHyperVaultErrors.Unauthorized.selector);
        vault.exitEmergency();
        bytes memory data = abi.encodeCall(HyperVault.exitEmergency, ());
        vm.prank(owner);
        vm.expectRevert(IHyperVaultErrors.Unauthorized.selector);
        vault.queue(data);
        // The guardian waits for the redeemers.
        vm.prank(guardian);
        vm.expectRevert(IHyperVaultErrors.RedemptionsPending.selector);
        vault.exitEmergency();
        vm.prank(alice);
        vault.cancelRedeemRequest();
        vm.prank(guardian);
        vault.exitEmergency();
        assertFalse(vault.emergency());
    }

    function test_EmergencyBridgeOnlyByListedRolesOutsideAWindow() public {
        _fundCore(10_000e6);
        _setWithdrawable(address(vault), 10_000e6);
        vm.prank(stranger);
        vm.expectRevert(IHyperVaultErrors.Unauthorized.selector);
        vault.bridgeToEvm(1_000e6);
        vm.prank(guardian);
        vault.triggerEmergency();
        vm.prank(guardian);
        vault.bridgeToEvm(1_000e6);
        // Round 4: nobody outside the listed roles unwinds, not even in emergency.
        vm.prank(stranger);
        vm.expectRevert(IHyperVaultErrors.Unauthorized.selector);
        vault.bridgeToEvm(1_000e6);
        vm.prank(guardian);
        vm.expectRevert(IHyperVaultErrors.BridgeInFlight.selector);
        vault.bridgeToEvm(1_000e6);
        _skipBridgeWindow();
        vm.prank(guardian);
        vault.bridgeToEvm(1_000e6); // no per epoch slot: whenever no window is open (audit N-02)
    }

    function test_EmergencySettlePaysProRataAndRefundsDeposits() public {
        _fundCore(10_000e6); // alice holds 10k of shares, all on Core
        _deposit(bob, 500e6);
        _redeem(alice, vault.balanceOf(alice)); // wants 10k, only part can be paid at first
        vm.prank(guardian);
        vault.triggerEmergency();
        // A rescuer bridges 4k back.
        _setWithdrawable(address(vault), 10_000e6);
        vm.prank(guardian);
        vault.bridgeToEvm(4_000e6);
        _skipBridgeWindow();
        usdc.mint(address(vault), 4_000e6);
        _setCore(address(vault), 6_000e6, 0, 0);
        vault.checkRisk();
        vm.prank(guardian);
        vault.settle();
        // Bob's deposit is refunded, alice got 4k and 60% of her shares come back (partial fill + return, V-01).
        (, uint256 depShares,,, uint256 burned,,,) = vault.epochs(1);
        assertEq(depShares, 0);
        assertApproxEqRel(burned, (10_000e6 * 1e6 * 4) / 10, 1e14);
        _claim(bob);
        assertEq(usdc.balanceOf(bob), 1_000_000e6, "deposit refunded");
        (uint256 cs, uint256 ca) = lens.claimable(vault, alice);
        assertApproxEqRel(cs, (10_000e6 * 1e6 * 6) / 10, 1e14, "unpaid shares come back");
        assertApproxEqAbs(ca, 4_000e6, 2);
        (, uint256 pendingRed) = lens.pendingRequest(vault, alice);
        assertEq(pendingRed, 0, "nothing stays queued");
        assertEq(vault.pendingRedeemShares(), 0, "vault pending matches");
        (uint256 fillShares, uint256 fillPaid, uint256 fillEpoch) = lens.partialFill(vault, alice);
        assertEq(fillShares, cs);
        assertEq(fillPaid, ca);
        assertEq(fillEpoch, 1);
        _claim(alice);
        assertApproxEqAbs(usdc.balanceOf(alice), 1_000_000e6 - 10_000e6 + 4_000e6, 2);
        assertEq(vault.balanceOf(alice), cs);
        // She queues the remainder again; the rest comes back with the next bridge.
        _redeem(alice, cs);
        vm.prank(guardian);
        vault.bridgeToEvm(6_000e6);
        _skipBridgeWindow();
        usdc.mint(address(vault), 6_000e6);
        _setCore(address(vault), 0, 0, 0);
        _setWithdrawable(address(vault), 0);
        vault.checkRisk();
        vm.prank(guardian);
        vault.settle();
        _claim(alice);
        assertApproxEqAbs(usdc.balanceOf(alice), 1_000_000e6, 3, "fully paid over two settlements");
        assertEq(vault.pendingRedeemShares(), 0);
        assertEq(vault.balanceOf(alice), 0);
    }

    // ------------------------------------------------------------------
    // Admin and timelock
    // ------------------------------------------------------------------
    function test_TimelockedManagerChange() public {
        address newManager = makeAddr("newManager");
        bytes memory data = abi.encodeCall(HyperVault.setManager, (newManager));
        vm.prank(owner);
        vault.queue(data);

        vm.expectRevert(IHyperVaultErrors.NotReady.selector);
        vault.execute(data);

        vm.warp(vault.queuedEta(keccak256(data)));
        vault.execute(data);
        assertEq(vault.manager(), newManager);
    }

    function test_QueuedChangeExpiresAfterGrace() public {
        bytes memory data = abi.encodeCall(HyperVault.setManager, (makeAddr("newManager")));
        vm.prank(owner);
        vault.queue(data);
        vm.warp(vault.queuedEta(keccak256(data)) + vault.GRACE_PERIOD() + 1);
        vm.expectRevert(IHyperVaultErrors.Expired.selector);
        vault.execute(data);
    }

    function test_GuardianCannotBeQueued() public {
        bytes memory data = abi.encodeWithSignature("setGuardian(address)", makeAddr("g2"));
        vm.prank(owner);
        vm.expectRevert(IHyperVaultErrors.Unauthorized.selector);
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
        a = bound(a, 10e6, 500_000e6); // MIN_DEPOSIT
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
        a = bound(a, 10e6, 400_000e6); // MIN_DEPOSIT
        b = bound(b, 10e6, 400_000e6);
        pnl = uint64(bound(pnl, 0, 100_000e6));
        _deposit(alice, a);
        _deposit(bob, b);
        _settle();
        _claim(alice);
        _claim(bob);
        vm.prank(manager);
        vault.bridgeToCore(a + b);
        _skipBridgeWindow();
        _setCore(address(vault), int64(uint64(a + b + pnl)), 0, 0);

        uint256 aliceVal = vault.convertToAssets(vault.balanceOf(alice));
        uint256 expected = a + (uint256(pnl) * a) / (a + b);
        // Virtual shares (offset 1e6) capture a negligible slice of profit; bounded by pnl / 1e6 per share unit.
        assertApproxEqAbs(aliceVal, expected, uint256(pnl) / 1e5 + 2);
    }
}
