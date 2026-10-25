// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {R1Base} from "../../R1Base.t.sol";
import {GainsVault} from "../../../../../src/gains/GainsVault.sol";
import {GainsVaultPolicy} from "../../../../../src/gains/GainsVaultPolicy.sol";
import {InitParams, OpenParams, IGainsVaultErrors, MIN_HOLD, MIN_HOLD_L2_BLOCKS} from "../../../../../src/gains/GainsTypes.sol";

/// @notice Fix round WP2: the changes made on top of the gains-r2 patch stack.
///         - GR2 XF-03: closes and flattens sync the index set, so unseen pending-order indexes never pile up;
///         - GR2 XF-04: Gains' pair open-interest cap bounds the pair cap (from the HL review's GAINS-OPENTRADE);
///         - the KEY-01 loss gate on the two paths its fix test does not reach: a leverage raise and the drawdown limit
///           (the comparison with GAINS-OPENTRADE's tests).
///         XF-01, XF-02 and FF-02 are asserted where their PoCs were (XRKey06Econ03, KnownExploits KX-03).
contract WP2FixTest is R1Base {
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

    function _mk(GainsVaultPolicy.RiskConfig memory risk, uint256 nav) internal returns (GainsVault v) {
        uint32[] memory assets = new uint32[](2);
        assets[0] = BTC;
        assets[1] = ETH;
        v = GainsVault(Clones.clone(address(vaultImpl)));
        GainsVaultPolicy p = GainsVaultPolicy(Clones.clone(address(policyImpl)));
        p.initialize(owner, risk, assets, 2 days, address(platform), address(v));
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

    function _waitHold() internal {
        _skip(MIN_HOLD);
        vm.roll(vm.getBlockNumber() + MIN_HOLD_L2_BLOCKS);
    }

    function _unseenOrders(GainsVault v) internal view returns (uint256) {
        (, uint32 orderCursor,,) = v.indexSet();
        return diamond.orderCount(address(v)) - orderCursor;
    }

    // ------------------------------------------------------------------ XF-03
    /// @notice Ten close requests in a row, nothing else: before the fix each one left its pending-order index unseen
    ///         (10 unseen, ~26k gas each in every NAV read until a sync); now each close pulls the earlier ones first,
    ///         so at most the last request is unseen.
    function test_WP2_XF03_closesKeepUnseenOrdersBounded() public {
        GainsVault v = _mk(_live(), 100_000e6);
        uint32[] memory idx = new uint32[](10);
        for (uint256 i; i < 10; ++i) {
            idx[i] = _open(v, i % 2 == 0 ? ETH : BTC, true, 1_000e6, 2_000);
        }
        v.syncIndexes(type(uint256).max);
        _waitHold();
        for (uint256 i; i < 10; ++i) {
            vm.prank(manager);
            v.closeTrade(idx[i], _px(i % 2 == 0 ? ETH : BTC));
            assertLe(_unseenOrders(v), 1, "at most the request just made is unseen");
        }
        assertEq(diamond.orderCount(address(v)) - 10, 10, "ten close requests were filed (the ten opens before them)");
    }

    /// @notice The guardian's flattenIndices (the GR1-08 escape) also syncs and still goes through when the diamond's
    ///         counters cannot be read: the sync pulls nothing and never reverts.
    function test_WP2_XF03_flattenIndicesSyncsAndNeverRevertsOnIt() public {
        GainsVault v = _mk(_live(), 100_000e6);
        uint32 a = _open(v, ETH, true, 1_000e6, 2_000);
        uint32 b = _open(v, ETH, true, 1_000e6, 2_000);
        vm.prank(guardian);
        v.closeTrade(a, _px(ETH));
        vm.mockCallRevert(address(diamond), abi.encodeWithSignature("getCounters(address,uint8)"), "layout changed");
        uint32[] memory list = new uint32[](1);
        list[0] = b;
        vm.prank(guardian);
        assertEq(v.flattenIndices(list, 0, _px(ETH)), 1, "closed by index with the counters unreadable");
    }

    // ------------------------------------------------------------------ XF-04
    /// @notice The mock's skew depth makes the depth cap effectively unbounded; Gains' pair OI cap of 300k then binds:
    ///         250k fits, 100k more is refused "pair depth". An OI cap of 0 means none.
    function test_WP2_XF04_pairOpenInterestCapBoundsThePairCap() public {
        GainsVault v = _mk(_live(), 1_000_000e6);
        diamond.setPairMaxOi(ETH, 300_000e6);
        _open(v, ETH, true, 10_000e6, 25_000); // 250k
        OpenParams memory p = _params(ETH, true, 4_000e6, 25_000);
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(IGainsVaultErrors.OrderRejected.selector, "pair depth"));
        v.openTrade(p); // 350k > 300k
        diamond.setPairMaxOi(ETH, 0);
        vm.prank(manager);
        v.openTrade(p);
    }

    // ------------------------------------------------------------------ loss gate, paths not covered by KEY01FixTest
    /// @notice A leverage raise adds exposure, so the daily-loss gate refuses it before any checkRisk; lowering the
    ///         leverage (de-risking) stays open.
    function test_WP2_lossGate_leverageRaiseRefusedOverTheDailyLoss() public {
        GainsVault v = _mk(_live(), 100_000e6);
        uint32 idx = _open(v, ETH, true, 20_000e6, 10_000); // 200k
        _open(v, ETH, true, 20_000e6, 10_000); // 400k, 4x
        v.checkRisk(); // the day starts here
        _setPrice(ETH, _px(ETH) * 955 / 1000); // -4.5 % x 4 = -18 % NAV: over the 15 % daily loss
        assertFalse(v.breached(), "no checkRisk has run");
        vm.prank(manager);
        vm.expectRevert(IGainsVaultErrors.ReduceOnlyMode.selector);
        v.updateLeverage(idx, 11_000);
        vm.prank(manager);
        v.updateLeverage(idx, 9_000);
    }

    /// @notice The drawdown branch: a 12 % fall from the peak share price with a 10 % drawdown limit (inside the 15 %
    ///         daily loss) refuses new risk at once; exits stay open after the hold.
    function test_WP2_lossGate_drawdownOverTheLimitRefusesNewRisk() public {
        GainsVaultPolicy.RiskConfig memory r = _live();
        r.maxDrawdownBps = 1_000;
        GainsVault v = _mk(r, 100_000e6);
        uint32 idx = _open(v, ETH, true, 20_000e6, 10_000);
        _open(v, ETH, true, 20_000e6, 10_000); // 400k, 4x
        v.checkRisk(); // peak and day start here
        _setPrice(ETH, _px(ETH) * 970 / 1000); // -3 % x 4 = -12 % NAV
        OpenParams memory p = _params(BTC, true, 1_000e6, 10_000);
        vm.prank(manager);
        vm.expectRevert(IGainsVaultErrors.ReduceOnlyMode.selector);
        v.openTrade(p);
        _waitHold();
        vm.prank(manager);
        v.closeTrade(idx, _px(ETH));
    }
}
