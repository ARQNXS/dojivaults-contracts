// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/// @title PxMath
/// @notice Price helpers for HyperCore perps.
/// @dev HyperCore accepts perp prices with at most 5 significant figures and at most (6 - szDecimals)
///      decimals. Integer prices are always valid. Raw precompile mark prices already carry exactly
///      (6 - szDecimals) decimals, so rounding the raw integer to 5 significant figures yields a valid tick.
library PxMath {
    uint256 internal constant BPS = 10_000;

    /// @notice Rounds `raw` (a price in raw precompile units) to 5 significant figures.
    /// @param up Round up when true, down when false.
    function toSigFigs5(uint256 raw, bool up) internal pure returns (uint256) {
        if (raw < 100_000) return raw;
        uint256 unit = 1;
        uint256 v = raw;
        while (v >= 100_000) {
            v /= 10;
            unit *= 10;
        }
        uint256 floored = (raw / unit) * unit;
        if (up && floored < raw) return floored + unit;
        return floored;
    }

    /// @notice Builds an aggressive but bounded limit price (1e8 scale) for an IOC order.
    /// @param rawMark raw precompile mark price, (6 - szDecimals) decimals
    /// @param szDecimals asset size decimals
    /// @param isBuy order side
    /// @param slippageBps max distance from mark
    function boundedLimitPx1e8(uint256 rawMark, uint8 szDecimals, bool isBuy, uint256 slippageBps)
        internal
        pure
        returns (uint64)
    {
        uint256 bounded = isBuy ? (rawMark * (BPS + slippageBps)) / BPS : (rawMark * (BPS - slippageBps)) / BPS;
        // Buys round down and sells round up so the price never exceeds the slippage bound.
        uint256 rounded = toSigFigs5(bounded, !isBuy);
        if (rounded == 0) rounded = 1;
        return SafeCast.toUint64(rounded * 10 ** (2 + szDecimals));
    }

    /// @notice Converts a position size (szDecimals units) to 1e8 scale.
    function size1e8(uint256 absSzi, uint8 szDecimals) internal pure returns (uint64) {
        return SafeCast.toUint64(absSzi * 10 ** (8 - szDecimals));
    }
}
