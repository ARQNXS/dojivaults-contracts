// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {console2} from "forge-std/Test.sol";
import {R1Base} from "./R1Base.t.sol";
import {GainsVault} from "../../../src/gains/GainsVault.sol";
import {GainsVaultPolicy} from "../../../src/gains/GainsVaultPolicy.sol";
import {IGainsDiamond} from "../../../src/gains/IGainsDiamond.sol";
import {IGainsVaultErrors, OpenParams} from "../../../src/gains/GainsTypes.sol";
import {MockChainlinkFeed} from "../../gains/mocks/GainsMocks.sol";

/// @notice Round 1 PoCs on the unit harness (mock diamond). Ids match contracts/audit/gains/ROUND1.md.
///         Fix round (contracts/audit/gains/FIXES-R1.md): the PoC of every fixed finding is now a regression test
///         (test_GR1_xx_...) that asserts the fixed behaviour and fails on the old code. PoCs of findings that were
///         accepted or not fixed keep their original name and still pass while the behaviour exists.
contract R1PoCTest is R1Base {
    // ------------------------------------------------------------------
    // GR1-04 (was PENDINGGRIEF): decoy market requests no longer hold the emergency settle
    // ------------------------------------------------------------------
    /// @notice A decoy reduce or close holds no collateral, so it no longer holds the emergency settle: the guardian
    ///         pays alice while the decoy is in flight.
    function test_GR1_04_decoyClosesNoLongerBlockTheEmergencySettle() public {
        uint32 idx = _fundVenue(100_000e6);
        _redeem(alice, vault.balanceOf(alice) / 2);
        vm.prank(guardian);
        vault.triggerEmergency(); // guardian == sentinel on a standalone vault

        // The manager may still exit at any time (R4): a 1 USDC reduce at a price far off the market.
        vm.prank(manager);
        vault.reduceTrade(idx, 1e6, 0, 1);
        assertEq(vault.venue().pending, 1, "the decoy is in flight");
        assertFalse(vault.ordersPending(), "but it holds no collateral");

        vm.prank(guardian);
        vault.settle(); // exit-only emergency settle runs through the decoy
        assertEq(vault.pendingRedeemShares(), 0, "alice's redemption is settled");
    }

    /// @notice An order that does hold collateral holds settle for at most one Gains timeout: once the epoch is
    ///         overdue no new one can be placed, and anyone cancels the last one after its timeout.
    function test_GR1_04_holdingOrderBlocksAtMostOneTimeout() public {
        _deposit(alice, 100_000e6);
        _settle();
        _claim(alice);
        _redeem(alice, vault.balanceOf(alice) / 4);
        _warp(uint256(vault.epochStartedAt()) + 7 days - 10); // just before maxEpochDuration
        uint32 order = _request(vault, ETH, true, 10_000e6, 2_000); // a market open: holds 10k on the diamond
        _skip(10); // overdue
        vm.prank(manager);
        vm.expectRevert(IGainsVaultErrors.EpochOverdue.selector);
        vault.openTrade(_params(ETH, true, 10_000e6, 2_000));

        vm.prank(guardian);
        vm.expectRevert(IGainsVaultErrors.OrdersPending.selector);
        vault.settle(); // the open in flight holds the overdue exit-only settle ...
        vm.roll(vm.getBlockNumber() + diamond.timeoutBlocks());
        vm.prank(stranger);
        vault.cancelTimedOut(order); // ... until anyone cancels it after Gains' timeout
        vm.prank(guardian);
        vault.settle();
        assertEq(vault.pendingRedeemShares(), 0);
    }

    // ------------------------------------------------------------------
    // GR1-23 (was DUSTCHECKPOINT): a dust vault is no longer frozen by a 1 USDC donation
    // ------------------------------------------------------------------
    function test_GR1_23_dustCheckpointDoesNotFreezeSettle() public {
        _deposit(alice, 1_000e6);
        _settle();
        _claim(alice);
        _skip(1 hours); // management fee shares accrue for the fee recipient
        _redeem(alice, vault.balanceOf(alice));
        _settle();
        _claim(alice);
        uint256 dust = vault.totalAssets();
        console2.log("dust NAV (wei) and checkpoint", dust, vault.checkpointNav());
        assertLt(dust, 10_000, "a few thousand wei of NAV left, like the live vault (37 wei)");
        assertGt(vault.totalSupply(), 0, "fee shares remain");

        usdc.mint(stranger, 1e6);
        vm.prank(stranger);
        usdc.transfer(address(vault), 1e6); // the donation
        _deposit(bob, 10_000e6);

        _skip(1 hours); // the minimum epoch age for a settle that prices deposits
        vault.checkRisk();
        vm.prank(manager);
        vault.settle(); // old code: NavMoved every hour for ~55 h
        assertEq(vault.pendingDepositAssets(), 0, "bob's deposit is priced at once");
    }

    // ------------------------------------------------------------------
    // GR1-24 (was ADVERSETRUNC): no valuation price can wrap any more
    // ------------------------------------------------------------------
    /// @dev The smallest 8-decimal-representable mid whose short adverse edge (mid x 1.002) no longer fits a uint64:
    ///      about 1.841e19 in 1e10 precision (1.84 billion USD per unit), a valid uint64 the old GainsPrice.read accepted.
    function _wrapMid() internal pure returns (uint64) {
        uint256 lo = (uint256(type(uint64).max) + 1) * 10_000 / 10_020 + 1;
        return uint64((lo + 99) / 100 * 100);
    }

    function test_GR1_24_readRefusesAPriceWhoseBandEdgeWraps() public {
        ethFeed.set(int256(uint256(_wrapMid()) / 100), vm.getBlockTimestamp());
        vm.expectRevert(abi.encodeWithSelector(IGainsVaultErrors.PriceStale.selector, uint256(ETH)));
        policy.price(ETH);
    }

    /// @notice The spike no longer values a 5k short at a 9k profit: NAV refuses the price instead.
    function test_GR1_24_shortNotValuedAtAProfitWhenTheFeedSpikes() public {
        _deposit(alice, 100_000e6);
        _settle();
        _claim(alice);
        _open(vault, ETH, false, 5_000e6, 2_000); // 5k short at 2x, opened at 3,000
        ethFeed.set(int256(uint256(_wrapMid()) / 100), vm.getBlockTimestamp());
        vm.expectRevert(abi.encodeWithSelector(IGainsVaultErrors.PriceStale.selector, uint256(ETH)));
        vault.totalAssets();
    }

    // ------------------------------------------------------------------
    // GR1-40 (accepted): allowAsset copies whatever the factory curates at execution, not what the owner queued
    // ------------------------------------------------------------------
    function test_CURATIONSWAP_allowAssetTakesTheFeedCuratedAtExecution() public {
        vm.prank(owner);
        policy.queueAllowAsset(SOL); // the owner (and the depositors watching) see SOL with solFeed, band 25
        MockChainlinkFeed other = new MockChainlinkFeed(8, 1e8); // 1 USD "SOL"
        vm.prank(platformOwner);
        platform.setAssetCurated(SOL, true, address(other), 365 days, 25);
        _warp(policy.assetAllowEta(SOL)); // hl-r2 exit-before-effect: wait for the stored eta
        vm.prank(stranger);
        policy.allowAsset(SOL); // anyone executes
        assertEq(policy.feedOf(SOL).feed, address(other), "the vault prices SOL with a feed its owner never queued");
        assertEq(policy.feedOf(SOL).maxAge, 365 days, "and a one-year staleness limit");
    }

    // ------------------------------------------------------------------
    // GR1-16 (was RESTINGINSTOP): a full stop cancels the vault's resting opens
    // ------------------------------------------------------------------
    function test_GR1_16_fullStopCancelsRestingOrders() public {
        _deposit(alice, 100_000e6);
        _settle();
        _claim(alice);
        OpenParams memory p = _params(ETH, true, 20_000e6, 3_000);
        p.tradeType = 1; // limit
        p.expectedPrice = _px(ETH) * 99 / 100;
        vm.prank(manager);
        vault.openTrade(p);
        uint32 idx = diamond.tradeCount(address(vault)) - 1;

        uint256 idle = vault.idleAssets();
        vm.prank(guardian);
        vault.triggerEmergency(); // full stop + emergency: reduce only, agent revoked, resting opens cancelled
        assertFalse(diamond.getTrade(address(vault), idx).isOpen, "the resting order is cancelled");
        assertEq(vault.idleAssets(), idle + 20_000e6, "its collateral is back");
        vm.expectRevert(bytes("mock: no limit order"));
        diamond.executeLimit(address(vault), idx, p.expectedPrice); // Gains' bot has nothing left to trigger
    }

    // ------------------------------------------------------------------
    // GR1-34 (accepted): the operator's shortfall ignores queued deposits that settle nets against the redemptions
    // ------------------------------------------------------------------
    function test_SHORTFALLDEPOSITS_operatorReducesWhenDepositsAlreadyCover() public {
        address op = makeAddr("operator");
        vm.prank(owner);
        vault.setOperator(op);
        _deposit(alice, 100_000e6);
        _settle();
        _claim(alice);
        uint32 idx = _open(vault, ETH, true, 90_000e6, 2_000);
        _redeem(alice, vault.balanceOf(alice) / 2); // ~49.7k at NAV
        _deposit(bob, 60_000e6); // more than enough to pay it in a normal settle (available = idle + deposits)

        uint256 snap = vm.snapshotState();
        _ageEpoch(vault);
        vault.checkRisk();
        vm.prank(op);
        vault.settle(); // proof: the settle pays the redemptions in full without any reduce
        vm.revertToState(snap);

        uint256 shortfall = vault.redemptionShortfall();
        console2.log("shortfall the operator may reduce for (USDC)", shortfall / 1e6);
        assertGt(shortfall, 39_000e6);
        vm.prank(op);
        vault.reduceTrade(idx, uint120(shortfall), 0, _px(ETH)); // accepted: ~40k of the strategy unwound for nothing
        assertEq(vault.venue().pending, 1);
    }

    // ------------------------------------------------------------------
    // GR1-39 (documented): the launch seed is not the launcher's: the first depositors receive it
    // ------------------------------------------------------------------
    function test_SEEDGIFT_firstDepositorReceivesTheSeed() public {
        usdc.mint(address(vault), 1e6); // what GainsVaultFactory.create does with seedUsdc
        _deposit(alice, 20e6);
        _settle();
        _claim(alice);
        _redeem(alice, vault.balanceOf(alice));
        _settle();
        uint256 b = usdc.balanceOf(alice);
        _claim(alice);
        console2.log("alice deposited 20 USDC, got back (wei)", usdc.balanceOf(alice) - b);
        assertGt(usdc.balanceOf(alice) - b, 20.99e6, "the 1 USDC seed went to the first depositor (live vault: 20 -> 20.999963)");
    }

    // ------------------------------------------------------------------
    // GR1-41 (was FLATTENSLIP): flatten(slippage 0) is capped like a custom flatten
    // ------------------------------------------------------------------
    function test_GR1_41_defaultFlattenCappedLikeACustomOne() public {
        GainsVaultPolicy.RiskConfig memory r = _defaultRisk();
        r.maxSlippageBps = 2_000;
        (GainsVault v, GainsVaultPolicy p) = _vaultWith(r);
        assertEq(p.flattenSlippage(0), 3_000, "3% (maxFlattenSlippageBps) for slippage 0, not 20%");
        vm.expectRevert(GainsVaultPolicy.SlippageTooHigh.selector);
        p.flattenSlippage(301); // a custom one is capped at 3% as before
        _depositTo(v, alice, 100_000e6);
        _settleV(v);
        v.claim(alice);
        uint32 idx = _open(v, ETH, true, 10_000e6, 2_000);
        vm.prank(guardian);
        v.triggerBreach();
        vm.prank(guardian); // the sentinel (== guardian here) in a breach
        v.flatten(ETH, 0, _px(ETH), 1);
        assertEq(diamond.getTradeInfo(address(v), idx).maxSlippageP, 3_000, "the close fills within 3% of expectedPrice");
    }

    // ------------------------------------------------------------------
    // GR1-01 (was PENDINGLEVNOTIONAL): pending leverage-only increases count at their full added notional
    // ------------------------------------------------------------------
    /// @notice The first leverage-only increase now counts, so the second one is refused at the policy.
    function test_GR1_01_secondLeverageOnlyIncreaseRefused() public {
        _deposit(alice, 100_000e6);
        _settle();
        _claim(alice);
        uint32 a = _open(vault, ETH, true, 25_000e6, 2_000); // 50k notional
        uint32 b = _open(vault, BTC, true, 25_000e6, 2_000); // 50k notional
        assertApproxEqRel(vault.venue().notional, 100_000e6, 0.01e18);

        vm.prank(manager);
        vault.increaseTrade(a, 0, 7_900, _px(ETH), SLIP); // leverage-only: Gains stores collateral 0 in the order
        assertApproxEqRel(vault.venue().notional, 297_500e6, 0.01e18, "the pending +197.5k counts");
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(IGainsVaultErrors.OrderRejected.selector, "leverage"));
        vault.increaseTrade(b, 0, 7_900, _px(BTC), SLIP);
        // and a second request on the same trade is refused by the vault itself
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(IGainsVaultErrors.PendingOrderExists.selector, a));
        vault.increaseTrade(a, 0, 100, _px(ETH), SLIP);
    }

    /// @notice ROUND1's "31x" scenario at the size MAX_POSITIONS allows: 10 trades + 10 pending increases = 20
    ///         (XREVIEW's 20 trades + 20 increases does not fit the ceiling). Each leverage-only increase alone is
    ///         within the 3x policy; on the old code all ten passed (16.5x under a 3x policy). Now the cumulative
    ///         pending exposure is checked: only the first fits, and vault leverage stays within the policy.
    function test_GR1_01_tenConcurrentLeverageIncreasesRefusedAtThePolicy() public {
        _deposit(alice, 100_000e6);
        _settle();
        _claim(alice);
        uint32[10] memory idx;
        for (uint256 i; i < 10; ++i) {
            idx[i] = _open(vault, i % 2 == 0 ? ETH : BTC, true, 5_000e6, 3_000); // 15k each: 150k = 1.5x
        }
        uint256 accepted;
        for (uint256 i; i < 10; ++i) {
            uint16 pair = i % 2 == 0 ? ETH : BTC;
            // +29x on 5k collateral = +145k: alone, 150k open + 145k <= 3x
            vm.prank(manager);
            try vault.increaseTrade(idx[i], 0, 29_000, _px(pair), SLIP) {
                ++accepted;
            } catch (bytes memory err) {
                assertEq(err, abi.encodeWithSelector(IGainsVaultErrors.OrderRejected.selector, "leverage"));
            }
        }
        console2.log("leverage-only increases accepted (old code: 10)", accepted);
        assertEq(accepted, 1, "only the first fits the 3x policy");
        uint256 lev = vault.venue().notional * 10_000 / vault.totalAssets();
        assertLe(lev, 30_000, "open + pending exposure within 3x");
    }

    // ------------------------------------------------------------------
    // GR1-09 (not fixed, FIXES-R1.md): exit-only settle prices the venue, so a stale feed holds every redemption
    // until the pair is flattened
    // ------------------------------------------------------------------
    function test_STALESETTLE_emergencyRedemptionsWaitForAFlattenWhenAFeedIsStale() public {
        uint32 idx = _fundVenue(100_000e6);
        _deposit(bob, 50_000e6);
        _settle(); // bob's 50k sits idle: enough to pay alice's redemption below in full
        _claim(bob);
        _redeem(alice, vault.balanceOf(alice) / 4);
        vm.prank(guardian);
        vault.triggerEmergency();
        // The ETH feed stops (deprecated / stale): only ETH is held.
        uint256 t = vm.getBlockTimestamp() + 2_700;
        vm.warp(t);
        btcFeed.set(btcFeed.answer(), t);
        vm.prank(guardian);
        vm.expectPartialRevert(IGainsVaultErrors.PriceStale.selector);
        vault.settle(); // although idle USDC covers the redemption in full
        // The only way out without a timelocked feed rotation: crystallize the ETH book.
        vm.prank(guardian);
        vault.flatten(ETH, 0, _px(ETH), type(uint256).max);
        diamond.fill(address(vault), diamond.orderCount(address(vault)) - 1, _px(ETH));
        assertFalse(diamond.getTrade(address(vault), idx).isOpen);
        vm.prank(guardian);
        vault.settle(); // now it runs: nothing priced on ETH any more
        assertEq(vault.pendingRedeemShares(), 0);
    }
}
