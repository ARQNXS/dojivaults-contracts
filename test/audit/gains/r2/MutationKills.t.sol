// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Vm} from "forge-std/Vm.sol";
import {R1Base} from "../R1Base.t.sol";
import {GainsVaultPolicy} from "../../../../src/gains/GainsVaultPolicy.sol";
import {OpenParams, IGainsVaultErrors as E} from "../../../../src/gains/GainsTypes.sol";

/// @notice Round 2 mutation testing (domain MUT): tests that kill the mutants that survived the existing suites on
///         fund-moving lines. Each test names the mutant(s) it kills (ids from contracts/audit/gains/r2/MUTATION.md,
///         Gambit ids or R<n> for the supplementary operators). Every one passes on the unmutated contracts.
contract MutationKillsTest is R1Base {
    // ------------------------------------------------------------------ requestDeposit / requestRedeem guards

    /// Logic#3 (`assets == 0` -> false): a zero deposit must fail as ZeroAmount, not fall through to DepositTooSmall.
    function test_MUT_Logic3_zeroDepositIsZeroAmount() public {
        vm.prank(alice);
        vm.expectRevert(E.ZeroAmount.selector);
        vault.requestDeposit(0, alice);
    }

    /// Logic#20 (`controller == address(0)` -> false): USDC queued for controller 0 could only ever be claimed to
    /// address(0) (shares minted there are lost).
    function test_MUT_Logic20_depositForZeroControllerReverts() public {
        vm.prank(alice);
        vm.expectRevert(E.ZeroAddress.selector);
        vault.requestDeposit(10e6, address(0));
    }

    /// Math#41 (GainsVaultMath.transfer `bal < amount` -> false, the subtraction is unchecked): a redeem request of
    /// more shares than the owner holds must revert, or the owner's balance wraps to ~2^256 shares.
    function test_MUT_Math41_redeemAboveBalanceReverts() public {
        _deposit(alice, 1_000e6);
        _settle();
        _claim(alice);
        uint256 bal = vault.balanceOf(alice);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, bal, bal + 1));
        vault.requestRedeem(bal + 1, alice, alice);
        // through an approved spender as well
        vm.prank(alice);
        vault.approve(bob, type(uint256).max);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, bal, bal + 1));
        vault.requestRedeem(bal + 1, bob, alice);
        assertEq(vault.balanceOf(alice), bal, "balance untouched");
    }

    /// Logic#67 (cap check `+ deferredDepositAssets` -> `-`): the deposit cap counts the insiders' deferred deposits.
    function test_MUT_Logic67_capCountsDeferredDeposits() public {
        vm.prank(owner);
        vault.setDepositCap(100_000e6);
        usdc.mint(manager, 50_000e6);
        vm.startPrank(manager);
        usdc.approve(address(vault), type(uint256).max);
        vault.requestDeposit(40_000e6, manager); // insider: deferred to the next epoch
        vm.stopPrank();
        assertEq(vault.deferredDepositAssets(), 40_000e6);
        _deposit(alice, 50_000e6); // 90k counted
        vm.prank(bob);
        vm.expectRevert(E.CapExceeded.selector);
        vault.requestDeposit(10_000e6 + 1, bob); // 100k + 1 with the deferred 40k counted
        _deposit(bob, 10_000e6); // exactly the cap
    }

    /// Logic#168 (requestRedeem `controller == address(0)` -> false): shares escrowed for controller 0 could only be
    /// claimed to address(0).
    function test_MUT_Logic168_redeemForZeroControllerReverts() public {
        _deposit(alice, 1_000e6);
        _settle();
        _claim(alice);
        uint256 bal = vault.balanceOf(alice);
        vm.prank(alice);
        vm.expectRevert(E.ZeroAddress.selector);
        vault.requestRedeem(bal, address(0), alice);
    }

    /// Math#139 (priceAt `supply == 0` -> false): without shares the price is 0, so a checkRisk on an empty vault
    /// holding a donation never raises the peak (the first mint resets the references, settle:325-329) and starts the
    /// day at price 0.
    function test_MUT_Math139_emptyVaultPriceIsZero() public {
        usdc.mint(address(vault), 5e6); // donation, no shares
        uint256 peak0 = vault.peakSharePrice();
        _skip(1 days); // a new risk day: dayStartSharePrice is rewritten from the price
        vault.checkRisk();
        assertEq(vault.peakSharePrice(), peak0, "peak not raised by an empty vault");
        assertEq(vault.dayStartSharePrice(), 0, "day start = price of an empty vault = 0");
    }

    /// Math#157 (priceAt `nav + 1` -> `nav - 1`): checkRisk's price (priceAt) equals sharePrice() (toAssets of one
    /// share) at the same NAV, so the risk references are in the same units as the settle price (round 1 SM6).
    function test_MUT_Math157_riskPriceEqualsSharePrice() public {
        _deposit(alice, 100_000e6);
        _settle();
        _claim(alice);
        _skip(1 days);
        vault.checkRisk();
        assertEq(vault.dayStartSharePrice(), vault.sharePrice(), "day start = share price at the same NAV");
    }

    /// Math#174 (redemptionShortfall `pending > 0` -> false): the operator's bound counts the pending redemptions
    /// at the checkpoint NAV, not only the claimable reserve.
    function test_MUT_Math174_shortfallCountsPendingRedemptions() public {
        _fundVenue(100_000e6); // all NAV on the venue, no idle USDC
        uint256 sh = vault.balanceOf(alice) / 4;
        _redeem(alice, sh);
        uint256 owed = Math.mulDiv(sh, uint256(vault.checkpointNav()) + 1, vault.totalSupply() + 1e6);
        assertGt(owed, 24_000e6);
        assertEq(vault.redemptionShortfall(), owed, "pending redemptions at the checkpoint NAV, nothing idle");
    }

    /// Logic#160 (requestRedeem `shares == 0` -> false) and Logic#216 (cancelDepositRequest `depositAssets == 0` ->
    /// false): empty requests and empty cancels revert instead of moving a request pointer / emitting a no-op.
    function test_MUT_Logic160_216_emptyRequestsRevert() public {
        vm.prank(alice);
        vm.expectRevert(E.ZeroAmount.selector);
        vault.requestRedeem(0, alice, alice);
        vm.prank(stranger);
        vm.expectRevert(E.NothingToCancel.selector);
        vault.cancelDepositRequest();
    }

    /// Math#213 (redemptionShortfall: a market close in flight not counted): the trade's collateral is on its way
    /// back, so the operator's bound sees no shortfall while it covers the pending redemptions.
    function test_MUT_Math213_closeInFlightCountsAsAvailable() public {
        uint32 idx = _fundVenue(100_000e6);
        _redeem(alice, vault.balanceOf(alice) / 4);
        assertGt(vault.redemptionShortfall(), 24_000e6, "short before the close");
        _passHold(); // GR2-KEY-01b: the manager's exit waits out the minimum hold
        vm.prank(manager);
        vault.closeTrade(idx, _px(ETH)); // pending, not filled
        assertEq(vault.redemptionShortfall(), 0, "100k of collateral in flight covers ~25k");
    }

    /// Math#208 (redemptionShortfall: `!o.isOpen` no longer skipped): a filled (closed) close order of a list that
    /// still reports it must not count its trade's stale collateral as USDC on the way back.
    function test_MUT_Math208_closedOrdersIgnored() public {
        _fundVenue(100_000e6);
        _deposit(bob, 10_000e6);
        _settle();
        _claim(bob);
        uint32 b = _open(vault, BTC, true, 10_000e6, 1_000);
        _passHold();
        _closeFilled(vault, b, _px(BTC)); // its close order is now closed; Gains-like lists drop it, this one keeps it
        diamond.setIncludeClosed(true);
        uint256 sh = vault.balanceOf(alice) / 4;
        _redeem(alice, sh);
        uint256 owed = Math.mulDiv(sh, uint256(vault.checkpointNav()) + 1, vault.totalSupply() + 1e6);
        uint256 avail = usdc.balanceOf(address(vault)) - vault.pendingDepositAssets() - vault.deferredDepositAssets();
        assertEq(vault.redemptionShortfall(), owed > avail ? owed - avail : 0, "only open orders count");
    }

    /// Nav#121 (snapshot `held > fee` -> true): a pending order holding less than the gov fee a cancel would keep is
    /// worth 0, it must not make the NAV read underflow (a 1-wei collateral increase is accepted by the vault).
    function test_MUT_Nav121_tinyPendingIncreaseDoesNotBreakNav() public {
        uint32 idx = _fundVenue(100_000e6);
        _deposit(bob, 1_000e6);
        _settle();
        _claim(bob);
        diamond.setPair(ETH, 6e8, 285.7e18, 0.1e18, 0); // 0.06% fee: min gov fee ~0.07 USDC
        uint256 v0 = vault.venue().value;
        vm.prank(manager);
        vault.increaseTrade(idx, 1, 100, _px(ETH), SLIP);
        assertEq(vault.venue().value, v0, "1 wei held, below the gov fee: worth 0, NAV readable");
    }

    /// Logic#224 / #233 (cancelDepositRequest: the "epoch passed and not carried" check removed): a deposit that was
    /// already priced (shares minted, not yet claimed) cannot be cancelled; with the check gone the refund would come
    /// out of the other depositors' queue (pendingDepositAssets) while the minted shares stay claimable.
    function test_MUT_Logic224_233_settledDepositNotCancellable() public {
        _deposit(alice, 1_000e6);
        _settle(); // alice's deposit is priced; she has not claimed
        _deposit(bob, 5_000e6); // bob's USDC is in the queue
        vm.prank(alice);
        vm.expectRevert(E.NothingToCancel.selector);
        vault.cancelDepositRequest();
        assertEq(vault.pendingDepositAssets(), 5_000e6, "bob's queue intact");
    }

    /// Math#220 (redemptionShortfall: `else if (true)`): only a partial close that returns collateral counts as USDC
    /// on the way back; a pending market OPEN's collateral is leaving the vault, not coming back.
    function test_MUT_Math220_pendingOpenIsNotAvailable() public {
        _fundVenue(100_000e6);
        _deposit(bob, 10_000e6);
        _settle();
        _claim(bob);
        _request(vault, BTC, true, 10_000e6, 1_000); // pending open, holds 10k
        uint256 sh = vault.balanceOf(alice) / 4;
        _redeem(alice, sh);
        uint256 owed = Math.mulDiv(sh, uint256(vault.checkpointNav()) + 1, vault.totalSupply() + 1e6);
        uint256 avail = usdc.balanceOf(address(vault)) - vault.pendingDepositAssets() - vault.deferredDepositAssets();
        assertEq(avail, 0, "everything is on the diamond");
        assertEq(vault.redemptionShortfall(), owed, "the pending open's 10k does not count");
    }

    /// Nav#167 (blockingOrders: `!isOpen` no longer skipped): a filled (closed) market open that a list still reports
    /// holds nothing and must not hold settle.
    function test_MUT_Nav167_closedOrdersDoNotBlockSettle() public {
        _fundVenue(100_000e6); // its market open is filled, i.e. closed
        diamond.setIncludeClosed(true);
        assertFalse(vault.ordersPending(), "a closed order blocks nothing");
        _redeem(alice, vault.balanceOf(alice) / 10);
        _deposit(bob, 20_000e6);
        _settle(); // reverts OrdersPending if the closed open counted
    }

    /// Logic#270 (cancelRedeemRequest `r.epoch != currentEpoch || redeemShares == 0` -> false): nothing to cancel
    /// reverts.
    function test_MUT_Logic270_emptyRedeemCancelReverts() public {
        vm.prank(stranger);
        vm.expectRevert(E.NothingToCancel.selector);
        vault.cancelRedeemRequest();
    }

    /// Logic#333 (`_claimIfSettled` early return for an empty request), #363 (`shares > 0` -> true), #373
    /// (`assets > 0` -> true): a claim delivers only what is owed, with no zero-amount share or USDC transfer, and no
    /// Claimed event for an empty request (indexers and integrators read these events as payouts).
    function test_MUT_Logic333_363_373_claimEmitsOnlyRealTransfers() public {
        _deposit(alice, 1_000e6);
        _settle();
        // deposit-only claim: shares, no USDC
        vm.recordLogs();
        vault.claim(alice);
        _assertOneNonZeroTransfer();
        // redemption fully paid (every share burned): USDC, no shares back
        _redeem(alice, vault.balanceOf(alice));
        _settle();
        vm.recordLogs();
        vault.claim(alice);
        _assertOneNonZeroTransfer();
        // alice's request is empty now; a new deposit runs _claimIfSettled(alice) on it
        vm.recordLogs();
        vm.prank(alice);
        vault.requestDeposit(10e6, alice);
        bytes32 claimed = keccak256("Claimed(address,uint256,uint256,uint256)");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) assertTrue(logs[i].topics[0] != claimed, "no Claimed for an empty request");
    }

    function _assertOneNonZeroTransfer() internal {
        bytes32 t = keccak256("Transfer(address,address,uint256)");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 n;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == t) {
                ++n;
                assertGt(abi.decode(logs[i].data, (uint256)), 0, "no zero-amount transfer");
            }
        }
        assertEq(n, 1, "exactly one transfer per claim here");
    }

    /// Policy#543 (applyPendingConfig `delete _pending` removed): an applied loosening is no longer pending and
    /// cannot be applied a second time (round 1 #753, for the config).
    function test_MUT_Policy543_applyClearsThePendingConfig() public {
        GainsVaultPolicy.RiskConfig memory r = _defaultRisk();
        r.maxDailyLossBps = 800; // looser: queued
        vm.prank(owner);
        policy.proposeConfig(r);
        assertTrue(policy.pendingConfig().exists);
        vm.warp(policy.pendingConfig().eta); // GR2-CFG-01: the stored eta, not queue + timelock
        policy.applyPendingConfig();
        assertEq(policy.maxDailyLossBps(), 800);
        assertFalse(policy.pendingConfig().exists, "nothing pending after the apply");
        vm.expectRevert(GainsVaultPolicy.NothingPending.selector);
        policy.applyPendingConfig();
    }

    /// Nav#376 / #377 (`added` of a pending partial open with collateral deleted / 0): the exposure the order adds
    /// counts in the vault's notional (the leverage check of the next order reads it).
    function test_MUT_Nav376_377_pendingIncreaseAddsNotional() public {
        uint32 idx = _fundVenue(100_000e6);
        _deposit(bob, 10_000e6);
        _settle();
        _claim(bob);
        uint256 n0 = vault.venue().notional;
        vm.prank(manager);
        vault.increaseTrade(idx, 5_000e6, 2_000, _px(ETH), SLIP);
        assertEq(vault.venue().notional, n0 + 10_000e6, "5k x 2x pending counts");
    }

    /// Logic#116 (RequestPending check ignores a queued deposit): an insider's next-epoch deposit for a controller
    /// that already has a current-epoch deposit must revert, or the two queues (pending / deferred) and the one
    /// request pointer disagree.
    function test_MUT_Logic116_mixedEpochDepositReverts() public {
        _deposit(alice, 1_000e6); // current epoch
        usdc.mint(manager, 1_000e6);
        vm.startPrank(manager);
        usdc.approve(address(vault), type(uint256).max);
        vm.expectRevert(E.RequestPending.selector);
        vault.requestDeposit(1_000e6, alice); // insider sender: next epoch, same controller
        vm.stopPrank();
    }

    /// Math#68 / #85 / #95 (GainsVaultMath.spendAllowance): a spender's redeem request spends exactly the shares from a
    /// finite allowance (not to 0, not wrapping to amount - current), and leaves an infinite allowance untouched.
    function test_MUT_Math68_85_95_redeemSpendsAllowanceExactly() public {
        _deposit(alice, 1_000e6);
        _settle();
        _claim(alice);
        uint256 bal = vault.balanceOf(alice);
        vm.prank(alice);
        vault.approve(bob, bal / 2);
        vm.prank(bob);
        vault.requestRedeem(bal / 5, bob, alice);
        assertEq(vault.allowance(alice, bob), bal / 2 - bal / 5, "finite allowance spent exactly");
        vm.prank(alice);
        vault.approve(stranger, type(uint256).max);
        vm.prank(stranger);
        vault.requestRedeem(bal / 5, stranger, alice);
        assertEq(vault.allowance(alice, stranger), type(uint256).max, "infinite allowance untouched");
    }

    // ------------------------------------------------------------------ GainsNav valueHigh (GR1-02)

    /// Nav#38 / #39 / #40 (a resting limit order's collateral left out of valueHigh): deposits must mint at the
    /// favourable edge INCLUDING the resting orders, i.e. strictly fewer shares than at the adverse-edge NAV whenever
    /// a trade is open. Without the limit collateral in valueHigh, idle + valueHigh < NAV and deposits mint at the
    /// adverse edge, diluting the holders by about 2 x band x the open notional.
    function test_MUT_Nav38_restingOrderCountsInValueHigh() public {
        _deposit(alice, 100_000e6);
        _settle();
        _claim(alice);
        _open(vault, ETH, true, 30_000e6, 3_000); // 90k notional, band 20 bps: edges differ by ~360 USDC
        OpenParams memory lim = _params(ETH, true, 20_000e6, 2_000);
        lim.tradeType = 1; // LIMIT, rests on the diamond with its collateral
        lim.expectedPrice = _px(ETH) * 9 / 10;
        vm.prank(manager);
        vault.openTrade(lim);

        _deposit(bob, 10_000e6);
        _ageEpoch(vault);
        vault.checkRisk();
        uint256 navAdverse = vault.totalAssets();
        vm.prank(manager);
        vault.settle();
        (, uint256 depShares,,,,,,) = vault.epochs(vault.currentEpoch() - 1);
        uint256 supplyAtMint = vault.totalSupply() - depShares;
        uint256 atAdverse = Math.mulDiv(10_000e6, supplyAtMint + 1e6, navAdverse + 1);
        // favourable edge: ~0.36% fewer shares than at the adverse NAV (mutant: equal)
        assertLt(depShares * 1_000, atAdverse * 999, "deposit minted at the favourable edge incl. resting orders");
    }
}
