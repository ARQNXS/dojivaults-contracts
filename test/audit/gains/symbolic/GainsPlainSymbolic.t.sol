// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

/// @dev Narrow-domain twins of the share / claim / fee checks in GainsSymbolic.t.sol with mulDiv(a, b, c) written as
///      a * b / c. That is exact while a * b < 2^256, which the 64 / 80 bit domains guarantee, and OZ Math.mulDiv
///      returns the same floor (Ceil = floor + (remainder > 0)). The production-call checks time out inside mulDiv's
///      512-bit assembly; these prove the same inequalities for the vault's formulas (GainsVaultMath.toShares /
///      toAssets / priceAt, GainsVaultLogic.settle 272-278 and _accrueFees 364 / 379-380, claimableWithCarry 216-221).
///      Domains: amounts and NAV < 2^64 units (1.8e13 USDC), supply < 2^80 share units (1.2e12 shares at 1e12 units).
contract GainsPlainMathSymbolic is Test {
    uint256 internal constant OFF = 1e6;

    function _toShares(uint256 a, uint256 nav, uint256 supply) internal pure returns (uint256) {
        return supply == 0 ? a * OFF : (a * (supply + OFF)) / (nav + 1);
    }

    function _toAssets(uint256 s, uint256 nav, uint256 supply) internal pure returns (uint256) {
        return supply == 0 ? s / OFF : (s * (nav + 1)) / (supply + OFF);
    }

    function check_P_SM2_roundTrip(uint64 a, uint64 nav, uint80 supply) public pure {
        vm.assume(supply > 0);
        uint256 sh = _toShares(a, nav, supply);
        assert(_toAssets(sh, uint256(nav) + a, uint256(supply) + sh) <= a);
    }

    function check_P_SM3_mintNeverDilutes(uint64 a, uint64 nav, uint80 supply) public pure {
        vm.assume(supply > 0);
        uint256 sh = _toShares(a, nav, supply);
        assert((uint256(nav) + a + 1) * (uint256(supply) + OFF) >= (uint256(nav) + 1) * (uint256(supply) + sh + OFF));
    }

    function check_P_SM4_redeemNeverDilutes(uint80 sh, uint64 nav, uint80 supply) public pure {
        vm.assume(supply > 0 && sh <= supply);
        uint256 paid = _toAssets(sh, nav, supply);
        assert(paid <= nav);
        assert((uint256(nav) - paid + 1) * (uint256(supply) + OFF) >= (uint256(nav) + 1) * (uint256(supply) - sh + OFF));
    }

    function check_P_SM9_partialFill(uint80 redShares, uint64 redAssets, uint64 available) public pure {
        vm.assume(redAssets > 0 && available < redAssets);
        uint256 burned = (uint256(redShares) * available) / redAssets;
        assert(burned <= redShares);
        assert(burned * redAssets <= uint256(available) * redShares);
    }

    function check_P_CL1_twoRedeemers(uint64 s1, uint64 s2, uint64 paid, uint64 burned) public pure {
        uint256 S = uint256(s1) + s2;
        vm.assume(S > 0 && burned <= S);
        assert((uint256(s1) * paid) / S + (uint256(s2) * paid) / S <= paid);
        uint256 b1 = (uint256(s1) * burned + S - 1) / S;
        uint256 b2 = (uint256(s2) * burned + S - 1) / S;
        uint256 r1 = b1 < s1 ? s1 - b1 : 0;
        uint256 r2 = b2 < s2 ? s2 - b2 : 0;
        assert(r1 + r2 <= S - burned);
    }

    /// FE-1 plain: fee shares at the post-mint state are worth <= the fee, and newPrice <= price.
    function check_P_FE1_feeShares(uint64 assets, uint80 supply, uint64 feeAssets) public pure {
        vm.assume(supply > 0 && assets > 0 && feeAssets > 0 && feeAssets < assets);
        uint256 fs = (uint256(feeAssets) * (uint256(supply) + OFF)) / (uint256(assets) - feeAssets);
        assert(_toAssets(fs, assets, uint256(supply) + fs) <= feeAssets);
        uint256 p0 = ((uint256(assets) + 1) * 1e12) / (uint256(supply) + OFF);
        uint256 p1 = ((uint256(assets) + 1) * 1e12) / (uint256(supply) + fs + OFF);
        assert(p1 <= p0);
    }

    /// FE-4 plain: a rescaled reference never rises; no false loss when the price was at or above it.
    function check_P_FE4_rescale(uint64 peak, uint64 price, uint64 newPrice) public pure {
        vm.assume(price > 0 && newPrice < price);
        uint256 p2 = (uint256(peak) * newPrice) / price;
        assert(p2 <= peak);
        if (peak <= price) assert(p2 <= newPrice);
    }

    /// NV-1 plain (pnlPercent of GainsNav.sol:176-183 with 32-bit prices and leverage): floor at -100%, sign.
    function check_P_NV1_pnlShape(uint32 openPrice, uint32 cur, bool long, uint24 lev) public pure {
        vm.assume(openPrice > 0);
        int256 o = int256(uint256(openPrice));
        int256 c = int256(uint256(cur));
        int256 p = ((long ? c - o : o - c) * 100 * 1e10 * int256(uint256(lev))) / o / 1e3;
        if (p < -100e10) p = -100e10;
        assert(p >= -100e10);
        if (long && cur >= openPrice) assert(p >= 0);
        if (!long && cur <= openPrice) assert(p >= 0);
    }
}
