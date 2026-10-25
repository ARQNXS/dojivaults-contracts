// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {R1Base} from "../gains/R1Base.t.sol";
import {GainsVault} from "../../../src/gains/GainsVault.sol";
import {GainsVaultPolicy} from "../../../src/gains/GainsVaultPolicy.sol";
import {InitParams} from "../../../src/gains/GainsTypes.sol";

/// @notice WP4 (WP2 open item O8): once the epoch is overdue, GainsVaultLens previews the exit-only settle a redeemer
///         can force, which charges no performance fee (GR2 XF-01). Before the deadline the preview still equals what
///         a settle mints. Management fee 0, so every fee share is a performance fee share.
contract WP4_GainsLensFee is R1Base {
    function _cfg() internal pure returns (GainsVaultPolicy.RiskConfig memory) {
        return GainsVaultPolicy.RiskConfig({
            maxLeverageBps: 50_000,
            maxDailyLossBps: 1_500,
            maxDrawdownBps: 5_000,
            maxSlippageBps: 100,
            maxOrderNotional: 10_000_000e6,
            maxEpochDuration: 1 days,
            maxNavMoveBps: 2_000,
            maxFlattenSlippageBps: 300
        });
    }

    /// @dev alice 100k at 1.00, 3x ETH long, ETH +5 % three hours into the epoch: a gain above the high water mark.
    function _gain() internal returns (GainsVault v) {
        uint32[] memory assets = new uint32[](2);
        assets[0] = BTC;
        assets[1] = ETH;
        v = GainsVault(Clones.clone(address(vaultImpl)));
        GainsVaultPolicy p = GainsVaultPolicy(Clones.clone(address(policyImpl)));
        p.initialize(owner, _cfg(), assets, 2 days, address(platform), address(v));
        InitParams memory ip = _standaloneParams(p);
        ip.managementFeeBps = 0;
        ip.performanceFeeBps = 2_000;
        v.initialize(ip);
        vm.prank(alice);
        usdc.approve(address(v), type(uint256).max);
        _depositTo(v, alice, 100_000e6);
        _settleV(v);
        v.claim(alice);
        _open(v, ETH, true, 30_000e6, 10_000);
        _skip(3 hours);
        _setPrice(ETH, _px(ETH) * 105 / 100);
        assertGt(v.sharePrice(), v.highWaterMark(), "a gain above the high water mark");
    }

    function _toDeadline(GainsVault v) internal {
        _skip(uint256(v.epochDeadline()) - block.timestamp);
        assertGe(block.timestamp, uint256(v.epochDeadline()), "overdue");
    }

    /// Before the deadline: the preview counts the performance fee, and the manager's settle mints exactly it.
    function test_WP4_lensFee_beforeTheDeadlineThePreviewCountsThePerformanceFee() public {
        GainsVault v = _gain();
        (uint256 preview,) = lens.pendingFeeShares(v);
        assertGt(preview, 0, "performance fee previewed");
        uint256 before = v.balanceOf(feeRecipient);
        vm.prank(manager);
        v.settle();
        assertEq(v.balanceOf(feeRecipient) - before, preview, "preview = minted");
    }

    /// Overdue: no performance fee in the preview, and the exit-only settle (a platform role, overdue) mints none.
    function test_WP4_lensFee_overduePreviewMatchesTheExitOnlySettle() public {
        GainsVault v = _gain();
        _redeemFrom(v, alice, v.balanceOf(alice) / 10);
        _toDeadline(v);
        (uint256 preview,) = lens.pendingFeeShares(v);
        assertEq(preview, 0, "no performance fee once overdue");
        assertEq(lens.sharePriceAfterFees(v), lens.previewRedeem(v, 1e12), "after-fee price from the same preview");
        uint256 before = v.balanceOf(feeRecipient);
        uint256 hwm = v.highWaterMark();
        vm.prank(owner);
        v.settle(); // exit-only: the owner is a platform role here, allowed once overdue
        assertEq(v.balanceOf(feeRecipient) - before, preview, "the exit-only settle mints what the lens previewed: nothing");
        assertEq(v.highWaterMark(), hwm, "high water mark unchanged");
    }

    /// Documented limit: overdue, the manager's own settle is still a normal settle and charges the performance fee.
    ///  The preview shows the redeemer's forced exit, not that settle.
    function test_WP4_lensFee_overdueManagerSettleStillCharges() public {
        GainsVault v = _gain();
        _toDeadline(v);
        (uint256 preview,) = lens.pendingFeeShares(v);
        assertEq(preview, 0);
        uint256 before = v.balanceOf(feeRecipient);
        vm.prank(manager);
        v.settle();
        assertGt(v.balanceOf(feeRecipient) - before, 0, "the manager's settle charges the fee");
    }
}
