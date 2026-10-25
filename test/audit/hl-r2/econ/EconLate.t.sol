// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {console2} from "forge-std/console2.sol";
import {EconBase} from "./EconBase.t.sol";
import {BreachReason} from "../../../../src/VaultTypes.sol";

/// @notice HLR2-E07: a Core -> EVM transfer that lands later than MAX_UNLANDED_BLOCKS (300 blocks, ~5 min on small
///         blocks) is read as a loss (documented R3-08 trade-off). The consequence quantified: the phantom loss
///         breaches the vault, and the redemption-only settle the operator's planner runs automatically in a loss
///         breach pays the redeemers at the NAV that misses the USDC in transit. When it lands, the stayers keep it.
contract HlR2LateLanding is EconBase {
}
