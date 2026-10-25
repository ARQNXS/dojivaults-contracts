// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import "./KeysForkBase.sol";

/// @notice GR2-KEY-01: Gains v10 skew price impact is a linear "mark" on the pair's net OI. A thief who holds the agent
///         key (or the manager's) can trade the vault in and out while trading the other side from his own Gains
///         account, so his account sells high and buys low on the mark the vault moves. The vault's loss above its
///         normal round-trip cost reaches the thief, not only Gains LPs.
///         Formula (PriceImpactUtils.getTradeSkewPriceImpactP: (skew + size/2) / depth, /2, in %): with the vault
///         size V and the thief size A (USD), one cycle moves V * A / (200 * depthUsd) from the vault to the thief,
///         independent of the existing skew.
contract KeysSkewForkTest is KeysForkBase {
    struct Run {
        int256 vaultLoss; // USDC the vault ends with less than it started (flat to flat), signed
        int256 thiefPnl; // USDC the thief's own Gains account gained
    }

    /// @param n vault trades of `perTrade` notional each (25x), the thief one opposite trade of n * perTrade (50x)
    function _cycle(uint16 pair, uint256 n, uint256 perTrade, bool withThief, uint256 waitBlocks)
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
        uint32 tIdx;
        uint256 thief0 = 2_000_000e6;
        if (withThief) {
            t = _newTrader(thief0);
            tIdx = _openOutside(t, pair, false, uint120(n * perTrade / 50), 50_000, c);
        }
        for (uint256 i; i < n; ++i) {
            _closeVault(mgr, idx[i], c);
        }
        if (withThief) {
            if (waitBlocks > 0) _roll(waitBlocks);
            _closeOutside(t, tIdx, c);
            r.thiefPnl = int256(_usdc(address(t))) - int256(thief0);
        }
        r.vaultLoss = int256(vault0) - int256(_usdc(address(v)));
    }

    function _compare(uint16 pair, uint256 n, uint256 perTrade, uint256 waitBlocks)
        internal
        returns (Run memory base, Run memory attacked)
    {
        _depositSettle(alice, n * perTrade / 5 + 10_000e6); // the vault at 5x of NAV
        uint256 snap = vm.snapshotState();
        base = _cycle(pair, n, perTrade, false, 0);
        vm.revertToState(snap);
        _mockArbBlock(); // vm mocks survive revertToState: re-point ArbSys and the feeds at the reverted block
        _refreshCl();
        attacked = _cycle(pair, n, perTrade, true, waitBlocks);
        uint64 c = cl[_feed(pair)];
        uint256 depthUsd = IGainsExtraK(address(DIAMOND)).getPairSkewDepth(USDC_INDEX, pair) * c / 1e10 / 1e12; // 1e6
        uint256 vUsd = n * perTrade;
        console2.log("pair", pair, "skew depth (USDC 1e6)", depthUsd);
        console2.log("vault notional V = thief notional A (USDC 1e6)", vUsd);
        console2.log("predicted V*A/(200*depth) (USDC 1e6)", vUsd * vUsd / (200 * depthUsd));
        console2.log("vault round trip, no thief: loss (signed, 1e6) below");
        console2.logInt(base.vaultLoss);
        console2.log("vault round trip, thief inside: loss (signed, 1e6) below");
        console2.logInt(attacked.vaultLoss);
        console2.log("extra vault loss caused by the thief's trade (signed, 1e6) below");
        console2.logInt(attacked.vaultLoss - base.vaultLoss);
        console2.log("thief own-account PnL (signed, 1e6) below");
        console2.logInt(attacked.thiefPnl);
    }

    /// @dev Bound check, not an extraction: an opposite trade held across the vault's round trip adds an extra vault
    ///      loss bounded by the skew term V*A/(200*depthUsd) (measured 96.7% to 99.98% of it), and at the live per-order caps the opposite
    ///      account's own Gains costs exceed what it captures (net negative). The fix sizes against the skew term.
    function _assertBound(uint16 pair) internal {
        (Run memory base, Run memory att) = _compare(pair, 5, 250_000e6, 0);
        uint64 c = cl[_feed(pair)];
        uint256 depthUsd = IGainsExtraK(address(DIAMOND)).getPairSkewDepth(USDC_INDEX, pair) * c / 1e10 / 1e12;
        uint256 v = 5 * 250_000e6;
        int256 predicted = int256(v * v / (200 * depthUsd));
        int256 extra = att.vaultLoss - base.vaultLoss;
        assertGt(extra, 0, "the opposite trade makes the vault's round trip dearer");
        assertLe(extra, predicted + predicted / 100, "the skew term V*A/(200*depthUsd) bounds the extra vault loss");
        assertGe(extra, predicted * 90 / 100, "and is within 10% of it (measured 96.7% to 99.98%)");
        assertLt(att.thiefPnl, 0, "at the live caps the opposite account's own costs exceed the capture");
    }

    // ------------------------------------------------------------------ GR2-KEY-01 fix (KEY-01b), inverted PoCs
    // The PoCs test_GR2_KEY_01_skewTermBoundsExtraVaultLoss_{ETH,SOL,BTC} ran _assertBound(pair): a vault of 5 x 250k
    // (V = 1.25M) round trip with an opposite 1.25M trade. Measured pre-fix (KEYS.md, live depths): extra vault loss
    // BTC 239.62 / ETH 567.72 / SOL 1,855.95 USDC against a skew term of 239.67 / 567.91 / 1,919.18 (1.9 / 4.5 / 14.8 bps
    // of V); opposite account -760.38 / -432.25 / -329.50 USDC. On the fixed vault, with the guardian's 1 % launch caps,
    // all three FAILED at 517,076,707 with OrderRejected("pair depth") (WP5 fork2 log, fork2-all-fork.txt): ETH and SOL
    // at the first 250k order, BTC at the second. Inverted: the PoC's size is refused at the first order past the cap,
    // and the largest size the vault takes stays within 1 % of the skew depth, so the skew term V*A/(200*depth) at the
    // cap (A = V) is at most depth / 2,000,000 (about 7 USDC on ETH's 14.19M depth, vs 550 at the PoC's V on this block).
    // _assertBound and _compare are kept for the record (and for a raised-cap run).

    function test_GR2_KEY_01_fix_pairCapRefusesTheSkewRoundTrip_ETH() public {
        _depositSettle(alice, 5 * 250_000e6 / 5 + 10_000e6);
        _assertPairCapRefusesPoC(ETH, 5, 250_000e6);
    }

    function test_GR2_KEY_01_fix_pairCapRefusesTheSkewRoundTrip_SOL() public {
        _depositSettle(alice, 5 * 250_000e6 / 5 + 10_000e6);
        _assertPairCapRefusesPoC(SOL, 5, 250_000e6);
    }

    function test_GR2_KEY_01_fix_pairCapRefusesTheSkewRoundTrip_BTC() public {
        _depositSettle(alice, 5 * 250_000e6 / 5 + 10_000e6);
        _assertPairCapRefusesPoC(BTC, 5, 250_000e6);
    }
}
