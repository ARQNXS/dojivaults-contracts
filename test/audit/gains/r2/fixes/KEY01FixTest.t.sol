// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {R1Base} from "../../R1Base.t.sol";
import {GainsVault} from "../../../../../src/gains/GainsVault.sol";
import {GainsVaultPolicy} from "../../../../../src/gains/GainsVaultPolicy.sol";
import {InitParams, OpenParams} from "../../../../../src/gains/GainsTypes.sol";
import {IGainsVaultErrors, DEFAULT_PAIR_SKEW_CAP_BPS} from "../../../../../src/gains/GainsTypes.sol";

/// @notice GR2-KEY-01 fix test, mock diamond (contracts/audit/gains/r2/fixes/GR2-KEY-01). Asserts the FIXED behaviour,
///         so it fails on 4ec6feb and passes with fix.diff. Run it from contracts/test/audit/gains/r2/fixes/.
///         The diamond's getPairSkewDepth is set with vm.mockCall so the test compiles and runs on both trees (the
///         unfixed vault never calls it). Fixed rules: (1) per pair, open + resting + pending + new notional <= 5 % of
///         the pair's 1 % skew depth (USD at Chainlink); (2) the daily loss / drawdown limits refuse new risk at the
///         order's own NAV read, before any checkRisk.
contract KEY01FixTest is R1Base {
    bytes4 internal constant SKEW_DEPTH = bytes4(keccak256("getPairSkewDepth(uint8,uint16)"));
    uint8 internal constant CI = 3;

    function _live() internal pure returns (GainsVaultPolicy.RiskConfig memory) {
        return GainsVaultPolicy.RiskConfig({
            maxLeverageBps: 50_000,
            maxDailyLossBps: 1_500,
            maxDrawdownBps: 5_000,
            maxSlippageBps: 100,
            maxOrderNotional: 250_000e6,
            maxEpochDuration: 1 days,
            maxNavMoveBps: 2_000,
            maxFlattenSlippageBps: 300
        });
    }

    function _mk(uint256 nav) internal returns (GainsVault v) {
        uint32[] memory assets = new uint32[](2);
        assets[0] = BTC;
        assets[1] = ETH;
        v = GainsVault(Clones.clone(address(vaultImpl)));
        GainsVaultPolicy p = GainsVaultPolicy(Clones.clone(address(policyImpl)));
        p.initialize(owner, _live(), assets, 2 days, address(platform), address(v));
        InitParams memory ip = _standaloneParams(p);
        ip.managementFeeBps = 0;
        ip.performanceFeeBps = 0;
        ip.timelockDelay = 2 days;
        v.initialize(ip);
        vm.prank(alice);
        usdc.approve(address(v), type(uint256).max);
        _depositTo(v, alice, nav);
        _settleV(v);
        v.claim(alice);
    }

    /// @dev ETH's 1 % skew depth such that 5 % of it is `capUsd` (1e6) at the current Chainlink price.
    function _setEthDepthForCap(uint256 capUsd) internal {
        uint256 depth = capUsd * 1e22 * 10_000 / (DEFAULT_PAIR_SKEW_CAP_BPS * uint256(_px(ETH)));
        vm.mockCall(address(diamond), abi.encodeWithSelector(SKEW_DEPTH, CI, ETH), abi.encode(depth));
    }

    function _try(GainsVault v, uint16 pair, uint120 coll, uint24 lev) internal returns (bool ok) {
        OpenParams memory p = _params(pair, true, coll, lev);
        vm.prank(manager);
        try v.openTrade(p) {
            ok = true;
        } catch {}
    }

    /// @notice XR_08's shape on the mock: 250k orders on one pair. With the cap at 600k of ETH notional the third order
    ///         (750k) is refused, filled or pending alike; another pair is not affected; a fill leaves the bound.
    function test_KEY01_fix_perPairNotionalCappedAtFivePercentOfSkewDepth() public {
        GainsVault v = _mk(1_000_000e6);
        _setEthDepthForCap(600_000e6);
        _open(v, ETH, true, 10_000e6, 25_000); // 250k, filled
        _request(v, ETH, false, 10_000e6, 25_000); // 250k, pending (a short counts the same: gross notional)
        OpenParams memory p = _params(ETH, true, 10_000e6, 25_000);
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(IGainsVaultErrors.OrderRejected.selector, "pair depth"));
        v.openTrade(p); // 750k > 600k
        assertTrue(_try(v, ETH, 4_000e6, 25_000), "100k more fits (600k)");
        assertFalse(_try(v, ETH, 1_000e6, 10_000), "the next 10k does not");
        assertTrue(_try(v, BTC, 10_000e6, 25_000), "BTC (deep) unaffected");
    }

    /// @notice increaseTrade counts against the same per-pair cap.
    function test_KEY01_fix_increaseCountsAgainstThePairCap() public {
        GainsVault v = _mk(1_000_000e6);
        _setEthDepthForCap(300_000e6);
        uint32 idx = _open(v, ETH, true, 10_000e6, 25_000); // 250k
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(IGainsVaultErrors.OrderRejected.selector, "pair depth"));
        v.increaseTrade(idx, 4_000e6, 25_000, _px(ETH), SLIP); // +100k -> 350k
        vm.prank(manager);
        v.increaseTrade(idx, 2_000e6, 25_000, _px(ETH), SLIP); // +50k -> 300k
    }

    /// @notice A pair Gains reports no skew depth for takes no new risk (fail closed).
    function test_KEY01_fix_noSkewDepthRefused() public {
        GainsVault v = _mk(100_000e6);
        vm.mockCall(address(diamond), abi.encodeWithSelector(SKEW_DEPTH, CI, ETH), abi.encode(uint256(0)));
        OpenParams memory p = _params(ETH, true, 1_000e6, 10_000);
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(IGainsVaultErrors.OrderRejected.selector, "no skew depth"));
        v.openTrade(p);
    }

    /// @notice A daily loss over the limit refuses new risk at once, before any checkRisk records the breach (the churn
    ///         route of KEY-01 stops at the limit instead of the next keeper run).
    function test_KEY01_fix_dailyLossOverLimitRefusesNewRiskBeforeCheckRisk() public {
        GainsVault v = _mk(100_000e6);
        uint32 idx = _open(v, ETH, true, 20_000e6, 10_000); // 200k
        _open(v, ETH, true, 20_000e6, 10_000); // 400k, 4x
        v.checkRisk(); // the day starts here
        _setPrice(ETH, _px(ETH) * 955 / 1000); // -4.5 % x 4 = -18 % NAV: over the 15 % daily loss
        assertFalse(v.breached(), "no checkRisk has run");
        OpenParams memory p = _params(BTC, true, 1_000e6, 10_000);
        vm.prank(manager);
        vm.expectRevert(IGainsVaultErrors.ReduceOnlyMode.selector);
        v.openTrade(p);
        vm.prank(manager);
        vm.expectRevert(IGainsVaultErrors.ReduceOnlyMode.selector);
        v.increaseTrade(idx, 1_000e6, 10_000, _px(ETH), SLIP);
        // exits stay open (after the GR2-KEY-01b minimum hold, fix round WP2)
        _passHold();
        vm.prank(manager);
        v.closeTrade(idx, _px(ETH));
    }

    /// @notice Within the daily loss limit new risk is still accepted (the gate measures like checkRisk).
    function test_KEY01_fix_lossWithinLimitStillTrades() public {
        GainsVault v = _mk(100_000e6);
        _open(v, ETH, true, 20_000e6, 10_000);
        _open(v, ETH, true, 20_000e6, 10_000); // 400k, 4x
        v.checkRisk();
        _setPrice(ETH, _px(ETH) * 970 / 1000); // -3 % x 4 = -12 % NAV
        assertTrue(_try(v, BTC, 1_000e6, 10_000), "12 % < 15 %: accepted");
    }
}
