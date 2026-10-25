// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import "../XReviewKeyForkBase.sol";
import {PAIR_CAP_RAISE_DELAY} from "../../../../../src/gains/GainsTypes.sol";

interface ISkewK {
    function getPairSkewDepth(uint8 collateralIndex, uint16 pairIndex) external view returns (uint256);
    function getPairOiAfterV10Token(uint8 collateralIndex, uint16 pairIndex) external view returns (uint128, uint128);
}

/// @notice GR2-KEY-01b fork tests (contracts/audit/gains/r2/fixes/GR2-KEY-01b, FIX-DESIGN.md section A/B). Real gTrade
///         v10 diamond on an Arbitrum fork, oracle answered at one price per step (the XR_08 harness). Run from
///         contracts/test/audit/gains/r2/fixes/ of a scratch tree with
///         ARBITRUM_RPC_URL=https://arb1.arbitrum.io/rpc GAINS_FORK_BLOCK=$(( $(cast block-number --rpc-url $ARBITRUM_RPC_URL) - 40 ))
///         (or the GAINS_FORK_BLOCK_DEFAULT pin on an archive RPC; XR_FORK_BLOCK, if set, overrides GAINS_FORK_BLOCK).
///
///         The thief's best route at the per-pair cap V = f x depth is a DOUBLE swing: the vault opens long V, the
///         thief opens a short flagged isCounterTrade (it lowers the pair's skew, so Gains charges it
///         getPairCounterTradeFeeRateMultiplier = 0.429 x the ETH fee, live), the vault closes the long and opens a
///         short V, the thief closes. His skew capture is 2 V A / (200 depth) = f / 100 of A (5 bps at f = 5 %), his
///         round trip costs 2 x 3.5 bps x 0.429 + 1 bp spread = 4.0 bps of A: positive at f = 5 % with no fee tier at all.
///         Every step waits WAIT_L2_BLOCKS (650 s), longer than KEY-01b's minimum hold: the hold changes nothing in the
///         thief's expected PnL (one oracle price throughout), which is the point FIX-DESIGN.md B makes.
///
///         Revision 2 (per-pair factory cap): the factory's guardian sets BTC / ETH / SOL to 1 % (the first setting is
///         immediate). KEY01B_CAP_BPS (default 100) sets ETH's cap for the run: above 100 the guardian queues the raise,
///         the fork warps PAIR_CAP_RAISE_DELAY, the guardian executes it, and a fresh vault is launched (the first
///         vault's epoch is overdue after the warp). So one tree measures the route at 1 %, 5 % and 10 % on one block.
contract KEY01bForkFixTest is XReviewKeyForkBase {
    uint256 internal constant WAIT_L2_BLOCKS = 2_600; // _roll warps (blocks + 3) / 4 s = 650 s
    uint16 internal capBps;

    function setUp() public override {
        super.setUp();
        if (!forked) return;
        capBps = uint16(vm.envOr("KEY01B_CAP_BPS", uint256(100)));
        vm.startPrank(fGuardian);
        factory.setPairSkewCap(BTC, 100);
        factory.setPairSkewCap(ETH, 100);
        factory.setPairSkewCap(SOL, 100);
        if (capBps < 100) factory.setPairSkewCap(ETH, capBps);
        vm.stopPrank();
        if (capBps > 100) {
            vm.prank(fGuardian);
            factory.queuePairSkewCap(ETH, capBps);
            vm.warp(vm.getBlockTimestamp() + PAIR_CAP_RAISE_DELAY);
            _mockArbBlock();
            _refreshCl();
            vm.prank(fGuardian);
            factory.executePairSkewCap(ETH);
            (v, pol) = _create(bytes32(uint256(2)));
            vm.prank(alice);
            USDC.approve(address(v), type(uint256).max);
        }
        assertEq(factory.pairSkewCapBps(ETH), capBps, "ETH cap for this run");
    }

    function _depthUsd(uint16 pair, uint64 c) internal view returns (uint256) {
        return ISkewK(address(DIAMOND)).getPairSkewDepth(USDC_INDEX, pair) * c / 1e22;
    }

    /// @dev Signed pair skew in USDC (1e6) at price c: long minus short open interest (v10 tokens).
    function _skewUsd(uint16 pair, uint64 c) internal view returns (int256) {
        (uint128 l, uint128 s) = ISkewK(address(DIAMOND)).getPairOiAfterV10Token(USDC_INDEX, pair);
        return (int256(uint256(l)) - int256(uint256(s))) * int256(uint256(c)) / 1e22;
    }

    function _openThief(GainsSpikeTrader t, uint16 pair, bool long, uint120 coll, uint24 lev, uint64 px, bool counter)
        internal
        returns (uint32 idx)
    {
        G.Trade memory tr = _gtrade(pair, long, coll, lev, px);
        tr.isCounterTrade = counter;
        vm.recordLogs();
        t.openTrade(tr, 1_000);
        Vm.Log[] memory req = vm.getRecordedLogs();
        _roll(1);
        Vm.Log[] memory fill = _fill(req, px);
        idx = uint32(uint256(_find(fill, G.MarketExecuted.selector).topics[2]));
    }

    function _openMany(bool long, uint256 n, uint256 perTrade, uint64 c) internal returns (uint32[] memory idx) {
        idx = new uint32[](n);
        for (uint256 i; i < n; ++i) {
            idx[i] = _openVault(mgr, ETH, long, uint120(perTrade / 25), 25_000, c);
        }
    }

    /// @return thiefPnl the opposite account's USDC result over its round trip
    /// @return term 2 V A / (200 depth), the skew capture the model predicts
    function _doubleSwing(bool counter) internal returns (int256 thiefPnl, uint256 term, uint256 vUsd, uint256 aUsd) {
        uint64 c = cl[_feed(ETH)];
        uint256 depth = _depthUsd(ETH, c);
        uint256 cap = depth * capBps / 10_000;
        uint256 n = cap / 250_000e6 + 1;
        uint256 perTrade = cap * 98 / 100 / n;
        vUsd = perTrade * n;
        _depositSettle(alice, vUsd / 4 + 20_000e6);

        // WP5 port: the vault's first leg goes the way the pair is already skewed, so the skew it leaves is the
        // largest the cap allows on the pinned block. At 517,076,707 ETH is skewed short (-25.4 ETH, about -63k USDC)
        // and the 1 % cap is about 139k: a first long would leave only about +76k, below the 100k a counter trade
        // needs, so the route is run mirrored (vault short, thief long). The capture term 2 V A / (200 depth) and the
        // fees are the same on either side.
        int256 skew0 = _skewUsd(ETH, c);
        bool vaultLong = skew0 >= 0;
        uint32[] memory first = _openMany(vaultLong, n, perTrade, c);
        int256 skew = _skewUsd(ETH, c);
        console2.log("ETH depth / cap / vault V (USDC 1e6)", depth, cap, vUsd);
        console2.log("ETH skew before / after the vault's first leg (signed USDC 1e6), vault long first:", vaultLong);
        console2.logInt(skew0);
        console2.logInt(skew);
        uint256 absSkew = skew >= 0 ? uint256(skew) : uint256(-skew);
        require(absSkew > 100_000e6, "pair skew too small for a counter trade on this block");
        aUsd = absSkew * 95 / 100;
        if (aUsd > vUsd) aUsd = vUsd;
        aUsd = aUsd / 1e6 * 1e6;

        uint256 thief0 = 1_000_000e6;
        GainsSpikeTrader t = _newTrader(thief0);
        // counter max leverage ETH: 10x; the thief takes the side that lowers the skew
        uint32 ti = _openThief(t, ETH, !vaultLong, uint120(aUsd / 10), 10_000, c, counter);

        _roll(WAIT_L2_BLOCKS);
        for (uint256 i; i < n; ++i) {
            _closeVault(mgr, first[i], c);
        }
        _openMany(!vaultLong, n, perTrade, c);
        _closeOutside(t, ti, c);
        thiefPnl = int256(_usdc(address(t))) - int256(thief0);
        term = 2 * vUsd * aUsd / (200 * depth);
        console2.log("cap bps of depth / thief A (USDC 1e6) / counter flag", capBps, aUsd, counter ? 1 : 0);
        console2.log("capture term 2VA/(200 depth) (USDC 1e6)", term);
        console2.log("thief PnL (signed USDC 1e6):");
        console2.logInt(thiefPnl);
    }

    /// @dev The thief's best route at the cap. At f = 5 % and 10 % it nets a profit with the counter-trade fee alone
    ///      (capture 5 / 10 bps against a 4.0 bps round trip); at f = 1 % (the default) the same route loses.
    function test_KEY01b_fork_doubleSwingCounterTrade_atTheCap() public {
        (int256 pnl, uint256 term,, uint256 aUsd) = _doubleSwing(true);
        if (capBps >= 500) {
            assertGt(pnl, 0, "at 5 % of depth or more the counter-trade double swing is profitable");
        } else {
            assertLe(capBps, 100, "the loss is asserted at 1 % or below");
            assertLt(pnl, 0, "at the KEY-01b cap the thief's best route loses");
            // and by more than a third of the capture: cost 4.0 bps vs capture f / 100
            assertLt(pnl + int256(term) / 3, 0, "with margin");
        }
        assertGt(aUsd, 0, "thief traded");
    }

    /// @dev Control: the same route without the counter-trade flag pays the full fee (8 bps round trip): it loses at
    ///      1 % and 5 %, and at 10 % it is about even (capture 10 bps against 8.0), so only the PnL is logged there.
    function test_KEY01b_fork_doubleSwingPlainTrade_losesAtEitherCap() public {
        (int256 pnl,,,) = _doubleSwing(false);
        if (capBps <= 500) assertLt(pnl, 0, "without the counter-trade discount the route loses");
    }

    /// @dev XR_08's vault side at the KEY-01b cap: 250k ETH longs from a ~1M vault. The first order past ETH's cap of its
    ///      depth is refused "pair depth".
    function test_KEY01b_fork_XR08_ethOpensRefusedAtTheCap() public {
        uint256 perTrade = 250_000e6;
        _depositSettle(alice, 20 * perTrade / 5 + 60_000e6);
        uint64 c = cl[_feed(ETH)];
        uint256 capUsd = _depthUsd(ETH, c) * capBps / 10_000;
        uint256 opened;
        bool refused;
        for (uint256 i; i < 20; ++i) {
            vm.recordLogs();
            vm.prank(mgr);
            (bool ok, bytes memory ret) =
                address(v).call(abi.encodeCall(GainsVault.openTrade, (_params(ETH, true, uint120(perTrade / 25), 25_000))));
            Vm.Log[] memory req = vm.getRecordedLogs();
            if (!ok) {
                assertEq(ret, abi.encodeWithSignature("OrderRejected(string)", "pair depth"), "refused by the pair cap");
                refused = true;
                break;
            }
            _roll(1);
            _fill(req, c);
            opened += perTrade;
        }
        console2.log("cap (USDC 1e6) / opened before the refusal", capUsd, opened);
        assertTrue(refused, "refused before XR_08's 5M");
        assertLe(opened, capUsd, "never above the cap");
        assertGt(opened + perTrade, capUsd, "refused at the first order past the cap");
    }

    /// @dev KEY-01b only: the manager's close inside the minimum hold is refused "min hold" on the real diamond (the
    ///      trade's Gains lastPosIncreaseBlock is read in ArbSys L2 blocks); the guardian's close is not; after the hold
    ///      the manager's close goes through.
    function test_KEY01b_fork_minHoldOnTheRealDiamond() public {
        _depositSettle(alice, 100_000e6);
        uint64 c = cl[_feed(ETH)];
        uint32 a = _openVault(mgr, ETH, true, uint120(50_000e6 / 25), 25_000, c);
        uint32 b = _openVault(mgr, ETH, true, uint120(50_000e6 / 25), 25_000, c);
        vm.prank(mgr);
        vm.expectRevert(abi.encodeWithSignature("OrderRejected(string)", "min hold"));
        v.closeTrade(a, c);
        _closeVault(fGuardian, b, c); // platform exits are never held
        _roll(WAIT_L2_BLOCKS);
        _closeVault(mgr, a, c);
    }
}
