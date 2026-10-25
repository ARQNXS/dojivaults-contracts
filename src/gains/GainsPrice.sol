// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

/// @notice Chainlink Data Feed (AggregatorV3Interface subset).
interface IChainlinkFeed {
    function decimals() external view returns (uint8);
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

/// @title GainsPrice
/// @notice Chainlink reads for Gains vaults, the analog of the HyperCore mark price precompile (PLAN.md 4.1, 4.3).
///         One feed per pair with its own staleness limit and NAV band, behind the Arbitrum sequencer uptime feed.
/// @dev Every failure is a named revert: a stale, missing or broken feed reverts PriceStale(pairIndex), a sequencer
///      that is down or inside its grace period reverts SequencerDown(). Only NAV, deposits, settle and new risk
///      read prices; exits never do (PLAN.md section 1), so a stale feed freezes the first and never the second.
library GainsPrice {
    uint256 internal constant BPS = 10_000;
    /// @dev Gains prices are 1e10.
    uint8 internal constant PRICE_DECIMALS = 10;
    /// @dev Widest NAV band a curated pair may have (10%): a band is deviation threshold + measured spread.
    uint16 internal constant MAX_BAND_BPS = 1_000;
    /// @dev Highest price read accepts: the valuation price mid x (1 + MAX_BAND_BPS) still fits uint64 (GR1-24).
    uint256 internal constant MAX_PRICE = (uint256(type(uint64).max) * BPS) / (BPS + MAX_BAND_BPS);
    /// @dev Gas forwarded to a feed call: a feed that halts exceptionally burns this much, not 63/64 of the read's
    ///      gas, and the read still ends in PriceStale / SequencerDown (GR1-44). A Chainlink proxy needs ~20k.
    uint256 internal constant FEED_GAS = 200_000;

    /// @notice Per pair price config. One storage slot.
    /// @param feed Chainlink aggregator (USD quote)
    /// @param maxAge staleness limit in seconds: the feed heartbeat plus a margin
    /// @param bandBps NAV band B: feed deviation threshold + measured Chainlink vs Gains oracle spread (4.3)
    /// @param decimals the feed's decimals, read when the pair is configured and checked on every read (GR1-13)
    struct Feed {
        address feed;
        uint32 maxAge;
        uint16 bandBps;
        uint8 decimals;
    }

    error PriceStale(uint256 pairIndex);
    error SequencerDown();
    error NoPriceFeed(uint256 pairIndex);
    error SequencerGraceOutOfRange(uint256 gracePeriod);
    error SequencerFeedNotCurrent();

    /// @notice Bounds of the sequencer grace period, in the factory and in every policy (GV-03): long enough for the
    ///         feeds to catch up after an outage, never so long that a value set by mistake (or by a hostile cold key)
    ///         freezes every priced path for days. Exits never read a price.
    uint256 internal constant MIN_SEQUENCER_GRACE = 1 hours;
    uint256 internal constant MAX_SEQUENCER_GRACE = 1 days;

    function checkSequencerGrace(uint256 gracePeriod) internal pure {
        if (gracePeriod < MIN_SEQUENCER_GRACE || gracePeriod > MAX_SEQUENCER_GRACE) revert SequencerGraceOutOfRange(gracePeriod);
    }

    /// @notice Chainlink price of `pairIndex` in 1e10.
    /// @param sequencer L2 sequencer uptime feed (zero skips the check, for chains without one)
    /// @param gracePeriod seconds after the sequencer came back during which prices are not trusted
    function read(Feed memory f, address sequencer, uint256 gracePeriod, uint256 pairIndex)
        internal
        view
        returns (uint64 px1e10)
    {
        checkSequencer(sequencer, gracePeriod);
        if (f.feed == address(0)) revert NoPriceFeed(pairIndex);
        (bool ok, int256 answer,, uint256 updatedAt) = _latest(f.feed);
        if (!ok || answer <= 0 || updatedAt == 0 || updatedAt > block.timestamp || block.timestamp - updatedAt > f.maxAge) {
            revert PriceStale(pairIndex);
        }
        uint256 px = uint256(answer);
        if (f.decimals < PRICE_DECIMALS) {
            // checked before scaling: an absurd answer is PriceStale, never an arithmetic panic
            uint256 m = 10 ** (PRICE_DECIMALS - f.decimals);
            if (px > type(uint64).max / m) revert PriceStale(pairIndex);
            px *= m;
        } else if (f.decimals > PRICE_DECIMALS) {
            px /= 10 ** (f.decimals - PRICE_DECIMALS);
        }
        if (px == 0 || px > MAX_PRICE) revert PriceStale(pairIndex);
        // A proxy whose aggregator moved to other decimals would misprice by 10^k without a revert (GR1-13).
        if (_decimals(f.feed) != f.decimals) revert PriceStale(pairIndex);
        px1e10 = uint64(px);
    }

    /// @notice Reverts SequencerDown() while the Arbitrum sequencer is down, and for `gracePeriod` after it came back.
    /// @dev Chainlink's uptime feed: answer 0 = up, 1 = down; startedAt = when the status last changed. A round that
    ///      has not started (startedAt 0) is treated as down.
    function checkSequencer(address sequencer, uint256 gracePeriod) internal view {
        if (sequencer == address(0)) return;
        (bool ok, int256 answer, uint256 startedAt,) = _latest(sequencer);
        if (!ok || answer != 0 || startedAt == 0 || startedAt > block.timestamp || block.timestamp - startedAt <= gracePeriod) {
            revert SequencerDown();
        }
    }

    /// @notice Valuation price for a trade (4.3 step 4): the adverse edge of the band around the Chainlink price.
    function adverse(uint64 mid, uint16 bandBps, bool long) internal pure returns (uint64) {
        return long ? uint64((uint256(mid) * (BPS - bandBps)) / BPS) : uint64((uint256(mid) * (BPS + bandBps)) / BPS);
    }

    /// @dev A feed that reverts or returns malformed data reads as not ok (then PriceStale / SequencerDown), never as
    ///      a raw low-level revert the executor cannot decode.
    function _latest(address feed) private view returns (bool ok, int256 answer, uint256 startedAt, uint256 updatedAt) {
        bytes memory ret;
        (ok, ret) = feed.staticcall{gas: FEED_GAS}(abi.encodeCall(IChainlinkFeed.latestRoundData, ()));
        if (!ok || ret.length < 160) return (false, 0, 0, 0);
        (, answer, startedAt, updatedAt,) = abi.decode(ret, (uint80, int256, uint256, uint256, uint80));
    }

    /// @dev The feed's current decimals; type(uint256).max when the call fails or returns malformed data (then it
    ///      never equals the cached value and the read is PriceStale).
    function _decimals(address feed) private view returns (uint256) {
        (bool ok, bytes memory ret) = feed.staticcall{gas: FEED_GAS}(abi.encodeCall(IChainlinkFeed.decimals, ()));
        if (!ok || ret.length < 32) return type(uint256).max;
        return abi.decode(ret, (uint256));
    }
}
