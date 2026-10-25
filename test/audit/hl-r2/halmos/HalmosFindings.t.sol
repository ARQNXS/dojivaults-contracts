// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {PxMath} from "../../../../src/libraries/PxMath.sol";

/// @title hl-r2 PoCs for the counterexamples Halmos found (forge tests, they pass while the behaviour exists)
contract HalmosFindingsTest is Test {
    /// HLR2-HAL01 (Info): PxMath.boundedLimitPx1e8 floors `rawMark * (BPS - slippageBps) / BPS` before rounding a sell
    /// UP to 5 significant figures. When the floored value already has 5 significant figures the round-up does
    /// nothing, and the sell limit lands up to one raw tick BELOW mark * (1 - slippage): the documented "never
    /// exceeds the slippage bound" is off by < 1 tick (here 0.91 of a tick, 1e-6 of the price). Counterexample from
    /// Halmos (check_H8), validated concretely: rawMark 1,090,708, slippage 1,682 bps, szDecimals 0, sell.
    function test_HLR2_HAL01_sellLimitBelowTheBandByLessThanOneTick() public pure {
        uint256 rawMark = 1_090_708;
        uint256 slip = 1_682;
        uint64 px = PxMath.boundedLimitPx1e8(rawMark, 0, false, slip);
        uint256 p = px / 1e2; // back to raw units (szDecimals 0)
        assertEq(p, 907_250);
        // exact bound: 1,090,708 * 0.8318 = 907,250.9144
        assertLt(p * 10_000, rawMark * (10_000 - slip), "below the exact band");
        assertGt((p + 1) * 10_000, rawMark * (10_000 - slip), "by less than one tick");
    }
}
