// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {console2} from "forge-std/Test.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {R1Base} from "../../R1Base.t.sol";
import {GainsVault} from "../../../../../src/gains/GainsVault.sol";
import {GainsVaultPolicy} from "../../../../../src/gains/GainsVaultPolicy.sol";
import {InitParams} from "../../../../../src/gains/GainsTypes.sol";
import {BreachReason} from "../../../../../src/VaultTypes.sol";

/// @notice Cross-review of the GR2-KEY-06 and GR2-ECON-03 patches (contracts/audit/gains/r2/XREVIEW-FIXES.md). Fix
///         round WP2 applied the review's changes XF-02 (the prior-checkpoint cap on exit-only settles only) and XF-01
///         (no performance fee in an exit-only settle): the three tests that demonstrated them are inverted (the
///         demonstration runs are in contracts/audit/fix-round/wp2-logs).
contract XRKey06Econ03Test is R1Base {
    address internal redeemer = makeAddr("xr.redeemer");
    address internal stayer = makeAddr("xr.stayer");

    function _live() internal pure returns (GainsVaultPolicy.RiskConfig memory) {
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

    function _mk(uint16 perf) internal returns (GainsVault v, GainsVaultPolicy p) {
        // 01:00 UTC: the scenarios below stay inside one UTC day where a daily loss matters (START is 22:13 UTC)
        _warp((vm.getBlockTimestamp() / 1 days + 1) * 1 days + 1 hours);
        uint32[] memory assets = new uint32[](2);
        assets[0] = BTC;
        assets[1] = ETH;
        v = GainsVault(Clones.clone(address(vaultImpl)));
        p = GainsVaultPolicy(Clones.clone(address(policyImpl)));
        p.initialize(owner, _live(), assets, 2 days, address(platform), address(v));
        InitParams memory ip = _standaloneParams(p);
        ip.managementFeeBps = 0;
        ip.performanceFeeBps = perf;
        ip.timelockDelay = 2 days;
        v.initialize(ip);
        address[2] memory who = [redeemer, stayer];
        for (uint256 i; i < who.length; ++i) {
            usdc.mint(who[i], 1_000_000e6);
            vm.prank(who[i]);
            usdc.approve(address(v), type(uint256).max);
        }
        _depositTo(v, redeemer, 50_000e6);
        _depositTo(v, stayer, 50_000e6);
        _settleV(v);
        v.claim(redeemer);
        v.claim(stayer);
    }

    function _paidTo(GainsVault v, address who) internal returns (uint256 got) {
        uint256 b = usdc.balanceOf(who);
        v.claim(who);
        got = usdc.balanceOf(who) - b;
    }

    // ==================================================================
    // GR2-KEY-06: the "value its last ratchet replaced" cap and audit C-01
    // ==================================================================
    /// @dev 100k vault, 4x ETH long, the redeemer (an accomplice of whoever can push NAV) queues a full exit; two hours
    ///      later ETH falls 4.5 % (NAV -18 %).
    function _lossSetup() internal returns (GainsVault v, uint64 p0) {
        (v,) = _mk(0);
        _open(v, ETH, true, uint120(v.totalAssets() * 4 / 10), 10_000);
        _redeemFrom(v, redeemer, v.balanceOf(redeemer));
        _skip(2 hours);
        p0 = _px(ETH);
    }

    /// @notice XF-02 fix (inverted from test_XR_KEY06_pumpBackToTheReplacedValuePaidAfterADownwardRatchet). After a
    ///         real loss the keeper's checkRisk ratchets the (stale) checkpoint DOWN to the loss NAV and records the
    ///         daily-loss breach. Inside the next hour a NAV back near the pre-loss level (a pump, or a rebound: the vault
    ///         cannot tell) is NOT paid by the redemption-only settle: its cap stays the post-loss checkpoint (C-01), the
    ///         prior value counts only in exit-only settles. Before XF-02 the redeemer got > 7k more here.
    function test_XR_KEY06_XF02_fix_redemptionOnlyAfterADownwardRatchetPaysAtTheLossCheckpoint() public {
        (GainsVault v, uint64 p0) = _lossSetup();
        uint256 nav0 = v.totalAssets();
        _setPrice(ETH, p0 * 955 / 1000);
        vm.prank(stranger);
        v.checkRisk(); // anyone (the keeper): ratchet down + breach
        assertEq(uint8(v.breachReason()), uint8(BreachReason.DAILY_LOSS), "daily loss breach");
        uint256 cpLoss = v.checkpointNav();
        assertLt(cpLoss, nav0 * 85 / 100, "checkpoint ratcheted down to the loss NAV");
        _skip(20 minutes);
        _setPrice(ETH, p0 * 995 / 1000); // NAV back to ~98 % of the pre-loss level
        uint256 navPump = v.totalAssets();
        uint256 shares = v.pendingRedeemShares();
        uint256 supply = v.totalSupply();
        uint256 atLossCp = shares * (cpLoss + 1) / (supply + 1e6);
        uint256 atPump = shares * (navPump + 1) / (supply + 1e6);
        vm.prank(manager);
        v.settle(); // redemption-only
        uint256 paid = _paidTo(v, redeemer);
        console2.log("pre-loss NAV / loss checkpoint / NAV at settle", nav0, cpLoss, navPump);
        console2.log("redeemer paid / at the loss checkpoint / at the settle NAV", paid, atLossCp, atPump);
        assertApproxEqAbs(paid, atLossCp, 1e6, "paid at the post-loss checkpoint (C-01)");
        assertLt(paid + 7_000e6, atPump, "> 7k below the NAV pushed back up inside the hour");
    }

    /// @notice Unchanged by the fixes (pre-existing, documented C-01 window). The same pump inside the first interval
    ///         after the loss (the keeper's checkRisk records the breach but cannot move a fresh checkpoint) is paid: the
    ///         C-01 cap is the pre-loss checkpoint. With XF-02, KEY-06 no longer extends this window.
    function test_XR_KEY06_preExisting_pumpPaidInTheFirstIntervalOnBothTrees() public {
        (GainsVault v, uint64 p0) = _lossSetup();
        v.checkRisk(); // fresh checkpoint at the pre-loss NAV
        uint256 cp0 = v.checkpointNav();
        _skip(5 minutes);
        _setPrice(ETH, p0 * 955 / 1000);
        v.checkRisk(); // breach recorded, checkpoint fresh: not moved
        assertEq(uint8(v.breachReason()), uint8(BreachReason.DAILY_LOSS));
        assertEq(v.checkpointNav(), cp0, "checkpoint unchanged inside the interval");
        _skip(20 minutes);
        _setPrice(ETH, p0 * 995 / 1000);
        uint256 shares = v.pendingRedeemShares();
        uint256 atPump = shares * (v.totalAssets() + 1) / (v.totalSupply() + 1e6);
        vm.prank(manager);
        v.settle();
        assertApproxEqAbs(_paidTo(v, redeemer), atPump, 1e6, "paid at the pushed-up NAV on both trees");
    }

    // ==================================================================
    // GR2-ECON-03: performance fee in an exit-only settle prices on the full NAV, redemptions on the cap
    // ==================================================================
    /// @dev 100k vault, 20 % performance fee, 3x ETH long, ETH +3 % (a gain over the HWM). Optionally the owner tightens
    ///      maxLeverage to 2x and checkRisk records a LEVERAGE breach. The redeemer queues a full exit, the epoch runs
    ///      overdue, the keeper checkpoints, and ETH rises another 1 % inside the hour (NAV above the fresh checkpoint).
    function _feeSetup(bool leverageBreach) internal returns (GainsVault v, uint64 pT) {
        GainsVaultPolicy p;
        (v, p) = _mk(2_000);
        _open(v, ETH, true, uint120(v.totalAssets() * 3 / 10), 10_000);
        _skip(2 hours);
        _setPrice(ETH, _px(ETH) * 103 / 100);
        if (leverageBreach) {
            GainsVaultPolicy.RiskConfig memory c = _live();
            c.maxLeverageBps = 20_000;
            vm.prank(owner);
            p.proposeConfig(c); // tighter: instant
        }
        v.checkRisk();
        if (leverageBreach) assertEq(uint8(v.breachReason()), uint8(BreachReason.LEVERAGE), "leverage breach");
        _redeemFrom(v, redeemer, v.balanceOf(redeemer));
        _skip(1 days); // overdue
        v.checkRisk(); // keeper's checkpoint at the current NAV
        _skip(10 minutes);
        pT = _px(ETH);
    }

    /// @dev Exit-only settle by the guardian (a platform role, the epoch is overdue); returns the redeemer's payout.
    function _exitOnlyPayout(GainsVault v) internal returns (uint256) {
        vm.prank(guardian);
        v.settle();
        return _paidTo(v, redeemer);
    }

    /// @notice XF-01 fix (inverted from test_XR_ECON03_exitOnlyInLeverageBreach_higherNavPaysTheRedeemerLess). An
    ///         overdue exit-only settle in a LEVERAGE breach charges no performance fee, so a higher NAV no longer pays
    ///         the redeemer less (before XF-01 he paid the fee on a gain he was not paid for: > 50 USDC less).
    function test_XR_ECON03_XF01_fix_exitOnlyInLeverageBreach_higherNavNeverPaysTheRedeemerLess() public {
        (GainsVault v, uint64 pT) = _feeSetup(true);
        uint256 snap = vm.snapshotState();
        _setPrice(ETH, pT); // NAV = the checkpoint
        uint256 base = _exitOnlyPayout(v);
        vm.revertToState(snap);
        _setPrice(ETH, pT * 101 / 100); // NAV above the checkpoint
        uint256 higher = _exitOnlyPayout(v);
        console2.log("redeemer payout: NAV at the cap / NAV 1 % ETH higher", base, higher);
        assertGe(higher, base, "a higher NAV never pays the redeemer less");
    }

    /// @notice XF-01 fix (inverted from test_XR_ECON03_preExisting_exitOnlyNoBreach_higherNavPaysTheRedeemerLess): the
    ///         same without a breach; an overdue exit-only settle by a platform role used to charge the performance fee
    ///         on the full NAV.
    function test_XR_ECON03_XF01_fix_exitOnlyNoBreach_higherNavNeverPaysTheRedeemerLess() public {
        (GainsVault v, uint64 pT) = _feeSetup(false);
        uint256 snap = vm.snapshotState();
        _setPrice(ETH, pT);
        uint256 base = _exitOnlyPayout(v);
        vm.revertToState(snap);
        _setPrice(ETH, pT * 101 / 100);
        uint256 higher = _exitOnlyPayout(v);
        console2.log("redeemer payout (no breach): NAV at the cap / NAV 1 % ETH higher", base, higher);
        assertGe(higher, base, "a higher NAV never pays the redeemer less");
    }

    /// @notice EXPECTED: passes on both trees. Two leverage-breach settles in a row with no new gain: the second one
    ///         mints no performance fee (the HWM moved in the first on the patched tree; on 4ec6feb neither charges).
    function test_XR_ECON03_noDoubleChargeAcrossLeverageBreachSettles() public {
        (GainsVault v,) = _feeSetup(true);
        vm.prank(manager);
        v.settle(); // normal settle in a leverage breach (treasury): charges once on the patched tree
        uint256 s1 = v.totalSupply();
        uint256 hwm1 = v.highWaterMark();
        _skip(2 hours);
        v.checkRisk();
        vm.prank(manager);
        v.settle();
        assertEq(v.totalSupply(), s1, "no second fee mint at the same NAV");
        assertEq(v.highWaterMark(), hwm1, "HWM unchanged");
    }
}
