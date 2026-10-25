// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {R1Base} from "../R1Base.t.sol";
import {GainsNav} from "../../../../src/gains/GainsNav.sol";
import {GainsPrice} from "../../../../src/gains/GainsPrice.sol";
import {IGainsDiamond} from "../../../../src/gains/IGainsDiamond.sol";

/// @notice Round 2 mutation kills for GainsNav._closingPrice (lines 257-269): the shared mock returns 0 for Gains'
///         skew and cumulative-volume price impact, so the two-pass impact logic was only exercised by fork tests,
///         which the mutation harness cannot run. Here vm.mockCall gives the diamond a cumulative impact that depends
///         on the "pnl positive" flag (Gains' protection close factor decision) and the expected value is recomputed
///         in the test with the same Gains formula (STAGE0.md C; round 1's NavDiff fork tests matched it to 0.005 bp).
/// @dev The replica below inlines GainsNav's pure helpers (pnlPercent, priceAfterImpact, tradeValuePure,
///      totalTradeFeesRaw): mutants of those helpers are excluded from this file in the mutation run (as NavUnit).
contract MutationKillsImpactTest is R1Base {
    uint16 internal constant BAND = 20; // ETH band in GainsBase

    function _mockCumul(uint32 idx, bool flag, int256 impact) internal {
        IGainsDiamond.Trade memory t = diamond.getTrade(address(vault), idx);
        uint256 size = (uint256(t.collateralAmount) * t.leverage) / 1e3;
        uint256 sizeUsd = diamond.getUsdNormalizedValue(3, size);
        vm.mockCall(
            address(diamond),
            abi.encodeWithSelector(IGainsDiamond.getTradeCumulVolPriceImpactP.selector, address(vault), t.pairIndex, t.long, sizeUsd, flag),
            abi.encode(impact)
        );
    }

    /// Gains' market-close value at the adverse band edge, two-pass impact (the replica of GainsNav._valueAt).
    function _expected(uint32 idx, int256 cumulNeg, int256 cumulPos) internal view returns (uint256) {
        IGainsDiamond.Trade memory t = diamond.getTrade(address(vault), idx);
        uint64 p = GainsPrice.adverse(_px(ETH), BAND, t.long);
        uint256 size = (uint256(t.collateralAmount) * t.leverage) / 1e3;
        uint256 feesRaw = GainsNav.totalTradeFeesRaw(IGainsDiamond(address(diamond)), 3, t.pairIndex, size);
        (,, int256 realized) = diamond.getTradeRealizedPnlCollateral(address(vault), idx);
        int256 hmr = diamond.holding(address(vault), idx) - realized;
        int256 base = GainsNav.fixedSpreadP(diamond.pairSpreadP(address(vault), t.pairIndex), t.long);
        uint256 v1 = GainsNav.tradeValuePure(
            t.collateralAmount, GainsNav.pnlPercent(t.openPrice, GainsNav.priceAfterImpact(p, base + cumulNeg), t.long, t.leverage), int256(feesRaw) + hmr, 1e12
        );
        int256 cumul = v1 > t.collateralAmount ? cumulPos : cumulNeg;
        uint64 cp = GainsNav.priceAfterImpact(p, base + cumul);
        return GainsNav.tradeValuePure(t.collateralAmount, GainsNav.pnlPercent(t.openPrice, cp, t.long, t.leverage), int256(feesRaw) + hmr, 1e12);
    }

    function _setup() internal returns (uint32 idx) {
        diamond.setPair(ETH, 6e8, 285.7e18, 0.1e18, 0); // 0.06% fee: 60 USDC per 100k of notional
        _deposit(alice, 100_000e6);
        _settle();
        _claim(alice);
        idx = _open(vault, ETH, true, 10_000e6, 10_000); // 100k notional long
    }

    /// Nav#527 (pass 1 uses base - cumul0), #543 (the flag's comparison swapped), #544 (final price uses base -
    /// cumul): with a -1% cumulative impact the trade is under water in pass 1, so the -1% applies to the value.
    function test_MUT_Nav527_543_544_twoPassImpact() public {
        uint32 idx = _setup();
        _setPrice(ETH, uint64((uint256(_px(ETH)) * 10_050) / 10_000)); // +0.5%: +0.3% at the adverse edge
        int256 neg = -1e10; // -1%
        _mockCumul(idx, false, neg);
        _mockCumul(idx, true, 0);
        uint256 e = _expected(idx, neg, 0);
        assertLt(e, 10_000e6, "pass 1 decides 'pnl negative': the impact applies");
        assertEq(vault.venue().value, e, "NAV = Gains' two-pass close value");
    }

    /// Nav#532 (pass 1 fees: feesTiered - (holding - realized)): the opening fee booked as realized counts against
    /// the value in pass 1. Here pnl is +90 USDC and fees 60 + 60: pass 1 must see 'pnl negative' (cumul 0); with the
    /// sign flipped it sees +90 and picks the positive-pnl impact (-1%).
    function test_MUT_Nav532_passOneCountsRealizedFees() public {
        uint32 idx = _setup();
        // +0.09% at the adverse edge: mid = open x 1.0009 / 0.998
        _setPrice(ETH, uint64((uint256(_px(ETH)) * 10_009 * 10_000) / (10_000 * 9_980)));
        _mockCumul(idx, false, 0);
        _mockCumul(idx, true, -1e10);
        uint256 e = _expected(idx, 0, -1e10);
        assertGt(e + 200e6, 10_000e6, "no impact applied: within fees of the collateral");
        assertEq(vault.venue().value, e, "NAV = Gains' two-pass close value");
    }

    /// Nav#519 (`contractsVersion < V9_2` early return -> false): a pre-v9.2 trade closes at the oracle price, no
    /// spread or impact (Gains applied none before v9.2).
    function test_MUT_Nav519_preV92TradeHasNoImpact() public {
        uint32 idx = _setup();
        diamond.setContractsVersion(address(vault), idx, 0);
        vm.mockCall(address(diamond), abi.encodeWithSelector(IGainsDiamond.getTradeCumulVolPriceImpactP.selector), abi.encode(int256(-1e10)));
        IGainsDiamond.Trade memory t = diamond.getTrade(address(vault), idx);
        uint64 p = GainsPrice.adverse(_px(ETH), BAND, true);
        uint256 feesRaw = GainsNav.totalTradeFeesRaw(IGainsDiamond(address(diamond)), 3, ETH, 100_000e6);
        (,, int256 realized) = diamond.getTradeRealizedPnlCollateral(address(vault), idx);
        uint256 e = GainsNav.tradeValuePure(
            t.collateralAmount, GainsNav.pnlPercent(t.openPrice, p, true, t.leverage), int256(feesRaw) + diamond.holding(address(vault), idx) - realized, 1e12
        );
        assertEq(vault.venue().value, e, "valued at the band edge, no impact");
    }

    function _openAt(uint64 openPx, bool long) internal returns (uint32 idx) {
        _deposit(alice, 100_000e6);
        _settle();
        _claim(alice);
        _setPrice(ETH, openPx);
        idx = _open(vault, ETH, long, 10_000e6, 10_000); // 10x
    }

    /// Nav#R303 (long: `price <= liq` -> `<`) and #R305 (short: `price >= liq` -> `>`): a trade whose valuation
    /// price (the adverse band edge) is exactly its liquidation price is worth 0 (GR1-03). Prices chosen so the edge
    /// lands on the mock's liquidation price (open x (1 -/+ 0.9 / leverage)) without rounding.
    function test_MUT_NavR303_longAtLiquidationPriceWorthZero() public {
        _openAt(2_994e10, true); // liq = 2,724.54
        _setPrice(ETH, 2_730e10); // adverse long edge = 2,730 x 0.998 = 2,724.54
        assertEq(vault.venue().value, 0);
    }

    function test_MUT_NavR305_shortAtLiquidationPriceWorthZero() public {
        _openAt(3_006e10, false); // liq = 3,276.54
        _setPrice(ETH, 3_270e10); // adverse short edge = 3,270 x 1.002 = 3,276.54
        assertEq(vault.venue().value, 0);
    }

    /// Nav#R307 (`contractsVersion < V9_2` -> `<=`): a v9.2 trade gets the spread and impact on close.
    function test_MUT_NavR307_v92TradeGetsTheSpread() public {
        diamond.setPair(ETH, 0, 285.7e18, 0.1e18, 1e9); // 0.1% spread
        uint32 idx = _openAt(3_000e10, true);
        diamond.setContractsVersion(address(vault), idx, 1); // V9_2
        uint256 e = _expected(idx, 0, 0);
        assertEq(vault.venue().value, e, "half the spread against the long");
        assertLt(e, 10_000e6);
    }

    /// Nav#R309 (`valueNoFactor > collateral` -> `>=`): Gains' "pnl positive" flag is strict: a trade worth exactly
    /// its collateral in pass 1 takes the negative-pnl impact.
    function test_MUT_NavR309_flagIsStrict() public {
        uint32 idx = _openAt(2_994e10, true); // no fees (feeP 0), no spread
        _setPrice(ETH, 3_000e10); // adverse edge = 2,994 = open: pass-1 value == collateral exactly
        _mockCumul(idx, false, 0);
        _mockCumul(idx, true, -1e10);
        assertEq(vault.venue().value, 10_000e6, "flag false: no impact, exactly the collateral");
    }
}
