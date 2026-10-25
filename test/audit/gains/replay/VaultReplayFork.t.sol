// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import "../../../gains/fork/GainsForkBase.sol";
import {NavCalc} from "../../../gains/spike/NavCalc.sol";
import {GainsVault} from "../../../../src/gains/GainsVault.sol";
import {GainsVaultFactory} from "../../../../src/gains/GainsVaultFactory.sol";
import {GainsVaultPolicy} from "../../../../src/gains/GainsVaultPolicy.sol";
import {IGainsDiamond} from "../../../../src/gains/IGainsDiamond.sol";
import {OpenParams} from "../../../../src/gains/GainsTypes.sol";

interface IGainsTriggerR {
    function triggerOrder(uint256 packed) external;
    function getChainlinkToken() external view returns (address);
}

/// @notice Round 1 review, tools task 3: real gTrade mainnet trades replayed THROUGH a GainsVault on an Arbitrum One
///         fork. For each recorded exit (market close, partial close, TP, SL, liquidation; the 19 cases of
///         test/gains/fork/GainsForkReplay.t.sol) the fork is taken at the exit tx (state just before it). A fresh
///         factory vault opens the same pair / side / leverage (same collateral where the policy allows, else scaled),
///         filled so that its Gains open price equals the real trade's open price (two oracle iterations on a
///         snapshot), then the real exit is applied through the vault at the real oracle answer (TP / SL through a
///         bot trigger with the real trigger in the oracle range, liquidation through a LIQ trigger).
///         Measured per case:
///           e1  vault USDC realized - independent payout prediction (NavCalc on the vault's trade, exact Gains model)
///           e2  NAV continuity at band 0: totalAssets before the exit - totalAssets after (both with navPrice mocked to
///               the execution price and band 0): what GainsNav says the trade is worth vs what Gains paid
///           e3  vault payout - real trader payout x scale; e3g the same on gross value (collateral + pnl after impact,
///               before closing / holding fees and realized pnl, i.e. without the real trade's history)
///           band  totalAssets with the real band (feed at the oracle price) - band 0 NAV, in bps of notional
///         Skips without ARBITRUM_RPC_URL.
contract VaultReplayForkTest is GainsForkBase {
    enum Kind { MARKET, PARTIAL, TP, SL, LIQ }

    struct Case {
        Kind kind;
        uint16 pair;
        uint256 block_;
        bytes32 tx_;
        address trader;
        uint32 index;
        uint64 oraclePrice;
        uint256 paid;
        uint120 collateralDelta;
    }

    struct Row {
        uint120 collR;
        uint120 collV;
        uint24 lev;
        bool long;
        uint64 openR;
        uint64 openV;
        uint64 execPx;
        uint256 notional;
        int256 paidV;
        int256 predV;
        int256 scaledR;
        int256 grossR;
        int256 grossV;
        int256 navBefore0;
        int256 navAfter0;
        int256 navRaw;
        int256 navAfterRaw;
        bool liquidated;
        bool stillOpen;
        uint8 ev; // 1 MarketExecuted, 2 LimitExecuted, 3 PositionSizeDecreaseExecuted, 4 TriggerOrderCanceled
        uint8 cancelReason;
        bool evExact;
        uint256 evMarketPx;
        uint256 evAmount;
        uint256 evTransfer;
        int256 holdR; // real trade: pending holding fees at the exit price (+ = paid by the trader)
        int256 realR; // real trade: total realized pnl (earlier partials, realized fees)
        uint256 feeR; // real trade: closing fee as charged (fee tier applied)
        int256 holdV;
        uint256 feeV;
        int256 realV;
        int256[3] impModel; // model (market close): fixed spread, cumulative volume, skew (1e10 %)
        int256[3] impEvent; // the trigger's LimitExecuted priceImpact
        uint256 modelPx; // model price after impact
        int256 modelPnlP; // model pnl percent (1e10 %)
        int256 evPnlP; // trigger event percentProfit
    }

    address internal constant BTC_USD = 0x6ce185860a4963106506C203335A2910413708e9;
    address internal constant ETH_USD = 0x639Fe6ab55C921f74e7fac1ee960C0B6293ba612;
    address internal constant SOL_USD = 0x24ceA4b8ce57cdA5058b924B9B9987992450590c;
    address internal constant SEQ = 0xFdB631F5EE196F0ed6FAa767959853A9F217697D;
    uint8 internal constant T_TP = 4;
    uint8 internal constant T_SL = 5;
    uint8 internal constant T_LIQ = 6;

    IGainsDiamond internal D = IGainsDiamond(address(0xFF162c694eAA571f685030649814282eA457f169));
    GainsVaultFactory internal factory;
    GainsVault internal v;
    GainsVaultPolicy internal pol;
    address internal fOwner = makeAddr("fOwner");
    address internal creator = makeAddr("creator");
    address internal mgr = makeAddr("mgr");
    address internal keeper = makeAddr("keeper");
    address internal alice = makeAddr("alice");
    address internal bot = makeAddr("bot");
    uint256 internal arbStart;
    mapping(address => uint64) internal cl;

    Case[] internal c;
    uint64[4][] internal ans;

    function setUp() public override {
        if (bytes(vm.envOr("ARBITRUM_RPC_URL", string(""))).length == 0) {
            vm.skip(true);
            return;
        }
        c.push(Case(Kind.PARTIAL, 0, 515214451, 0x8d6d3bfdadec64ed9894de5d74aef19d1cf18d0270a57a7f6ea454d07269848f, 0xDE23E9483832c24bDBA171cB9FA63D1Aa0D45588, 1, 822073830000000, 682773, 821466));
        c.push(Case(Kind.MARKET, 0, 515214957, 0x25b12eadeb992c93eea20654dc2f450090a23911d9c025ec0ca90ff81568de3b, 0xDE23E9483832c24bDBA171cB9FA63D1Aa0D45588, 1, 822579710000000, 999270, 0));
        c.push(Case(Kind.MARKET, 1, 515221565, 0x5d1a1d1249bb113094623f2672af671eddb12a6ec8af8617f25f3d90ddc031c4, 0x9D086cF6F0DebCfD5852b6D7989664FE1d73aEAe, 1598, 24425564000000, 7086055, 0));
        c.push(Case(Kind.MARKET, 33, 515203383, 0x2e6b1370922835b34fc837999a288a475ec83c6666245ba4de0cd37f45c93bd7, 0xfbfc6911Ae994D937324201209096A93435863cf, 2026, 1052500000000, 142046556, 0));
        c.push(Case(Kind.MARKET, 1, 515203486, 0xbeda0cdd1865dbfb8c5c387b8bab8a64327cd7f6b989b9e4f3d4a1af730b1f88, 0x9D086cF6F0DebCfD5852b6D7989664FE1d73aEAe, 1597, 24394658000000, 8764497, 0));
        c.push(Case(Kind.TP, 1, 515204509, 0xe5a6b49f5141085b798560d90c10d992a4e782f680a7f834aa358c9a804dcbdf, 0x9D086cF6F0DebCfD5852b6D7989664FE1d73aEAe, 1596, 24371214198872, 9411744, 0));
        c.push(Case(Kind.MARKET, 33, 515197984, 0x7b1745250ff79bd9c9d76b7197aa4efc2460ab6d6e8fe7d9cb086fbba5be6380, 0x9D086cF6F0DebCfD5852b6D7989664FE1d73aEAe, 1588, 1057125300000, 6965531, 0));
        c.push(Case(Kind.MARKET, 1, 515200985, 0xa2d49e5e26776f85af780339311291fbf5a387f833e8274d0b830b12def91938, 0x9D086cF6F0DebCfD5852b6D7989664FE1d73aEAe, 1592, 24488796000000, 6813693, 0));
        c.push(Case(Kind.LIQ, 33, 515203168, 0x0196926a0b16f4be6f671d69f576b76560c4542b1ef2971e1a0dc4ddd27b230e, 0x4925C57cB143A803291F3D7f6c72De06697B3BD8, 528, 1052777756701, 0, 0));
        c.push(Case(Kind.PARTIAL, 0, 515183328, 0x4e23b67b4ba8d2feafd768d27d9ba2adec1805de9d792818959ba7479f3bbb71, 0x83e3624B5C9676Ed96B6EE340F5b158E0Be5db44, 10, 822360450000000, 555897, 702526));
        c.push(Case(Kind.SL, 0, 515187815, 0x006547ff8b766cbd891c99506c53b8f6f3bc1a58681a022fe86c117d930b8d2b, 0x310a5086973Bc12D7ae6b8fAb51946AE82395123, 67, 824384958728106, 430366884, 0));
        c.push(Case(Kind.SL, 1, 515188003, 0xccdff72e35785b79fae50809e5c08033e7afcfc7ffb9df1aa1f0f748367ca786, 0xD70D9d88c54ef8584f66351e06Faa653812eFFD0, 234, 24635873058586, 2940895, 0));
        c.push(Case(Kind.PARTIAL, 0, 515192064, 0x085cc59f85d4bb011c2dc649097b58e1c04dc99ae68a0c24973adee609b678ec, 0xDE23E9483832c24bDBA171cB9FA63D1Aa0D45588, 0, 823114280000000, 834364, 988614));
        c.push(Case(Kind.SL, 0, 515173227, 0x410007277829c4676ffcba4b42127f5a7e3b8c704f0246c97d3b8e681de100d4, 0xea908e6c26A2eFAeB5cBBdDD2fB9Ce6ee3a35D4A, 1073, 820039208724116, 1828050, 0));
        c.push(Case(Kind.PARTIAL, 0, 515133514, 0xb42c2f993984602f581e4063b5bf84025b2f307115f180984238bc3abd3b5e43, 0xA0A0b6A691eBF91E4C723aEF6Fb387d74484bE0b, 428, 823593560000000, 125468725, 71286922));
        c.push(Case(Kind.TP, 33, 515095039, 0x7bd2ed5f27dbde9b20a73955cabad2a6415c6667abfb563e55cfc0d6c33bbbb3, 0x9bbC36d40c9C895f0CDEbE90b64A44C3898612f2, 310, 1058961529215, 136362053, 0));
        c.push(Case(Kind.LIQ, 1, 515074227, 0x5d6b4813dca95e36f44aaaa24a6ac3dd7ecb8b165a5801b3923c8b5db111f96f, 0x466eA343585A96Af51F8d98e6981aF043866D148, 281, 23332922393981, 0, 0));
        c.push(Case(Kind.LIQ, 0, 515078357, 0x7204d15feb9835452bdb740c5f29eccfd830f65811c40c09fc2cb2e2cd22eacd, 0xea908e6c26A2eFAeB5cBBdDD2fB9Ce6ee3a35D4A, 1070, 799661049366821, 0, 0));
        c.push(Case(Kind.TP, 0, 515078450, 0xb1c78c88218b3648ad03e77423a20cd47bca7b7f3a1051869baf2ab5237c4ce8, 0x0ba80Bd575C61eCDbA729A7f4f2D23Df54c48193, 2227, 797996587483304, 4038657248, 0));
        // real oracle answers of the exit txs, in case order: current, open, high, low (call traces: node
        // fulfill(bytes32,uint256) for market fills, the diamond's internal trigger callback for signed-price triggers)
        ans.push([uint64(822082610000000), 822073830000000, 822082610000000, 822073830000000]); // 0x8d6d3bfd fulfill
        ans.push([uint64(822579710000000), 822567080000000, 822579710000000, 822567080000000]); // 0x25b12ead fulfill
        ans.push([uint64(24427662000000), 24428161000000, 24428161000000, 24427662000000]); // 0x5d1a1d12 fulfill
        ans.push([uint64(1052500000000), 1052500000000, 1052500000000, 1052500000000]); // 0x2e6b1370 fulfill
        ans.push([uint64(24394658000000), 24394658000000, 24394658000000, 24394658000000]); // 0xbeda0cdd fulfill
        ans.push([uint64(24371214198872), 24374693000000, 24374693000000, 24368100000000]); // 0xe5a6b49f callback
        ans.push([uint64(1057125300000), 1057125300000, 1057125300000, 1057125300000]); // 0x7b174525 fulfill
        ans.push([uint64(24488796000000), 24488796000000, 24488796000000, 24488796000000]); // 0xa2d49e5e fulfill
        ans.push([uint64(1052777756701), 1052798399999, 1052798399999, 1052698600000]); // 0x0196926a callback
        ans.push([uint64(822360450000000), 822360450000000, 822360450000000, 822360450000000]); // 0x4e23b67b fulfill
        ans.push([uint64(824384958728106), 824166609999999, 824392170000000, 824160810000000]); // 0x006547ff callback
        ans.push([uint64(24635873058586), 24626980000000, 24643462000000, 24626980000000]); // 0xccdff72e callback
        ans.push([uint64(823114280000000), 823114280000000, 823114280000000, 823114280000000]); // 0x085cc59f fulfill
        ans.push([uint64(820039208724116), 820075910000000, 820084400000000, 819987709999999]); // 0x41000727 callback
        ans.push([uint64(823593560000000), 823593560000000, 823593560000000, 823593560000000]); // 0xb42c2f99 fulfill
        ans.push([uint64(1058961529215), 1058950000000, 1059080700000, 1058880900000]); // 0x7bd2ed5f callback
        ans.push([uint64(23332921043749), 23347284000000, 23347284000000, 23332102000000]); // 0x5d6b4813 callback
        ans.push([uint64(799660993084006), 799934890000000, 799934890000000, 799262310000000]); // 0x7204d15f callback
        ans.push([uint64(797996587483304), 798140580000000, 798140580000000, 797968790000000]); // 0xb1c78c88 callback
    }

    // 19 cases, one test each (one fork per test)
    function test_replay_00() public { _run(0); }
    function test_replay_01() public { _run(1); }
    function test_replay_02() public { _run(2); }
    function test_replay_03() public { _run(3); }
    function test_replay_04() public { _run(4); }
    function test_replay_05() public { _run(5); }
    function test_replay_06() public { _run(6); }
    function test_replay_07() public { _run(7); }
    function test_replay_08() public { _run(8); }
    function test_replay_09() public { _run(9); }
    function test_replay_10() public { _run(10); }
    function test_replay_11() public { _run(11); }
    function test_replay_12() public { _run(12); }
    function test_replay_13() public { _run(13); }
    function test_replay_14() public { _run(14); }
    function test_replay_15() public { _run(15); }
    function test_replay_16() public { _run(16); }
    function test_replay_17() public { _run(17); }
    function test_replay_18() public { _run(18); }

    /// @dev Diagnostics for the short SL case 10: synthetic answers instead of the real one. mode 1: current = open =
    ///      high = low = SL; mode 2: current = open = the real current price, range [SL, current]; mode 3: as mode 2
    ///      with the range widened to [SL - 0.5%, current + 0.5%]. Modes 1 and 2 are NOT_HIT (cancel reason 11), mode 3
    ///      executes: a range that only touches the SL at its edge does not trigger it, which is why the replay feeds
    ///      the real recorded answers (case 10: open 824,166.61, low 824,160.81 < SL 824,319 < high 824,392.17).
    uint8 internal diagMode;

    function test_diag_shortSl_10() public {
        for (uint8 m = 1; m <= 3; m++) {
            diagMode = m;
            console2.log("DIAG mode", m);
            _run(10);
        }
    }

    // ------------------------------------------------------------------ chain
    function _arb() internal view returns (uint256) {
        return arbStart + (vm.getBlockNumber() - l1Start);
    }

    function _mockArb() internal {
        vm.mockCall(ARB_SYS, abi.encodeWithSelector(IArbSys.arbBlockNumber.selector), abi.encode(_arb()));
    }

    function _rollR(uint256 blocks) internal {
        vm.roll(vm.getBlockNumber() + blocks);
        vm.warp(vm.getBlockTimestamp() + (blocks + 3) / 4);
        _mockArb();
        _refresh();
    }

    function _feedOf(uint16 pair) internal pure returns (address) {
        return pair == BTC ? BTC_USD : pair == ETH ? ETH_USD : SOL_USD;
    }

    function _setCl(address feed, uint64 px) internal {
        cl[feed] = px;
        uint256 t = vm.getBlockTimestamp();
        vm.mockCall(
            feed,
            abi.encodeWithSelector(IChainlinkFeed.latestRoundData.selector),
            abi.encode(uint80(1), int256(uint256(px / 100)), t, t, uint80(1))
        );
    }

    function _refresh() internal {
        _setCl(BTC_USD, cl[BTC_USD]);
        _setCl(ETH_USD, cl[ETH_USD]);
        _setCl(SOL_USD, cl[SOL_USD]);
    }

    // ------------------------------------------------------------------ vault
    function _deploy(uint256 navNeeded) internal {
        // fix round (GR1-02): a settle that prices deposits runs 1 h into the epoch. The vault is created and the
        // deposit requested 1 h before the fork block's timestamp, and settled back at it, so the replayed trades keep
        // their recorded blocks and times (nothing here touches the diamond before the settle).
        uint256 t0 = vm.getBlockTimestamp();
        vm.warp(t0 - 1 hours);
        _setCl(BTC_USD, (_chainlink1e10(BTC_USD) / 100) * 100);
        _setCl(ETH_USD, (_chainlink1e10(ETH_USD) / 100) * 100);
        _setCl(SOL_USD, (_chainlink1e10(SOL_USD) / 100) * 100);
        factory = new GainsVaultFactory(
            fOwner, address(new GainsVault()), address(new GainsVaultPolicy()), USDC, D, SEQ, 3_600, makeAddr("treasury"),
            makeAddr("fGuardian"), makeAddr("fSentinel")
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
        deal(address(USDC), alice, navNeeded + 10e6);
        uint32[] memory assets = new uint32[](3);
        assets[0] = BTC;
        assets[1] = ETH;
        assets[2] = SOL;
        vm.prank(creator);
        USDC.approve(address(factory), 1e6);
        vm.prank(creator);
        (address va, address pa) = factory.create(
            GainsVaultFactory.CreateParams({
                name: "Replay",
                symbol: "gR",
                owner: creator,
                manager: mgr,
                feeRecipient: creator,
                managementFeeBps: 0,
                performanceFeeBps: 0,
                timelockDelay: 2 days,
                depositCap: type(uint128).max,
                risk: GainsVaultPolicy.RiskConfig({
                    maxLeverageBps: 100_000,
                    maxDailyLossBps: 5_000,
                    maxDrawdownBps: 5_000,
                    maxSlippageBps: 100,
                    maxOrderNotional: 100_000_000e6,
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
                salt: bytes32(uint256(7))
            }),
            GainsVaultFactory.PermitData(0, 0, 0, bytes32(0), bytes32(0))
        );
        v = GainsVault(va);
        pol = GainsVaultPolicy(pa);
        vm.prank(alice);
        USDC.approve(va, type(uint256).max);
        vm.prank(alice);
        v.requestDeposit(navNeeded, alice);
        vm.warp(t0);
        _rollR(8);
        vm.prank(keeper);
        v.settle();
        v.claim(alice);
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

    function _answer(Vm.Log[] memory req, uint64 open, uint64 high, uint64 low) internal returns (Vm.Log[] memory) {
        uint256 packed = uint256(open) | (uint256(open) << 56) | (uint256(high) << 112) | (uint256(low) << 168)
            | (uint256(uint32(vm.getBlockTimestamp())) << 224);
        vm.recordLogs();
        uint256 n;
        for (uint256 i; i < req.length; i++) {
            if (req[i].topics[0] != ORACLE_REQUEST) continue;
            (address requester, bytes32 requestId) = abi.decode(req[i].data, (address, bytes32));
            if (requester != address(DIAMOND)) continue;
            vm.prank(req[i].emitter);
            DIAMOND.fulfill(requestId, packed);
            n++;
        }
        require(n > 0, "no oracle request");
        return vm.getRecordedLogs();
    }

    /// @dev Answers with a full aggregator answer: current | open << 56 | high << 112 | low << 168 | ts << 224.
    function _answer4(Vm.Log[] memory req, uint64[4] memory a) internal returns (Vm.Log[] memory) {
        uint256 packed = uint256(a[0]) | (uint256(a[1]) << 56) | (uint256(a[2]) << 112) | (uint256(a[3]) << 168)
            | (uint256(uint32(vm.getBlockTimestamp())) << 224);
        vm.recordLogs();
        uint256 n;
        for (uint256 j; j < req.length; j++) {
            if (req[j].topics[0] != ORACLE_REQUEST) continue;
            (address requester, bytes32 requestId) = abi.decode(req[j].data, (address, bytes32));
            if (requester != address(DIAMOND)) continue;
            vm.prank(req[j].emitter);
            DIAMOND.fulfill(requestId, packed);
            n++;
        }
        require(n > 0, "no oracle request");
        return vm.getRecordedLogs();
    }

    /// @dev Opens through the vault and fills at `oracle`; returns the trade index and its Gains open price.
    function _openAt(uint16 pair, bool long, uint120 coll, uint24 lev, uint64 expected, uint64 oracle)
        internal
        returns (uint32 idx, uint64 openPx)
    {
        Vm.Log[] memory req =
            _call(mgr, abi.encodeCall(GainsVault.openTrade, (OpenParams(pair, long, coll, lev, expected, 1_000, 0, 0, 0))));
        _rollR(1);
        Vm.Log[] memory fill = _answer(req, oracle, oracle, oracle);
        idx = uint32(uint256(_find(fill, G.MarketExecuted.selector).topics[2]));
        openPx = D.getTrade(address(v), idx).openPrice;
    }

    function _trigger(uint8 orderType, uint32 idx) internal returns (Vm.Log[] memory logs) {
        address link = IGainsTriggerR(address(D)).getChainlinkToken();
        deal(link, bot, 10e18);
        vm.prank(bot);
        IERC20(link).approve(address(D), type(uint256).max);
        uint256 packed = uint256(orderType) | (uint256(uint160(address(v))) << 8) | (uint256(idx) << 168);
        vm.recordLogs();
        vm.prank(bot);
        IGainsTriggerR(address(D)).triggerOrder(packed);
        logs = vm.getRecordedLogs();
    }

    function _liq(uint32 idx, uint64 px) internal view returns (uint256) {
        IGainsDiamond.Trade memory t = D.getTrade(address(v), idx);
        return D.getTradeLiquidationPrice(
            IGainsDiamond.LiqPriceInput({
                collateralIndex: t.collateralIndex,
                trader: t.user,
                pairIndex: t.pairIndex,
                index: t.index,
                openPrice: t.openPrice,
                long: t.long,
                collateral: t.collateralAmount,
                leverage: t.leverage,
                additionalFeeCollateral: 0,
                liquidationParams: D.getTradeLiquidationParams(t.user, t.index),
                currentPairPrice: px,
                isCounterTrade: false,
                partialCloseMultiplier: 1e18,
                beforeOpened: false
            })
        );
    }

    /// @dev band 0 NAV at `px`: navPrice mocked to (px, 0).
    function _nav0(uint16 pair, uint64 px) internal returns (int256) {
        vm.mockCall(address(pol), abi.encodeCall(GainsVaultPolicy.navPrice, (uint32(pair))), abi.encode(px, uint16(0)));
        return int256(v.totalAssets());
    }

    // ------------------------------------------------------------------ one case
    function _run(uint256 i) internal {
        Case memory k = c[i];
        vm.createSelectFork("arbitrum", k.tx_);
        l1Start = vm.getBlockNumber();
        arbStart = k.block_;
        vm.etch(ARB_SYS, hex"00");
        _mockArb();

        Row memory r;
        IGainsDiamond.Trade memory tr = D.getTrade(k.trader, k.index);
        r.collR = tr.collateralAmount;
        r.lev = tr.leverage;
        r.long = tr.long;
        r.openR = tr.openPrice;
        uint64 trig = k.kind == Kind.TP ? tr.tp : k.kind == Kind.SL ? tr.sl : k.oraclePrice;
        r.execPx = k.oraclePrice; // Gains v10 executes TP / SL at the oracle answer (real LimitExecuted: marketPrice = answer x (1 + impact))
        {
            NavCalc.Breakdown memory br = k.kind == Kind.PARTIAL
                ? NavCalc.partialClose(DIAMOND, k.trader, k.index, r.execPx, k.collateralDelta)
                : NavCalc.value(DIAMOND, k.trader, k.index, r.execPx);
            // gross: collateral + pnl after impact, before fees / holding / realized pnl (the real trade's history)
            r.grossR = int256(br.collateral) + br.rawPnl;
            (r.holdR, r.realR, r.feeR) = (br.holdingFees, br.totalRealizedPnl, br.closingFee);
        }

        // collateral: the real one when the policy allows (>= 5 x min fee, size >= pair minimum), else scaled up
        uint256 minColl = 5 * D.getCollateralFromUsdNormalizedValue(USDC_INDEX, D.pairMinFeeUsd(k.pair));
        uint256 minPos = D.getCollateralFromUsdNormalizedValue(USDC_INDEX, D.pairMinPositionSizeUsd(k.pair));
        uint256 collV = r.collR;
        if (collV < minColl) collV = minColl * 11 / 10;
        if (collV * r.lev / 1e3 < minPos) collV = minPos * 1e3 * 11 / 10 / r.lev;
        r.collV = uint120(collV);
        r.notional = collV * r.lev / 1e3;
        _deploy(r.notional / 5 + 1_000e6);

        // open: Chainlink at the real open price for the policy check; two oracle passes so Gains' open price
        // (oracle + spread + impact) equals the real open price
        _setCl(_feedOf(k.pair), (r.openR / 100) * 100);
        uint256 snap = vm.snapshotState();
        (, uint64 o1) = _openAt(k.pair, r.long, r.collV, r.lev, r.openR, r.openR);
        vm.revertToState(snap);
        _mockArb();
        _refresh();
        uint64 oracle2 = uint64(uint256(r.openR) * r.openR / o1);
        snap = vm.snapshotState();
        (, uint64 o2) = _openAt(k.pair, r.long, r.collV, r.lev, r.openR, oracle2);
        vm.revertToState(snap);
        _mockArb();
        _refresh();
        uint64 oracle3 = uint64(uint256(oracle2) * r.openR / o2);
        uint32 idx;
        (idx, r.openV) = _openAt(k.pair, r.long, r.collV, r.lev, r.openR, oracle3);
        if (k.kind == Kind.TP || k.kind == Kind.SL) {
            vm.prank(mgr);
            v.setSlTp(idx, k.kind == Kind.SL ? tr.sl : 0, k.kind == Kind.TP ? tr.tp : 0);
        }
        // GR2-KEY-01b (WP5 port): the manager's market close / partial close waits the 10-minute minimum hold (2,700 L2
        // blocks, 675 s); Gains' TP / SL / liquidation triggers are never held and keep the original 2 blocks
        _rollR(k.kind == Kind.MARKET || k.kind == Kind.PARTIAL ? HOLD_BLOCKS : 2);

        // NAV just before the exit: real band at the oracle answer, then band 0 at the execution price
        uint120 deltaV = k.kind == Kind.PARTIAL ? uint120(uint256(k.collateralDelta) * r.collV / r.collR) : 0;
        _setCl(_feedOf(k.pair), (r.execPx / 100) * 100);
        r.navRaw = int256(v.totalAssets());
        r.navBefore0 = _nav0(k.pair, r.execPx);
        {
            NavCalc.Breakdown memory bv = k.kind == Kind.PARTIAL
                ? NavCalc.partialClose(DIAMOND, address(v), idx, r.execPx, deltaV)
                : NavCalc.value(DIAMOND, address(v), idx, r.execPx);
            r.predV = bv.value;
            r.grossV = int256(bv.collateral) + bv.rawPnl;
            (r.holdV, r.feeV, r.realV) = (bv.holdingFees, bv.closingFee, bv.totalRealizedPnl);
            r.impModel = [bv.fixedSpreadP, bv.cumulVolPriceImpactP, bv.skewPriceImpactP];
            (r.modelPx, r.modelPnlP) = (bv.priceAfterImpact, bv.pnlPercent);
            r.liquidated = bv.liquidated;
        }

        uint256 bal0 = USDC.balanceOf(address(v));
        Vm.Log[] memory req;
        if (k.kind == Kind.MARKET) req = _call(mgr, abi.encodeCall(GainsVault.closeTrade, (idx, k.oraclePrice)));
        else if (k.kind == Kind.PARTIAL) req = _call(mgr, abi.encodeCall(GainsVault.reduceTrade, (idx, deltaV, 0, k.oraclePrice)));
        else if (k.kind == Kind.TP) req = _trigger(T_TP, idx);
        else if (k.kind == Kind.SL) req = _trigger(T_SL, idx);
        else req = _trigger(T_LIQ, idx);
        if (k.kind == Kind.LIQ) console2.log("  vault liq price / real answer low", _liq(idx, k.oraclePrice), ans[i][3]);
        _rollR(1);
        // Triggers: the real oracle answer of the exit tx (current, open, high, low; from its call trace; signed-price
        // triggers carry the aggregated answer). Market fills aggregate several node answers across txs (the median
        // is the event's oraclePrice), so they are answered at that price.
        uint64[4] memory a = ans[i];
        if (k.kind == Kind.MARKET || k.kind == Kind.PARTIAL) a = [k.oraclePrice, k.oraclePrice, k.oraclePrice, k.oraclePrice];
        if (diagMode == 1) a = [trig, trig, trig, trig];
        else if (diagMode == 2) a = [k.oraclePrice, k.oraclePrice, k.oraclePrice > trig ? k.oraclePrice : trig, k.oraclePrice < trig ? k.oraclePrice : trig];
        else if (diagMode == 3) a = [k.oraclePrice, k.oraclePrice, uint64(uint256(k.oraclePrice) * 1005 / 1000), uint64(uint256(trig) * 995 / 1000)];
        if (diagMode != 0) console2.log("  answer cur / open / hi / lo", a[0], a[1]);
        if (diagMode != 0) console2.log("    ", a[2], a[3]);
        Vm.Log[] memory fill = _answer4(req, a);
        r.paidV = int256(USDC.balanceOf(address(v)) - bal0);
        r.navAfter0 = _nav0(k.pair, r.execPx);
        // raw (real band) NAV after: drop the navPrice mock, Chainlink stays at the execution price
        vm.clearMockedCalls();
        _mockArb();
        _refresh();
        r.navAfterRaw = int256(v.totalAssets());
        r.scaledR = int256(k.kind == Kind.PARTIAL ? k.paid * deltaV / k.collateralDelta : k.paid * r.collV / r.collR);
        r.stillOpen = D.getTrade(address(v), idx).isOpen && k.kind != Kind.PARTIAL;
        _events(fill, r);

        _log(k, r);
        if (diagMode != 0) return;
        // end-to-end: the vault's USDC moved by exactly what Gains reports it sent
        assertEq(r.paidV, int256(r.evAmount), "vault balance delta != Gains amountSentToTrader");
        if (k.kind == Kind.MARKET || k.kind == Kind.PARTIAL) {
            // market exits: exactly the independent Gains model at the oracle answer
            // (partial closes: NavCalc.partialClose rounds per step; 0.01 bp of notional)
            assertApproxEqAbs(r.paidV, r.predV, k.kind == Kind.PARTIAL ? r.notional / 1e6 + 1 : 1, "vault realized != Gains model payout");
        }
        if (k.kind == Kind.LIQ) assertEq(r.paidV, 0, "liquidation pays nothing");
        // N4 on real exits: GainsNav with the real band never values what was closed above what Gains paid
        assertLe(r.navRaw - r.navAfterRaw, 0, "NAV (real band) above the payout");
        if (k.kind == Kind.LIQ && r.stillOpen) _liqContinue(k, r, idx);
    }

    /// @dev The vault's trade survived the real liquidation answer (no accrued holding fees: its liquidation price is
    ///      further away). Extend the path to just past the vault's own liquidation price and liquidate it there.
    function _liqContinue(Case memory k, Row memory r, uint32 idx) internal {
        uint64 liqV = uint64(_liq(idx, k.oraclePrice));
        uint64 px = r.long ? liqV - liqV / 100_000 : liqV + liqV / 100_000; // 0.1 bp past it
        int256 nav0 = _nav0(k.pair, px);
        vm.clearMockedCalls();
        _mockArb();
        _setCl(_feedOf(k.pair), (px / 100) * 100);
        int256 navRawAt = int256(v.totalAssets());
        uint256 idleBefore = v.idleAssets();
        Vm.Log[] memory req = _trigger(T_LIQ, idx);
        _rollR(1);
        uint256 bal0 = USDC.balanceOf(address(v));
        Row memory r2;
        _events(_answer4(req, [px, px, px, px]), r2);
        uint256 paid = USDC.balanceOf(address(v)) - bal0;
        bool open = D.getTrade(address(v), idx).isOpen;
        console2.log("  LIQ continued at the vault's liq price (liqV, answer)", liqV, px);
        console2.log("  event kind / cancelReason, paid, still open", r2.ev, paid, open);
        console2.log("  NAV0 / NAV(real band) just before minus idle (trade value):");
        console2.logInt(nav0 - int256(idleBefore));
        console2.logInt(navRawAt - int256(idleBefore));
        assertFalse(open, "vault trade liquidated at its own liq price");
        assertEq(paid, 0, "liquidation pays nothing");
        assertEq(navRawAt, int256(idleBefore), "N3: a trade at its liquidation price is worth 0 in NAV");
    }

    bytes32 internal constant TRIGGER_CANCELED = keccak256("TriggerOrderCanceled((address,uint32),address,uint8,uint8)");

    function _events(Vm.Log[] memory fill, Row memory r) internal pure {
        for (uint256 i; i < fill.length; i++) {
            Vm.Log memory l = fill[i];
            if (l.emitter != address(DIAMOND)) continue;
            bytes32 t0 = l.topics[0];
            if (t0 == G.MarketExecuted.selector) {
                (,,, r.evMarketPx, r.evAmount) = _decodeMarketExecuted(l);
                r.ev = 1;
            } else if (t0 == G.LimitExecuted.selector) {
                G.Trade memory t;
                uint8 ot;
                uint256 op;
                G.TradePriceImpact memory pi;
                int256 pp;
                uint256 cp;
                (, t,, ot, op, r.evMarketPx,, pi, pp, r.evAmount, cp, r.evExact) = abi.decode(
                    l.data,
                    (G.Id, G.Trade, address, uint8, uint256, uint256, uint256, G.TradePriceImpact, int256, uint256, uint256, bool)
                );
                r.ev = 2;
                r.impEvent = [pi.fixedSpreadP, pi.cumulVolPriceImpactP, pi.skewPriceImpactP];
                r.evPnlP = pp;
            } else if (t0 == G.PositionSizeDecreaseExecuted.selector) {
                r.ev = 3;
            } else if (t0 == TRIGGER_CANCELED) {
                (,, r.cancelReason) = abi.decode(l.data, (G.Id, uint8, uint8));
                r.ev = 4;
            } else if (t0 == G.TradeValueTransferred.selector) {
                (int256 sent,) = abi.decode(l.data, (int256, int256));
                r.evTransfer = sent > 0 ? uint256(sent) : 0;
            }
        }
        if (r.ev == 3) r.evAmount = r.evTransfer;
    }

    function _bps(int256 x, uint256 base) internal pure returns (int256) {
        return base == 0 ? int256(0) : (x * 1e6) / int256(base); // 1e-2 bp units
    }

    function _log(Case memory k, Row memory r) internal pure {
        string[5] memory names = ["MARKET", "PARTIAL", "TP", "SL", "LIQ"];
        console2.log("ROW", names[uint8(k.kind)], k.pair, r.long ? "long" : "short");
        console2.logBytes32(k.tx_);
        console2.log("  lev 1e3, collR, collV", r.lev, r.collR, r.collV);
        console2.log("  openR, openV, execPx", r.openR, r.openV, r.execPx);
        console2.log("  notional", r.notional, r.liquidated ? "liquidated(model)" : "");
        console2.log("  paid real, real scaled, vault paid, model");
        console2.log("   ", k.paid);
        console2.logInt(r.scaledR);
        console2.logInt(r.paidV);
        console2.logInt(r.predV);
        console2.log("  e1 vault - model (1e-6 USDC):");
        console2.logInt(r.paidV - r.predV);
        console2.log("  e3 vault - real scaled (1e-6 USDC), in 0.01 bp of real scaled payout, of notional:");
        console2.logInt(r.paidV - r.scaledR);
        console2.logInt(_bps(r.paidV - r.scaledR, uint256(r.scaledR > 0 ? r.scaledR : int256(1))));
        console2.logInt(_bps(r.paidV - r.scaledR, r.notional));
        int256 gR = k.kind == Kind.PARTIAL ? r.grossR * int256(uint256(r.collV)) / int256(uint256(r.collR)) : r.grossR * int256(uint256(r.collV)) / int256(uint256(r.collR));
        console2.log("  e3g gross value vault - real scaled (1e-6 USDC), 0.01 bp of notional:");
        console2.logInt(r.grossV - gR);
        console2.logInt(_bps(r.grossV - gR, r.notional));
        console2.log("  e2 NAV0 before - NAV0 after (= value - payout) (1e-6 USDC), 0.01 bp of notional:");
        console2.logInt(r.navBefore0 - r.navAfter0);
        console2.logInt(_bps(r.navBefore0 - r.navAfter0, r.notional));
        console2.log("  e2raw NAV(real band) before - after (= band value - payout) (1e-6 USDC), 0.01 bp of notional:");
        console2.logInt(r.navRaw - r.navAfterRaw);
        console2.logInt(_bps(r.navRaw - r.navAfterRaw, r.notional));
        console2.log("  history: real holding fees, real realized pnl, real closing fee, vault holding fees, vault closing fee, vault realized pnl");
        console2.logInt(r.holdR);
        console2.logInt(r.realR);
        console2.log("   ", r.feeR);
        console2.logInt(r.holdV);
        console2.log("   ", r.feeV);
        console2.logInt(r.realV);
        console2.log("  impact model (spread, cumul, skew) / trigger event:");
        console2.logInt(r.impModel[0]);
        console2.logInt(r.impModel[1]);
        console2.logInt(r.impModel[2]);
        console2.logInt(r.impEvent[0]);
        console2.logInt(r.impEvent[1]);
        console2.logInt(r.impEvent[2]);
        console2.log("  model price after impact / pnl%, event pnl%", r.modelPx);
        console2.logInt(r.modelPnlP);
        console2.logInt(r.evPnlP);
        console2.log("  event kind, cancelReason, exact", r.ev, r.cancelReason, r.evExact);
        console2.log("  event marketPrice, amountSent, trade still open", r.evMarketPx, r.evAmount, r.stillOpen);
        console2.log("  band: NAV(real band, CL = exec price) - NAV0 (1e-6 USDC), 0.01 bp of notional:");
        console2.logInt(r.navRaw - r.navBefore0);
        console2.logInt(_bps(r.navRaw - r.navBefore0, r.notional));
    }
}
