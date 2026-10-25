// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import "./XReviewKeyForkBase.sol";

/// @notice Cross-review of GR2-KEY-01 (XREVIEW-KEY-EXE-FF.md). KEYS.md measured the skew capture at ONE size
///         (vault V = 5 x 250k = 1.25M, opposite A = 1.25M) and found the opposite account net negative on every pair;
///         it did not search for sizes where it comes out ahead. The live policy bounds the vault's notional only by
///         5 x NAV, 250k per order and 20 positions, with no per-pair limit: a 1M vault may hold 5M of SOL.
///         The opposite account's capture is V * A / (200 * depthUsd) (linear in V and in A; its own impact cancels
///         over its round trip), its cost is linear in A, so for a given pair it profits once V exceeds a break-even
///         size. Arithmetic from KEYS.md's SOL row: cost 2,185 USDC on 1.25M (17.5 bps), capture 96.7 % of the term,
///         depth 4.07M  ->  V* = 0.001748 * 200 * 4.07M / 0.967 = 1.47M of SOL.
///         Run: GAINS_FORK_BLOCK=$(cast block-number --rpc-url $ARBITRUM_RPC_URL) forge test --match-path <this file>
///         (XR_FORK_BLOCK, if set, overrides GAINS_FORK_BLOCK; unset, the GAINS_FORK_BLOCK_DEFAULT pin)
contract XReviewKeySkewForkTest is XReviewKeyForkBase {
    struct Run {
        int256 vaultLoss; // USDC the vault ends with less than it started (flat to flat)
        int256 thiefPnl; // the opposite account's USDC result
    }

    /// @param n vault trades of `perTrade` (25x, the agent / manager key); the opposite account holds `chunks` shorts of
    ///        `aEach` (50x) across the vault's round trip, all fills at one oracle price
    function _cycle(uint16 pair, uint256 n, uint256 perTrade, uint256 chunks, uint256 aEach, bool withThief)
        internal
        returns (Run memory r)
    {
        uint64 c = cl[_feed(pair)];
        uint256 vault0 = _usdc(address(v));
        uint32[] memory idx = new uint32[](n);
        for (uint256 i; i < n; ++i) {
            idx[i] = _openVault(mgr, pair, true, uint120(perTrade / 25), 25_000, c);
        }
        GainsSpikeTrader t;
        uint32[] memory tIdx = new uint32[](chunks);
        uint256 thief0 = 2_000_000e6;
        if (withThief) {
            t = _newTrader(thief0);
            for (uint256 j; j < chunks; ++j) {
                tIdx[j] = _openOutside(t, pair, false, uint120(aEach / 50), 50_000, c);
            }
        }
        for (uint256 i; i < n; ++i) {
            _closeVault(mgr, idx[i], c);
        }
        if (withThief) {
            for (uint256 j; j < chunks; ++j) {
                _closeOutside(t, tIdx[j], c);
            }
            r.thiefPnl = int256(_usdc(address(t))) - int256(thief0);
        }
        r.vaultLoss = int256(vault0) - int256(_usdc(address(v)));
    }

    function _run(uint16 pair, uint256 n, uint256 chunks, uint256 aEach)
        internal
        returns (int256 extra, int256 term, int256 thiefPnl)
    {
        uint256 perTrade = 250_000e6;
        _depositSettle(alice, n * perTrade / 5 + 60_000e6); // the vault at ~5x of NAV
        uint256 snap = vm.snapshotState();
        Run memory base = _cycle(pair, n, perTrade, 0, 0, false);
        vm.revertToState(snap);
        _mockArbBlock();
        _refreshCl();
        Run memory att = _cycle(pair, n, perTrade, chunks, aEach, true);
        uint64 c = cl[_feed(pair)];
        uint256 depthUsd = IGainsExtraK(address(DIAMOND)).getPairSkewDepth(USDC_INDEX, pair) * c / 1e10 / 1e12;
        uint256 vUsd = n * perTrade;
        uint256 aUsd = chunks * aEach;
        extra = att.vaultLoss - base.vaultLoss;
        term = int256(vUsd * aUsd / (200 * depthUsd));
        thiefPnl = att.thiefPnl;
        console2.log("pair / skew depth (USDC 1e6)", pair, depthUsd);
        console2.log("vault notional V / opposite notional A (USDC 1e6)", vUsd, aUsd);
        console2.log("vault NAV before (USDC 1e6)", _nav());
        console2.log("term V*A/(200*depth) (USDC 1e6)", uint256(term));
        console2.log("vault round trip alone, loss (signed 1e6) / with the opposite account / extra:");
        console2.logInt(base.vaultLoss);
        console2.logInt(att.vaultLoss);
        console2.logInt(extra);
        console2.log("opposite account PnL (signed 1e6):");
        console2.logInt(thiefPnl);
    }

    // ------------------------------------------------------------------ GR2-KEY-01 fix (KEY-01b), inverted PoCs
    // XR_05..08 ran _run(pair, n, chunks, aEach): a vault of n x 250k on one pair round-tripped against an opposite
    // account. Measured pre-fix: XR_05 SOL V = A = 1.5M (bound only); XR_06 SOL V = A = 2M, extra vault loss 4,703 of a
    // 4,883 term (block 516,418,885); XR_07 SOL V = A = 3M, 10,334 of 10,986; XR_08 ETH V = A = 5M, extra 9,038 / 9,045
    // (term 9,047 / 9,054) and the opposite account +5,036 / +5,043 USDC (blocks 516,416,592 / 516,418,885). On the
    // fixed vault, with the guardian's 1 % launch caps, all four FAILED at 517,076,707 with OrderRejected("pair depth")
    // at the first 250k order (WP5 fork2 log, fork2-all-fork.txt). Inverted: the PoC's vault size is refused at the
    // first order past the cap and the largest size the vault takes stays within 1 % of the pair's skew depth (the
    // opposite account's capture at the cap is analysed on the real diamond in fixes/KEY01bForkFixTest).
    // _cycle and _run are kept for the record (and for a raised-cap run).

    /// @dev XR_05: near KEYS.md's break-even estimate, V = 1.5M of SOL (6 x 250k).
    function test_GR2_XR_05_fix_pairCapRefusesV1_5M_SOL() public {
        _depositSettle(alice, 6 * 250_000e6 / 5 + 60_000e6);
        _assertPairCapRefusesPoC(SOL, 6, 250_000e6);
    }

    /// @dev XR_06: SOL above the break-even, V = 2M (8 x 250k, a 400k vault at 5x).
    function test_GR2_XR_06_fix_pairCapRefusesV2M_SOL() public {
        _depositSettle(alice, 8 * 250_000e6 / 5 + 60_000e6);
        _assertPairCapRefusesPoC(SOL, 8, 250_000e6);
    }

    /// @dev XR_07: SOL, V = 3M (12 x 250k, a 600k vault at 5x).
    function test_GR2_XR_07_fix_pairCapRefusesV3M_SOL() public {
        _depositSettle(alice, 12 * 250_000e6 / 5 + 60_000e6);
        _assertPairCapRefusesPoC(SOL, 12, 250_000e6);
    }

    /// @dev XR_08: ETH at the old live caps on a 1M vault, all 20 positions (V = 5M), where the opposite account came
    ///      out ahead.
    function test_GR2_XR_08_fix_pairCapRefusesV5M_ETH() public {
        _depositSettle(alice, 20 * 250_000e6 / 5 + 60_000e6);
        _assertPairCapRefusesPoC(ETH, 20, 250_000e6);
    }
}
