// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {Vm} from "forge-std/Vm.sol";
import {MAX_PAIR_SKEW_CAP_BPS} from "../../../src/gains/GainsTypes.sol";

interface IPairCapRead {
    function pairSkewCapBps(uint16 pair) external view returns (uint16);
}

/// @notice GR2-KEY-01b test helper for the fork suites (WP5 port). Fork tests that are not about the pair cap (NAV and
///         economics, GNS side effects, gas and lifecycle) open positions sized for the pre-cap vault, often above 1 %
///         of Gains' skew depth at the pinned block, and are refused OrderRejected("pair depth") at the launch cap.
///         The guardian may raise a pair's cap up to MAX_PAIR_SKEW_CAP_BPS (10 %) after PAIR_CAP_RAISE_DELAY (31 days,
///         queuePairSkewCap then executePairSkewCap). On a fork a 31-day warp breaks the Chainlink feed mocks, Gains'
///         oracle timestamps and the ArbSys mock, so the helper writes the end state of that raise straight into the
///         factory's storage: `_pairCap[pair]` = {bps: MAX_PAIR_SKEW_CAP_BPS, set: true, queuedBps: 0, eta: 0}.
/// @dev Slot of `mapping(uint16 pair => PairCap) _pairCap` in GainsVaultFactory, from
///      `forge inspect src/gains/GainsVaultFactory.sol:GainsVaultFactory storageLayout` (slot 21). PairCap packs
///      bps (uint16, bytes 0-1), set (bool, byte 2), queuedBps (uint16, bytes 3-4), eta (uint64, bytes 5-12) into one
///      word. The read-back through pairSkewCapBps catches a layout change.
library ForkPairCap {
    Vm private constant VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    uint256 internal constant PAIR_CAP_SLOT = 21;

    /// @return bps the cap read back through the factory (MAX_PAIR_SKEW_CAP_BPS, else it reverts)
    function raiseToMax(address factory, uint16 pair) internal returns (uint256 bps) {
        bytes32 slot = keccak256(abi.encode(uint256(pair), PAIR_CAP_SLOT));
        VM.store(factory, slot, bytes32(MAX_PAIR_SKEW_CAP_BPS | (uint256(1) << 16)));
        bps = IPairCapRead(factory).pairSkewCapBps(pair);
        require(bps == MAX_PAIR_SKEW_CAP_BPS, "ForkPairCap: _pairCap slot moved (forge inspect storageLayout)");
    }
}
