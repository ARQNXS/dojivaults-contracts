// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import "./LifecycleForkBase.sol";

/// @notice Task 1: the pending-order fields the vault relies on, verified on the real diamond, NAV continuity across
///         every request type, and the LC-01 / GR1-01 regression (a pending leverage-only increase is counted).
contract LC_PendingForkTest is LifecycleForkBase {
    // ------------------------------------------------------------------ MARKET_PARTIAL_CLOSE, collateral reduce
    /// @dev GainsVaultMath.redemptionShortfall (GainsVaultMath.sol:156) counts a pending MARKET_PARTIAL_CLOSE with
    ///      trade.leverage == 0 at trade.collateralAmount. Verified: Gains stores collateralAmount = delta, leverage = 0,
    ///      pairIndex = 0 for a collateral reduce.
    function test_lc_partialCloseCollateral_pendingFieldsAndNav() public {
        _depositSettle(alice, 20_000e6);
        uint32 idx = _openFilledV(ETH, true, 2_000e6, 5_000);
        _passHold(); // GR2-KEY-01b (WP5 port): was _rollFresh(1_000); the manager's reduce waits the 10-minute minimum hold
        uint64 p = _adverse(ETH, true);
        uint256 navBefore = _nav();
        uint256 sfBefore = v.redemptionShortfall();
        Vm.Log[] memory req = _req(mgr, abi.encodeCall(GainsVault.reduceTrade, (idx, uint120(700e6), uint24(0), p)));
        IGainsDiamond.PendingOrder memory o = _lastPending();
        assertEq(o.orderType, T_PARTIAL_CLOSE, "MARKET_PARTIAL_CLOSE");
        assertEq(o.trade.collateralAmount, 700e6, "collateralAmount = delta");
        assertEq(o.trade.leverage, 0, "leverage = 0 for a collateral reduce");
        assertEq(o.trade.index, idx);
        assertEq(o.trade.pairIndex, 0, "pairIndex left 0 by Gains (ETH is pair 1)");
        assertEq(sfBefore, 0);
        uint256 navPending = _nav();
        assertEq(navPending, navBefore, "a pending reduce leaves the trade valued as open");
        _rollFresh(1);
        navPending = _nav();
        uint256 b0 = _usdc();
        _fill(req, p);
        uint256 paid = _usdc() - b0;
        uint256 navAfter = _nav();
        console2.log("partial close 700 of 2000 ETH 5x: paid", paid);
        console2.log("  nav pending / after", navPending, navAfter);
        assertApproxEqAbs(navAfter, navPending, 2, "continuous at the valuation price");
    }

    /// @dev Leverage reduce (decreasePositionSize with leverageDelta): Gains stores collateralAmount = 0 and
    ///      leverage = the DELTA. redemptionShortfall ignores it (leverage != 0); GainsNav values the trade as open.
    ///      After the fill (negative PnL is moved to the gToken vault and booked on the trade), NAV must stay
    ///      continuous at the valuation price, at a loss and at a profit.
    function test_lc_partialCloseLeverage_pendingFieldsAndNav_loss() public {
        _leverageReduce(9_850); // -1.5%: 10x long at about -15%
    }

    function test_lc_partialCloseLeverage_pendingFieldsAndNav_profit() public {
        _leverageReduce(10_150); // +1.5%
    }

    function _leverageReduce(uint256 moveBps) internal {
        _depositSettle(alice, 20_000e6);
        uint32 idx = _openFilledV(ETH, true, 2_000e6, 10_000);
        _passHold(); // GR2-KEY-01b (WP5 port): was _rollFresh(1_000); the manager's reduce waits the 10-minute minimum hold
        _setCl(ETH_USD, _round(uint64(uint256(cl[ETH_USD]) * moveBps / 10_000)));
        uint64 p = _adverse(ETH, true);
        uint256 navBefore = _nav();
        Vm.Log[] memory req = _req(mgr, abi.encodeCall(GainsVault.reduceTrade, (idx, uint120(0), uint24(5_000), p)));
        IGainsDiamond.PendingOrder memory o = _lastPending();
        assertEq(o.orderType, T_PARTIAL_CLOSE);
        assertEq(o.trade.collateralAmount, 0, "collateral 0 for a leverage reduce");
        assertEq(o.trade.leverage, 5_000, "leverage = the delta, not the new leverage");
        assertEq(v.redemptionShortfall(), 0);
        assertEq(_nav(), navBefore, "pending leverage reduce: trade valued as open");
        _rollFresh(1);
        uint256 navPending = _nav();
        uint256 b0 = _usdc();
        Vm.Log[] memory fill = _fill(req, p);
        assertEq(_count(fill, G.PositionSizeDecreaseExecuted.selector), 1);
        uint256 paid = _usdc() - b0;
        uint256 navAfter = _nav();
        IGainsDiamond.Trade memory t = _trade(idx);
        assertEq(t.leverage, 5_000, "10x -> 5x");
        assertEq(t.collateralAmount, 2_000e6, "collateral unchanged by a leverage reduce");
        console2.log("leverage reduce 10x -> 5x, move bps", moveBps);
        console2.log("  paid to vault", paid);
        console2.log("  nav pending", navPending);
        console2.log("  nav after  ", navAfter);
        // tolerance: 1 bp of the trade notional (20,000 USDC) = 2 USDC
        assertApproxEqAbs(navAfter, navPending, 2e6, "NAV continuous across a leverage reduce at P");
    }

    // ------------------------------------------------------------------ UPDATE_LEVERAGE decrease (adds margin)
    /// @dev GainsNav.sol:71-73: a pending UPDATE_LEVERAGE holds collateral when o.trade.leverage (the NEW absolute
    ///      leverage) < the trade's leverage, and the held amount is o.trade.collateralAmount (the delta pulled).
    function test_lc_updateLeverageDecrease_pendingFieldsAndNav() public {
        _depositSettle(alice, 20_000e6);
        uint32 idx = _openFilledV(ETH, true, 1_000e6, 10_000);
        _rollFresh(1_000);
        uint256 navBefore = _nav();
        uint256 idleBefore = v.idleAssets();
        Vm.Log[] memory req = _req(mgr, abi.encodeCall(GainsVault.updateLeverage, (idx, uint24(5_000))));
        IGainsDiamond.PendingOrder memory o = _lastPending();
        assertEq(o.orderType, T_UPDATE_LEVERAGE);
        assertEq(o.trade.leverage, 5_000, "leverage = the new absolute leverage");
        assertEq(o.trade.collateralAmount, 1_000e6, "collateralAmount = delta (1000 x 10 / 5 - 1000)");
        assertEq(idleBefore - v.idleAssets(), 1_000e6, "delta pulled at request (exact approve)");
        assertEq(USDC.allowance(address(v), address(DIAMOND)), 0);
        uint256 navPending = _nav();
        console2.log("lev decrease ETH 10x->5x: nav before - pending (minGovFee used)", navBefore - navPending);
        _rollFresh(1);
        navPending = _nav();
        (,, int256 realizedBefore) = D.getTradeRealizedPnlCollateral(address(v), idx);
        _fill(req, _adverse(ETH, true));
        (,, int256 realizedAfter) = D.getTradeRealizedPnlCollateral(address(v), idx);
        uint256 navAfter = _nav();
        console2.log("  gov fee realized on the trade at fill", uint256(realizedBefore - realizedAfter));
        console2.log("  nav pending / after", navPending, navAfter);
        assertEq(_trade(idx).collateralAmount, 2_000e6);
        assertApproxEqAbs(navAfter, navPending, 1e6, "continuous within 1 USDC");
    }

    /// @notice Was the GR1-28 PoC `test_lc_updateLeverageDecrease_solFeeOnPairZero` (the held collateral's gov fee
    ///         priced on pair 0). Gains still leaves pending.trade.pairIndex = 0 on a SOL trade's order; GainsNav now
    ///         prices the fee on the trade's own pair: making pair 0's gov fee different leaves the NAV unchanged.
    function test_GR1_28_updateLeverageDecrease_solFeeOnTradesOwnPair() public {
        _depositSettle(alice, 20_000e6);
        uint32 idx = _openFilledV(SOL, true, 1_000e6, 10_000);
        _rollFresh(1_000);
        uint256 navBefore = _nav();
        Vm.Log[] memory req = _req(mgr, abi.encodeCall(GainsVault.updateLeverage, (idx, uint24(5_000))));
        IGainsDiamond.PendingOrder memory o = _lastPending();
        assertEq(o.trade.pairIndex, 0, "pairIndex 0 in the pending order of a SOL trade");
        uint256 navPending = _nav();
        uint256 feeUsedByNav = navBefore - navPending;
        // pair 0 (BTC) with 10x SOL's gov fee: a NAV that priced the fee on pair 0 would move
        bytes memory feeCall0 = abi.encodeCall(IGainsDiamond.getTradeFeeParams, (uint8(3), uint16(0)));
        IGainsDiamond.GlobalTradeFeeParams memory fp = D.getTradeFeeParams(3, SOL);
        fp.govFeeP *= 10;
        vm.mockCall(address(D), feeCall0, abi.encode(fp));
        assertEq(_nav(), navPending, "GR1-28: the fee follows the trade's pair (33), not pair 0");
        vm.clearMockedCalls();
        _refreshCl();
        _mockArbBlock();
        _rollFresh(1);
        (,, int256 r0) = D.getTradeRealizedPnlCollateral(address(v), idx);
        _fill(req, _adverse(SOL, true));
        (,, int256 r1) = D.getTradeRealizedPnlCollateral(address(v), idx);
        console2.log("SOL lev decrease: fee GainsNav reserved (pair 33)", feeUsedByNav);
        console2.log("SOL lev decrease: gov fee Gains realized (pair 33)", uint256(r0 - r1));
        assertGt(feeUsedByNav, 0);
    }

    // ------------------------------------------------------------------ UPDATE_LEVERAGE increase (returns collateral)
    function test_lc_updateLeverageIncrease_pendingFieldsAndNav() public {
        _depositSettle(alice, 20_000e6);
        uint32 idx = _openFilledV(ETH, true, 2_000e6, 5_000);
        _rollFresh(1_000);
        uint256 navBefore = _nav();
        uint256 notionalBefore = v.venue().notional;
        Vm.Log[] memory req = _req(mgr, abi.encodeCall(GainsVault.updateLeverage, (idx, uint24(10_000))));
        IGainsDiamond.PendingOrder memory o = _lastPending();
        assertEq(o.orderType, T_UPDATE_LEVERAGE);
        assertEq(o.trade.leverage, 10_000, "new absolute leverage");
        assertEq(o.trade.collateralAmount, 1_000e6, "delta to be returned");
        assertEq(_nav(), navBefore, "nothing held, trade valued as is");
        assertEq(v.venue().notional, notionalBefore, "constant size");
        _rollFresh(1);
        uint256 navPending = _nav();
        uint256 b0 = _usdc();
        _fill(req, _adverse(ETH, true));
        console2.log("lev increase 5x->10x: returned", _usdc() - b0);
        console2.log("  nav pending / after", navPending, _nav());
        assertEq(_usdc() - b0, 1_000e6, "delta returned to the vault");
        assertApproxEqAbs(_nav(), navPending, 1e6, "continuous within 1 USDC (gov fee)");
    }

    // ------------------------------------------------------------------ MARKET_PARTIAL_OPEN with collateral
    function test_lc_increaseWithCollateral_pendingFieldsAndNav() public {
        _depositSettle(alice, 20_000e6);
        uint32 idx = _openFilledV(ETH, true, 1_000e6, 5_000);
        _rollFresh(1_000);
        uint256 navBefore = _nav();
        uint256 notionalBefore = v.venue().notional;
        Vm.Log[] memory req = _req(mgr, abi.encodeCall(GainsVault.increaseTrade, (idx, uint120(500e6), uint24(4_000), cl[ETH_USD], uint16(1_000))));
        IGainsDiamond.PendingOrder memory o = _lastPending();
        assertEq(o.orderType, T_PARTIAL_OPEN);
        assertEq(o.trade.collateralAmount, 500e6, "collateral delta");
        assertEq(o.trade.leverage, 4_000, "leverage = the delta");
        assertEq(o.trade.pairIndex, 0, "pairIndex left 0");
        assertEq(v.venue().notional - notionalBefore, 2_000e6, "pending notional = 500 x 4");
        console2.log("increase 500 @4x: nav before - pending", navBefore - _nav());
        _rollFresh(1);
        uint256 navPending = _nav();
        _fill(req, cl[ETH_USD]);
        console2.log("  nav pending / after fill at C", navPending, _nav());
        console2.log("  notional after", v.venue().notional);
    }

    // ------------------------------------------------------------------ LC-01: leverage-only increase
    /// @notice Was `test_lc_increaseLeverageOnly_pendingNotionalIsZero` (LC-01 / GR1-01: a pending leverage-only
    ///         MARKET_PARTIAL_OPEN, collateralAmount 0 and leverage = delta, added 0 to the open notional). GainsNav now
    ///         counts it at the trade's collateral x the leverage delta while it is pending; the fill changes nothing.
    function test_GR1_01_leverageOnlyIncrease_countedWhilePending() public {
        _depositSettle(alice, 20_000e6);
        uint32 idx = _openFilledV(ETH, true, 1_000e6, 5_000);
        _rollFresh(1_000);
        uint256 notionalBefore = v.venue().notional;
        Vm.Log[] memory req = _req(mgr, abi.encodeCall(GainsVault.increaseTrade, (idx, uint120(0), uint24(10_000), cl[ETH_USD], uint16(1_000))));
        IGainsDiamond.PendingOrder memory o = _lastPending();
        assertEq(o.orderType, T_PARTIAL_OPEN);
        assertEq(o.trade.collateralAmount, 0, "no collateral for a leverage-only increase");
        assertEq(o.trade.leverage, 10_000, "leverage = delta");
        uint256 notionalPending = v.venue().notional;
        assertEq(notionalPending - notionalBefore, 10_000e6, "GR1-01: pending +10,000 USDC of size counted (1,000 x 10)");
        assertFalse(v.ordersPending(), "a leverage-only increase holds no collateral: settle is not held");
        _rollFresh(1);
        _fill(req, cl[ETH_USD]);
        assertEq(_trade(idx).leverage, 15_000, "filled: 5x + 10x");
        assertApproxEqRel(v.venue().notional, notionalPending, 0.01e18, "the fill does not add the size a second time");
    }

    /// @notice Was the LC-01 PoC `test_lc_LC01_leverageOnlyIncreasesBypassVaultLeverage` (GR1-01): under a 3x policy,
    ///         three leverage-only increases sent before the first fill each passed checkOrder against the same stale
    ///         open notional and the vault ended at several times maxLeverageBps. Now the first pending increase is
    ///         counted, a second one on another trade is refused "leverage", a second request on the same trade is
    ///         refused PendingOrderExists, and after the fill the vault is within the policy (no breach).
    function test_GR1_01_leverageOnlyIncreases_cannotBypassVaultLeverage() public {
        _depositSettle(alice, 10_000e6);
        uint32 a = _openFilledV(ETH, true, 1_000e6, 2_000);
        uint32 b = _openFilledV(BTC, true, 1_000e6, 2_000);
        uint32 c = _openFilledV(ETH, false, 1_000e6, 2_000);
        _rollFresh(10);
        uint256 nav = _nav();
        uint256 notional = v.venue().notional;
        uint256 maxLev = pol.maxLeverageBps();
        uint256 headroom = nav * maxLev / 10_000 - notional;
        // the largest leverage delta one increase may add on 1,000 USDC of collateral (99% of the headroom)
        uint24 delta = uint24(headroom * 990 / 1_000e6);
        console2.log("nav", nav, "notional", notional);
        console2.log("headroom", headroom, "leverage delta (1e3)", delta);
        Vm.Log[] memory req = _req(mgr, abi.encodeCall(GainsVault.increaseTrade, (a, uint120(0), delta, cl[ETH_USD], uint16(1_000))));
        assertEq(v.venue().notional - notional, uint256(1_000e6) * delta / 1_000, "the pending increase is counted");
        // a second leverage-only increase on another trade sees the pending one: refused
        vm.prank(mgr);
        vm.expectRevert(abi.encodeWithSelector(IGainsVaultErrors.OrderRejected.selector, "leverage"));
        v.increaseTrade(b, uint120(0), delta, cl[BTC_USD], uint16(1_000));
        vm.prank(mgr);
        vm.expectRevert(abi.encodeWithSelector(IGainsVaultErrors.OrderRejected.selector, "leverage"));
        v.increaseTrade(c, uint120(0), delta, cl[ETH_USD], uint16(1_000));
        // and the same trade cannot carry a second request while the first is in flight
        vm.prank(mgr);
        vm.expectRevert(abi.encodeWithSelector(IGainsVaultErrors.PendingOrderExists.selector, a));
        v.increaseTrade(a, uint120(0), uint24(1), cl[ETH_USD], uint16(1_000));
        _rollFresh(1);
        _fill(req, cl[ETH_USD]);
        uint256 levBps = v.venue().notional * 10_000 / _nav();
        console2.log("vault leverage after the fill (bps)", levBps, "policy max", maxLev);
        assertLe(levBps, maxLev + maxLev / 100, "within the policy maximum (1% fill tolerance)");
        v.checkRisk();
        assertFalse(v.breached(), "no leverage breach");
    }

    /// @dev Control: collateral increases are counted while pending, so the same sequence with collateral is refused.
    function test_lc_LC01_control_collateralIncreasesAreCounted() public {
        _depositSettle(alice, 10_000e6);
        uint32 a = _openFilledV(ETH, true, 1_000e6, 2_000);
        uint32 b = _openFilledV(BTC, true, 1_000e6, 2_000);
        _rollFresh(10);
        uint256 nav = _nav();
        uint256 headroom = nav * pol.maxLeverageBps() / 10_000 - v.venue().notional;
        // 1,000 USDC of collateral at the leverage that uses 60% of the headroom
        uint24 lev = uint24(headroom * 600 / 1_000e6);
        _req(mgr, abi.encodeCall(GainsVault.increaseTrade, (a, uint120(1_000e6), lev, cl[ETH_USD], uint16(1_000))));
        vm.prank(mgr);
        vm.expectRevert(abi.encodeWithSelector(IGainsVaultErrors.OrderRejected.selector, "leverage"));
        v.increaseTrade(b, uint120(1_000e6), lev, cl[BTC_USD], uint16(1_000));
    }
}
