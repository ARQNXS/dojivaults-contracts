// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Vm} from "forge-std/Vm.sol";
import {R1Base} from "../R1Base.t.sol";
import {GainsVaultPolicy} from "../../../../src/gains/GainsVaultPolicy.sol";
import {OpenParams, IGainsVaultErrors as E} from "../../../../src/gains/GainsTypes.sol";
import {MIN_RISK_NAV} from "../../../../src/VaultTypes.sol";

/// @notice Round 2 mutation kills, second set (see MutationKills.t.sol for the convention).
contract MutationKills2Test is R1Base {
    // ------------------------------------------------------------------ policy boundaries (direct calls)

    function _order(uint256 notional, uint256 collateral, uint256 minCollateral) internal pure returns (GainsVaultPolicy.Order memory o) {
        o.pair = 1; // ETH, allowed
        o.long = true;
        o.market = false;
        o.expectedPrice = 3_000e10;
        o.collateral = collateral;
        o.notional = notional;
        o.minCollateral = minCollateral;
        o.nav = 1_000_000e6;
        o.openNotional = 0;
    }

    /// Policy#R357 (`notional > max` -> `>=`) and #R361 (`collateral < min` -> `<=`): both limits are inclusive.
    function test_MUT_PolicyR357_R361_limitsInclusive() public view {
        (bool ok,) = policy.checkOrder(_order(1_000_000e6, 1e6, 0)); // exactly maxOrderNotional
        assertTrue(ok, "notional == max accepted");
        (ok,) = policy.checkOrder(_order(1_000e6, 50e6, 50e6)); // exactly the minimum collateral
        assertTrue(ok, "collateral == min accepted");
        (ok,) = policy.checkOrder(_order(1_000_000e6 + 1, 1e6, 0));
        assertFalse(ok);
    }

    /// Policy#R344 (`o.pair > type(uint16).max` -> `>=`): pair 65535 is a valid Gains pair index.
    function test_MUT_PolicyR344_lastPairIndexValid() public {
        uint16 last = type(uint16).max;
        vm.prank(platformOwner);
        platform.setAssetCurated(last, true, address(ethFeed), BTC_MAX_AGE, 20);
        vm.prank(owner);
        policy.queueAllowAsset(last);
        vm.warp(policy.assetAllowEta(last)); // GR2-CFG-01: the stored eta, not queue + timelock
        policy.allowAsset(last);
        GainsVaultPolicy.Order memory o = _order(1_000e6, 1e6, 0);
        o.pair = last;
        (bool ok, string memory reason) = policy.checkOrder(o);
        assertTrue(ok, reason);
    }

    /// Policy#R375 (`prev < MIN_RISK_NAV` -> `<=`): a checkpoint of exactly MIN_RISK_NAV is a real bound;
    /// Policy#R377 (`now > at + 1 day` -> `>=`): a checkpoint exactly one day old is still fresh.
    function test_MUT_PolicyR375_R377_checkpointBoundaries() public {
        uint256 at = vm.getBlockTimestamp();
        vm.expectRevert(abi.encodeWithSelector(GainsVaultPolicy.NavMoved.selector, MIN_RISK_NAV * 2, MIN_RISK_NAV));
        policy.nextCheckpoint(MIN_RISK_NAV, at, MIN_RISK_NAV * 2, true);
        (uint256 next, bool upd) = policy.nextCheckpoint(100e6, at - 1 days, 100e6, true);
        assertTrue(upd && next == 100e6, "exactly CHECKPOINT_MAX_AGE old: fresh");
    }

    /// Policy#R421-R453 (`||` -> `&&` inside _validate) and #R422 (`> 500_000` -> `>=`): each limit is checked on
    /// its own, and 50x is the inclusive ceiling.
    function test_MUT_PolicyValidate_eachFieldOnItsOwn() public {
        for (uint256 k; k < 15; ++k) {
            GainsVaultPolicy.RiskConfig memory c = _defaultRisk(); // fresh copy (memory structs alias)
            if (k == 0) c.maxLeverageBps = 0;
            if (k == 1) c.maxLeverageBps = 500_001;
            if (k == 2) c.maxDailyLossBps = 0;
            if (k == 3) c.maxDailyLossBps = 10_001;
            if (k == 4) c.maxDrawdownBps = 0;
            if (k == 5) c.maxDrawdownBps = 10_001;
            if (k == 6) c.maxSlippageBps = 0;
            if (k == 7) c.maxSlippageBps = 2_001;
            if (k == 8) c.maxOrderNotional = 0;
            if (k == 9) c.maxEpochDuration = 1 hours - 1;
            if (k == 10) c.maxEpochDuration = 30 days + 1;
            if (k == 11) c.maxNavMoveBps = 499;
            if (k == 12) c.maxNavMoveBps = 10_001;
            if (k == 13) c.maxFlattenSlippageBps = 0;
            if (k == 14) c.maxFlattenSlippageBps = 301;
            vm.prank(owner);
            vm.expectRevert(GainsVaultPolicy.InvalidConfig.selector);
            policy.proposeConfig(c);
        }
        // the inclusive ceiling validates (it fails later only on the NAV bound)
        GainsVaultPolicy.RiskConfig memory top = _defaultRisk();
        top.maxLeverageBps = 500_000;
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(GainsVaultPolicy.LeverageAboveNavBound.selector, uint32(0)));
        policy.proposeConfig(top);
    }

    // ------------------------------------------------------------------ settle pricing

    function _halfOnVenue() internal returns (uint32 idx) {
        _deposit(alice, 100_000e6);
        _settle();
        _claim(alice);
        idx = _open(vault, ETH, true, 50_000e6, 1_000);
        _setVenueValue(vault, idx, 50_000e6);
        _skip(1 hours);
        vault.checkRisk(); // checkpoint 100k
    }

    /// Logic#860 (exit-only `priceNav = min(nav, checkpoint)` -> always the checkpoint): after a loss below the
    /// checkpoint an exit is paid at the lower NAV, not at the stale higher checkpoint.
    function test_MUT_Logic860_exitPaysAtNavWhenBelowCheckpoint() public {
        uint32 idx = _halfOnVenue();
        _setVenueValue(vault, idx, 40_000e6); // NAV 90k < checkpoint 100k
        _redeem(alice, vault.balanceOf(alice) / 10);
        vm.prank(guardian);
        vault.triggerEmergency();
        vm.prank(guardian);
        vault.settle();
        (,,, uint256 paid,,,,) = vault.epochs(vault.currentEpoch() - 1);
        assertApproxEqRel(paid, 9_000e6, 1e15, "10% of the 90k NAV");
    }

    /// Logic#883 (exit-only `priceNav = checkpoint` -> 0 when the checkpoint is lower): after a gain above the
    /// checkpoint an exit is paid at the checkpoint (never at the unbounded NAV, never at 0).
    function test_MUT_Logic883_exitPaysAtCheckpointWhenBelowNav() public {
        _halfOnVenue();
        usdc.mint(address(vault), 10_000e6); // NAV 110k > checkpoint 100k
        _redeem(alice, vault.balanceOf(alice) / 10);
        vm.prank(guardian);
        vault.triggerEmergency();
        vm.prank(guardian);
        vault.settle();
        (,,, uint256 paid,,,,) = vault.epochs(vault.currentEpoch() - 1);
        assertApproxEqRel(paid, 10_000e6, 1e15, "10% of the 100k checkpoint");
    }

    /// Logic#930 (partial fill `burned = mulDiv(...)` -> 0): an emergency partial fill burns the shares it paid for.
    function test_MUT_Logic930_partialFillBurnsWhatItPays() public {
        _halfOnVenue();
        uint256 sh = vault.balanceOf(alice) * 3 / 4; // ~75k owed, 50k idle
        _redeem(alice, sh);
        vm.prank(guardian);
        vault.triggerEmergency();
        vm.prank(guardian);
        vault.settle();
        (,, uint256 red, uint256 paid, uint256 burned,,,) = vault.epochs(vault.currentEpoch() - 1);
        assertEq(red, sh);
        assertApproxEqAbs(paid, 50_000e6, 1e6, "all idle paid");
        assertApproxEqRel(burned, sh * 2 / 3, 1e15, "two thirds of the queued shares burned");
        assertLt(burned, sh);
    }

    /// Logic#894 / #901 (`if (depShares == 0) depIn = 0` removed): a deposit too small to mint a single share unit
    /// is refunded, not swallowed by the holders. (Reached with a share price above ~1e6 USDC per 1e12 units: a near
    /// empty vault holding a large donation; the dust checkpoint rule lets that settle run.)
    function test_MUT_Logic894_901_unmintableDepositRefunded() public {
        _deposit(alice, 10e6);
        _settle();
        _claim(alice);
        _redeem(alice, vault.balanceOf(alice) - 1); // one share unit stays
        _settle();
        _claim(alice);
        usdc.mint(address(vault), 20_000_000e6); // donation
        uint256 b0 = usdc.balanceOf(bob);
        _deposit(bob, 10e6);
        _settle();
        (, uint256 depShares,,,,,,) = vault.epochs(vault.currentEpoch() - 1);
        assertEq(depShares, 0, "nothing mintable");
        _claim(bob);
        assertEq(usdc.balanceOf(bob), b0, "refunded in full");
        assertEq(vault.balanceOf(bob), 0);
    }

    /// Logic#935 / #945 (`if (burned > 0)` / `if (depShares > 0)` -> true): settle emits no zero-amount share
    /// Transfer (burn of 0 on a deposit-only epoch, mint of 0 on a redemption-only one).
    function test_MUT_Logic935_945_settleEmitsNoZeroTransfer() public {
        _deposit(alice, 1_000e6);
        vm.recordLogs();
        _settle(); // deposit only
        _noZeroTransfer();
        _claim(alice);
        _redeem(alice, vault.balanceOf(alice) / 2);
        vm.recordLogs();
        _settle(); // redemption only
        _noZeroTransfer();
    }

    function _noZeroTransfer() internal {
        bytes32 t = keccak256("Transfer(address,address,uint256)");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == t && logs[i].emitter == address(vault)) {
                assertGt(abi.decode(logs[i].data, (uint256)), 0, "no zero-amount share transfer");
            }
        }
    }

    /// Logic#783 (`pendingPerf != 0 && ...` -> true): without a scheduled raise a settle leaves the performance
    /// fee alone (the mutant would write pendingPerformanceFeeBps = 0 into it).
    function test_MUT_Logic783_settleKeepsThePerformanceFee() public {
        _deposit(alice, 1_000e6);
        _settle();
        assertEq(vault.performanceFeeBps(), 2_000);
    }

    /// Logic#1110 / #1111 (first mint: `peakSharePrice = price` deleted / 0) and #1123 (`price > peak` -> no raise),
    /// #1173 / #1174 (EpochResult.sharePrice not written / 0): settle records the price and raises the peak.
    function test_MUT_Logic1110_1123_1173_settleRecordsPriceAndPeak() public {
        _deposit(alice, 100_000e6);
        _settle();
        (,,,,,, uint256 p1,) = vault.epochs(vault.currentEpoch() - 1);
        assertEq(p1, vault.sharePrice(), "epoch share price recorded");
        assertEq(vault.peakSharePrice(), p1, "first mint starts the peak at the price");
        usdc.mint(address(vault), 5_000e6); // +5% gain, no checkRisk in between
        _deposit(bob, 1_000e6);
        _ageEpoch(vault);
        vm.prank(manager);
        vault.settle();
        (,,,,,, uint256 p2,) = vault.epochs(vault.currentEpoch() - 1);
        assertGt(p2, p1);
        assertEq(vault.peakSharePrice(), p2, "settle raises the peak");
    }

    /// Logic#1459 (`if (update) _setCheckpoint` -> always): a checkRisk inside CHECKPOINT_INTERVAL keeps the
    /// checkpoint AND its timestamp (refreshing the timestamp would let hourly calls freeze the ratchet forever).
    function test_MUT_Logic1459_checkpointNotRefreshedInsideInterval() public {
        _deposit(alice, 100_000e6);
        _settle();
        _skip(2 hours);
        vault.checkRisk();
        uint64 at = vault.checkpointAt();
        _skip(30 minutes);
        vault.checkRisk();
        assertEq(vault.checkpointAt(), at, "inside the interval: unchanged");
    }

    /// Logic#1546 (openTrade zero checks -> false) and #1578 (`tradeType > STOP` -> false).
    function test_MUT_Logic1546_1578_openTradeInputChecks() public {
        _deposit(alice, 100_000e6);
        _settle();
        OpenParams memory p = _params(ETH, true, 0, 2_000);
        vm.prank(manager);
        vm.expectRevert(E.ZeroAmount.selector);
        vault.openTrade(p);
        p = _params(ETH, true, 1_000e6, 0);
        vm.prank(manager);
        vm.expectRevert(E.ZeroAmount.selector);
        vault.openTrade(p);
        p = _params(ETH, true, 1_000e6, 2_000);
        p.expectedPrice = 0;
        vm.prank(manager);
        vm.expectRevert(E.ZeroAmount.selector);
        vault.openTrade(p);
        p = _params(ETH, true, 1_000e6, 2_000);
        p.tradeType = 3;
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(E.OrderRejected.selector, "trade type"));
        vault.openTrade(p);
    }
}
