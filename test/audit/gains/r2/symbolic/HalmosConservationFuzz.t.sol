// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {ConservationProps} from "./ConservationProps.sol";

/// @dev Forge fuzz twins of every Halmos check (100,000 runs each). Same internal property functions, so the
///      statements are identical; a failing assert fails the test, vm.assume discards the input (as in Halmos).
contract HalmosConservationFuzz is ConservationProps {
    /// forge-config: default.fuzz.runs = 100000
    /// forge-config: default.fuzz.max-test-rejects = 100000000
    function test_fuzz_C1_depositRequest(uint128 bal, uint128 pend, uint128 defer, uint128 claim, uint128 wallet, uint128 assets, bool insider) public pure {
        _c1(bal, pend, defer, claim, wallet, assets, insider);
    }

    /// forge-config: default.fuzz.runs = 100000
    /// forge-config: default.fuzz.max-test-rejects = 100000000
    function test_fuzz_C2_redeemRequest(uint128 ownerBal, uint128 escrow, uint128 others, uint128 pendRed, uint128 shares, uint256 allowance, bool bySpender)
        public
        pure
    {
        _c2(ownerBal, escrow, others, pendRed, shares, allowance, bySpender);
    }

    /// forge-config: default.fuzz.runs = 100000
    /// forge-config: default.fuzz.max-test-rejects = 100000000
    function test_fuzz_C3_cancelDeposit(uint128 bal, uint128 pend, uint128 defer, uint128 claim, uint128 assets, bool deferred) public pure {
        _c3(bal, pend, defer, claim, assets, deferred);
    }

    /// forge-config: default.fuzz.runs = 100000
    /// forge-config: default.fuzz.max-test-rejects = 100000000
    function test_fuzz_C4_cancelRedeem(uint128 escrow, uint128 pendRed, uint128 holder, uint128 shares) public pure {
        _c4(escrow, pendRed, holder, shares);
    }

    /// forge-config: default.fuzz.runs = 100000
    /// forge-config: default.fuzz.max-test-rejects = 100000000
    function test_fuzz_C5_settle(
        uint64 bal,
        uint64 pend,
        uint64 defer,
        uint64 claim,
        uint128 supply,
        uint128 escrow,
        uint128 redShares,
        bool emergency,
        bool lossBreach,
        bool treasury,
        uint64 redAssets,
        uint128 depSharesRaw,
        uint128 burnedPartial
    ) public pure {
        _c5(bal, pend, defer, claim, supply, escrow, redShares, emergency, lossBreach, treasury, redAssets, depSharesRaw, burnedPartial);
    }

    /// forge-config: default.fuzz.runs = 100000
    /// forge-config: default.fuzz.max-test-rejects = 100000000
    function test_fuzz_C6_claim(uint128 bal, uint128 pend, uint128 defer, uint128 claim, uint128 escrow, uint128 shares, uint128 assets) public pure {
        _c6(bal, pend, defer, claim, escrow, shares, assets);
    }

    /// forge-config: default.fuzz.runs = 100000
    /// forge-config: default.fuzz.max-test-rejects = 100000000
    function test_fuzz_C7_feeMint(uint128 supply, uint64 assets, uint64 feeAssets, uint128 feeSharesRaw, uint16 protoBps, uint128 holders) public pure {
        _c7(supply, assets, feeAssets, feeSharesRaw, protoBps, holders);
    }

    /// forge-config: default.fuzz.runs = 100000
    /// forge-config: default.fuzz.max-test-rejects = 100000000
    function test_fuzz_N0_zeroConverts(uint128 nav, uint128 supply) public pure {
        _n0(nav, supply);
    }

    /// forge-config: default.fuzz.runs = 100000
    /// forge-config: default.fuzz.max-test-rejects = 100000000
    function test_fuzz_N1_twoRedeemers(uint16 s1, uint16 s2, uint16 paid, uint16 burned) public pure {
        _n1(s1, s2, paid, burned);
    }

    /// forge-config: default.fuzz.runs = 100000
    /// forge-config: default.fuzz.max-test-rejects = 100000000
    function test_fuzz_N1p_twoRedeemersPlain(uint16 s1, uint16 s2, uint16 paid, uint16 burned) public pure {
        _n1p(s1, s2, paid, burned);
    }

    /// forge-config: default.fuzz.runs = 100000
    /// forge-config: default.fuzz.max-test-rejects = 100000000
    function test_fuzz_N2_partialFill(uint16 redShares, uint16 redAssets, uint16 available) public pure {
        _n2(redShares, redAssets, available);
    }

    /// forge-config: default.fuzz.runs = 100000
    /// forge-config: default.fuzz.max-test-rejects = 100000000
    function test_fuzz_N3_twoDepositors(uint16 d1, uint16 d2, uint16 depShares) public pure {
        _n3(d1, d2, depShares);
    }

    /// forge-config: default.fuzz.runs = 100000
    /// forge-config: default.fuzz.max-test-rejects = 100000000
    function test_fuzz_N4_redAssetsAtMostNav(uint32 shares, uint32 nav, uint32 supply) public pure {
        _n4(shares, nav, supply);
    }

    /// forge-config: default.fuzz.runs = 100000
    /// forge-config: default.fuzz.max-test-rejects = 100000000
    function test_fuzz_N5_mintNeverDilutes(uint32 a, uint32 nav, uint32 supply) public pure {
        _n5(a, nav, supply);
    }

    /// forge-config: default.fuzz.runs = 100000
    /// forge-config: default.fuzz.max-test-rejects = 100000000
    function test_fuzz_N6_redeemNeverDilutes(uint32 sh, uint32 nav, uint32 supply) public pure {
        _n6(sh, nav, supply);
    }

    /// forge-config: default.fuzz.runs = 100000
    /// forge-config: default.fuzz.max-test-rejects = 100000000
    function test_fuzz_N7_operatorCapMonotone32(uint32 a, uint32 b) public pure {
        _n7(a, b);
    }

    /// forge-config: default.fuzz.runs = 100000
    /// forge-config: default.fuzz.max-test-rejects = 100000000
    function test_fuzz_N8_protocolSplit(uint128 feeShares, uint16 bps) public pure {
        _n8(feeShares, bps);
    }
}
