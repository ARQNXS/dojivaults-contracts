// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {GainsVault} from "../../../../../src/gains/GainsVault.sol";
import {MIN_HOLD, MIN_HOLD_L2_BLOCKS} from "../../../../../src/gains/GainsTypes.sol";
import {BreachReason} from "../../../../../src/VaultTypes.sol";
import {CIDiamond} from "../ConservationMocks.sol";
import {CIWorld} from "../ConservationWorld.sol";
import {CIHandler, CIValuer} from "../ConservationHandler.sol";

/// @notice Cross-review of GR2-CI-01 (contracts/audit/gains/r2/XREVIEW-FIXES.md), 4ec6feb (scratchpad XR-FIX/asis), the
///         conservation world (live shape: 5x, daily loss 15 %, drawdown 50 %, maxNavMove 20 %). Tests the CI
///         reviewer's code-read claim: checkRisk raises the lifetime peak (and, on the first check of a UTC day, the
///         day-start price) from the NAV inflated by a non-holding order reported under an unknown type, so a false
///         daily-loss breach fires when the phantom disappears, and the peak stays inflated.
contract XRCi01Test is Test {
    CIWorld internal w;
    CIHandler internal h;
    GainsVault internal vault;
    CIDiamond internal diamond;

    function setUp() public {
        w = new CIWorld();
        h = new CIHandler(w, new CIValuer());
        vault = w.vault();
        diamond = w.diamond();
        vault.checkRisk();
        h.seed(); // 700k in, ETH long 80k x 3 (trade 0), BTC short 100k x 2 (trade 1)
    }

    function _toNextUtcDay() internal {
        uint256 next = (vm.getBlockTimestamp() / 1 days + 1) * 1 days + 60;
        while (vm.getBlockTimestamp() < next) {
            uint256 left = next - vm.getBlockTimestamp();
            h.wait(left > 2 hours ? 2 hours : left);
        }
    }

    /// @notice Two partial closes (hold nothing) reported under unknown type 10 across a UTC midnight: the first
    ///         checkRisk of the day takes the inflated price as the day start and the peak; when Gains reports the real
    ///         type again, the next checkRisk records a DAILY_LOSS breach with no loss at all, and the lifetime peak stays
    ///         ~25 % above the true price (the 50 % drawdown limit now fires at a ~37 % real loss).
    function test_XR_CI01_phantomRaisesDayStartAndPeak_falseDailyLossBreach() public {
        // fix round WP2: the manager's reduces come after the GR2-KEY-01b minimum hold (time and L2 blocks)
        h.wait(MIN_HOLD);
        vm.roll(vm.getBlockNumber() + MIN_HOLD_L2_BLOCKS);
        uint256 trueNav = h.idleNow() + h.venueNow().adv;
        uint256 truePrice = vault.sharePrice();
        uint256 peak0 = vault.peakSharePrice();
        vm.startPrank(w.MANAGER());
        vault.reduceTrade(0, 79_000e6, 0, h.ethPx());
        vault.reduceTrade(1, 99_000e6, 0, h.btcPx());
        vm.stopPrank();
        uint32 o2 = diamond.orderCount(address(vault)) - 1;
        uint32 o1 = o2 - 1;
        diamond.retype(address(vault), o1, 10);
        diamond.retype(address(vault), o2, 10);
        uint256 navIn = vault.totalAssets();
        console2.log("true NAV / NAV with the two orders as type 10", trueNav, navIn);
        assertGt(navIn, trueNav * 125 / 100, "phantom > 25 % of NAV");

        _toNextUtcDay(); // Gains has not resolved the orders (settle is held: OrdersPending)
        vm.prank(address(0xBEEF));
        vault.checkRisk(); // first check of the day (anyone; live: the keeper every 5 min)
        uint256 dayStart = vault.dayStartSharePrice();
        uint256 peak = vault.peakSharePrice();
        console2.log("share price true / day start / peak before / peak now", truePrice, dayStart, peak0);
        console2.log("peak now", peak);
        assertGt(dayStart, truePrice * 124 / 100, "day start taken from the inflated NAV");
        assertGt(peak, peak0 * 124 / 100, "lifetime peak raised from the inflated NAV");
        assertFalse(vault.breached());

        diamond.restoreType(address(vault), o1);
        diamond.restoreType(address(vault), o2);
        assertApproxEqAbs(vault.totalAssets(), trueNav, 1e6, "NAV back to the true value (no loss happened)");
        vm.prank(address(0xBEEF));
        (, uint256 daily, uint256 dd) = vault.checkRisk();
        console2.log("daily loss bps / drawdown bps after the phantom left", daily, dd);
        assertTrue(vault.breached(), "breach");
        assertEq(uint8(vault.breachReason()), uint8(BreachReason.DAILY_LOSS), "false DAILY_LOSS breach");
        assertGt(daily, 1_500);

        // the daily breach clears at the next UTC day; the inflated lifetime peak does not
        _toNextUtcDay();
        vm.prank(address(0xBEEF));
        (,, dd) = vault.checkRisk();
        assertFalse(vault.breached(), "daily breach cleared by the day reset");
        assertEq(vault.peakSharePrice(), peak, "the inflated peak stays (only resume() after a DRAWDOWN breach resets it)");
        console2.log("standing drawdown bps from the phantom peak", dd);
        assertGt(dd, 1_900, "~20 % of the 50 % drawdown budget used by a phantom");
    }
}
