// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {R1Base} from "../../R1Base.t.sol";
import {GainsVault} from "../../../../../src/gains/GainsVault.sol";
import {GainsVaultPolicy} from "../../../../../src/gains/GainsVaultPolicy.sol";
import {InitParams} from "../../../../../src/gains/GainsTypes.sol";
import {BreachReason} from "../../../../../src/VaultTypes.sol";

/// @notice GR2-ECON-03 fix test (contracts/audit/gains/r2/fixes/GR2-ECON-03). Asserts the FIXED behaviour, so it fails
///         on 4ec6feb and passes with fix.diff. Run it from contracts/test/audit/gains/r2/fixes/ (imports are relative
///         to that folder). Mock diamond, live-like policy (5x, 15 % daily loss, 50 % drawdown, 1 day epochs, 20 % NAV
///         move), management fee 0 so every fee share is a performance fee share.
///         Fixed rule: the performance fee is charged in every settle except a loss-breach (redemption-only) or an
///         emergency settle; the scheduled raise switches under the same condition; the lens previews the same.
contract ECON03FixTest is R1Base {
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

    function _mk() internal returns (GainsVault v) {
        uint32[] memory assets = new uint32[](2);
        assets[0] = BTC;
        assets[1] = ETH;
        v = GainsVault(Clones.clone(address(vaultImpl)));
        GainsVaultPolicy p = GainsVaultPolicy(Clones.clone(address(policyImpl)));
        p.initialize(owner, _live(), assets, 2 days, address(platform), address(v));
        InitParams memory ip = _standaloneParams(p);
        ip.managementFeeBps = 0;
        ip.performanceFeeBps = 2_000;
        v.initialize(ip);
        vm.prank(alice);
        usdc.approve(address(v), type(uint256).max);
        vm.prank(bob);
        usdc.approve(address(v), type(uint256).max);
    }

    function _settleNoCheck(GainsVault v) internal {
        _ageEpoch(v);
        vm.prank(manager);
        v.settle();
    }

    function _flat(GainsVault v) internal {
        _passHold(); // fix round WP2: the manager's closes wait out the GR2-KEY-01b minimum hold
        uint32 n = diamond.tradeCount(address(v));
        for (uint32 i; i < n; ++i) {
            if (diamond.getTrade(address(v), i).isOpen) _closeFilled(v, i, _px(ETH));
        }
    }

    /// @dev The EconPoC scenario up to the moment before the breach settle: alice 100k bought at 1.00, a 3x ETH long,
    ///      ETH +3 % (an uncharged gain above the high water mark), bob queues 100k, the manager opens to exactly 5x.
    function _scenario() internal returns (GainsVault v) {
        v = _mk();
        _depositTo(v, alice, 100_000e6);
        _settleV(v);
        v.claim(alice);
        _open(v, ETH, true, 30_000e6, 10_000);
        _skip(3 hours);
        _setPrice(ETH, _px(ETH) * 103 / 100);
        _depositTo(v, bob, 100_000e6);
        uint256 nav = v.totalAssets();
        uint256 notional = v.venue().notional;
        _open(v, ETH, true, uint120((nav * 50_000 / 10_000 - notional) / 10), 10_000);
    }

    /// @dev Bob's and the fee recipient's USDC after everything is closed and everyone has left.
    function _finish(GainsVault v, bool breach) internal returns (uint256 bobOut, uint256 feeOut) {
        v.claim(bob);
        _flat(v);
        if (breach) {
            _skip(16 minutes);
            v.clearLeverageBreach();
        }
        uint256 b0 = usdc.balanceOf(bob);
        uint256 f0 = usdc.balanceOf(feeRecipient);
        _skip(1 hours);
        _settleV(v);
        address[3] memory who = [alice, bob, feeRecipient];
        for (uint256 i; i < who.length; ++i) {
            uint256 s = v.balanceOf(who[i]);
            if (s > 0) _redeemFrom(v, who[i], s);
        }
        _skip(2 hours);
        _settleV(v);
        for (uint256 i; i < who.length; ++i) {
            v.claim(who[i]);
        }
        bobOut = usdc.balanceOf(bob) - b0;
        feeOut = usdc.balanceOf(feeRecipient) - f0;
    }

    /// @notice The leverage-breach settle crystallises the performance fee before it mints bob's shares: bob and the
    ///         fee recipient end exactly where a settle without the breach leaves them.
    function test_ECON03_fix_leverageBreachSettleChargesThePerformanceFeeBeforeMinting() public {
        GainsVault v = _scenario();
        uint256 snap = vm.snapshotState();

        v.checkRisk();
        assertTrue(v.breached() && v.breachReason() == BreachReason.LEVERAGE, "leverage breach");
        uint256 feeShares0 = v.balanceOf(feeRecipient);
        _settleNoCheck(v);
        assertGt(v.highWaterMark(), 1e6, "performance fee crystallised in the leverage-breach settle");
        assertGt(v.balanceOf(feeRecipient), feeShares0, "fee shares minted in that settle");
        (uint256 bobA, uint256 feeA) = _finish(v, true);

        vm.revertToState(snap);
        _settleNoCheck(v); // control: the same settle without the breach
        (uint256 bobC, uint256 feeC) = _finish(v, false);

        assertApproxEqAbs(bobA, bobC, 1e6, "bob pays no performance fee on gains made before he entered");
        assertApproxEqAbs(feeA, feeC, 1e6, "the fee recipient collects no extra fee");
    }

    /// @notice A scheduled performance fee raise switches in a leverage-breach settle (the settle charged the running
    ///         epoch at the old rate), exactly as in a normal settle.
    function test_ECON03_fix_leverageBreachSettleSwitchesTheScheduledRaise() public {
        GainsVault v = _scenario();
        vm.prank(owner);
        v.queue(abi.encodeCall(GainsVault.setFees, (0, 3_000)));
        // the timelock (2 days) runs past the 1 day epoch; the raise is scheduled at execution
        _skip(2 days);
        v.execute(abi.encodeCall(GainsVault.setFees, (0, 3_000)));
        assertEq(v.pendingPerformanceFeeBps(), 3_000, "raise scheduled");
        v.checkRisk();
        assertEq(uint8(v.breachReason()), uint8(BreachReason.LEVERAGE), "leverage breach");
        vm.prank(manager);
        v.settle();
        assertEq(v.pendingPerformanceFeeBps(), 0, "the raise switched on");
        assertEq(v.performanceFeeBps(), 3_000);
    }

    /// @notice Lens parity: in a leverage breach the lens previews the performance fee settle() then mints.
    function test_ECON03_fix_lensPreviewsThePerformanceFeeInALeverageBreach() public {
        GainsVault v = _scenario();
        v.checkRisk();
        assertEq(uint8(v.breachReason()), uint8(BreachReason.LEVERAGE));
        (uint256 preview,) = lens.pendingFeeShares(v);
        assertGt(preview, 0, "the lens counts the performance fee");
        uint256 before = v.balanceOf(feeRecipient);
        vm.prank(manager);
        v.settle();
        assertEq(v.balanceOf(feeRecipient) - before, preview, "the lens preview equals the minted fee shares");
    }

    /// @dev alice 100k at 1.00, 3x ETH long, ETH +10 % (NAV 130k, an uncharged gain), a 3,000 bps raise scheduled.
    function _gainAndRaise() internal returns (GainsVault v) {
        v = _mk();
        _depositTo(v, alice, 100_000e6);
        _settleV(v);
        v.claim(alice);
        _open(v, ETH, true, 30_000e6, 10_000);
        _setPrice(ETH, _px(ETH) * 110 / 100);
        vm.prank(owner);
        v.queue(abi.encodeCall(GainsVault.setFees, (0, 3_000)));
        _skip(2 days);
        v.execute(abi.encodeCall(GainsVault.setFees, (0, 3_000)));
        v.checkRisk(); // a new UTC day: the day starts at the gained price
        assertGt(v.sharePrice(), 1.25e6, "gain above the high water mark");
    }

    /// @notice Regression: a daily-loss breach settle (redemption-only) still charges no performance fee and keeps the
    ///         raise scheduled (audit C-01 / R3-06 unchanged).
    function test_ECON03_fix_lossBreachSettleStillChargesNoPerformanceFee() public {
        GainsVault v = _gainAndRaise();
        _setPrice(ETH, _px(ETH) * 93 / 100); // -7 %: NAV 130k -> ~107k, a 17.8 % daily loss, still above the HWM
        v.checkRisk();
        assertEq(uint8(v.breachReason()), uint8(BreachReason.DAILY_LOSS), "daily loss breach");
        assertGt(v.sharePrice(), 1e6, "still above the high water mark");
        uint256 before = v.balanceOf(feeRecipient);
        vm.prank(manager);
        v.settle();
        assertEq(v.balanceOf(feeRecipient), before, "no performance fee shares");
        assertEq(v.highWaterMark(), 1e6, "high water mark unchanged");
        assertEq(v.pendingPerformanceFeeBps(), 3_000, "raise still scheduled");
        (uint256 preview,) = lens.pendingFeeShares(v);
        assertEq(preview, 0, "lens: no performance fee in a loss breach");
    }

    /// @notice Regression: an emergency (exit-only) settle charges no performance fee and keeps the raise scheduled.
    function test_ECON03_fix_emergencySettleStillChargesNoPerformanceFee() public {
        GainsVault v = _gainAndRaise();
        vm.prank(guardian);
        v.triggerEmergency();
        (uint256 preview,) = lens.pendingFeeShares(v);
        assertEq(preview, 0, "lens: no performance fee in emergency");
        uint256 before = v.balanceOf(feeRecipient);
        vm.prank(guardian);
        v.settle();
        assertEq(v.balanceOf(feeRecipient), before, "no performance fee shares");
        assertEq(v.highWaterMark(), 1e6, "high water mark unchanged");
        assertEq(v.pendingPerformanceFeeBps(), 3_000, "raise still scheduled");
    }
}
