// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import "./NavForkBase.sol";
import {GTrade} from "../../../../src/gains/IGainsDiamond.sol";

/// @notice Round 1 review (3.1): pending-order valuation on the real diamond. Answers the lead's open hypothesis
///         "does the diamond store collateralAmount = delta and leverage = delta / new leverage in pending
///         UPDATE_LEVERAGE and MARKET_PARTIAL_CLOSE orders" and checks NAV continuity across each request and fill.
contract NavPendingForkTest is NavForkBase {
    function setUp() public override {
        super.setUp();
        if (!forked) return;
        (v, pol) = _create(bytes32(uint256(950)), _risk(30_000), 0, 0);
        _depositSettle(v, alice, 100_000e6);
    }

    function _pending() internal view returns (IGainsDiamond.PendingOrder memory o) {
        IGainsDiamond.PendingOrder[] memory os = D.getPendingOrders(address(v));
        assertEq(os.length, 1, "one pending order");
        o = os[0];
    }

    /// @notice UPDATE_LEVERAGE decrease: Gains pulls delta = c x lev / newLev - c at request and stores
    ///         collateralAmount = delta, leverage = the NEW absolute leverage, pairIndex 0. GainsNav values it at
    ///         delta - minGovFee(pair 0): NAV moves by exactly that fee at the request; across the fill (Gains
    ///         realizes the gov fee on success too) NAV moves by the realized fee only.
    function test_PENDING_fork_leverageDecreaseStoredAsDeltaAndNewLeverage() public {
        (uint32 idx,) = _open(v, ETH, true, 2_000e6, 20_000, _c(ETH));
        _rollFresh(10);
        uint256 nav0 = v.totalAssets();
        Vm.Log[] memory req = _call(v, mgr, abi.encodeCall(GainsVault.updateLeverage, (idx, uint24(10_000))));
        IGainsDiamond.PendingOrder memory o = _pending();
        assertEq(o.orderType, GTrade.UPDATE_LEVERAGE);
        assertEq(o.trade.collateralAmount, 2_000e6, "collateralAmount = delta (2,000 x 20 / 10 - 2,000)");
        assertEq(o.trade.leverage, 10_000, "leverage = the new absolute leverage");
        assertEq(o.trade.pairIndex, 0, "pairIndex left 0");
        uint256 nav1 = v.totalAssets();
        uint256 fee0 = harness.minGovFee(D, 3, 0);
        assertEq(nav0 - nav1, fee0, "request: NAV down by exactly the reserved gov fee");
        console2.log("NAV before / pending", nav0, nav1);
        console2.log("minGovFee pair 0 / pair 1 (ETH)", fee0, harness.minGovFee(D, 3, 1));
        _rollFresh(1);
        _fill(req, _c(ETH));
        assertFalse(v.ordersPending());
    }

    /// @notice MARKET_PARTIAL_CLOSE: collateral reduce stores collateralAmount = delta, leverage = 0; leverage reduce
    ///         stores collateralAmount = 0, leverage = delta. The trade stays valued as open while it is pending.
    function test_PENDING_fork_partialCloseStoredAsDeltas() public {
        (uint32 idx,) = _open(v, ETH, true, 2_000e6, 20_000, _c(ETH));
        _passHold(); // GR2-KEY-01b (WP5 port): the manager's reduce waits the 10-minute minimum hold
        uint256 nav0 = v.totalAssets();
        Vm.Log[] memory req = _call(v, mgr, abi.encodeCall(GainsVault.reduceTrade, (idx, uint120(500e6), uint24(0), _c(ETH))));
        IGainsDiamond.PendingOrder memory o = _pending();
        assertEq(o.orderType, GTrade.MARKET_PARTIAL_CLOSE);
        assertEq(o.trade.collateralAmount, 500e6, "collateral delta");
        assertEq(o.trade.leverage, 0, "leverage 0 = a collateral reduce");
        assertEq(v.totalAssets(), nav0, "pending close: trade still valued as open, nothing else");
        _rollFresh(1);
        _fill(req, _c(ETH));
        _rollFresh(10);
        Vm.Log[] memory req2 = _call(v, mgr, abi.encodeCall(GainsVault.reduceTrade, (idx, uint120(0), uint24(5_000), _c(ETH))));
        o = _pending();
        assertEq(o.trade.collateralAmount, 0, "leverage reduce: collateral 0");
        assertEq(o.trade.leverage, 5_000, "leverage = the delta");
        _rollFresh(1);
        _fill(req2, _c(ETH));
    }

    /// @notice NAV continuity across a leverage-decrease fill at the Chainlink price: the trade's value at P is
    ///         independent of leverage at constant size except for the gov fee Gains realizes on the update.
    function test_PENDING_fork_navContinuousAcrossLeverageDecreaseFill() public {
        (uint32 idx,) = _open(v, ETH, true, 2_000e6, 20_000, _c(ETH));
        _rollFresh(10);
        uint256 nav0 = v.totalAssets();
        Vm.Log[] memory req = _call(v, mgr, abi.encodeCall(GainsVault.updateLeverage, (idx, uint24(10_000))));
        _rollFresh(1);
        uint256 navPending = v.totalAssets();
        _fill(req, _c(ETH));
        uint256 nav2 = v.totalAssets();
        IGainsDiamond.Trade memory t = D.getTrade(address(v), idx);
        assertEq(t.leverage, 10_000, "filled");
        assertEq(t.collateralAmount, 4_000e6);
        console2.log("NAV before / pending / after fill", nav0, navPending, nav2);
        int256 drift = int256(nav2) - int256(nav0);
        console2.log("NAV change across the leverage decrease (1e6)");
        console2.logInt(drift);
        assertApproxEqAbs(nav2, nav0, 0.2e6, "within the gov fee (~0.04) plus one block of holding fees");
    }
}
