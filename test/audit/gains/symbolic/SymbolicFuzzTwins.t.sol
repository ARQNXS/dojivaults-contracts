// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {GainsShareMathSymbolic, GainsFeeMathSymbolic, GainsNavSymbolic, GainsOperatorBoundSymbolic} from "./GainsSymbolic.t.sol";
import {GainsPlainMathSymbolic} from "./GainsPlainSymbolic.t.sol";

/// @dev Forge fuzz twins of every Halmos check expected to hold (the expected counterexamples NV4b, NV6b, NV7, OB4b are
///      left out). Evidence for the checks Halmos could not close within its time cap. Run with FOUNDRY_FUZZ_RUNS=100000.
///      NV4d bounds its inputs instead of assuming (an int64 draw almost never lands within +-100%).

contract GainsShareMathSymbolicFuzzTwins is GainsShareMathSymbolic {
    /// @dev Halmos semantics: an assertion failure (Panic 0x01) fails; any other revert (checked-arithmetic overflow
    ///      outside the realistic domain, a rejected assumption) discards the input.
    function _onRevert(bytes memory e) internal pure {
        if (keccak256(e) == keccak256(abi.encodeWithSignature("Panic(uint256)", uint256(1)))) revert("assertion failed");
        vm.assume(false);
    }

    function testFuzz_SM1_roundingOrder(uint128 a, uint128 nav, uint160 supply) public view {
        try this.check_SM1_roundingOrder(a, nav, supply) {} catch (bytes memory e) {
            _onRevert(e);
        }
    }
    function testFuzz_SM2_roundTripNeverProfits(uint128 a, uint128 nav, uint160 supply) public view {
        try this.check_SM2_roundTripNeverProfits(a, nav, supply) {} catch (bytes memory e) {
            _onRevert(e);
        }
    }
    function testFuzz_SM3_mintNeverDilutes(uint128 a, uint128 nav, uint120 supply) public view {
        try this.check_SM3_mintNeverDilutes(a, nav, supply) {} catch (bytes memory e) {
            _onRevert(e);
        }
    }
    function testFuzz_SM4_redeemNeverDilutes(uint120 sh, uint128 nav, uint120 supply) public view {
        try this.check_SM4_redeemNeverDilutes(sh, nav, supply) {} catch (bytes memory e) {
            _onRevert(e);
        }
    }
    function testFuzz_SM5_monotone(uint128 a, uint128 b, uint128 nav, uint160 supply) public view {
        try this.check_SM5_monotone(a, b, nav, supply) {} catch (bytes memory e) {
            _onRevert(e);
        }
    }
    function testFuzz_SM6_priceAtMatchesSharePrice(uint128 nav, uint160 supply) public view {
        try this.check_SM6_priceAtMatchesSharePrice(nav, supply) {} catch (bytes memory e) {
            _onRevert(e);
        }
    }
    function testFuzz_SM7_firstMint(uint128 a) public view {
        try this.check_SM7_firstMint(a) {} catch (bytes memory e) {
            _onRevert(e);
        }
    }
    function testFuzz_SM8_redAssetsBounded(uint160 sh, uint128 nav, uint160 supply) public view {
        try this.check_SM8_redAssetsBounded(sh, nav, supply) {} catch (bytes memory e) {
            _onRevert(e);
        }
    }
    function testFuzz_SM9_partialFillBurn(uint160 redShares, uint128 redAssets, uint128 available) public view {
        try this.check_SM9_partialFillBurn(redShares, redAssets, available) {} catch (bytes memory e) {
            _onRevert(e);
        }
    }
    function testFuzz_CL1_claimsNeverExceedEpoch(uint128 s1, uint128 s2, uint128 paid, uint128 burned) public view {
        try this.check_CL1_claimsNeverExceedEpoch(s1, s2, paid, burned) {} catch (bytes memory e) {
            _onRevert(e);
        }
    }
    function testFuzz_CL2_threeRedeemers(uint96 s1, uint96 s2, uint96 s3, uint96 paid) public view {
        try this.check_CL2_threeRedeemers(s1, s2, s3, paid) {} catch (bytes memory e) {
            _onRevert(e);
        }
    }
    function testFuzz_CL3_depositSharesNeverExceedMint(uint128 d1, uint128 d2, uint160 depShares) public view {
        try this.check_CL3_depositSharesNeverExceedMint(d1, d2, depShares) {} catch (bytes memory e) {
            _onRevert(e);
        }
    }
}

contract GainsFeeMathSymbolicFuzzTwins is GainsFeeMathSymbolic {
    /// @dev Halmos semantics: an assertion failure (Panic 0x01) fails; any other revert (checked-arithmetic overflow
    ///      outside the realistic domain, a rejected assumption) discards the input.
    function _onRevert(bytes memory e) internal pure {
        if (keccak256(e) == keccak256(abi.encodeWithSignature("Panic(uint256)", uint256(1)))) revert("assertion failed");
        vm.assume(false);
    }

    function testFuzz_FE1_feeSharesWorthAtMostTheFee(uint128 supply, uint128 assets, uint32 elapsed, uint16 mgmt) public view {
        try this.check_FE1_feeSharesWorthAtMostTheFee(supply, assets, elapsed, mgmt) {} catch (bytes memory e) {
            _onRevert(e);
        }
    }
    function testFuzz_FE2_protocolSplit(uint128 feeShares, uint16 protoBps) public view {
        try this.check_FE2_protocolSplit(feeShares, protoBps) {} catch (bytes memory e) {
            _onRevert(e);
        }
    }
    function testFuzz_FE3_newPriceNotAbovePrice(uint128 supply, uint128 assets, uint32 elapsed, uint16 mgmt, uint16 perf, uint128 hwm) public view {
        try this.check_FE3_newPriceNotAbovePrice(supply, assets, elapsed, mgmt, perf, hwm) {} catch (bytes memory e) {
            _onRevert(e);
        }
    }
    function testFuzz_FE4_referencesRescaledNoFalseLoss(uint128 supply, uint128 assets, uint32 elapsed, uint16 mgmt, uint128 peak, uint128 dayStart) public view {
        try this.check_FE4_referencesRescaledNoFalseLoss(supply, assets, elapsed, mgmt, peak, dayStart) {} catch (bytes memory e) {
            _onRevert(e);
        }
    }
    function testFuzz_FE5_feeBelowNav(uint128 supply, uint128 assets, uint32 elapsed, uint16 mgmt, uint16 perf, uint128 hwm) public view {
        try this.check_FE5_feeBelowNav(supply, assets, elapsed, mgmt, perf, hwm) {} catch (bytes memory e) {
            _onRevert(e);
        }
    }
    function testFuzz_FE6_hwmMonotone(uint128 supply, uint128 assets, uint32 elapsed, uint16 mgmt, uint16 perf, uint128 hwm) public view {
        try this.check_FE6_hwmMonotone(supply, assets, elapsed, mgmt, perf, hwm) {} catch (bytes memory e) {
            _onRevert(e);
        }
    }
}

contract GainsNavSymbolicFuzzTwins is GainsNavSymbolic {
    /// @dev Halmos semantics: an assertion failure (Panic 0x01) fails; any other revert (checked-arithmetic overflow
    ///      outside the realistic domain, a rejected assumption) discards the input.
    function _onRevert(bytes memory e) internal pure {
        if (keccak256(e) == keccak256(abi.encodeWithSignature("Panic(uint256)", uint256(1)))) revert("assertion failed");
        vm.assume(false);
    }

    function testFuzz_NV1_pnlPercentShape(uint64 openPrice, uint64 cur, bool long, uint24 lev) public view {
        try this.check_NV1_pnlPercentShape(openPrice, cur, long, lev) {} catch (bytes memory e) {
            _onRevert(e);
        }
    }
    function testFuzz_NV2_pnlPercentMonotone(uint64 openPrice, uint64 c1, uint64 c2, bool long, uint24 lev) public view {
        try this.check_NV2_pnlPercentMonotone(openPrice, c1, c2, long, lev) {} catch (bytes memory e) {
            _onRevert(e);
        }
    }
    function testFuzz_NV3_tradeValuePureShape(uint120 coll, int64 pnlP1, int64 pnlP2, int128 fee1, int128 fee2) public view {
        try this.check_NV3_tradeValuePureShape(coll, pnlP1, pnlP2, fee1, fee2) {} catch (bytes memory e) {
            _onRevert(e);
        }
    }
    function testFuzz_NV4_priceAfterImpactZero(uint64 px) public view {
        try this.check_NV4_priceAfterImpactZero(px) {} catch (bytes memory e) {
            _onRevert(e);
        }
    }
    function testFuzz_NV4c_negativeImpactNeverRaisesPrice(uint64 px, int64 i) public view {
        try this.check_NV4c_negativeImpactNeverRaisesPrice(px, i) {} catch (bytes memory e) {
            _onRevert(e);
        }
    }
    function testFuzz_NV4d_monotoneWithinHundredPercent(uint64 px, int64 i1, int64 i2) public view {
        px = uint64(bound(px, 0, type(uint64).max / 2));
        i1 = int64(bound(i1, -100e10, 100e10));
        i2 = int64(bound(i2, i1, 100e10));
        this.check_NV4d_monotoneWithinHundredPercent(px, i1, i2);
    }
    function testFuzz_NV5_fixedSpread(uint128 spreadP, bool long) public view {
        try this.check_NV5_fixedSpread(spreadP, long) {} catch (bytes memory e) {
            _onRevert(e);
        }
    }
    function testFuzz_NV6_adverseLong(uint64 mid, uint16 band) public view {
        try this.check_NV6_adverseLong(mid, band) {} catch (bytes memory e) {
            _onRevert(e);
        }
    }
    function testFuzz_NV6c_adverseShortBelowWrap(uint64 mid, uint16 band) public view {
        try this.check_NV6c_adverseShortBelowWrap(mid, band) {} catch (bytes memory e) {
            _onRevert(e);
        }
    }
    function testFuzz_NV7b_adverseDistanceRounded(uint64 mid, uint16 band, bool long) public view {
        try this.check_NV7b_adverseDistanceRounded(mid, band, long) {} catch (bytes memory e) {
            _onRevert(e);
        }
    }
    function testFuzz_NV8_notionalNoOverflow(uint160 sizeToken, uint64 mid) public view {
        try this.check_NV8_notionalNoOverflow(sizeToken, mid) {} catch (bytes memory e) {
            _onRevert(e);
        }
    }
}

contract GainsOperatorBoundSymbolicFuzzTwins is GainsOperatorBoundSymbolic {
    /// @dev Halmos semantics: an assertion failure (Panic 0x01) fails; any other revert (checked-arithmetic overflow
    ///      outside the realistic domain, a rejected assumption) discards the input.
    function _onRevert(bytes memory e) internal pure {
        if (keccak256(e) == keccak256(abi.encodeWithSignature("Panic(uint256)", uint256(1)))) revert("assertion failed");
        vm.assume(false);
    }

    function testFuzz_OB2_bounds(uint200 s) public view {
        try this.check_OB2_bounds(s) {} catch (bytes memory e) {
            _onRevert(e);
        }
    }
    function testFuzz_OB3_monotone(uint200 a, uint200 b) public view {
        try this.check_OB3_monotone(a, b) {} catch (bytes memory e) {
            _onRevert(e);
        }
    }
    function testFuzz_OB3b_monotone64(uint64 a, uint64 b) public view {
        try this.check_OB3b_monotone64(a, b) {} catch (bytes memory e) {
            _onRevert(e);
        }
    }
    function testFuzz_OB4c_neverReverts64(uint64 s) public view {
        try this.check_OB4c_neverReverts64(s) {} catch (bytes memory e) {
            _onRevert(e);
        }
    }
    function testFuzz_OB4_neverRevertsInDomain(uint200 s) public view {
        try this.check_OB4_neverRevertsInDomain(s) {} catch (bytes memory e) {
            _onRevert(e);
        }
    }
}

contract GainsPlainMathSymbolicFuzzTwins is GainsPlainMathSymbolic {
    /// @dev Halmos semantics: an assertion failure (Panic 0x01) fails; any other revert (checked-arithmetic overflow
    ///      outside the realistic domain, a rejected assumption) discards the input.
    function _onRevert(bytes memory e) internal pure {
        if (keccak256(e) == keccak256(abi.encodeWithSignature("Panic(uint256)", uint256(1)))) revert("assertion failed");
        vm.assume(false);
    }

    function testFuzz_P_SM2_roundTrip(uint64 a, uint64 nav, uint80 supply) public view {
        try this.check_P_SM2_roundTrip(a, nav, supply) {} catch (bytes memory e) {
            _onRevert(e);
        }
    }
    function testFuzz_P_SM3_mintNeverDilutes(uint64 a, uint64 nav, uint80 supply) public view {
        try this.check_P_SM3_mintNeverDilutes(a, nav, supply) {} catch (bytes memory e) {
            _onRevert(e);
        }
    }
    function testFuzz_P_SM4_redeemNeverDilutes(uint80 sh, uint64 nav, uint80 supply) public view {
        try this.check_P_SM4_redeemNeverDilutes(sh, nav, supply) {} catch (bytes memory e) {
            _onRevert(e);
        }
    }
    function testFuzz_P_SM9_partialFill(uint80 redShares, uint64 redAssets, uint64 available) public view {
        try this.check_P_SM9_partialFill(redShares, redAssets, available) {} catch (bytes memory e) {
            _onRevert(e);
        }
    }
    function testFuzz_P_CL1_twoRedeemers(uint64 s1, uint64 s2, uint64 paid, uint64 burned) public view {
        try this.check_P_CL1_twoRedeemers(s1, s2, paid, burned) {} catch (bytes memory e) {
            _onRevert(e);
        }
    }
    function testFuzz_P_FE1_feeShares(uint64 assets, uint80 supply, uint64 feeAssets) public view {
        try this.check_P_FE1_feeShares(assets, supply, feeAssets) {} catch (bytes memory e) {
            _onRevert(e);
        }
    }
    function testFuzz_P_FE4_rescale(uint64 peak, uint64 price, uint64 newPrice) public view {
        try this.check_P_FE4_rescale(peak, price, newPrice) {} catch (bytes memory e) {
            _onRevert(e);
        }
    }
    function testFuzz_P_NV1_pnlShape(uint32 openPrice, uint32 cur, bool long, uint24 lev) public view {
        try this.check_P_NV1_pnlShape(openPrice, cur, long, lev) {} catch (bytes memory e) {
            _onRevert(e);
        }
    }
}
