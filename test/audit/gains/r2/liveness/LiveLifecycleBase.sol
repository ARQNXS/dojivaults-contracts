// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import "./LiveForkBase.sol";
import {GainsVault} from "../../../../../src/gains/GainsVault.sol";
import {GainsVaultFactory} from "../../../../../src/gains/GainsVaultFactory.sol";
import {GainsVaultPolicy} from "../../../../../src/gains/GainsVaultPolicy.sol";
import {GainsVaultLens} from "../../../../../src/gains/GainsVaultLens.sol";
import {GainsPrice} from "../../../../../src/gains/GainsPrice.sol";
import {IGainsDiamond} from "../../../../../src/gains/IGainsDiamond.sol";
import {IGainsVaultErrors, MAX_PAIR_SKEW_CAP_BPS, OpenParams} from "../../../../../src/gains/GainsTypes.sol";
import {ForkPairCap} from "../../../../gains/fork/ForkPairCap.sol";

interface IGainsTriggerLive {
    function triggerOrder(uint256 packed) external;
    function getChainlinkToken() external view returns (address);
    function getTradingActivated() external view returns (uint8);
    function getTradePendingOrderBlock(IGainsDiamond.Id calldata tradeId, uint8 orderType) external view returns (uint256);
}

/// @notice Round 1 review, sub-reviewer 3.2 / 3.3 (async order lifecycle, exits and liveness). Same harness as
///         test/gains/fork/GainsVaultFork.t.sol (real gTrade v10 diamond on an Arbitrum One fork, oracle answers
///         emulated by pranking the diamond's Chainlink operator nodes, Chainlink feeds frozen with mockCall), copied
///         here so this directory does not inherit and re-run the Stage 1 tests. Skips without ARBITRUM_RPC_URL.
abstract contract LiveLifecycleBase is LiveForkBase {
    address internal constant BTC_USD = 0x6ce185860a4963106506C203335A2910413708e9;
    address internal constant ETH_USD = 0x639Fe6ab55C921f74e7fac1ee960C0B6293ba612;
    address internal constant SOL_USD = 0x24ceA4b8ce57cdA5058b924B9B9987992450590c;
    address internal constant SEQ = 0xFdB631F5EE196F0ed6FAa767959853A9F217697D;
    uint16 internal constant BAND = 20;

    // PendingOrderType
    uint8 internal constant T_MARKET_CLOSE = 1;
    uint8 internal constant T_LIMIT_OPEN = 2;
    uint8 internal constant T_STOP_OPEN = 3;
    uint8 internal constant T_TP = 4;
    uint8 internal constant T_SL = 5;
    uint8 internal constant T_LIQ = 6;
    uint8 internal constant T_UPDATE_LEVERAGE = 7;
    uint8 internal constant T_PARTIAL_OPEN = 8;
    uint8 internal constant T_PARTIAL_CLOSE = 9;

    GainsVaultFactory internal factory;
    GainsVault internal v;
    GainsVaultPolicy internal pol;
    GainsVaultLens internal lens;
    IGainsDiamond internal D = IGainsDiamond(address(0xFF162c694eAA571f685030649814282eA457f169));

    address internal fOwner = makeAddr("fOwner");
    address internal fGuardian = makeAddr("fGuardian");
    address internal fSentinel = makeAddr("fSentinel");
    address internal treasury = makeAddr("treasury");
    address internal creator = makeAddr("creator");
    address internal mgr = makeAddr("mgr");
    address internal keeper = makeAddr("keeper");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal bot = makeAddr("bot");
    address internal stranger = makeAddr("stranger");

    mapping(address feed => uint64) internal cl;

    function setUp() public virtual override {
        super.setUp();
        if (!forked) return;
        _setCl(BTC_USD, _round(_chainlink1e10(BTC_USD)));
        _setCl(ETH_USD, _round(_chainlink1e10(ETH_USD)));
        _setCl(SOL_USD, _round(_chainlink1e10(SOL_USD)));

        GainsVault impl = new GainsVault();
        GainsVaultPolicy pimpl = new GainsVaultPolicy();
        lens = new GainsVaultLens();
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

        vm.startPrank(GUSDC);
        USDC.transfer(creator, 10e6);
        USDC.transfer(alice, 200_000e6);
        USDC.transfer(bob, 200_000e6);
        vm.stopPrank();
        (v, pol) = _create(bytes32(uint256(1)));
        vm.prank(alice);
        USDC.approve(address(v), type(uint256).max);
        vm.prank(bob);
        USDC.approve(address(v), type(uint256).max);
    }

    // ------------------------------------------------------------------ harness
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
                name: "Gains LC Vault",
                symbol: "gLC",
                owner: creator,
                manager: mgr,
                feeRecipient: creator,
                managementFeeBps: 0,
                performanceFeeBps: 0,
                timelockDelay: 2 days,
                depositCap: 1_000_000e6,
                risk: GainsVaultPolicy.RiskConfig({
                    maxLeverageBps: 30_000,
                    maxDailyLossBps: 500,
                    maxDrawdownBps: 1_500,
                    maxSlippageBps: 100,
                    maxOrderNotional: 1_000_000e6,
                    maxEpochDuration: 7 days,
                    maxNavMoveBps: 2_000,
                    maxFlattenSlippageBps: 300
                }),
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
            abi.encodeWithSelector(ILiveChainlinkFeed.latestRoundData.selector),
            abi.encode(uint80(1), int256(uint256(px / 100)), t, t, uint80(1))
        );
    }

    function _refreshCl() internal {
        _setCl(BTC_USD, cl[BTC_USD]);
        _setCl(ETH_USD, cl[ETH_USD]);
        _setCl(SOL_USD, cl[SOL_USD]);
    }

    function _rollFresh(uint256 blocks) internal {
        _roll(blocks);
        _refreshCl();
    }

    /// @dev GR2-KEY-01b (WP5 port): the manager's and the agent's closes, reduces and flattens wait MIN_HOLD (10 min)
    ///      from the pair's last new risk and MIN_HOLD_L2_BLOCKS (2,400) from the trade's last increase. 2,700 L2 blocks
    ///      advance _roll's clock by 675 s and ArbSys by 2,700: past both.
    uint256 internal constant HOLD_BLOCKS = 2_700;

    /// @dev GR2-KEY-01b (WP5 port): the minimum hold with the Chainlink mocks kept fresh.
    function _passHold() internal {
        _rollFresh(HOLD_BLOCKS);
    }

    /// @dev GR2-KEY-01b (WP5 port): for tests that are not about the pair cap and need more than 1 % of Gains' skew
    ///      depth (or a pair the guardian never set). Raises `pair` to the code maximum (10 %), the end state of the
    ///      guardian's 31-day queued raise, written into the factory's storage (test/gains/fork/ForkPairCap.sol says why).
    function _raisePairCapToMax(uint16 pair) internal {
        assertEq(ForkPairCap.raiseToMax(address(factory), pair), MAX_PAIR_SKEW_CAP_BPS, "pair cap at the 10 % maximum");
    }

    // ------------------------------------------------------------------ GR2-LIVE-01 fix (WP5)
    /// @dev GR2-LIVE-01: pulls the vault's unseen index range with the permissionless syncIndexes in batches of 500; returns the worst batch's gas.
    function _syncInBatches(uint256 n) internal returns (uint256 worst) {
        uint256 pulled;
        while (pulled < n) {
            (uint256 g, bytes memory ret) = _gasRet(stranger, abi.encodeCall(GainsVault.syncIndexes, (uint256(500))));
            uint256 steps = abi.decode(ret, (uint256));
            assertGt(steps, 0, "progress");
            assertLt(g, 26_000_000, "a batch of 500 fits with 20 % headroom under 32M");
            if (g > worst) worst = g;
            pulled += steps;
        }
    }

    function _gasRet(address caller, bytes memory data) internal returns (uint256 g, bytes memory ret) {
        vm.prank(caller);
        g = gasleft();
        bool ok;
        (ok, ret) = address(v).call(data);
        g -= gasleft();
        require(ok, "call failed");
    }

    function _adverse(uint16 pair, bool long) internal view returns (uint64) {
        return GainsPrice.adverse(cl[_feed(pair)], pair == SOL ? 25 : BAND, long);
    }

    function _depositSettle(address who, uint256 amt) internal {
        vm.prank(who);
        v.requestDeposit(amt, who);
        _rollFresh(4 * 3_600);
        v.checkRisk();
        vm.prank(keeper);
        v.settle();
        v.claim(who);
    }

    function _req(address caller, bytes memory data) internal returns (Vm.Log[] memory logs) {
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

    function _openParams(uint16 pair, bool long, uint120 coll, uint24 lev) internal view returns (OpenParams memory) {
        return OpenParams(pair, long, coll, lev, cl[_feed(pair)], 1_000, 0, 0, 0);
    }

    function _openFilledV(uint16 pair, bool long, uint120 coll, uint24 lev) internal returns (uint32 idx) {
        Vm.Log[] memory req = _req(mgr, abi.encodeCall(GainsVault.openTrade, (_openParams(pair, long, coll, lev))));
        _rollFresh(1);
        Vm.Log[] memory fill = _fill(req, cl[_feed(pair)]);
        idx = uint32(uint256(_find(fill, G.MarketExecuted.selector).topics[2]));
    }

    function _usdc() internal view returns (uint256) {
        return USDC.balanceOf(address(v));
    }

    function _pending() internal view returns (IGainsDiamond.PendingOrder[] memory) {
        return D.getPendingOrders(address(v));
    }

    function _lastPending() internal view returns (IGainsDiamond.PendingOrder memory o) {
        IGainsDiamond.PendingOrder[] memory os = _pending();
        require(os.length > 0, "no pending order");
        return os[os.length - 1];
    }

    function _trade(uint32 idx) internal view returns (IGainsDiamond.Trade memory) {
        return D.getTrade(address(v), idx);
    }

    function _nav() internal view returns (uint256) {
        return v.totalAssets();
    }

    function _absDiff(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a - b : b - a;
    }

    /// @dev A bot's trigger order (TP 4, SL 5, LIQ 6, LIMIT_OPEN 2, STOP_OPEN 3) on the vault's trade, paying 1 LINK.
    function _trigger(address caller, uint8 orderType, uint32 idx) internal returns (Vm.Log[] memory logs) {
        address link = IGainsTriggerLive(address(D)).getChainlinkToken();
        deal(link, caller, 10e18);
        vm.prank(caller);
        IERC20(link).approve(address(D), type(uint256).max);
        uint256 packed = uint256(orderType) | (uint256(uint160(address(v))) << 8) | (uint256(idx) << 168);
        vm.recordLogs();
        vm.prank(caller);
        IGainsTriggerLive(address(D)).triggerOrder(packed);
        logs = vm.getRecordedLogs();
    }

    function _fillRange(Vm.Log[] memory requestLogs, uint64 open, uint64 high, uint64 low)
        internal
        returns (Vm.Log[] memory fillLogs)
    {
        uint256 packed = uint256(open) | (uint256(open) << 56) | (uint256(high) << 112) | (uint256(low) << 168)
            | (uint256(uint32(vm.getBlockTimestamp())) << 224);
        vm.recordLogs();
        uint256 answered;
        for (uint256 i; i < requestLogs.length; i++) {
            Vm.Log memory l = requestLogs[i];
            if (l.topics[0] != ORACLE_REQUEST) continue;
            (address requester, bytes32 requestId) = abi.decode(l.data, (address, bytes32));
            if (requester != address(DIAMOND)) continue;
            vm.prank(l.emitter);
            DIAMOND.fulfill(requestId, packed);
            answered++;
        }
        require(answered > 0, "no oracle request");
        fillLogs = vm.getRecordedLogs();
    }

    function _limitExecuted(Vm.Log[] memory fill)
        internal
        pure
        returns (G.Trade memory t, uint8 orderType, uint256 oraclePrice, uint256 marketPrice, uint256 sent, bool exact)
    {
        Vm.Log memory l = _find(fill, G.LimitExecuted.selector);
        (, t,, orderType, oraclePrice, marketPrice,,,, sent,, exact) = abi.decode(
            l.data,
            (G.Id, G.Trade, address, uint8, uint256, uint256, uint256, G.TradePriceImpact, int256, uint256, uint256, bool)
        );
    }

    /// @dev Execution gas of one vault call (forge 1.8: each top-level call starts cold, see GainsVaultFork.t.sol).
    function _gas(address caller, bytes memory data) internal returns (uint256 g, Vm.Log[] memory logs) {
        vm.recordLogs();
        vm.prank(caller);
        g = gasleft();
        (bool ok, bytes memory ret) = address(v).call(data);
        g -= gasleft();
        if (!ok) {
            assembly {
                revert(add(ret, 32), mload(ret))
            }
        }
        logs = vm.getRecordedLogs();
    }

    /// @dev Calls the vault and returns whether it succeeded plus the revert data (no revert).
    function _try(address caller, bytes memory data) internal returns (bool ok, bytes memory ret) {
        vm.prank(caller);
        (ok, ret) = address(v).call(data);
    }

    function _sel(bytes memory ret) internal pure returns (bytes4 s) {
        if (ret.length >= 4) {
            assembly {
                s := mload(add(ret, 32))
            }
        }
    }
}
