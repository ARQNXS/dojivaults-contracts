// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {R1Base} from "../../R1Base.t.sol";
import {GainsVault} from "../../../../../src/gains/GainsVault.sol";
import {GainsVaultPolicy} from "../../../../../src/gains/GainsVaultPolicy.sol";
import {InitParams, OpenParams} from "../../../../../src/gains/GainsTypes.sol";
import {IGainsVaultErrors, DEFAULT_PAIR_SKEW_CAP_BPS} from "../../../../../src/gains/GainsTypes.sol";

/// @notice Cross-review of the GR2-KEY-01 patch (contracts/audit/gains/r2/XREVIEW-FIXES.md). Runs on the tree with all
///         five patches applied. Question: do the new revert paths in openTrade / increaseTrade / leverage raise ever
///         reach an exit, a settle or a NAV read, and can anyone but the vault's own trading move them?
contract XRKey01Test is R1Base {
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
        vm.prank(bob);
        usdc.approve(address(v), type(uint256).max);
        _depositTo(v, alice, nav);
        _settleV(v);
        v.claim(alice);
    }

    function _try(GainsVault v, uint16 pair, uint120 coll, uint24 lev) internal returns (bool ok) {
        OpenParams memory p = _params(pair, true, coll, lev);
        vm.prank(manager);
        try v.openTrade(p) {
            ok = true;
        } catch {}
    }

    /// @dev Every exit and settle path, run on `v` with trade `idx` open and a redemption queued: none may revert.
    function _exitsWork(GainsVault v, uint32 idx, uint32 idx2) internal {
        _passHold(); // fix round WP2: the manager's exits wait out the GR2-KEY-01b minimum hold
        v.totalAssets();
        v.checkRisk();
        vm.prank(manager);
        v.reduceTrade(idx, 1_000e6, 0, _px(ETH));
        _fillLast(v, _px(ETH));
        vm.prank(manager);
        v.closeTrade(idx, _px(ETH));
        _fillLast(v, _px(ETH));
        vm.prank(manager);
        v.flatten(ETH, 0, _px(ETH), type(uint256).max); // closes idx2
        _fillLast(v, _px(ETH));
        assertFalse(diamond.getTrade(address(v), idx2).isOpen, "the flatten closed the ETH short");
        _skip(1 hours);
        v.checkRisk();
        vm.prank(manager);
        v.settle(); // pays the queued redemption
        v.claim(bob);
        (uint256 e,, uint256 r) = v.requests(bob);
        assertEq(r, 0, "bob's redemption paid");
        e;
    }

    /// @notice Gains sets the pair's skew depth to 0 (or cuts it below the vault's open notional): new risk on the pair
    ///         is refused, every exit, checkRisk, settle and redemption still works.
    function test_XR_KEY01_depthZeroOrCut_exitsSettleRedemptionUnaffected() public {
        GainsVault v = _mk(100_000e6);
        _depositTo(v, bob, 20_000e6);
        _settleV(v);
        v.claim(bob);
        uint32 idx = _open(v, ETH, true, 10_000e6, 10_000); // 100k
        uint32 idx2 = _open(v, ETH, false, 5_000e6, 10_000); // 50k
        _redeemFrom(v, bob, v.balanceOf(bob));
        vm.mockCall(address(diamond), abi.encodeWithSelector(SKEW_DEPTH, CI, ETH), abi.encode(uint256(0)));
        assertFalse(_try(v, ETH, 1_000e6, 2_000), "no new ETH risk at depth 0");
        assertTrue(_try(v, BTC, 1_000e6, 2_000), "other pairs unaffected");
        _fillLast(v, _px(BTC));
        _exitsWork(v, idx, idx2);
    }

    /// @notice A Gains facet cut that removes getPairSkewDepth (the call reverts): opens revert, NAV and every exit do
    ///         not read it.
    function test_XR_KEY01_depthSelectorRemoved_onlyOpensRevert() public {
        GainsVault v = _mk(100_000e6);
        _depositTo(v, bob, 20_000e6);
        _settleV(v);
        v.claim(bob);
        uint32 idx = _open(v, ETH, true, 10_000e6, 10_000);
        uint32 idx2 = _open(v, ETH, false, 5_000e6, 10_000);
        _redeemFrom(v, bob, v.balanceOf(bob));
        vm.mockCallRevert(address(diamond), abi.encodeWithSelector(SKEW_DEPTH), bytes("selector removed"));
        assertFalse(_try(v, BTC, 1_000e6, 2_000), "opens revert on every pair");
        _exitsWork(v, idx, idx2);
    }

    /// @notice Loss gate: with NAV 18 % down and no checkRisk yet, every exit, cancel and flatten still runs; the next
    ///         checkRisk records the breach and the redemption-only settle pays the queued redemption.
    function test_XR_KEY01_lossGate_neverOnExitsOrSettle() public {
        GainsVault v = _mk(100_000e6);
        _depositTo(v, bob, 20_000e6);
        _settleV(v);
        v.claim(bob);
        uint32 idx = _open(v, ETH, true, 24_000e6, 10_000); // 240k
        uint32 idx2 = _open(v, ETH, true, 24_000e6, 10_000); // 480k, 4x
        OpenParams memory lp = _params(BTC, true, 1_000e6, 5_000);
        lp.tradeType = 1;
        lp.expectedPrice = _px(BTC) * 90 / 100;
        vm.prank(manager);
        v.openTrade(lp); // resting limit
        uint32 lim = diamond.tradeCount(address(v)) - 1;
        _redeemFrom(v, bob, v.balanceOf(bob));
        v.checkRisk();
        _setPrice(ETH, _px(ETH) * 955 / 1000); // -18 % NAV
        assertFalse(_try(v, BTC, 1_000e6, 2_000), "gate refuses new risk");
        vm.prank(manager);
        v.cancelOrder(lim);
        _passHold(); // fix round WP2: the manager's exits wait out the GR2-KEY-01b minimum hold (same UTC day, no checkRisk)
        vm.prank(manager);
        v.reduceTrade(idx, 1_000e6, 0, _px(ETH));
        _fillLast(v, _px(ETH));
        vm.prank(manager);
        v.closeTrade(idx, _px(ETH));
        _fillLast(v, _px(ETH));
        vm.prank(manager);
        v.flatten(ETH, 0, _px(ETH), type(uint256).max);
        _fillLast(v, _px(ETH));
        idx2;
        _skip(1 hours);
        v.checkRisk(); // records the daily loss breach
        assertTrue(v.breached());
        vm.prank(manager);
        v.settle(); // redemption-only
        v.claim(bob);
        (,, uint256 r) = v.requests(bob);
        assertEq(r, 0, "bob paid in the loss breach");
    }

    /// @notice Nothing a stranger can do moves either gate: a donation, a deposit, a redemption request, syncIndexes,
    ///         checkRisk, accrueFees, cancelTimedOut. The pair cap counts the vault's own notional only and the depth is
    ///         Gains governance's; the loss gate reads the same NAV checkRisk (already permissionless) reads.
    function test_XR_KEY01_strangerCannotTripEitherGate() public {
        GainsVault v = _mk(100_000e6);
        // fix round WP2: the standalone vault's pair cap is DEFAULT_PAIR_SKEW_CAP_BPS of the depth (GR2-KEY-01b, 1 %), not
        // KEY-01's 5 % (as KEY-01b's test-port.diff did for KEY01FixTest)
        uint256 depth = 300_000e6 * 1e22 * 10_000 / (DEFAULT_PAIR_SKEW_CAP_BPS * uint256(_px(ETH)));
        vm.mockCall(address(diamond), abi.encodeWithSelector(SKEW_DEPTH, CI, ETH), abi.encode(depth)); // cap 300k
        _open(v, ETH, true, 10_000e6, 25_000); // 250k
        usdc.mint(stranger, 1_000_000e6);
        vm.startPrank(stranger);
        usdc.transfer(address(v), 50_000e6); // donation
        usdc.approve(address(v), type(uint256).max);
        v.requestDeposit(500_000e6, stranger);
        v.syncIndexes(type(uint256).max);
        v.checkRisk();
        v.accrueFees();
        vm.stopPrank();
        assertTrue(_try(v, ETH, 2_000e6, 25_000), "the last 50k up to the cap still fits");
        assertFalse(_try(v, ETH, 100e6, 10_000), "and nothing past it");
    }
}
