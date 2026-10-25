// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {Test, Vm, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IGainsDiamondSpike as G} from "../spike/IGainsDiamondSpike.sol";
import {GainsSpikeTrader} from "../spike/GainsSpikeTrader.sol";

/// @dev Default Arbitrum One block for every Gains fork base (2026-10-22, the diamond after Gains' 2026-09 facet cuts).
///      GAINS_FORK_BLOCK (env) overrides it. The public RPC keeps ~10-20 min of state: pass a recent block there
///      (e.g. GAINS_FORK_BLOCK=$(( $(cast block-number --rpc-url $ARBITRUM_RPC_URL) - 40 ))) or use an archive RPC.
uint256 constant GAINS_FORK_BLOCK_DEFAULT = 517_076_707;

interface IArbSys {
    function arbBlockNumber() external view returns (uint256);
}

/// @notice Arbitrum One mainnet fork harness for Stage 0 (PLAN.md 7). Skips when ARBITRUM_RPC_URL is not set.
/// @dev Two fork-only shims, both outside Gains code:
///      1. ArbSys (0x64) does not exist in revm. Gains' ChainUtils.getBlockNumber() calls arbBlockNumber() on
///         chain 42161, so it is mocked to follow vm.roll.
///      2. Oracle fills: the diamond requests prices from its Chainlink operator nodes (getOracles()). We answer
///         by pranking each node and calling fulfill(requestId, packed answer), which is the call the node makes.
///         Packing per PackingUtils.unpackAggregatorAnswer: current | open<<56 | high<<112 | low<<168 | ts<<224.
abstract contract GainsForkBase is Test {
    /// @dev L2 block of the fork, set in setUp from _forkBlock() (or by _forkAt in a test).
    uint256 internal FORK_BLOCK;

    G internal constant DIAMOND = G(0xFF162c694eAA571f685030649814282eA457f169);
    IERC20 internal constant USDC = IERC20(0xaf88d065e77c8cC2239327C5EDb3A432268e5831);
    address internal constant GUSDC = 0xd3443ee1e91aF28e5FB858Fbd0D72A63bA8046E0;
    address internal constant ARB_SYS = address(100);

    uint8 internal constant USDC_INDEX = 3;
    uint16 internal constant BTC = 0;
    uint16 internal constant ETH = 1;
    uint16 internal constant SOL = 33;

    // PendingOrderType values used by the diamond (SDK enum stops at 6, see STAGE0.md)
    uint8 internal constant MARKET_OPEN = 0;
    uint8 internal constant MARKET_CLOSE = 1;

    GainsSpikeTrader internal trader;
    bool internal forked;
    /// @dev On an Arbitrum fork revm's block.number is the L1 block number; Gains reads L2 blocks via ArbSys.
    uint256 internal l1Start;

    function setUp() public virtual {
        if (bytes(vm.envOr("ARBITRUM_RPC_URL", string(""))).length == 0) {
            vm.skip(true);
            return;
        }
        _forkAt(_forkBlock());
        forked = true;

        trader = new GainsSpikeTrader(DIAMOND, USDC, address(this));
        vm.prank(GUSDC);
        USDC.transfer(address(trader), 1_000e6);
    }

    // ---------- chain helpers ----------

    /// @dev GAINS_FORK_BLOCK (env), else GAINS_FORK_BLOCK_DEFAULT. A child overrides it to pin its own block.
    function _forkBlock() internal view virtual returns (uint256) {
        return vm.envOr("GAINS_FORK_BLOCK", GAINS_FORK_BLOCK_DEFAULT);
    }

    /// @dev Forks at L2 block `block_` and points ArbSys at it. A test that asserts chain data at one block calls it
    ///      first (state of the setUp fork, e.g. `trader`, is not carried over).
    function _forkAt(uint256 block_) internal {
        FORK_BLOCK = block_;
        vm.createSelectFork("arbitrum", block_);
        l1Start = vm.getBlockNumber();
        vm.etch(ARB_SYS, hex"00");
        _mockArbBlock();
    }

    /// @dev L2 block number seen by the diamond: FORK_BLOCK plus every block rolled since setUp.
    function _arbBlock() internal view returns (uint256) {
        return FORK_BLOCK + (vm.getBlockNumber() - l1Start);
    }

    function _mockArbBlock() internal {
        vm.mockCall(ARB_SYS, abi.encodeWithSelector(IArbSys.arbBlockNumber.selector), abi.encode(_arbBlock()));
    }

    /// @dev Arbitrum produces ~4 blocks per second; advance time with blocks so oracle answers stay fresh.
    function _roll(uint256 blocks) internal {
        vm.roll(vm.getBlockNumber() + blocks);
        vm.warp(vm.getBlockTimestamp() + (blocks + 3) / 4);
        _mockArbBlock();
    }

    /// @dev GR2-KEY-01b minimum hold (WP5 port): the vault refuses the manager's and the agent's closes, reduces and
    ///      flattens within MIN_HOLD (10 min) of the pair's last new risk and MIN_HOLD_L2_BLOCKS (2,400) of the trade's
    ///      last increase. 2,700 L2 blocks advance _roll's clock by 675 s (11.25 min) and ArbSys by 2,700: past both.
    uint256 internal constant HOLD_BLOCKS = 2_700;

    /// @dev Waits out the minimum hold before a held exit. A base with frozen Chainlink mocks overrides it to refresh
    ///      them (_rollFresh); a test that needs stale feeds rolls blocks itself.
    function _passHold() internal virtual {
        _roll(HOLD_BLOCKS);
    }

    // ---------- oracle fill ----------

    function _packAnswer(uint64 price) internal view returns (uint256) {
        uint256 p = uint256(price);
        return p | (p << 56) | (p << 112) | (p << 168) | (uint256(uint32(vm.getBlockTimestamp())) << 224);
    }

    /// @dev OracleRequest(bytes32 indexed specId, address requester, bytes32 requestId, uint256 payment,
    ///      address callbackAddr, bytes4 callbackFunctionId, uint256 cancelExpiration, uint256 dataVersion, bytes data)
    ///      emitted by each Chainlink operator the diamond paid (one per node, nodesCount in PriceRequested).
    bytes32 internal constant ORACLE_REQUEST = keccak256(
        "OracleRequest(bytes32,address,bytes32,uint256,address,bytes4,uint256,uint256,bytes)"
    );

    /// @dev Answers every oracle request in `requestLogs` at `price`, each from the operator it was sent to
    ///      (msg.sender must be that operator, else SourceNotOracleOfRequest). Fills in the current block, so
    ///      a caller can read state (NavCalc) in the same block first. Returns the fill logs.
    function _fill(Vm.Log[] memory requestLogs, uint64 price) internal returns (Vm.Log[] memory fillLogs) {
        vm.recordLogs();
        uint256 answered;
        for (uint256 i; i < requestLogs.length; i++) {
            Vm.Log memory l = requestLogs[i];
            if (l.topics[0] != ORACLE_REQUEST) continue;
            (address requester, bytes32 requestId) = abi.decode(l.data, (address, bytes32));
            if (requester != address(DIAMOND)) continue;
            vm.prank(l.emitter);
            DIAMOND.fulfill(requestId, _packAnswer(price));
            answered++;
        }
        require(answered > 0, "no oracle request");
        fillLogs = vm.getRecordedLogs();
    }

    function _count(Vm.Log[] memory logs, bytes32 topic0) internal pure returns (uint256 n) {
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter == address(DIAMOND) && logs[i].topics[0] == topic0) n++;
        }
    }

    function _find(Vm.Log[] memory logs, bytes32 topic0) internal pure returns (Vm.Log memory l) {
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter == address(DIAMOND) && logs[i].topics[0] == topic0) return logs[i];
        }
        revert("log not found");
    }

    // ---------- trading helpers ----------

    function _trade(uint16 pairIndex, bool long, uint120 collateral, uint24 leverage, uint64 openPrice, uint8 tradeType)
        internal
        pure
        returns (G.Trade memory t)
    {
        t.pairIndex = pairIndex;
        t.long = long;
        t.isOpen = true;
        t.leverage = leverage;
        t.collateralIndex = USDC_INDEX;
        t.tradeType = tradeType;
        t.collateralAmount = collateral;
        t.openPrice = openPrice;
    }

    /// @dev Opens a market trade and returns the request logs. Index of the new pending order = counters before.
    function _requestOpen(uint16 pairIndex, bool long, uint120 collateral, uint24 leverage, uint64 price)
        internal
        returns (Vm.Log[] memory logs)
    {
        vm.recordLogs();
        trader.openTrade(_trade(pairIndex, long, collateral, leverage, price, 0), 1000); // 1% slippage
        logs = vm.getRecordedLogs();
    }

    /// @dev Opens and fills a market trade at `price`; returns the trade index.
    function _openFilled(uint16 pairIndex, bool long, uint120 collateral, uint24 leverage, uint64 price)
        internal
        returns (uint32 index)
    {
        Vm.Log[] memory req = _requestOpen(pairIndex, long, collateral, leverage, price);
        _roll(1);
        Vm.Log[] memory fill = _fill(req, price);
        Vm.Log memory l = _find(fill, G.MarketExecuted.selector);
        index = uint32(uint256(l.topics[2]));
    }

    /// @dev MarketExecuted / PositionSize*Executed / LeverageUpdateExecuted fields are read from these logs.
    function _decodeMarketExecuted(Vm.Log memory l)
        internal
        pure
        returns (G.Trade memory t, bool open, uint256 oraclePrice, uint256 marketPrice, uint256 amountSentToTrader)
    {
        (, t, open, oraclePrice, marketPrice,,,, amountSentToTrader,) = abi.decode(
            l.data, (G.Id, G.Trade, bool, uint256, uint256, uint256, G.TradePriceImpact, int256, uint256, uint256)
        );
    }

    function _openTrades() internal view returns (G.Trade[] memory) {
        return DIAMOND.getTrades(address(trader));
    }

    /// @dev Pair price in 1e10 from a Chainlink feed with `decimals` decimals.
    function _chainlink1e10(address feed) internal view returns (uint64) {
        (, int256 answer,,,) = IChainlinkFeed(feed).latestRoundData();
        uint8 dec = IChainlinkFeed(feed).decimals();
        return uint64(uint256(answer) * 1e10 / (10 ** dec));
    }
}

interface IChainlinkFeed {
    function decimals() external view returns (uint8);
    function description() external view returns (string memory);
    function getRoundData(uint80 roundId)
        external
        view
        returns (uint80, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}
