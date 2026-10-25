// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {GainsVaultMath} from "../../../../src/gains/GainsVaultMath.sol";
import {GainsNav} from "../../../../src/gains/GainsNav.sol";
import {GainsPrice} from "../../../../src/gains/GainsPrice.sol";
import {operatorReduceCap} from "../../../../src/gains/GainsTypes.sol";
import {BPS, DECIMALS_OFFSET, ONE_SHARE, YEAR} from "../../../../src/VaultTypes.sol";

/// @dev Halmos harnesses (round 1, brief section 4 "Symbolic"). Every check_ calls the production library function
///      (internal pure functions are inlined into this harness from the imported source) except the fee and claim
///      shapes, whose production code reads VaultStorage and makes external calls: those copy the exact expressions of
///      GainsVaultLogic._accrueFees (lines 353-381) and GainsVaultMath.claimableWithCarry (lines 216-221) / settle
///      (lines 265-278) and are marked COPY. Domains are the reachable ones: USDC amounts < 2^128 (> 3e32 USDC),
///      share supply < 2^160, prices uint64 1e10, leverage uint24 1e3.
///      Run: see contracts/audit/gains/tools/HALMOS.md.
contract GainsShareMathSymbolic is Test {
    uint256 internal constant OFF = 10 ** DECIMALS_OFFSET;

    // ------------------------------------------------------------------ share math (GainsVaultMath)

    /// SM-1 rounding direction: Floor <= Ceil and Ceil - Floor <= 1 for both conversions.
    function check_SM1_roundingOrder(uint128 a, uint128 nav, uint160 supply) public pure {
        vm.assume(supply > 0);
        uint256 f = GainsVaultMath.toShares(a, nav, supply, Math.Rounding.Floor);
        uint256 c = GainsVaultMath.toShares(a, nav, supply, Math.Rounding.Ceil);
        assert(f <= c && c - f <= 1);
        uint256 fa = GainsVaultMath.toAssets(a, nav, supply, Math.Rounding.Floor);
        uint256 ca = GainsVaultMath.toAssets(a, nav, supply, Math.Rounding.Ceil);
        assert(fa <= ca && ca - fa <= 1);
    }

    /// SM-2 deposit then immediate redeem at the post-mint state never returns more than was deposited
    ///      (settle mints Floor; a redemption pays Floor).
    function check_SM2_roundTripNeverProfits(uint128 a, uint128 nav, uint160 supply) public pure {
        vm.assume(supply > 0);
        uint256 sh = GainsVaultMath.toShares(a, nav, supply, Math.Rounding.Floor);
        uint256 back = GainsVaultMath.toAssets(sh, uint256(nav) + a, uint256(supply) + sh, Math.Rounding.Floor);
        assert(back <= a);
    }

    /// SM-3 a mint at Floor never dilutes existing holders: (nav + a + 1) / (supply + sh + OFF) >= (nav + 1) / (supply + OFF).
    function check_SM3_mintNeverDilutes(uint128 a, uint128 nav, uint120 supply) public pure {
        vm.assume(supply > 0);
        uint256 sh = GainsVaultMath.toShares(a, nav, supply, Math.Rounding.Floor);
        vm.assume(sh < 2 ** 125); // cross-multiplied below: keep both products < 2^256
        assert((uint256(nav) + a + 1) * (uint256(supply) + OFF) >= (uint256(nav) + 1) * (uint256(supply) + sh + OFF));
    }

    /// SM-4 a redemption paid at Floor never dilutes the remaining holders.
    function check_SM4_redeemNeverDilutes(uint120 sh, uint128 nav, uint120 supply) public pure {
        vm.assume(supply > 0 && sh <= supply);
        uint256 paid = GainsVaultMath.toAssets(sh, nav, supply, Math.Rounding.Floor);
        assert(paid <= nav);
        assert((uint256(nav) - paid + 1) * (uint256(supply) + OFF) >= (uint256(nav) + 1) * (uint256(supply) - sh + OFF));
    }

    /// SM-5 monotone in the amount.
    function check_SM5_monotone(uint128 a, uint128 b, uint128 nav, uint160 supply) public pure {
        vm.assume(supply > 0 && a <= b);
        assert(
            GainsVaultMath.toShares(a, nav, supply, Math.Rounding.Floor)
                <= GainsVaultMath.toShares(b, nav, supply, Math.Rounding.Floor)
        );
        assert(
            GainsVaultMath.toAssets(a, nav, supply, Math.Rounding.Floor)
                <= GainsVaultMath.toAssets(b, nav, supply, Math.Rounding.Floor)
        );
    }

    /// SM-6 priceAt (checkRisk / fee path) equals toAssets(ONE_SHARE) Floor (sharePrice / settle path).
    function check_SM6_priceAtMatchesSharePrice(uint128 nav, uint160 supply) public pure {
        vm.assume(supply > 0);
        assert(GainsVaultMath.priceAt(nav, supply) == GainsVaultMath.toAssets(ONE_SHARE, nav, supply, Math.Rounding.Floor));
    }

    /// SM-7 first mint (supply 0): 1 USDC = 1e6 share units, and redeeming them returns exactly the deposit.
    function check_SM7_firstMint(uint128 a) public pure {
        uint256 sh = GainsVaultMath.toShares(a, 0, 0, Math.Rounding.Floor);
        assert(sh == uint256(a) * OFF);
        assert(GainsVaultMath.toAssets(sh, a, sh, Math.Rounding.Floor) <= a);
    }

    /// SM-8 a redemption of shares <= supply never asks for more than NAV (settle redAssets <= priceNav).
    function check_SM8_redAssetsBounded(uint160 sh, uint128 nav, uint160 supply) public pure {
        vm.assume(supply > 0 && sh <= supply);
        assert(GainsVaultMath.toAssets(sh, nav, supply, Math.Rounding.Floor) <= nav);
    }

    // ------------------------------------------------------------------ emergency partial fill (COPY settle 272-278)

    /// SM-9 partial fill burns at most the queued shares and never more than the payout covers.
    function check_SM9_partialFillBurn(uint160 redShares, uint128 redAssets, uint128 available) public pure {
        vm.assume(redAssets > 0 && available < redAssets);
        uint256 burned = Math.mulDiv(redShares, available, redAssets, Math.Rounding.Floor);
        assert(burned <= redShares);
        // value of the burned shares at the epoch price never exceeds the USDC paid for them
        assert(uint256(burned) * redAssets <= uint256(available) * redShares);
    }

    // ------------------------------------------------------------------ claims (COPY claimableWithCarry 216-221)

    /// CL-1 two redeemers of one epoch: claims sum to <= what the epoch paid; returned shares sum to <= the
    ///      escrow left after the burn (redShares - burned), each redeemer's burnedForMe <= its shares.
    function check_CL1_claimsNeverExceedEpoch(uint128 s1, uint128 s2, uint128 paid, uint128 burned) public pure {
        uint256 S = uint256(s1) + s2;
        vm.assume(S > 0 && burned <= S);
        uint256 a1 = Math.mulDiv(s1, paid, S, Math.Rounding.Floor);
        uint256 a2 = Math.mulDiv(s2, paid, S, Math.Rounding.Floor);
        assert(a1 + a2 <= paid);
        uint256 b1 = Math.mulDiv(s1, burned, S, Math.Rounding.Ceil);
        uint256 b2 = Math.mulDiv(s2, burned, S, Math.Rounding.Ceil);
        uint256 r1 = b1 < s1 ? s1 - b1 : 0;
        uint256 r2 = b2 < s2 ? s2 - b2 : 0;
        assert(r1 + r2 <= S - burned);
    }

    /// CL-2 three redeemers (same property, deeper sum).
    function check_CL2_threeRedeemers(uint96 s1, uint96 s2, uint96 s3, uint96 paid) public pure {
        uint256 S = uint256(s1) + s2 + s3;
        vm.assume(S > 0);
        uint256 t = Math.mulDiv(s1, paid, S) + Math.mulDiv(s2, paid, S) + Math.mulDiv(s3, paid, S);
        assert(t <= paid);
    }

    /// CL-3 deposit claims of one epoch: shares delivered sum to <= depositShares minted.
    function check_CL3_depositSharesNeverExceedMint(uint128 d1, uint128 d2, uint160 depShares) public pure {
        uint256 D = uint256(d1) + d2;
        vm.assume(D > 0);
        assert(Math.mulDiv(d1, depShares, D) + Math.mulDiv(d2, depShares, D) <= depShares);
    }
}

contract GainsFeeMathSymbolic is Test {
    uint256 internal constant OFF = 10 ** DECIMALS_OFFSET;

    struct FeeOut {
        uint256 feeAssets;
        uint256 feeShares;
        uint256 protocolShares;
        uint256 price;
        uint256 newPrice;
        uint256 peak;
        uint256 dayStart;
        uint256 hwm;
    }

    /// COPY of GainsVaultLogic._accrueFees lines 347-381 with storage replaced by arguments (the protocol recipient
    /// is assumed set). supply and assets as read there.
    function _accrue(
        uint256 supply,
        uint256 assets,
        uint256 elapsed,
        uint16 mgmt,
        uint16 perf,
        uint16 protoBps,
        bool withPerformance,
        uint256 hwm,
        uint256 peak,
        uint256 dayStart
    ) internal pure returns (FeeOut memory o) {
        o.peak = peak;
        o.dayStart = dayStart;
        o.hwm = hwm;
        if (supply == 0 || assets == 0) return o;
        uint256 feeAssets = Math.mulDiv(assets, uint256(mgmt) * elapsed, BPS * YEAR);
        uint256 price = GainsVaultMath.priceAt(assets, supply);
        if (withPerformance && price > hwm && perf > 0) {
            uint256 gain = Math.mulDiv(price - hwm, supply, ONE_SHARE);
            feeAssets += Math.mulDiv(gain, perf, BPS);
        }
        o.feeAssets = feeAssets;
        o.price = price;
        uint256 newSupply = supply;
        if (feeAssets > 0 && feeAssets < assets) {
            o.feeShares = Math.mulDiv(feeAssets, supply + OFF, assets - feeAssets);
            if (protoBps > 0) o.protocolShares = Math.mulDiv(o.feeShares, protoBps, BPS);
            newSupply += o.feeShares; // protocol + recipient = feeShares (recipient gets feeShares - protocolShares)
        }
        o.newPrice = GainsVaultMath.priceAt(assets, newSupply);
        if (withPerformance && o.newPrice > hwm) o.hwm = o.newPrice;
        if (o.feeShares > 0 && o.newPrice < price) {
            o.peak = Math.mulDiv(peak, o.newPrice, price);
            o.dayStart = Math.mulDiv(dayStart, o.newPrice, price);
        }
    }

    /// FE-1 the minted fee shares are never worth more than the fee (no over-mint): value of feeShares at the
    ///      post-mint state <= feeAssets; and newPrice <= price.
    function check_FE1_feeSharesWorthAtMostTheFee(uint128 supply, uint128 assets, uint32 elapsed, uint16 mgmt) public pure {
        vm.assume(supply > 0 && assets > 0 && mgmt <= 500);
        FeeOut memory o = _accrue(supply, assets, elapsed, mgmt, 0, 0, false, 0, 0, 0);
        assert(o.newPrice <= o.price);
        if (o.feeShares > 0) {
            uint256 worth = GainsVaultMath.toAssets(o.feeShares, assets, uint256(supply) + o.feeShares, Math.Rounding.Floor);
            assert(worth <= o.feeAssets);
        }
    }

    /// FE-2 protocol split: protocolShares <= feeShares x protocolBps / BPS <= feeShares (recipient part >= 0).
    function check_FE2_protocolSplit(uint128 feeShares, uint16 protoBps) public pure {
        vm.assume(protoBps <= 5_000);
        uint256 p = Math.mulDiv(feeShares, protoBps, BPS);
        assert(p <= feeShares);
        assert(p * BPS <= uint256(feeShares) * protoBps);
    }

    /// FE-3 newPrice <= price with the performance fee too (the fee path never raises the share price).
    function check_FE3_newPriceNotAbovePrice(uint128 supply, uint128 assets, uint32 elapsed, uint16 mgmt, uint16 perf, uint128 hwm)
        public
        pure
    {
        vm.assume(supply > 0 && assets > 0 && mgmt <= 500 && perf <= 3_000);
        FeeOut memory o = _accrue(supply, assets, elapsed, mgmt, perf, 0, true, hwm, 0, 0);
        assert(o.newPrice <= o.price);
    }

    /// FE-4 the rescaled references never rise and fee dilution never creates a loss: if the price was at or above a
    ///      reference before the mint, the new price is at or above the rescaled reference.
    function check_FE4_referencesRescaledNoFalseLoss(
        uint128 supply,
        uint128 assets,
        uint32 elapsed,
        uint16 mgmt,
        uint128 peak,
        uint128 dayStart
    ) public pure {
        vm.assume(supply > 0 && assets > 0 && mgmt <= 500);
        FeeOut memory o = _accrue(supply, assets, elapsed, mgmt, 0, 0, false, 0, peak, dayStart);
        assert(o.peak <= peak && o.dayStart <= dayStart);
        if (peak <= o.price) assert(o.peak <= o.newPrice);
        if (dayStart <= o.price) assert(o.dayStart <= o.newPrice);
    }

    /// FE-5 the fee never reaches the NAV in the reachable domain (feeAssets < assets): mgmt <= 5%, elapsed <= 10
    ///      years, perf <= 30%, hwm > 0. Otherwise the whole accrual is silently skipped.
    function check_FE5_feeBelowNav(uint128 supply, uint128 assets, uint32 elapsed, uint16 mgmt, uint16 perf, uint128 hwm)
        public
        pure
    {
        vm.assume(supply > 0 && assets > 0 && mgmt <= 500 && perf <= 3_000 && hwm > 0 && elapsed <= 10 * YEAR);
        FeeOut memory o = _accrue(supply, assets, elapsed, mgmt, perf, 0, true, hwm, 0, 0);
        assert(o.feeAssets < assets);
    }

    /// FE-6 the high water mark only rises, and only to the post-fee price.
    function check_FE6_hwmMonotone(uint128 supply, uint128 assets, uint32 elapsed, uint16 mgmt, uint16 perf, uint128 hwm)
        public
        pure
    {
        vm.assume(supply > 0 && assets > 0 && mgmt <= 500 && perf <= 3_000);
        FeeOut memory o = _accrue(supply, assets, elapsed, mgmt, perf, 0, true, hwm, 0, 0);
        assert(o.hwm >= hwm);
        assert(o.hwm == hwm || o.hwm == o.newPrice);
    }
}

contract GainsNavSymbolic is Test {
    int256 internal constant P10 = 1e10;

    /// NV-1 pnlPercent: floored at -100%, sign follows the move, zero at the open price.
    function check_NV1_pnlPercentShape(uint64 openPrice, uint64 cur, bool long, uint24 lev) public pure {
        vm.assume(openPrice > 0);
        int256 p = GainsNav.pnlPercent(openPrice, cur, long, lev);
        assert(p >= -100 * P10);
        if (cur == openPrice) assert(p == 0);
        if (long && cur > openPrice) assert(p >= 0);
        if (!long && cur < openPrice) assert(p >= 0);
        if (long && cur < openPrice) assert(p <= 0);
    }

    /// NV-2 pnlPercent monotone in the price (long nondecreasing, short nonincreasing).
    function check_NV2_pnlPercentMonotone(uint64 openPrice, uint64 c1, uint64 c2, bool long, uint24 lev) public pure {
        vm.assume(openPrice > 0 && c1 <= c2);
        int256 p1 = GainsNav.pnlPercent(openPrice, c1, long, lev);
        int256 p2 = GainsNav.pnlPercent(openPrice, c2, long, lev);
        if (long) assert(p1 <= p2);
        else assert(p1 >= p2);
    }

    /// NV-3 tradeValuePure: >= 0, nondecreasing in pnl, nonincreasing in fees, <= collateral when pnl <= 0 and fees >= 0
    ///      (USDC precisionDelta 1e12, collateral < 2^120, pnl within [-100%, +1e6 %] = what a uint64 price allows at
    ///      open price >= 0.01 USD, NAV-11 domain).
    function check_NV3_tradeValuePureShape(uint120 coll, int64 pnlP1, int64 pnlP2, int128 fee1, int128 fee2) public pure {
        int256 lo = -100 * P10;
        vm.assume(pnlP1 >= lo && pnlP2 >= lo && pnlP1 <= pnlP2);
        vm.assume(fee1 <= fee2);
        uint128 pd = 1e12;
        uint256 v11 = GainsNav.tradeValuePure(coll, pnlP1, fee1, pd);
        uint256 v21 = GainsNav.tradeValuePure(coll, pnlP2, fee1, pd);
        uint256 v12 = GainsNav.tradeValuePure(coll, pnlP1, fee2, pd);
        assert(v11 <= v21);
        assert(v12 <= v11);
        if (pnlP1 <= 0 && fee1 >= 0) assert(v11 <= coll);
    }

    /// NV-4 priceAfterImpact: identity at 0 impact, monotone in the impact, never above the oracle price for a
    ///      negative impact. Expect a counterexample for the monotone property at the uint64 wrap (NAV-10, known).
    function check_NV4_priceAfterImpactZero(uint64 px) public pure {
        assert(GainsNav.priceAfterImpact(px, 0) == px);
    }

    function check_NV4b_priceAfterImpactMonotone(uint64 px, int64 i1, int64 i2) public pure {
        vm.assume(i1 <= i2);
        assert(GainsNav.priceAfterImpact(px, i1) <= GainsNav.priceAfterImpact(px, i2));
    }

    function check_NV4c_negativeImpactNeverRaisesPrice(uint64 px, int64 i) public pure {
        vm.assume(i <= 0);
        assert(GainsNav.priceAfterImpact(px, i) <= px);
    }

    /// NV-4d the same within the reachable impact (|impact| <= 100%, = 100e10): no wrap.
    function check_NV4d_monotoneWithinHundredPercent(uint64 px, int64 i1, int64 i2) public pure {
        vm.assume(i1 <= i2 && i1 >= -100 * P10 && i2 <= 100 * P10 && uint256(px) * 2 <= type(uint64).max);
        assert(GainsNav.priceAfterImpact(px, i1) <= GainsNav.priceAfterImpact(px, i2));
    }

    /// NV-5 fixedSpreadP: against the trader on close (long <= 0, short >= 0), magnitude spread / 2.
    function check_NV5_fixedSpread(uint128 spreadP, bool long) public pure {
        int256 s = GainsNav.fixedSpreadP(spreadP, long);
        if (long) assert(s <= 0 && uint256(-s) == spreadP / 2);
        else assert(s >= 0 && uint256(s) == spreadP / 2);
    }

    /// NV-6 GainsPrice.adverse: long <= mid, short >= mid for every band <= MAX_BAND_BPS. Expect a counterexample for
    ///      the short (uint64 wrap, ADVERSETRUNC / NAV-10, known).
    function check_NV6_adverseLong(uint64 mid, uint16 band) public pure {
        vm.assume(band <= GainsPrice.MAX_BAND_BPS);
        assert(GainsPrice.adverse(mid, band, true) <= mid);
    }

    function check_NV6b_adverseShort(uint64 mid, uint16 band) public pure {
        vm.assume(band <= GainsPrice.MAX_BAND_BPS);
        assert(GainsPrice.adverse(mid, band, false) >= mid);
    }

    /// NV-6c the short is sound below the wrap threshold (mid x (1 + band) < 2^64), i.e. for any answer GainsPrice.read
    ///      can return below ~1.67e9 USD at a 10% band.
    function check_NV6c_adverseShortBelowWrap(uint64 mid, uint16 band) public pure {
        vm.assume(band <= GainsPrice.MAX_BAND_BPS);
        vm.assume(uint256(mid) * (10_000 + band) / 10_000 <= type(uint64).max);
        assert(GainsPrice.adverse(mid, band, false) >= mid);
    }

    /// NV-7 the band is applied at most once by adverse: |adverse - mid| <= mid x band / BPS + 1.
    function check_NV7_adverseDistance(uint64 mid, uint16 band, bool long) public pure {
        vm.assume(band <= GainsPrice.MAX_BAND_BPS);
        vm.assume(uint256(mid) * (10_000 + band) / 10_000 <= type(uint64).max);
        uint256 a = GainsPrice.adverse(mid, band, long);
        uint256 d = a > mid ? a - mid : mid - a;
        assert(d * 10_000 <= uint256(mid) * band);
    }

    /// NV-7b NV-7 with the floor rounding allowed for (one 1e-10 unit, toward the vault): the band is applied once.
    function check_NV7b_adverseDistanceRounded(uint64 mid, uint16 band, bool long) public pure {
        vm.assume(band <= GainsPrice.MAX_BAND_BPS);
        vm.assume(uint256(mid) * (10_000 + band) / 10_000 <= type(uint64).max);
        uint256 a = GainsPrice.adverse(mid, band, long);
        uint256 d = a > mid ? a - mid : mid - a;
        assert(d * 10_000 <= uint256(mid) * band + 10_000);
        assert(d * 10_000 + 10_000 > uint256(mid) * band);
    }

    /// NV-8 open notional term positionSizeToken (1e18) x mid (1e10) / 1e22 cannot overflow for uint160 sizes.
    function check_NV8_notionalNoOverflow(uint160 sizeToken, uint64 mid) public pure {
        uint256 n = (uint256(sizeToken) * mid) / 1e22;
        assert(n <= type(uint256).max);
    }
}

contract GainsOperatorBoundSymbolic is Test {
    /// OB-1 cap(0) = 0.
    function check_OB1_zero() public pure {
        assert(operatorReduceCap(0) == 0);
    }

    /// OB-2 cap >= shortfall and cap <= shortfall x 1.02 + 1 USDC, no overflow below 2^200.
    function check_OB2_bounds(uint200 s) public pure {
        vm.assume(s > 0);
        uint256 c = operatorReduceCap(s);
        assert(c >= s);
        assert(c <= uint256(s) + (uint256(s) * 200) / 10_000 + 1e6);
        assert(c - s >= 1e6);
    }

    /// OB-3 monotone.
    function check_OB3_monotone(uint200 a, uint200 b) public pure {
        vm.assume(a <= b);
        assert(operatorReduceCap(a) <= operatorReduceCap(b));
    }

    /// OB-3b monotone over the USDC domain (any shortfall < 2^64 units = 1.8e13 USDC), easier for the solver.
    function check_OB3b_monotone64(uint64 a, uint64 b) public pure {
        vm.assume(a <= b);
        assert(operatorReduceCap(a) <= operatorReduceCap(b));
    }

    /// OB-4c no revert over the USDC domain.
    function check_OB4c_neverReverts64(uint64 s) public view {
        try this.capExt(s) returns (uint256 c) {
            assert(c >= s);
        } catch {
            assert(false);
        }
    }

    function capExt(uint256 s) external pure returns (uint256) {
        return operatorReduceCap(s);
    }

    /// OB-4 no revert (checked-arithmetic panic) for any shortfall the vault can compute (< 2^200; USDC supply < 2^64).
    function check_OB4_neverRevertsInDomain(uint200 s) public view {
        try this.capExt(s) returns (uint256 c) {
            assert(c >= s);
        } catch {
            assert(false);
        }
    }

    /// OB-4b for any uint256: expected counterexample (overflow of shortfall x 200 above 2^256 / 200), unreachable.
    function check_OB4b_revertsOnlyAboveDomain(uint256 s) public view {
        try this.capExt(s) returns (uint256 c) {
            assert(c >= s);
        } catch {
            assert(false);
        }
    }
}
