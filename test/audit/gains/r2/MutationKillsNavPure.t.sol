// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {GainsNav} from "../../../../src/gains/GainsNav.sol";

/// @notice Round 2 mutation kills for GainsNav's pure helpers. They are INLINED into this test contract, so the
///         artifact-swap driver excludes this file for mutants of those lines (run_mut.py EXCL) and the kills are
///         proven with an honest full compile of the mutated tree (mutation/honest.py).
contract MutationKillsNavPureTest is Test {
    int256 internal constant P_10 = 1e10;

    /// Nav#621 (pnlPercent `if (openPrice == 0) return 0` -> never): a zero open price is a 0% pnl, not a division
    /// by zero that would make the whole NAV read revert.
    function test_MUT_Nav621_zeroOpenPriceIsZeroPnl() public pure {
        assertEq(GainsNav.pnlPercent(0, 3_000e10, true, 10_000), 0);
        assertEq(GainsNav.pnlPercent(0, 3_000e10, false, 10_000), 0);
    }

    /// Nav#680 (`minP = ~100 * P_10`, i.e. -101%), #682 (`if (false) p = minP`), #690 (clamp deleted), #691
    /// (`p = 0`): a loss beyond -100% is clamped to exactly -100% (Gains' getPnlPercent).
    function test_MUT_Nav680_682_690_691_lossClampedAtMinus100() public pure {
        // 10x long, price -99%: raw -990%
        assertEq(GainsNav.pnlPercent(100e10, 1e10, true, 10_000), -100 * P_10);
        // 10x short, price x3: raw -2000%
        assertEq(GainsNav.pnlPercent(100e10, 300e10, false, 10_000), -100 * P_10);
        // inside the range: unclamped
        assertEq(GainsNav.pnlPercent(100e10, 95e10, true, 10_000), -50 * P_10);
    }

    /// Nav#733 (priceAfterImpact `if (raw <= 0) return 0` -> never): an impact below -100% gives price 0 (no wrap
    /// to a huge uint and no saturation to type(uint64).max, which would value a long at its maximum).
    function test_MUT_Nav733_negativePriceIsZero() public pure {
        assertEq(GainsNav.priceAfterImpact(1e10, -200 * P_10), 0);
        assertEq(GainsNav.priceAfterImpact(1e10, -100 * P_10), 0);
    }
}
