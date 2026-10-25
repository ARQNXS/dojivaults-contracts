// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import "./GainsForkBase.sol";
import {NavCalc} from "../spike/NavCalc.sol";
import {GainsVault} from "../../../src/gains/GainsVault.sol";
import {GainsVaultFactory} from "../../../src/gains/GainsVaultFactory.sol";
import {GainsVaultPolicy} from "../../../src/gains/GainsVaultPolicy.sol";
import {GainsVaultLens} from "../../../src/gains/GainsVaultLens.sol";
import {GainsPrice} from "../../../src/gains/GainsPrice.sol";
import {GainsNav} from "../../../src/gains/GainsNav.sol";
import {IGainsDiamond} from "../../../src/gains/IGainsDiamond.sol";
import {IGainsVaultErrors, OpenParams} from "../../../src/gains/GainsTypes.sol";

interface IGainsTrigger {
    function triggerOrder(uint256 packed) external;
    function getChainlinkToken() external view returns (address);
}

/// @notice Stage 1 fork tests (PLAN.md 4.6, 7): a GainsVault from a GainsVaultFactory trades the real gTrade v10
///         diamond on an Arbitrum One fork. Every fill runs the deployed facets, answered by the Stage 0 oracle
///         emulation (GainsForkBase). Chainlink is frozen with mockCall so the tests choose C; the oracle answer is
///         chosen per fill. Filling at the adverse band edge P makes GainsNav's value directly comparable with the
///         USDC Gains pays (exact), filling at C shows the band's conservatism.
contract GainsVaultForkTest is GainsForkBase {
    address internal constant BTC_USD = 0x6ce185860a4963106506C203335A2910413708e9;
    address internal constant ETH_USD = 0x639Fe6ab55C921f74e7fac1ee960C0B6293ba612;
    address internal constant SOL_USD = 0x24ceA4b8ce57cdA5058b924B9B9987992450590c;
    address internal constant SEQ = 0xFdB631F5EE196F0ed6FAa767959853A9F217697D;
    uint16 internal constant BAND = 20;

    GainsVaultFactory internal factory;
    GainsVault internal v;
    GainsVaultPolicy internal pol;
    GainsVaultLens internal lens;

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

    mapping(address feed => uint64) internal cl;

    function setUp() public override {
        super.setUp();
        if (!forked) return;
        _setCl(BTC_USD, _round(_chainlink1e10(BTC_USD)));
        _setCl(ETH_USD, _round(_chainlink1e10(ETH_USD)));
        _setCl(SOL_USD, _round(_chainlink1e10(SOL_USD)));

        GainsVault impl = new GainsVault();
        GainsVaultPolicy pimpl = new GainsVaultPolicy();
        lens = new GainsVaultLens();
        factory = new GainsVaultFactory(
            fOwner, address(impl), address(pimpl), USDC, IGainsDiamond(address(DIAMOND)), SEQ, 3_600, treasury, fGuardian, fSentinel
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
                name: "Gains Fork Vault",
                symbol: "gFV",
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
        return (px / 100) * 100; // Chainlink 8 decimals in 1e10
    }

    function _feed(uint16 pair) internal pure returns (address) {
        return pair == BTC ? BTC_USD : pair == ETH ? ETH_USD : SOL_USD;
    }

    /// @dev Freezes a Chainlink feed at `px` (1e10), updated now.
    function _setCl(address feed, uint64 px) internal {
        cl[feed] = px;
        uint256 t = vm.getBlockTimestamp();
        vm.mockCall(
            feed,
            abi.encodeWithSelector(IChainlinkFeed.latestRoundData.selector),
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

    /// @dev GR2-KEY-01b (WP5 port): the minimum hold with the Chainlink mocks kept fresh.
    function _passHold() internal override {
        _rollFresh(HOLD_BLOCKS);
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

    // ------------------------------------------------------------------ open, close, partial
    function test_fork_openAndCloseThroughTheVault_navExactAtTheValuationPrice() public {
        _depositSettle(alice, 10_000e6);
        uint256 navStart = v.totalAssets();
        uint32 idx = _openFilledV(ETH, true, 1_000e6, 5_000);
        G.Trade memory t = DIAMOND.getTrade(address(v), idx);
        assertEq(t.user, address(v), "the vault is the Gains trader");
        assertEq(t.collateralAmount, 1_000e6);
        assertEq(USDC.allowance(address(v), address(DIAMOND)), 0, "exact approval, consumed");
        assertLt(v.totalAssets(), navStart, "the band and the opening fee are booked at once");

        _passHold(); // GR2-KEY-01b (WP5 port): the manager's exit waits the 10-minute minimum hold
        _setCl(ETH_USD, _round(cl[ETH_USD] * 101 / 100)); // +1%
        uint64 p = _adverse(ETH, true);
        Vm.Log[] memory req = _req(mgr, abi.encodeCall(GainsVault.closeTrade, (idx, p)));
        _rollFresh(1);
        uint256 value = v.venue().value; // the pending close leaves the trade valued as open
        NavCalc.Breakdown memory b = NavCalc.value(DIAMOND, address(v), idx, p);
        assertEq(int256(value), b.value, "GainsNav == NavCalc (Gains' close path) at P");
        uint256 before = _usdc();
        Vm.Log[] memory fill = _fill(req, p); // Gains' oracle answers exactly the valuation price
        uint256 paid = _usdc() - before;
        (,,,, uint256 sent) = _decodeMarketExecuted(_find(fill, G.MarketExecuted.selector));
        assertEq(paid, sent, "the payout came back to the vault");
        assertEq(paid, value, "NAV at the valuation price == USDC Gains paid at that price (exact)");
        assertEq(v.totalAssets(), _usdc() - v.claimableRedeemAssets());
        console2.log("open+close ETH 5x +1%: paid", paid);
    }

    function test_fork_navIsConservativeAtTheChainlinkPrice() public {
        _depositSettle(alice, 10_000e6);
        uint32 idx = _openFilledV(BTC, false, 2_000e6, 10_000);
        _passHold(); // GR2-KEY-01b (WP5 port): was _rollFresh(1_000); the manager's close waits the 10-minute minimum hold
        uint64 c = cl[BTC_USD];
        Vm.Log[] memory req = _req(mgr, abi.encodeCall(GainsVault.closeTrade, (idx, c)));
        _rollFresh(1);
        uint256 nav = v.totalAssets();
        uint256 notional = v.venue().notional;
        uint256 idle = v.idleAssets();
        uint256 before = _usdc();
        _fill(req, c); // the oracle at Chainlink
        uint256 paid = _usdc() - before;
        assertLe(nav, idle + paid, "NAV never above the payout at the oracle price");
        assertLe(idle + paid - nav, (2 * uint256(BAND) * notional) / 10_000, "within 2 x band x notional (PLAN.md 4.3)");
        console2.log("BTC short 10x: NAV gap vs payout at C (USDC 1e6)", idle + paid - nav);
    }

    function test_fork_partialCloseThenClose_navContinuousAcrossFills() public {
        _depositSettle(alice, 20_000e6);
        uint32 idx = _openFilledV(ETH, true, 2_000e6, 10_000);
        _rollFresh(345_600); // a day of funding and borrowing
        _setCl(ETH_USD, _round(cl[ETH_USD] * 1005 / 1000));
        uint64 p = _adverse(ETH, true);

        Vm.Log[] memory req = _req(mgr, abi.encodeCall(GainsVault.reduceTrade, (idx, uint120(800e6), uint24(0), p)));
        _rollFresh(1);
        uint256 navBefore = v.totalAssets();
        NavCalc.Breakdown memory pc = NavCalc.partialClose(DIAMOND, address(v), idx, p, 800e6);
        uint256 before = _usdc();
        Vm.Log[] memory fill = _fill(req, p);
        assertEq(_count(fill, G.PositionSizeDecreaseExecuted.selector), 1);
        uint256 paid = _usdc() - before;
        assertEq(int256(paid), pc.value, "partial close payout == Gains' formula at P");
        uint256 navAfter = v.totalAssets();
        assertApproxEqAbs(navAfter, navBefore, 2, "NAV continuous across a fill at the valuation price");

        _rollFresh(345_600);
        p = _adverse(ETH, true);
        req = _req(mgr, abi.encodeCall(GainsVault.closeTrade, (idx, p)));
        _rollFresh(1);
        uint256 value = v.venue().value;
        before = _usdc();
        _fill(req, p);
        assertEq(_usdc() - before, value, "remaining 12 USDC close: exact");
    }

    // ------------------------------------------------------------------ TP, SL, liquidation executed by Gains
    function _trigger(uint8 orderType, uint32 idx) internal returns (Vm.Log[] memory logs) {
        address link = IGainsTrigger(address(DIAMOND)).getChainlinkToken();
        deal(link, bot, 10e18);
        vm.prank(bot);
        IERC20(link).approve(address(DIAMOND), type(uint256).max);
        uint256 packed = uint256(orderType) | (uint256(uint160(address(v))) << 8) | (uint256(idx) << 168);
        vm.recordLogs();
        vm.prank(bot);
        IGainsTrigger(address(DIAMOND)).triggerOrder(packed);
        logs = vm.getRecordedLogs();
    }

    /// @dev An oracle answer with a range (open / high / low), as the nodes report it for a lookback trigger. Gains
    ///      compares TP and SL with the market price (oracle + skew impact at size 0), so an answer exactly at the
    ///      trigger may read as NOT_HIT; a range around it is an exact execution at the trigger.
    function _fillRange(Vm.Log[] memory requestLogs, uint64 open, uint64 high, uint64 low) internal returns (Vm.Log[] memory fillLogs) {
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

    function _limitExecuted(Vm.Log[] memory fill) internal pure returns (uint8 orderType, uint256 sent) {
        Vm.Log memory l = _find(fill, G.LimitExecuted.selector);
        (,,, orderType,,,,,, sent,,) = abi.decode(
            l.data,
            (G.Id, G.Trade, address, uint8, uint256, uint256, uint256, G.TradePriceImpact, int256, uint256, uint256, bool)
        );
    }

    function test_fork_takeProfitExecutedByGains() public {
        _depositSettle(alice, 10_000e6);
        uint32 idx = _openFilledV(ETH, true, 1_000e6, 5_000);
        uint64 c = cl[ETH_USD];
        uint64 tp = c * 101 / 100;
        uint64 sl = c * 95 / 100;
        vm.prank(mgr);
        v.setSlTp(idx, sl, tp);
        assertEq(DIAMOND.getTrade(address(v), idx).tp, tp);
        _rollFresh(100);
        _setCl(ETH_USD, _round(tp));
        Vm.Log[] memory req = _trigger(4, idx);
        _rollFresh(1);
        uint256 before = _usdc();
        Vm.Log[] memory fill = _fillRange(req, tp * 1001 / 1000, tp * 1001 / 1000, tp * 999 / 1000);
        (uint8 ot, uint256 sent) = _limitExecuted(fill);
        assertEq(ot, 4, "TP_CLOSE");
        assertEq(_usdc() - before, sent, "TP payout to the vault");
        assertEq(_openTradesOf().length, 0);
        assertEq(v.totalAssets(), _usdc() - v.claimableRedeemAssets(), "all idle again");
        console2.log("TP payout", sent);
    }

    function test_fork_stopLossExecutedByGains() public {
        _depositSettle(alice, 10_000e6);
        uint32 idx = _openFilledV(BTC, false, 1_000e6, 5_000);
        uint64 sl = cl[BTC_USD] * 102 / 100; // short: stop above
        vm.prank(mgr);
        v.setSlTp(idx, sl, 0);
        _rollFresh(100);
        _setCl(BTC_USD, _round(sl));
        Vm.Log[] memory req = _trigger(5, idx);
        _rollFresh(1);
        uint256 nav = v.totalAssets();
        uint256 before = _usdc();
        Vm.Log[] memory fill = _fillRange(req, sl * 1001 / 1000, sl * 1001 / 1000, sl * 999 / 1000);
        (uint8 ot, uint256 sent) = _limitExecuted(fill);
        assertEq(ot, 5, "SL_CLOSE");
        assertEq(_usdc() - before, sent);
        assertLe(nav, v.totalAssets() + 1, "NAV before the SL was never above what it paid");
        console2.log("SL payout", sent);
    }

    function test_fork_liquidationValuedAtZeroBeforeGainsLiquidates() public {
        _depositSettle(alice, 10_000e6);
        uint32 idx = _openFilledV(ETH, true, 10e6, 100_000); // 100x, 1,000 USD position
        uint256 liq = NavCalc.liquidationPrice(DIAMOND, DIAMOND.getTrade(address(v), idx), cl[ETH_USD]);
        // Chainlink still above the liquidation price, but within the band of it: GainsNav says 0 already.
        _setCl(ETH_USD, _round(uint64(liq * (10_000 + 10) / 10_000)));
        assertEq(v.venue().value, 0, "within the band of liquidation: valued at 0");
        uint64 crash = uint64(liq * 99 / 100);
        _setCl(ETH_USD, _round(crash));
        Vm.Log[] memory req = _trigger(6, idx);
        _rollFresh(1);
        uint256 before = _usdc();
        Vm.Log[] memory fill = _fill(req, crash);
        (uint8 ot, uint256 sent) = _limitExecuted(fill);
        assertEq(ot, 6, "LIQ_CLOSE");
        assertEq(sent, 0);
        assertEq(_usdc(), before, "a liquidation pays nothing, as valued");
        assertEq(_openTradesOf().length, 0);
    }

    function _openTradesOf() internal view returns (G.Trade[] memory) {
        return DIAMOND.getTrades(address(v));
    }

    // ------------------------------------------------------------------ timeout, cancel, callback cancel
    function test_fork_timedOutOpenBlocksSettleUntilAnyoneCancels() public {
        _depositSettle(alice, 10_000e6);
        vm.prank(bob);
        v.requestDeposit(1_000e6, bob);
        _rollFresh(4 * 3_600); // GR1-02: the settles below price bob, so they run an hour into the epoch
        uint256 usdcBefore = _usdc();
        _req(mgr, abi.encodeCall(GainsVault.openTrade, (_openParams(ETH, true, 1_000e6, 5_000))));
        assertEq(_usdc(), usdcBefore - 1_000e6, "collateral pulled at request");
        IGainsDiamond.PendingOrder[] memory o = IGainsDiamond(address(DIAMOND)).getPendingOrders(address(v));
        assertEq(o.length, 1);
        uint32 orderIndex = o[0].index;

        _rollFresh(199);
        assertEq(lens.timedOutOrders(v).length, 0);
        vm.prank(bob);
        vm.expectRevert(); // Gains: WaitTimeout
        v.cancelTimedOut(orderIndex);
        _rollFresh(1); // exactly 200 L2 blocks
        assertEq(lens.timedOutOrders(v).length, 1, "the keeper sees it");
        v.checkRisk();
        vm.prank(keeper);
        vm.expectRevert(IGainsVaultErrors.OrdersPending.selector);
        v.settle();

        vm.prank(bob); // anyone: the vault calls cancelOrderAfterTimeout as the trader
        v.cancelTimedOut(orderIndex);
        assertEq(_usdc(), usdcBefore, "full collateral back");
        assertFalse(v.ordersPending());
        vm.prank(keeper);
        v.settle();
    }

    function test_fork_restingLimitOrderValuedAndCancelled() public {
        _depositSettle(alice, 10_000e6);
        OpenParams memory p = _openParams(ETH, true, 1_000e6, 5_000);
        p.tradeType = 1;
        p.expectedPrice = cl[ETH_USD] * 95 / 100;
        uint256 nav = v.totalAssets();
        vm.prank(mgr);
        v.openTrade(p);
        assertEq(v.totalAssets(), nav, "resting collateral valued in full");
        G.Trade[] memory t = _openTradesOf();
        assertEq(t[0].tradeType, 1);
        vm.prank(mgr);
        v.cancelOrder(t[0].index);
        assertEq(v.totalAssets(), nav);
        assertEq(_openTradesOf().length, 0);
    }

    function test_fork_callbackCancelledOpenValuedNetOfTheGovFee() public {
        _depositSettle(alice, 10_000e6);
        Vm.Log[] memory req = _req(mgr, abi.encodeCall(GainsVault.openTrade, (_openParams(ETH, true, 1_000e6, 5_000))));
        _rollFresh(1);
        uint256 navPending = v.totalAssets();
        Vm.Log[] memory fill = _fill(req, cl[ETH_USD] * 105 / 100); // 5% away, 1% slippage: the callback cancels
        assertEq(_count(fill, G.MarketOpenCanceled.selector), 1);
        assertEq(v.totalAssets(), navPending, "pending open valued at exactly what a cancel returns");
        assertFalse(v.ordersPending());
    }

    // ------------------------------------------------------------------ full epoch cycle
    function test_fork_epochCycle_navCheckedAgainstPayouts() public {
        _depositSettle(alice, 60_000e6);
        vm.prank(bob);
        v.requestDeposit(40_000e6, bob);
        _rollFresh(4 * 3_600);
        v.checkRisk();
        vm.prank(keeper);
        v.settle();
        v.claim(bob);
        uint256 supply0 = v.totalSupply();
        assertGt(supply0, 0);

        uint32 eth = _openFilledV(ETH, true, 20_000e6, 3_000);
        uint32 btc = _openFilledV(BTC, false, 10_000e6, 2_000);
        _rollFresh(86_400); // six hours
        _setCl(ETH_USD, _round(cl[ETH_USD] * 1012 / 1000));
        _setCl(BTC_USD, _round(cl[BTC_USD] * 1004 / 1000));
        v.checkRisk();

        // bob leaves: the BTC short is closed at the valuation price to fund him; NAV prices his shares.
        uint256 bobShares = v.balanceOf(bob);
        vm.prank(bob);
        v.requestRedeem(bobShares, bob, bob);
        uint64 pb = _adverse(BTC, false);
        Vm.Log[] memory req = _req(mgr, abi.encodeCall(GainsVault.closeTrade, (btc, pb)));
        _rollFresh(1);
        uint256 btcValue = v.venue().value;
        uint256 b0 = _usdc();
        _fill(req, pb);
        uint256 btcPaid = _usdc() - b0;
        assertLe(v.venue().value + btcPaid, btcValue + 1, "BTC payout == its NAV share");
        _rollFresh(4 * 3_600);
        v.checkRisk();
        uint256 navAtSettle = v.totalAssets();
        uint256 bobOwed = (bobShares * (navAtSettle + 1)) / (v.totalSupply() + 1e6);
        vm.prank(keeper);
        v.settle();
        uint256 bobBefore = USDC.balanceOf(bob);
        v.claim(bob);
        assertApproxEqAbs(USDC.balanceOf(bob) - bobBefore, bobOwed, 1, "bob paid his share of NAV");

        // alice leaves: the ETH long closes at Chainlink (better than the band edge), the surplus is hers.
        uint256 aliceShares = v.balanceOf(alice);
        vm.prank(alice);
        v.requestRedeem(aliceShares, alice, alice);
        uint64 c = cl[ETH_USD];
        req = _req(mgr, abi.encodeCall(GainsVault.closeTrade, (eth, c)));
        _rollFresh(1);
        uint256 navBefore = v.totalAssets();
        uint256 notional = v.venue().notional;
        b0 = _usdc();
        _fill(req, c);
        uint256 navAfter = v.totalAssets();
        assertGe(navAfter, navBefore, "closing at C never lowers NAV");
        assertLe(navAfter - navBefore, (2 * uint256(BAND) * notional) / 10_000, "gap within 2 x band x notional");
        _rollFresh(4 * 3_600);
        v.checkRisk();
        vm.prank(keeper);
        v.settle();
        uint256 aliceBefore = USDC.balanceOf(alice);
        v.claim(alice);
        uint256 alicePaid = USDC.balanceOf(alice) - aliceBefore;

        // Conservation: what went in == what came out + what is still in the vault (seed and rounding).
        assertEq(v.totalSupply(), 0, "everyone out");
        uint256 left = _usdc();
        assertLe(left, 1e6 + 10, "only the creator's 1 USDC seed (and rounding) stays");
        console2.log("bob paid", USDC.balanceOf(bob) - bobBefore, "alice paid", alicePaid);
        console2.log("left in the vault", left);
    }

    // ------------------------------------------------------------------ exits under a price outage
    function test_fork_exitsWithTheSequencerDownAndFeedsBroken() public {
        _depositSettle(alice, 10_000e6);
        uint32 a = _openFilledV(ETH, true, 1_000e6, 5_000);
        _openFilledV(ETH, false, 1_000e6, 3_000);
        uint32 c = _openFilledV(BTC, true, 1_000e6, 5_000);
        _passHold(); // GR2-KEY-01b (WP5 port): the manager's exit waits the 10-minute minimum hold
        vm.mockCall(
            SEQ, abi.encodeWithSelector(IChainlinkFeed.latestRoundData.selector), abi.encode(uint80(1), int256(1), uint256(1), uint256(1), uint80(1))
        );
        vm.mockCallRevert(ETH_USD, abi.encodeWithSelector(IChainlinkFeed.latestRoundData.selector), "down");
        vm.expectRevert(GainsPrice.SequencerDown.selector);
        v.totalAssets();

        uint64 pe = cl[ETH_USD];
        Vm.Log[] memory r1 = _req(mgr, abi.encodeCall(GainsVault.closeTrade, (a, pe)));
        Vm.Log[] memory r2 = _req(mgr, abi.encodeCall(GainsVault.reduceTrade, (c, uint120(400e6), uint24(0), cl[BTC_USD])));
        vm.prank(fSentinel);
        v.triggerBreach();
        Vm.Log[] memory r3 = _req(fSentinel, abi.encodeCall(GainsVault.flatten, (ETH, 0, pe, type(uint256).max)));
        _roll(1);
        uint256 b0 = _usdc();
        _fill(r1, pe);
        _fill(r2, cl[BTC_USD]);
        _fill(r3, pe);
        assertGt(_usdc(), b0, "exits filled and paid with every price source down");
        assertEq(IGainsDiamond(address(DIAMOND)).getPendingOrders(address(v)).length, 0);
    }

    // ------------------------------------------------------------------ gas per vault action (PLAN.md 4.4)
    function test_fork_gasPerVaultAction() public {
        uint256 g;
        g = gasleft();
        _create(bytes32(uint256(2)));
        console2.log("gas create (factory, 2 clones + init, seed)", g - gasleft());

        vm.prank(alice);
        g = gasleft();
        v.requestDeposit(50_000e6, alice);
        console2.log("gas requestDeposit", g - gasleft());
        _rollFresh(4 * 3_600);
        g = gasleft();
        v.checkRisk();
        console2.log("gas checkRisk (0 trades)", g - gasleft());
        vm.prank(keeper);
        g = gasleft();
        v.settle();
        console2.log("gas settle (0 trades)", g - gasleft());
        v.claim(alice);

        OpenParams memory p = _openParams(ETH, true, 1_000e6, 5_000);
        vm.recordLogs();
        vm.prank(mgr);
        g = gasleft();
        v.openTrade(p);
        console2.log("gas openTrade (market request)", g - gasleft());
        Vm.Log[] memory req = vm.getRecordedLogs();
        _rollFresh(1);
        Vm.Log[] memory fill = _fill(req, cl[ETH_USD]);
        uint32 idx = uint32(uint256(_find(fill, G.MarketExecuted.selector).topics[2]));

        vm.recordLogs();
        vm.prank(mgr);
        g = gasleft();
        v.increaseTrade(idx, 500e6, 5_000, cl[ETH_USD], 1_000);
        console2.log("gas increaseTrade (request)", g - gasleft());
        req = vm.getRecordedLogs();
        _rollFresh(1);
        _fill(req, cl[ETH_USD]);

        vm.recordLogs();
        vm.prank(mgr);
        g = gasleft();
        v.updateLeverage(idx, 4_000);
        console2.log("gas updateLeverage lower (request)", g - gasleft());
        req = vm.getRecordedLogs();
        _rollFresh(1);
        _fill(req, cl[ETH_USD]);

        vm.prank(mgr);
        g = gasleft();
        v.setSlTp(idx, cl[ETH_USD] * 90 / 100, cl[ETH_USD] * 120 / 100);
        console2.log("gas setSlTp (both)", g - gasleft());

        for (uint256 i; i < 2; ++i) {
            _openFilledV(i == 0 ? BTC : SOL, i == 0, 1_000e6, 3_000);
        }
        g = gasleft();
        v.totalAssets();
        console2.log("gas totalAssets view (3 trades)", g - gasleft());
        g = gasleft();
        v.checkRisk();
        console2.log("gas checkRisk (3 trades)", g - gasleft());

        _passHold(); // GR2-KEY-01b (WP5 port): the manager's exit waits the 10-minute minimum hold
        vm.recordLogs();
        vm.prank(mgr);
        g = gasleft();
        v.reduceTrade(idx, 500e6, 0, cl[ETH_USD]);
        console2.log("gas reduceTrade (request)", g - gasleft());
        req = vm.getRecordedLogs();
        _rollFresh(1);
        _fill(req, cl[ETH_USD]);

        vm.recordLogs();
        vm.prank(mgr);
        g = gasleft();
        v.closeTrade(idx, cl[ETH_USD]);
        console2.log("gas closeTrade (request)", g - gasleft());
        req = vm.getRecordedLogs();
        _rollFresh(1);
        _fill(req, cl[ETH_USD]);

        OpenParams memory lp = _openParams(ETH, true, 1_000e6, 5_000);
        lp.tradeType = 1;
        lp.expectedPrice = cl[ETH_USD] * 95 / 100;
        vm.prank(mgr);
        g = gasleft();
        v.openTrade(lp);
        console2.log("gas openTrade (limit, stored)", g - gasleft());
        G.Trade[] memory ts = _openTradesOf();
        vm.prank(mgr);
        g = gasleft();
        v.cancelOrder(ts[ts.length - 1].index);
        console2.log("gas cancelOrder (limit)", g - gasleft());

        _req(mgr, abi.encodeCall(GainsVault.openTrade, (_openParams(ETH, false, 1_000e6, 5_000))));
        IGainsDiamond.PendingOrder[] memory o = IGainsDiamond(address(DIAMOND)).getPendingOrders(address(v));
        _rollFresh(200);
        vm.prank(bob);
        g = gasleft();
        v.cancelTimedOut(o[0].index);
        console2.log("gas cancelTimedOut", g - gasleft());

        _openFilledV(ETH, true, 1_000e6, 5_000);
        _openFilledV(ETH, false, 1_000e6, 5_000);
        vm.recordLogs();
        vm.prank(fGuardian);
        g = gasleft();
        v.flatten(ETH, 0, cl[ETH_USD], type(uint256).max);
        console2.log("gas flatten (2 ETH trades, 2 close requests)", g - gasleft());
        req = vm.getRecordedLogs();
        assertEq(IGainsDiamond(address(DIAMOND)).getPendingOrders(address(v)).length, 2);
        _rollFresh(1);
        _fill(req, cl[ETH_USD]);
        assertEq(IGainsDiamond(address(DIAMOND)).getPendingOrders(address(v)).length, 0);

        // NAV gas at the MAX_POSITIONS ceiling
        uint256 n = v.venue().orders;
        while (n < v.MAX_POSITIONS()) {
            _openFilledV(n % 2 == 0 ? BTC : ETH, n % 3 == 0, 300e6, 2_000);
            n = v.venue().orders;
        }
        g = gasleft();
        v.totalAssets();
        console2.log("gas totalAssets view (MAX_POSITIONS = 20 trades)", g - gasleft());
        _rollFresh(4 * 3_600);
        g = gasleft();
        v.checkRisk();
        console2.log("gas checkRisk (20 trades)", g - gasleft());
        uint256 redeemShares = v.balanceOf(alice) / 100;
        vm.prank(alice);
        v.requestRedeem(redeemShares, alice, alice);
        vm.prank(keeper);
        g = gasleft();
        v.settle();
        console2.log("gas settle (20 trades)", g - gasleft());
        vm.prank(mgr);
        vm.expectRevert(abi.encodeWithSelector(IGainsVaultErrors.TooManyPositions.selector, 20, 20));
        v.openTrade(_openParams(ETH, true, 300e6, 2_000));
    }

    // ------------------------------------------------------------------ gas at the MAX_POSITIONS ceiling
    /// @dev Execution gas of one vault call. Forge 1.8 runs each top-level call of a test with cold accounts and slots
    ///      (checked: re-reading 100 slots written by the previous call costs ~2,250 gas each), so this is the
    ///      transaction's execution gas; add 21,000 + calldata for the total.
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

    /// @dev 20 positions spread over every curated pair (BTC, ETH, SOL). Worst case: all of them open market trades,
    ///      the expensive kind to value. openTrade and increaseTrade are measured at 19 (the last allowed), the NAV
    ///      readers at 20. Each must stay under 10M gas, except a settle that prices deposits (14M, GR1-02).
    function test_fork_gasAtMaxPositions() public {
        _depositSettle(alice, 100_000e6);
        uint16[3] memory pairs = [BTC, ETH, SOL];
        uint256 n = v.venue().orders;
        while (n < v.MAX_POSITIONS() - 1) {
            _openFilledV(pairs[n % 3], n % 2 == 0, 400e6, 3_000);
            n = v.venue().orders;
        }
        assertEq(n, 19);
        uint256 g;
        uint256 limit = 10_000_000;

        // increaseTrade at 19 open trades (adds collateral and size to the first trade), then filled
        G.Trade[] memory ts = _openTradesOf();
        Vm.Log[] memory req;
        (g, req) = _gas(mgr, abi.encodeCall(GainsVault.increaseTrade, (ts[0].index, 100e6, 3_000, cl[_feed(ts[0].pairIndex)], 1_000)));
        console2.log("gas increaseTrade (19 trades)", g);
        assertLt(g, limit, "increaseTrade");
        _rollFresh(1);
        _fill(req, cl[_feed(ts[0].pairIndex)]);

        // openTrade of the 20th position
        OpenParams memory p = _openParams(SOL, true, 400e6, 3_000);
        (g, req) = _gas(mgr, abi.encodeCall(GainsVault.openTrade, (p)));
        console2.log("gas openTrade (19 trades -> 20th)", g);
        assertLt(g, limit, "openTrade");
        _rollFresh(1);
        _fill(req, cl[SOL_USD]);
        assertEq(v.venue().orders, 20);
        assertEq(lens.openPositions(v), 20);

        (g,) = _gas(address(this), abi.encodeCall(GainsVault.totalAssets, ()));
        console2.log("gas totalAssets view (20 trades)", g);
        assertLt(g, limit, "totalAssets");
        _rollFresh(4 * 3_600);
        (g,) = _gas(keeper, abi.encodeCall(GainsVault.checkRisk, ()));
        console2.log("gas checkRisk (20 trades)", g);
        assertLt(g, limit, "checkRisk");
        uint256 redeemShares = v.balanceOf(alice) / 100;
        vm.prank(alice);
        v.requestRedeem(redeemShares, alice, alice);
        (g,) = _gas(keeper, abi.encodeCall(GainsVault.settle, ()));
        console2.log("gas settle (20 trades)", g);
        assertLt(g, limit, "settle");

        // a settle that prices deposits values every trade at both band edges (value + valueHigh, GR1-02): two
        // valuations per trade only then, so this one reading has its own budget (measured 13.40M, rounded up)
        vm.prank(bob);
        v.requestDeposit(1_000e6, bob);
        _rollFresh(4 * 3_600);
        v.checkRisk();
        (g,) = _gas(keeper, abi.encodeCall(GainsVault.settle, ()));
        console2.log("gas settle with deposits (20 trades)", g);
        assertLt(g, 14_000_000, "settle with deposits");

        vm.prank(mgr);
        vm.expectRevert(abi.encodeWithSelector(IGainsVaultErrors.TooManyPositions.selector, 20, 20));
        v.openTrade(_openParams(ETH, true, 400e6, 3_000));
        // exits at the ceiling
        (g,) = _gas(fGuardian, abi.encodeCall(GainsVault.flatten, (BTC, 0, cl[BTC_USD], type(uint256).max)));
        console2.log("gas flatten (7 BTC trades at the ceiling)", g);
    }

    /// @dev The worst flatten: all 20 positions are open trades on one pair, closed in one call. An exit is never
    ///      refused at the ceiling, so it must fit an Arbitrum transaction (32M gas).
    function test_fork_gasFlattenTwentyTradesOnOnePair() public {
        _depositSettle(alice, 100_000e6);
        uint256 n = v.venue().orders;
        while (n < v.MAX_POSITIONS()) {
            _openFilledV(ETH, n % 2 == 0, 400e6, 3_000);
            n = v.venue().orders;
        }
        (uint256 g, Vm.Log[] memory req) = _gas(fGuardian, abi.encodeCall(GainsVault.flatten, (ETH, 0, cl[ETH_USD], type(uint256).max)));
        console2.log("gas flatten (20 ETH trades, 20 close requests)", g);
        assertLt(g, 32_000_000, "fits an Arbitrum transaction");
        assertEq(IGainsDiamond(address(DIAMOND)).getPendingOrders(address(v)).length, 20);
        _rollFresh(1);
        _fill(req, cl[ETH_USD]);
        assertEq(lens.openPositions(v), 0);
    }

    /// @dev Stage 3: the same 20 trades flattened in two transactions of 10 closes each (flatten's maxTrades). The
    ///      second batch skips the 10 closes already in flight and sends the other 10; both fill on the real diamond.
    function test_fork_flattenTwentyTradesInTwoBatches() public {
        _depositSettle(alice, 100_000e6);
        uint256 n = v.venue().orders;
        while (n < v.MAX_POSITIONS()) {
            _openFilledV(ETH, n % 2 == 0, 400e6, 3_000);
            n = v.venue().orders;
        }
        bytes memory batch = abi.encodeCall(GainsVault.flatten, (ETH, 0, cl[ETH_USD], 10));
        (uint256 g1, Vm.Log[] memory req1) = _gas(fGuardian, batch);
        console2.log("gas flatten batch 1 (10 of 20 ETH trades)", g1);
        assertEq(IGainsDiamond(address(DIAMOND)).getPendingOrders(address(v)).length, 10, "batch 1 in flight");
        (uint256 g2, Vm.Log[] memory req2) = _gas(fGuardian, batch);
        console2.log("gas flatten batch 2 (the other 10)", g2);
        assertEq(IGainsDiamond(address(DIAMOND)).getPendingOrders(address(v)).length, 20, "every close in flight");
        assertLt(g1, 16_000_000, "half of an Arbitrum transaction");
        assertLt(g2, 16_000_000, "half of an Arbitrum transaction");
        vm.prank(fGuardian);
        (uint256 sent, uint256 remaining) = v.flatten(ETH, 0, cl[ETH_USD], 10);
        assertEq(sent, 0, "nothing left to send");
        assertEq(remaining, 0);
        _rollFresh(1);
        _fill(req1, cl[ETH_USD]);
        _fill(req2, cl[ETH_USD]);
        assertEq(lens.openPositions(v), 0, "all 20 closed");
    }
}
