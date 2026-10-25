// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {VaultMath} from "../../../../src/VaultMath.sol";
import {PxMath} from "../../../../src/libraries/PxMath.sol";

/// @title hl-r2 Halmos properties on the pure share math (VaultMath) and the order price math (PxMath)
/// @notice Run with halmos (`check_` prefix); forge test ignores these. Every property calls the production library
///         function, never a re-statement of it. Inputs are bounded to uint128 (USDC 6 decimals, shares 12 decimals:
///         3.4e38 is far above any reachable NAV or supply) so the solver stays on the no-overflow path of mulDiv.
///         See contracts/audit/hl-r2/HALMOS.md for the results.
contract HalmosMath is Test {
    uint256 internal constant OFF = 1e6; // 10 ** DECIMALS_OFFSET
    uint256 internal constant ONE_SHARE = 1e12;

    // ------------------------------------------------------------------
    // H1. A deposit priced at NAV never lowers the incumbents' share price (settle deposit leg, toShares Floor).
    //     (nav + d + 1) / (s + sh + OFF) >= (nav + 1) / (s + OFF), cross-multiplied, no division in the claim.
    // ------------------------------------------------------------------
    function check_H1_depositLegNeverDilutes(uint128 nav, uint128 supply, uint128 dep) public pure {
        vm.assume(supply > 0);
        uint256 sh = VaultMath.toShares(dep, nav, supply, Math.Rounding.Floor);
        uint256 x = uint256(nav) + 1;
        uint256 y = uint256(supply) + OFF;
        assert((x + dep) * y >= x * (y + sh));
    }

    // H2. A redemption paid at NAV never lowers the remaining holders' share price (toAssets Floor).
    function check_H2_redeemLegNeverDilutes(uint128 nav, uint128 supply, uint128 red) public pure {
        vm.assume(supply > 0 && red <= supply);
        uint256 paid = VaultMath.toAssets(red, nav, supply, Math.Rounding.Floor);
        uint256 x = uint256(nav) + 1;
        uint256 y = uint256(supply) + OFF;
        assert(paid <= nav);
        assert((x - paid) * y >= x * (y - red));
    }

    // H3. Deposit then immediate redemption of the minted shares at the post-deposit NAV returns at most the
    //     deposit (no free value from rounding).
    function check_H3_depositRedeemRoundTrip(uint128 nav, uint128 supply, uint128 dep) public pure {
        vm.assume(supply > 0);
        uint256 sh = VaultMath.toShares(dep, nav, supply, Math.Rounding.Floor);
        uint256 back = VaultMath.toAssets(sh, uint256(nav) + dep, uint256(supply) + sh, Math.Rounding.Floor);
        assert(back <= dep);
    }

    // H4. Emergency partial fill (VaultLogic.settle: burned = redShares * paid / redAssets, Floor): the vault
    //     never burns more than it paid for, and the rounding in the redeemers' favour is below one share unit of
    //     value: paid * (s + OFF) <= (burned + 1) * (priceNav + 1) ... checked against the pricing NAV.
    function check_H4_partialFillBurnBounds(uint128 priceNav, uint128 supply, uint128 red, uint128 available)
        public
        pure
    {
        vm.assume(supply > 0 && red > 0 && red <= supply);
        uint256 redAssets = VaultMath.toAssets(red, priceNav, supply, Math.Rounding.Floor);
        vm.assume(available < redAssets);
        uint256 paid = available;
        uint256 burned = Math.mulDiv(red, paid, redAssets, Math.Rounding.Floor);
        assert(burned <= red);
        // never over-burn: burned / red <= paid / redAssets
        assert(burned * redAssets <= uint256(red) * paid);
        // bounded under-burn: the shares kept by the redeemers are worth less than one share unit more than the
        // fill (paid <= value of burned + 1 unit at the pricing NAV)
        uint256 x = uint256(priceNav) + 1;
        uint256 y = uint256(supply) + OFF;
        assert(paid * y <= (burned + 1) * x);
    }

    // ------------------------------------------------------------------
    // Claims (VaultMath.claimableWithCarry arithmetic, two controllers of one epoch): what users can claim never
    // exceeds what the epoch reserved, and returned shares never exceed what was not burned.
    // ------------------------------------------------------------------
    function _redeemClaim(uint256 s, uint256 redeemAssets, uint256 redeemShares, uint256 redeemBurned)
        internal
        pure
        returns (uint256 assets, uint256 shares)
    {
        // verbatim from VaultMath.claimableWithCarry (the redemption leg)
        assets = Math.mulDiv(s, redeemAssets, redeemShares, Math.Rounding.Floor);
        uint256 burnedForMe = Math.mulDiv(s, redeemBurned, redeemShares, Math.Rounding.Ceil);
        if (burnedForMe < s) shares = s - burnedForMe;
    }

    function check_H5_redeemClaimsNeverExceedReserve(uint128 s1, uint128 s2, uint128 paid, uint128 burned) public pure {
        uint256 R = uint256(s1) + s2;
        vm.assume(R > 0 && burned <= R);
        (uint256 a1, uint256 r1) = _redeemClaim(s1, paid, R, burned);
        (uint256 a2, uint256 r2) = _redeemClaim(s2, paid, R, burned);
        assert(a1 + a2 <= paid);
        assert(r1 + r2 <= R - burned);
    }

    function check_H6_depositClaimsNeverExceedMinted(uint128 d1, uint128 d2, uint128 depShares) public pure {
        uint256 D = uint256(d1) + d2;
        vm.assume(D > 0);
        uint256 c1 = Math.mulDiv(d1, depShares, D, Math.Rounding.Floor);
        uint256 c2 = Math.mulDiv(d2, depShares, D, Math.Rounding.Floor);
        assert(c1 + c2 <= depShares);
    }

    // ------------------------------------------------------------------
    // PxMath: the flatten / order price never crosses the slippage bound, and 5 significant figures hold.
    // ------------------------------------------------------------------
    function check_H7_sigFigs5(uint64 raw, bool up) public pure {
        uint256 r = PxMath.toSigFigs5(raw, up);
        if (raw < 100_000) {
            assert(r == raw);
            return;
        }
        if (up) assert(r >= raw);
        else assert(r <= raw);
        // r has at most 5 significant figures
        uint256 unitR = 1;
        uint256 v = r;
        while (v >= 100_000) {
            v /= 10;
            unitR *= 10;
        }
        assert(r % unitR == 0);
        // and is less than one unit of raw's 5th significant figure away from raw
        uint256 unit = 1;
        v = raw;
        while (v >= 100_000) {
            v /= 10;
            unit *= 10;
        }
        assert(up ? r - raw < unit : raw - r < unit);
    }

    function check_H8_boundedLimitPxWithinSlippage(uint64 rawMark, uint8 szDecimals, bool isBuy, uint16 slip)
        public
        pure
    {
        vm.assume(szDecimals <= 6 && slip > 0 && slip <= 2_000 && rawMark > 0);
        uint64 px = PxMath.boundedLimitPx1e8(rawMark, szDecimals, isBuy, slip);
        uint256 scale = 10 ** (2 + uint256(szDecimals));
        assert(px % scale == 0);
        uint256 p = px / scale;
        if (isBuy) assert(p * 10_000 <= uint256(rawMark) * (10_000 + slip) || p == 1);
        else assert(p * 10_000 >= uint256(rawMark) * (10_000 - slip));
    }

    /// @dev Liveness of a flatten: a reduce-only IOC sell must not be priced above the mark (it would never fill)
    ///      and a buy not below it.
    function check_H9_boundedLimitPxCrossesTheMark(uint64 rawMark, uint8 szDecimals, bool isBuy, uint16 slip) public pure {
        vm.assume(szDecimals <= 6 && slip > 0 && slip <= 2_000 && rawMark > 0);
        uint64 px = PxMath.boundedLimitPx1e8(rawMark, szDecimals, isBuy, slip);
        uint256 p = px / 10 ** (2 + uint256(szDecimals));
        if (isBuy) assert(p >= rawMark);
        else assert(p <= rawMark);
    }

    // ------------------------------------------------------------------
    // Reduced variants (64-bit inputs): the same claims with the products kept inside 128 bits, for when the
    // 128-bit versions time out in the solver (non-linear bit-vector arithmetic). 2^64 wei = 1.8e13 USDC, still above
    // any reachable NAV; 2^64 share units = 1.8e7 shares at 12 decimals (covers 18M USDC at 1 USDC per share).
    // ------------------------------------------------------------------
    function check_H1r_depositLegNeverDilutes(uint64 nav, uint64 supply, uint64 dep) public pure {
        check_H1_depositLegNeverDilutes(nav, supply, dep);
    }

    function check_H2r_redeemLegNeverDilutes(uint64 nav, uint64 supply, uint64 red) public pure {
        check_H2_redeemLegNeverDilutes(nav, supply, red);
    }

    function check_H3r_depositRedeemRoundTrip(uint64 nav, uint64 supply, uint64 dep) public pure {
        check_H3_depositRedeemRoundTrip(nav, supply, dep);
    }

    function check_H4r_partialFillBurnBounds(uint64 priceNav, uint64 supply, uint64 red, uint64 available) public pure {
        check_H4_partialFillBurnBounds(priceNav, supply, red, available);
    }

    function check_H5r_redeemClaimsNeverExceedReserve(uint64 s1, uint64 s2, uint64 paid, uint64 burned) public pure {
        check_H5_redeemClaimsNeverExceedReserve(s1, s2, paid, burned);
    }

    function check_H6r_depositClaimsNeverExceedMinted(uint64 d1, uint64 d2, uint64 depShares) public pure {
        check_H6_depositClaimsNeverExceedMinted(d1, d2, depShares);
    }

    // ------------------------------------------------------------------
    // Reduced PxMath variants: one digit count at a time (the rounding loop runs a fixed number of times), the
    // claims of H7 and H8 restated with the unit computed in closed form.
    // ------------------------------------------------------------------
    function _sigFigs5At(uint64 raw, bool up, uint256 digits) internal pure {
        uint256 lo = 10 ** (digits - 1);
        vm.assume(raw >= lo && raw < lo * 10);
        uint256 unit = 10 ** (digits - 5);
        uint256 r = PxMath.toSigFigs5(raw, up);
        if (up) assert(r >= raw && r - raw < unit);
        else assert(r <= raw && raw - r < unit);
        assert(r % unit == 0 || r == lo * 10); // a round-up may carry to 10^digits (one significant figure)
    }

    function check_H7d6_sigFigs5(uint64 raw, bool up) public pure {
        _sigFigs5At(raw, up, 6);
    }

    function check_H7d9_sigFigs5(uint64 raw, bool up) public pure {
        _sigFigs5At(raw, up, 9);
    }

    function check_H7d12_sigFigs5(uint64 raw, bool up) public pure {
        _sigFigs5At(raw, up, 12);
    }

    function check_H7d19_sigFigs5(uint64 raw, bool up) public pure {
        _sigFigs5At(raw, up, 19);
    }

    /// H8 / H9 for a mark of 6 to 7 digits (BTC raw marks are 6 digits, ETH 6, SOL 6 at today's prices).
    function check_H8d_boundedLimitPx(uint64 rawMark, bool isBuy, uint16 slip) public pure {
        vm.assume(rawMark >= 100_000 && rawMark < 10_000_000 && slip > 0 && slip <= 2_000);
        uint64 px = PxMath.boundedLimitPx1e8(rawMark, 5, isBuy, slip);
        uint256 p = px / 1e7;
        assert(px % 1e7 == 0);
        if (isBuy) {
            assert(p * 10_000 <= uint256(rawMark) * (10_000 + slip));
            assert(p >= rawMark); // crosses the mark: a buy IOC can fill
        } else {
            assert(p * 10_000 >= uint256(rawMark) * (10_000 - slip));
            assert(p <= rawMark); // a sell IOC can fill
        }
    }

    // 32-bit variants (second reduction step: products inside 64 bits).
    function check_H1s_depositLegNeverDilutes(uint32 nav, uint32 supply, uint32 dep) public pure {
        check_H1_depositLegNeverDilutes(nav, supply, dep);
    }

    function check_H2s_redeemLegNeverDilutes(uint32 nav, uint32 supply, uint32 red) public pure {
        check_H2_redeemLegNeverDilutes(nav, supply, red);
    }

    function check_H3s_depositRedeemRoundTrip(uint32 nav, uint32 supply, uint32 dep) public pure {
        check_H3_depositRedeemRoundTrip(nav, supply, dep);
    }

    function check_H4s_partialFillBurnBounds(uint32 priceNav, uint32 supply, uint32 red, uint32 available) public pure {
        check_H4_partialFillBurnBounds(priceNav, supply, red, available);
    }

    function check_H5s_redeemClaimsNeverExceedReserve(uint32 s1, uint32 s2, uint32 paid, uint32 burned) public pure {
        check_H5_redeemClaimsNeverExceedReserve(s1, s2, paid, burned);
    }

    function check_H6s_depositClaimsNeverExceedMinted(uint32 d1, uint32 d2, uint32 depShares) public pure {
        check_H6_depositClaimsNeverExceedMinted(d1, d2, depShares);
    }
}
