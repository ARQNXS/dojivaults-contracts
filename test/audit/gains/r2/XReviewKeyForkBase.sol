// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {Test, Vm, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IGainsDiamondSpike as G} from "../../../gains/spike/IGainsDiamondSpike.sol";
import {GainsSpikeTrader} from "../../../gains/spike/GainsSpikeTrader.sol";
import {GainsVault} from "../../../../src/gains/GainsVault.sol";
import {GainsVaultFactory} from "../../../../src/gains/GainsVaultFactory.sol";
import {GainsVaultPolicy} from "../../../../src/gains/GainsVaultPolicy.sol";
import {IGainsDiamond} from "../../../../src/gains/IGainsDiamond.sol";
import {MAX_PAIR_SKEW_CAP_BPS, OpenParams} from "../../../../src/gains/GainsTypes.sol";
import {ForkPairCap} from "../../../gains/fork/ForkPairCap.sol";
import {GAINS_FORK_BLOCK_DEFAULT} from "../../../gains/fork/GainsForkBase.sol";

interface IArbSysK {
    function arbBlockNumber() external view returns (uint256);
}

interface IFeedK {
    function decimals() external view returns (uint8);
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);
}

interface IGainsExtraK {
    function getPairSkewDepth(uint8 collateralIndex, uint16 pairIndex) external view returns (uint256);
    function getPairOiAfterV10Token(uint8 collateralIndex, uint16 pairIndex) external view returns (uint128, uint128);
    function getTraderActiveReferrer(address trader) external view returns (address);
    function registerPotentialReferrer(address trader, address referrer) external;
    function triggerOrder(uint256 packed) external;
    function getChainlinkToken() external view returns (address);
}

/// @notice Round 2 cross-review (XR-KEY): KeysForkBase with the fork block taken from XR_FORK_BLOCK (or GAINS_FORK_BLOCK),
///         otherwise unchanged. Round 2, domain KEY (compromised keys). Arbitrum One fork at a block >= 516,000,000 with the real gTrade
///         v10 diamond; oracle answers emulated by pranking the diamond's Chainlink operator nodes (the harness of
///         test/gains/fork/GainsForkBase.sol, copied). Vault created through a
///         fresh factory with the LIVE policy shape (5x, 15% daily loss, 50% drawdown, 3% slippage, 250k per order,
///         1 day epoch, 20% NAV move, 3% flatten). Skips without ARBITRUM_RPC_URL.
abstract contract XReviewKeyForkBase is Test {
    /// @dev XR_FORK_BLOCK, else GAINS_FORK_BLOCK (env), else GAINS_FORK_BLOCK_DEFAULT. The public RPC keeps
    ///      ~10-20 min of state, so a pinned block must be recent (or use an archive RPC).
    uint256 internal FORK_BLOCK;

    G internal constant DIAMOND = G(0xFF162c694eAA571f685030649814282eA457f169);
    IGainsDiamond internal constant D = IGainsDiamond(address(0xFF162c694eAA571f685030649814282eA457f169));
    IERC20 internal constant USDC = IERC20(0xaf88d065e77c8cC2239327C5EDb3A432268e5831);
    address internal constant GUSDC = 0xd3443ee1e91aF28e5FB858Fbd0D72A63bA8046E0;
    address internal constant ARB_SYS = address(100);
    address internal constant BTC_USD = 0x6ce185860a4963106506C203335A2910413708e9;
    address internal constant ETH_USD = 0x639Fe6ab55C921f74e7fac1ee960C0B6293ba612;
    address internal constant SOL_USD = 0x24ceA4b8ce57cdA5058b924B9B9987992450590c;
    address internal constant SEQ = 0xFdB631F5EE196F0ed6FAa767959853A9F217697D;
    uint8 internal constant USDC_INDEX = 3;
    uint16 internal constant BTC = 0;
    uint16 internal constant ETH = 1;
    uint16 internal constant SOL = 33;
    bytes32 internal constant ORACLE_REQUEST =
        keccak256("OracleRequest(bytes32,address,bytes32,uint256,address,bytes4,uint256,uint256,bytes)");

    bool internal forked;
    uint256 internal l1Start;

    GainsVaultFactory internal factory;
    GainsVault internal v;
    GainsVaultPolicy internal pol;

    address internal fOwner = makeAddr("fOwner"); // = guardian on the live deployment; kept apart here
    address internal fGuardian = makeAddr("fGuardian");
    address internal fSentinel = makeAddr("fSentinel");
    address internal treasury = makeAddr("treasury");
    address internal creator = makeAddr("creator"); // vault owner
    address internal mgr = makeAddr("mgr"); // trading powers identical to the agent's (ACCESS-MATRIX)
    address internal keeper = makeAddr("keeper"); // operator
    address internal alice = makeAddr("alice");
    address internal thief = makeAddr("thief");

    mapping(address feed => uint64) internal cl;

    function setUp() public virtual {
        if (bytes(vm.envOr("ARBITRUM_RPC_URL", string(""))).length == 0) {
            vm.skip(true);
            return;
        }
        // e.g. GAINS_FORK_BLOCK=$(cast block-number --rpc-url $ARBITRUM_RPC_URL): the Arbitrum (L2) block number
        FORK_BLOCK = vm.envOr("XR_FORK_BLOCK", vm.envOr("GAINS_FORK_BLOCK", GAINS_FORK_BLOCK_DEFAULT));
        require(FORK_BLOCK >= 516_000_000, "set GAINS_FORK_BLOCK to a recent Arbitrum block");
        vm.createSelectFork("arbitrum", FORK_BLOCK);
        console2.log("XR fork block", FORK_BLOCK);
        forked = true;
        l1Start = vm.getBlockNumber();
        vm.etch(ARB_SYS, hex"00");
        _mockArbBlock();
        _setCl(BTC_USD, _round(_chainlink1e10(BTC_USD)));
        _setCl(ETH_USD, _round(_chainlink1e10(ETH_USD)));
        _setCl(SOL_USD, _round(_chainlink1e10(SOL_USD)));

        GainsVault impl = new GainsVault();
        GainsVaultPolicy pimpl = new GainsVaultPolicy();
        factory = new GainsVaultFactory(
            fOwner, address(impl), address(pimpl), USDC, D, SEQ, 3_600, treasury, fGuardian, fSentinel
        );
        vm.startPrank(fOwner);
        factory.setLauncherAllowed(creator, true);
        factory.setAssetCurated(BTC, true, BTC_USD, 2_655, 20);
        factory.setAssetCurated(ETH, true, ETH_USD, 2_655, 20);
        factory.setAssetCurated(SOL, true, SOL_USD, 88_200, 25);
        factory.setMaxDepositCap(type(uint256).max);
        vm.stopPrank();
        // GR2-KEY-01b (WP5 port): the guardian sets the launch caps, 1 % of skew depth on BTC, ETH and SOL, as the
        // deploy does (docs/fix-round/DEPLOY-R2.md 3.5). Without them a factory vault takes no new exposure.
        vm.startPrank(factory.guardian());
        factory.setPairSkewCap(uint16(BTC), 100);
        factory.setPairSkewCap(uint16(ETH), 100);
        factory.setPairSkewCap(uint16(SOL), 100);
        vm.stopPrank();

        deal(address(USDC), creator, 10e6);
        deal(address(USDC), alice, 5_000_000e6);
        (v, pol) = _create(bytes32(uint256(1)));
        vm.prank(alice);
        USDC.approve(address(v), type(uint256).max);
    }

    function _create(bytes32 salt) internal returns (GainsVault vault, GainsVaultPolicy p) {
        uint32[] memory assets = new uint32[](3);
        assets[0] = BTC;
        assets[1] = ETH;
        assets[2] = SOL;
        vm.prank(creator);
        USDC.approve(address(factory), 1e6);
        vm.prank(creator);
        (address va, address pa) = factory.create(
            GainsVaultFactory.CreateParams({
                name: "Gains KEY Vault",
                symbol: "gKEY",
                owner: creator,
                manager: mgr,
                feeRecipient: creator,
                managementFeeBps: 200,
                performanceFeeBps: 2_000,
                timelockDelay: 2 days,
                depositCap: 100_000_000e6,
                risk: _livePolicy(),
                assets: assets,
                agent: address(0),
                agentSig: "",
                agentDeadline: 0,
                operator: keeper,
                hosted: false,
                seedUsdc: 1e6,
                salt: salt
            }),
            GainsVaultFactory.PermitData(0, 0, 0, bytes32(0), bytes32(0))
        );
        return (GainsVault(va), GainsVaultPolicy(pa));
    }

    /// @dev The policy of the earlier gTrade platform vault, as it was live during the review.
    function _livePolicy() internal pure returns (GainsVaultPolicy.RiskConfig memory) {
        return GainsVaultPolicy.RiskConfig({
            maxLeverageBps: 50_000,
            maxDailyLossBps: 1_500,
            maxDrawdownBps: 5_000,
            maxSlippageBps: 300,
            maxOrderNotional: 250_000e6,
            maxEpochDuration: 1 days,
            maxNavMoveBps: 2_000,
            maxFlattenSlippageBps: 300
        });
    }

    // ------------------------------------------------------------------ chain
    function _arbBlock() internal view returns (uint256) {
        return FORK_BLOCK + (vm.getBlockNumber() - l1Start);
    }

    function _mockArbBlock() internal {
        vm.mockCall(ARB_SYS, abi.encodeWithSelector(IArbSysK.arbBlockNumber.selector), abi.encode(_arbBlock()));
    }

    function _roll(uint256 blocks) internal {
        vm.roll(vm.getBlockNumber() + blocks);
        vm.warp(vm.getBlockTimestamp() + (blocks + 3) / 4);
        _mockArbBlock();
        _refreshCl();
    }

    function _chainlink1e10(address feed) internal view returns (uint64) {
        (, int256 answer,,,) = IFeedK(feed).latestRoundData();
        return uint64(uint256(answer) * 1e10 / (10 ** IFeedK(feed).decimals()));
    }

    function _round(uint64 px) internal pure returns (uint64) {
        return (px / 100) * 100;
    }

    function _feed(uint16 pair) internal pure returns (address) {
        return pair == BTC ? BTC_USD : pair == ETH ? ETH_USD : SOL_USD;
    }

    function _setCl(address feed, uint64 px) internal {
        cl[feed] = px;
        uint256 t = vm.getBlockTimestamp();
        vm.mockCall(
            feed,
            abi.encodeWithSelector(IFeedK.latestRoundData.selector),
            abi.encode(uint80(1), int256(uint256(px / 100)), t, t, uint80(1))
        );
    }

    function _refreshCl() internal {
        _setCl(BTC_USD, cl[BTC_USD]);
        _setCl(ETH_USD, cl[ETH_USD]);
        _setCl(SOL_USD, cl[SOL_USD]);
    }

    // ------------------------------------------------------------------ oracle
    function _fillAt(Vm.Log[] memory requestLogs, uint64 open, uint64 high, uint64 low)
        internal
        returns (Vm.Log[] memory fillLogs)
    {
        uint256 packed = uint256(open) | (uint256(open) << 56) | (uint256(high) << 112) | (uint256(low) << 168)
            | (uint256(uint32(vm.getBlockTimestamp())) << 224);
        vm.recordLogs();
        uint256 answered;
        for (uint256 i; i < requestLogs.length; i++) {
            Vm.Log memory l = requestLogs[i];
            if (l.topics.length == 0 || l.topics[0] != ORACLE_REQUEST) continue;
            (address requester, bytes32 requestId) = abi.decode(l.data, (address, bytes32));
            if (requester != address(DIAMOND)) continue;
            vm.prank(l.emitter);
            DIAMOND.fulfill(requestId, packed);
            answered++;
        }
        require(answered > 0, "no oracle request");
        fillLogs = vm.getRecordedLogs();
    }

    function _fill(Vm.Log[] memory requestLogs, uint64 price) internal returns (Vm.Log[] memory) {
        return _fillAt(requestLogs, price, price, price);
    }

    function _count(Vm.Log[] memory logs, bytes32 topic0) internal pure returns (uint256 n) {
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter == address(DIAMOND) && logs[i].topics.length > 0 && logs[i].topics[0] == topic0) n++;
        }
    }

    function _find(Vm.Log[] memory logs, bytes32 topic0) internal pure returns (Vm.Log memory l) {
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter == address(DIAMOND) && logs[i].topics.length > 0 && logs[i].topics[0] == topic0) {
                return logs[i];
            }
        }
        revert("log not found");
    }

    // ------------------------------------------------------------------ vault
    function _depositSettle(address who, uint256 amt) internal {
        vm.prank(who);
        v.requestDeposit(amt, who);
        _roll(4 * 3_600);
        v.checkRisk();
        vm.prank(keeper);
        v.settle();
        v.claim(who);
    }

    function _call(address caller, bytes memory data) internal returns (Vm.Log[] memory logs) {
        vm.recordLogs();
        vm.prank(caller);
        (bool ok, bytes memory ret) = address(v).call(data);
        if (!ok) {
            assembly {
                revert(add(ret, 32), mload(ret))
            }
        }
        logs = vm.getRecordedLogs();
    }

    function _params(uint16 pair, bool long, uint120 coll, uint24 lev) internal view returns (OpenParams memory) {
        return OpenParams(pair, long, coll, lev, cl[_feed(pair)], 1_000, 0, 0, 0);
    }

    /// @dev Opens (as `caller`, the manager or the agent) and fills at `px`; returns the vault trade index.
    function _openVault(address caller, uint16 pair, bool long, uint120 coll, uint24 lev, uint64 px)
        internal
        returns (uint32 idx)
    {
        Vm.Log[] memory req = _call(caller, abi.encodeCall(GainsVault.openTrade, (_params(pair, long, coll, lev))));
        _roll(1);
        Vm.Log[] memory fill = _fill(req, px);
        idx = uint32(uint256(_find(fill, G.MarketExecuted.selector).topics[2]));
    }

    function _closeVault(address caller, uint32 idx, uint64 px) internal returns (uint256 sent) {
        Vm.Log[] memory req = _call(caller, abi.encodeCall(GainsVault.closeTrade, (idx, px)));
        _roll(1);
        Vm.Log[] memory fill = _fill(req, px);
        (,,,,,,,, sent,) = abi.decode(
            _find(fill, G.MarketExecuted.selector).data,
            (G.Id, G.Trade, bool, uint256, uint256, uint256, G.TradePriceImpact, int256, uint256, uint256)
        );
    }

    // ------------------------------------------------------------------ an outside Gains trader (the thief's own account)
    function _newTrader(uint256 usdc) internal returns (GainsSpikeTrader t) {
        t = new GainsSpikeTrader(DIAMOND, USDC, address(this));
        deal(address(USDC), address(t), usdc);
    }

    function _gtrade(uint16 pair, bool long, uint120 coll, uint24 lev, uint64 px) internal pure returns (G.Trade memory t) {
        t.pairIndex = pair;
        t.long = long;
        t.isOpen = true;
        t.leverage = lev;
        t.collateralIndex = USDC_INDEX;
        t.tradeType = 0;
        t.collateralAmount = coll;
        t.openPrice = px;
    }

    function _openOutside(GainsSpikeTrader t, uint16 pair, bool long, uint120 coll, uint24 lev, uint64 px)
        internal
        returns (uint32 idx)
    {
        vm.recordLogs();
        t.openTrade(_gtrade(pair, long, coll, lev, px), 1_000);
        Vm.Log[] memory req = vm.getRecordedLogs();
        _roll(1);
        Vm.Log[] memory fill = _fill(req, px);
        idx = uint32(uint256(_find(fill, G.MarketExecuted.selector).topics[2]));
    }

    function _closeOutside(GainsSpikeTrader t, uint32 idx, uint64 px) internal {
        vm.recordLogs();
        t.closeTradeMarket(idx, px);
        Vm.Log[] memory req = vm.getRecordedLogs();
        _roll(1);
        _fill(req, px);
    }

    function _nav() internal view returns (uint256) {
        return v.totalAssets();
    }

    function _trade(uint32 idx) internal view returns (IGainsDiamond.Trade memory) {
        return D.getTrade(address(v), idx);
    }

    function _usdc(address a) internal view returns (uint256) {
        return USDC.balanceOf(a);
    }

    function _bps(uint256 part, uint256 whole) internal pure returns (uint256) {
        return part * 10_000 / whole;
    }

    // ------------------------------------------------------------------ GR2-KEY-01b (WP5 port)
    /// @dev The minimum hold: the manager's and the agent's closes, reduces and flattens wait MIN_HOLD (10 min) from the
    ///      pair's last new risk and MIN_HOLD_L2_BLOCKS (2,400) from the trade's last increase. 2,700 L2 blocks advance
    ///      _roll's clock by 675 s and ArbSys by 2,700 (the Chainlink mocks are refreshed by _roll).
    uint256 internal constant HOLD_BLOCKS = 2_700;

    function _passHold() internal {
        _roll(HOLD_BLOCKS);
    }

    /// @dev For tests that are not about the pair cap: raises `pair` to the code maximum (10 %), the end state of the
    ///      guardian's 31-day queued raise, written into the factory's storage (test/gains/fork/ForkPairCap.sol says why).
    function _raisePairCapToMax(uint16 pair) internal {
        assertEq(ForkPairCap.raiseToMax(address(factory), pair), MAX_PAIR_SKEW_CAP_BPS, "pair cap at the 10 % maximum");
    }

    /// @dev Gains' 1 % skew depth of `pair` and the factory's cap on it, in USDC (1e6) at the frozen Chainlink price
    ///      (the vault's own arithmetic: depth tokens 1e18 x price 1e10 / 1e22).
    function _pairCapUsd(uint16 pair) internal view returns (uint256 depthUsd, uint256 capUsd) {
        depthUsd = IGainsExtraK(address(DIAMOND)).getPairSkewDepth(USDC_INDEX, pair) * cl[_feed(pair)] / 1e22;
        capUsd = depthUsd * factory.pairSkewCapBps(pair) / 10_000;
    }

    /// @dev The manager opens `pair` longs of `perTrade` notional at leverage `lev` (1e3), each filled at the Chainlink
    ///      price, until the vault refuses one or `maxOrders` are open; a refusal must be OrderRejected("pair depth").
    /// @return opened notional opened before the refusal
    /// @return refused whether an order was refused
    function _openUntilPairDepth(uint16 pair, uint256 perTrade, uint256 maxOrders, uint24 lev)
        internal
        returns (uint256 opened, bool refused)
    {
        uint64 c = cl[_feed(pair)];
        for (uint256 i; i < maxOrders; ++i) {
            vm.recordLogs();
            vm.prank(mgr);
            (bool ok, bytes memory ret) =
                address(v).call(abi.encodeCall(GainsVault.openTrade, (_params(pair, true, uint120(perTrade * 1e3 / lev), lev))));
            Vm.Log[] memory req = vm.getRecordedLogs();
            if (!ok) {
                assertEq(ret, abi.encodeWithSignature("OrderRejected(string)", "pair depth"), "refused by the pair cap");
                return (opened, true);
            }
            _roll(1);
            _fill(req, c);
            opened += perTrade;
        }
    }

    /// @dev GR2-KEY-01 fix assertion at the production cap (the guardian's 1 %): the PoC's `n` orders of `perTrade` are
    ///      refused "pair depth" at the first one past the cap, and the largest size the vault takes (filled in chunks of
    ///      an eighth of the cap) stays within 1 % of the pair's skew depth. Runs from a snapshot it reverts.
    /// @return depthUsd Gains' 1 % skew depth (USDC 1e6)
    /// @return capUsd the cap (USDC 1e6)
    /// @return held the vault's notional on the pair at the refusal of the chunked fill
    function _assertPairCapRefusesPoC(uint16 pair, uint256 n, uint256 perTrade)
        internal
        returns (uint256 depthUsd, uint256 capUsd, uint256 held)
    {
        assertEq(factory.pairSkewCapBps(pair), 100, "the guardian's launch cap, 1 % of the skew depth");
        (depthUsd, capUsd) = _pairCapUsd(pair);
        uint256 snap = vm.snapshotState();
        (uint256 opened, bool refused) = _openUntilPairDepth(pair, perTrade, n, 25_000); // the PoC's orders, 25x
        assertTrue(refused, "the PoC's vault size is refused");
        assertLe(opened, capUsd, "never above the cap");
        assertGt(opened + perTrade, capUsd, "refused at the first order past the cap");
        vm.revertToState(snap);
        _mockArbBlock(); // vm mocks survive revertToState: re-point ArbSys and the feeds at the reverted block
        _refreshCl();
        uint256 chunk = capUsd / 8 / 1e6 * 1e6;
        (opened, refused) = _openUntilPairDepth(pair, chunk, 19, 5_000); // 5x: SOL's chunk is ~5k
        held = v.venue().notional;
        assertTrue(refused, "the chunked fill stops at the cap");
        assertLe(held, capUsd, "the largest size the vault takes is within 1 % of the skew depth");
        assertGt(opened + chunk, capUsd, "and the cap is reached");
        console2.log("pair / skew depth / cap (USDC 1e6)", pair, depthUsd, capUsd);
        console2.log("PoC vault size V / largest notional the vault took (USDC 1e6)", n * perTrade, held);
        console2.log("skew term V*A/(200*depth) at the PoC's V = A / at the cap (USDC 1e6)",
            n * perTrade * n * perTrade / (200 * depthUsd), held * held / (200 * depthUsd));
        vm.revertToState(snap);
        _mockArbBlock();
        _refreshCl();
    }
}
