// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {GainsBase} from "./GainsBase.t.sol";
import {GainsNav} from "../../src/gains/GainsNav.sol";
import {GainsPrice} from "../../src/gains/GainsPrice.sol";
import {GainsVaultPolicy, IGainsCuration} from "../../src/gains/GainsVaultPolicy.sol";
import {IGainsVaultErrors as E} from "../../src/gains/GainsTypes.sol";
import {BreachReason} from "../../src/VaultTypes.sol";
import {MockChainlinkFeed} from "./mocks/GainsMocks.sol";

/// @dev Calls the libraries' internal functions directly (inlined here, so coverage maps to the library source).
contract PriceAndNavHarness {
    function read(GainsPrice.Feed memory f, address sequencer, uint256 grace, uint256 pair) external view returns (uint64) {
        return GainsPrice.read(f, sequencer, grace, pair);
    }

    function pnlPercent(uint64 openPrice, uint64 currentPrice, bool long, uint24 leverage) external pure returns (int256) {
        return GainsNav.pnlPercent(openPrice, currentPrice, long, leverage);
    }

    function priceAfterImpact(uint64 px, int256 impactP) external pure returns (uint64) {
        return GainsNav.priceAfterImpact(px, impactP);
    }

    function tradeValuePure(uint256 collateral, int256 pnlP, int256 fees) external pure returns (uint256) {
        return GainsNav.tradeValuePure(collateral, pnlP, fees, 1e12);
    }
}

/// @dev A feed whose latestRoundData answers with fewer than five words.
contract ShortAnswerFeed {
    fallback() external {
        assembly {
            mstore(0, 1)
            return(0, 32)
        }
    }
}

/// @dev A curation source that lists a pair without a price feed (unreachable with GainsVaultFactory, which refuses
///      to curate without one) and runs without a sequencer feed (a chain without one).
contract BareCuration is IGainsCuration {
    mapping(uint32 => GainsPrice.Feed) internal feeds;

    function setFeed(uint32 asset, GainsPrice.Feed calldata f) external {
        feeds[asset] = f;
    }

    function isAssetCurated(uint32) external pure returns (bool) {
        return true;
    }

    function pairFeed(uint32 asset) external view returns (GainsPrice.Feed memory) {
        return feeds[asset];
    }

    function sequencerFeed() external pure returns (address) {
        return address(0);
    }

    function sequencerGracePeriod() external pure returns (uint256) {
        return 0;
    }
}

/// @notice Branch coverage of GainsNav, GainsPrice, GainsVaultPolicy and the settle paths of GainsVaultLogic: the
///         defensive reverts and clamps the behavioural suites do not reach.
contract GainsBranchesTest is GainsBase {
    PriceAndNavHarness internal h;

    function setUp() public override {
        super.setUp();
        h = new PriceAndNavHarness();
    }

    // ------------------------------------------------------------------ GainsPrice
    function _f(MockChainlinkFeed feed) internal view returns (GainsPrice.Feed memory) {
        return GainsPrice.Feed({feed: address(feed), maxAge: 3_600, bandBps: 20, decimals: feed.decimals()});
    }

    function _stale(GainsPrice.Feed memory f) internal {
        vm.expectRevert(abi.encodeWithSelector(GainsPrice.PriceStale.selector, uint256(7)));
        h.read(f, address(sequencer), SEQ_GRACE, 7);
    }

    function test_PriceRejectsEveryMalformedAnswer() public {
        uint256 t = vm.getBlockTimestamp();
        MockChainlinkFeed feed = new MockChainlinkFeed(8, 100e8);
        GainsPrice.Feed memory f = _f(feed);
        assertEq(h.read(f, address(sequencer), SEQ_GRACE, 7), 100e10);
        feed.set(-1, t);
        _stale(f); // negative
        feed.set(0, t);
        _stale(f); // zero
        feed.set(100e8, 0);
        _stale(f); // never updated
        feed.set(100e8, t + 1);
        _stale(f); // from the future
        feed.set(100e8, t - 3_601);
        _stale(f); // older than maxAge
        feed.set(100e8, t - 3_600);
        assertEq(h.read(f, address(sequencer), SEQ_GRACE, 7), 100e10, "exactly maxAge old is fresh");
        feed.set(type(int256).max, t);
        _stale(f); // does not fit a Gains price (uint64), checked before scaling
        feed.set(int256(uint256(type(uint64).max / 100)) + 1, t);
        _stale(f); // just past uint64 once scaled
        MockChainlinkFeed d10 = new MockChainlinkFeed(10, int256(uint256(type(uint64).max)) + 1);
        _stale(_f(d10)); // past uint64 without scaling
        feed.setReverts(true);
        _stale(f); // reverting feed
        f.feed = address(new ShortAnswerFeed());
        _stale(f); // malformed return data
        f.feed = address(0);
        vm.expectRevert(abi.encodeWithSelector(GainsPrice.NoPriceFeed.selector, uint256(7)));
        h.read(f, address(sequencer), SEQ_GRACE, 7);
    }

    function test_PriceScalesAnyFeedDecimals() public {
        uint256 t = vm.getBlockTimestamp();
        MockChainlinkFeed d10 = new MockChainlinkFeed(10, 2_500e10);
        assertEq(h.read(_f(d10), address(sequencer), SEQ_GRACE, 7), 2_500e10, "10 decimals: as is");
        MockChainlinkFeed d18 = new MockChainlinkFeed(18, 2_500e18);
        assertEq(h.read(_f(d18), address(sequencer), SEQ_GRACE, 7), 2_500e10, "18 decimals: scaled down");
        d18.set(1, t); // 1e-18 USD rounds to 0 in 1e10
        _stale(_f(d18));
    }

    function test_SequencerStates() public {
        MockChainlinkFeed feed = new MockChainlinkFeed(8, 100e8);
        GainsPrice.Feed memory f = _f(feed);
        uint256 t = vm.getBlockTimestamp();
        // no sequencer feed (a chain without one): not checked
        sequencer.setStatus(1, t);
        assertEq(h.read(f, address(0), SEQ_GRACE, 7), 100e10);
        sequencer.setStatus(0, 0); // a round that has not started
        vm.expectRevert(GainsPrice.SequencerDown.selector);
        h.read(f, address(sequencer), SEQ_GRACE, 7);
        sequencer.setStatus(0, t + 1); // status changed in the future
        vm.expectRevert(GainsPrice.SequencerDown.selector);
        h.read(f, address(sequencer), SEQ_GRACE, 7);
        sequencer.setReverts(true);
        vm.expectRevert(GainsPrice.SequencerDown.selector);
        h.read(f, address(sequencer), SEQ_GRACE, 7);
    }

    // ------------------------------------------------------------------ GainsNav
    function test_NavPureClampsAndFloors() public view {
        assertEq(h.pnlPercent(0, 100e10, true, 10_000), 0, "no open price: no pnl");
        assertEq(h.pnlPercent(100e10, 1e10, true, 100_000), -100e10, "loss capped at -100%");
        assertEq(h.pnlPercent(100e10, 110e10, false, 2_000), -20e10);
        assertEq(h.priceAfterImpact(100e10, -200e10), 0, "impact past -100% floors at 0");
        assertEq(h.priceAfterImpact(100e10, 1e10), 101e10);
        assertEq(h.tradeValuePure(1_000e6, 0, 2_000e6), 0, "fees above the value floor at 0");
        assertEq(h.tradeValuePure(1_000e6, 10e10, 0), 1_100e6);
    }

    function test_NavSkipsClosedTradesAndOrders() public {
        _deposit(alice, 100_000e6);
        _settle();
        _claim(alice);
        uint32 a = _open(vault, ETH, true, 10_000e6, 2_000);
        _open(vault, BTC, false, 5_000e6, 2_000);
        _passHold(); // GR2-KEY-01b: the manager's close waits out the minimum hold
        _closeFilled(vault, a, _px(ETH)); // a closed trade and a filled (closed) order on the diamond
        uint256 value = vault.venue().value;
        uint256 orders = vault.venue().orders;
        diamond.setIncludeClosed(true);
        assertEq(vault.venue().value, value, "closed entries are worth nothing");
        // GR2-LIVE-01 (fix round WP2): the vault reads its own indexes one by one, not Gains' lists, so closed entries a
        // list would show are neither valued nor counted (before, listed entries were counted)
        assertEq(vault.venue().orders, orders, "closed entries are not counted");
    }

    function test_NavPreV92TradeHasNoClosingImpact() public {
        _deposit(alice, 100_000e6);
        _settle();
        _claim(alice);
        uint32 idx = _open(vault, ETH, true, 10_000e6, 2_000);
        diamond.setPair(ETH, 0, 285.7e18, 0.1e18, 0.1e10); // 0.1% spread
        uint256 v10 = vault.venue().value;
        diamond.setContractsVersion(address(vault), idx, 0); // a trade opened before v9.2: no closing impact
        assertGt(vault.venue().value, v10, "no spread against the trade");
    }

    // ------------------------------------------------------------------ GainsVaultPolicy
    function _policy() internal returns (GainsVaultPolicy) {
        return GainsVaultPolicy(Clones.clone(address(policyImpl)));
    }

    function _assets(uint32 a) internal pure returns (uint32[] memory x) {
        x = new uint32[](1);
        x[0] = a;
    }

    function test_PolicyInitializeGuards() public {
        GainsVaultPolicy p = _policy();
        vm.expectRevert(GainsVaultPolicy.InvalidTimelock.selector);
        p.initialize(owner, _defaultRisk(), _assets(BTC), 1 days - 1, address(platform), address(vault));
        vm.expectRevert(GainsVaultPolicy.InvalidTimelock.selector);
        p.initialize(owner, _defaultRisk(), _assets(BTC), 30 days + 1, address(platform), address(vault));
        vm.expectRevert(GainsVaultPolicy.ZeroAddress.selector);
        p.initialize(owner, _defaultRisk(), _assets(BTC), 2 days, address(0), address(vault));
        vm.expectRevert(GainsVaultPolicy.InvalidPair.selector);
        p.initialize(owner, _defaultRisk(), _assets(70_000), 2 days, address(platform), address(vault));
        // a curation that lists a pair without a feed
        BareCuration bare = new BareCuration();
        vm.expectRevert(abi.encodeWithSelector(GainsVaultPolicy.AssetNotCurated.selector, BTC));
        p.initialize(owner, _defaultRisk(), _assets(BTC), 2 days, address(bare), address(vault));
        // ... and one without a sequencer feed: prices are read without the uptime check
        bare.setFeed(BTC, GainsPrice.Feed({feed: address(btcFeed), maxAge: BTC_MAX_AGE, bandBps: 20, decimals: 8}));
        p.initialize(owner, _defaultRisk(), _assets(BTC), 2 days, address(bare), address(vault));
        assertEq(p.sequencerFeed(), address(0));
        sequencer.setStatus(1, vm.getBlockTimestamp());
        assertEq(p.price(BTC), 100_000e10);
    }

    function test_PolicyNavBoundWithoutABand() public view {
        assertEq(policy.navBoundLeverageBps(DOGE, 500), type(uint256).max, "a pair never allowed has no band");
    }

    function _order() internal view returns (GainsVaultPolicy.Order memory) {
        return GainsVaultPolicy.Order({
            pair: ETH,
            long: true,
            market: true,
            expectedPrice: _px(ETH),
            maxSlippageP: SLIP,
            collateral: 1_000e6,
            notional: 2_000e6,
            minCollateral: 10e6,
            nav: 100_000e6,
            openNotional: 0
        });
    }

    function _rejects(GainsVaultPolicy.Order memory o, string memory reason) internal view {
        (bool ok, string memory r) = policy.checkOrder(o);
        assertFalse(ok);
        assertEq(r, reason);
    }

    function test_PolicyCheckOrderRejections() public view {
        GainsVaultPolicy.Order memory o = _order();
        (bool ok,) = policy.checkOrder(o);
        assertTrue(ok);
        o.pair = 70_000;
        _rejects(o, "invalid pair");
        o = _order();
        o.pair = SOL;
        _rejects(o, "asset not allowed");
        o = _order();
        o.expectedPrice = 0;
        _rejects(o, "no price");
        o = _order();
        o.maxSlippageP = SLIP + 1;
        _rejects(o, "slippage");
        o = _order();
        o.expectedPrice = _px(ETH) * 102 / 100;
        _rejects(o, "price above band");
        o = _order();
        o.long = false;
        o.expectedPrice = _px(ETH) * 98 / 100;
        _rejects(o, "price below band");
        o.market = false; // a resting order is not banded
        (ok,) = policy.checkOrder(o);
        assertTrue(ok);
        o = _order();
        o.notional = 1_000_001e6;
        _rejects(o, "notional too large");
        o = _order();
        o.collateral = 9e6;
        _rejects(o, "collateral below min");
        o = _order();
        o.notional = 299e6; // below the pair's fee basis: not a floor, Gains' minimum collateral is the only one
        (bool small,) = policy.checkOrder(o);
        assertTrue(small);
        o = _order();
        o.openNotional = 299_000e6;
        _rejects(o, "leverage");
    }

    function test_PolicyPendingAndTimelockPaths() public {
        vm.expectRevert(GainsVaultPolicy.NothingPending.selector);
        policy.applyPendingConfig();
        vm.expectRevert(GainsVaultPolicy.NothingPending.selector);
        policy.allowAsset(SOL);
        vm.expectRevert(GainsVaultPolicy.NothingPending.selector);
        policy.applyTimelockDelay();
        vm.startPrank(owner);
        vm.expectRevert(GainsVaultPolicy.InvalidTimelock.selector);
        policy.proposeTimelockDelay(1 days - 1);
        vm.expectRevert(GainsVaultPolicy.InvalidTimelock.selector);
        policy.proposeTimelockDelay(30 days + 1);
        policy.proposeTimelockDelay(3 days); // raising is instant
        assertEq(policy.timelockDelay(), 3 days);
        policy.proposeTimelockDelay(1 days); // lowering waits the current delay
        vm.stopPrank();
        assertEq(policy.timelockDelay(), 3 days);
        assertEq(policy.pendingTimelockDelay(), 1 days);
        vm.expectRevert(GainsVaultPolicy.NotReady.selector);
        policy.applyTimelockDelay();
        _skip(3 days);
        policy.applyTimelockDelay();
        assertEq(policy.timelockDelay(), 1 days);
        // a queued loosening expires after its grace period
        GainsVaultPolicy.RiskConfig memory c = _defaultRisk();
        c.maxDailyLossBps = 600;
        vm.prank(owner);
        policy.proposeConfig(c);
        _warp(uint256(policy.pendingConfig().eta) + 14 days + 1); // hl-r2 exit-before-effect: wait for the stored eta
        vm.expectRevert(GainsVaultPolicy.Expired.selector);
        policy.applyPendingConfig();
    }

    // ------------------------------------------------------------------ GainsVaultLogic.settle modes
    function test_SettleExitOnlyNeedsEmergencyOrOverdue() public {
        _deposit(alice, 1_000e6);
        _settle();
        _deposit(bob, 1_000e6);
        vault.checkRisk();
        // the platform roles settle only an overdue epoch (or in emergency); before that, never
        address[3] memory platformRoles = [guardian, guardian, owner];
        for (uint256 i; i < platformRoles.length; ++i) {
            vm.prank(platformRoles[i]);
            vm.expectRevert(E.Unauthorized.selector);
            vault.settle();
        }
        _skip(7 days);
        vm.prank(owner);
        vault.settle(); // overdue: exit only, the deposit is refunded
        (, uint256 refunded) = lens.claimable(vault, bob);
        assertEq(refunded, 1_000e6, "never minted in an exit-only settle");
    }

    function test_EmergencySettlePricesAtTheLowerOfNavAndCheckpoint() public {
        uint32 idx = _fundVenue(10_000e6);
        _redeem(alice, vault.balanceOf(alice) / 10);
        // NAV rises above the checkpoint: an exit-only settle pays at the checkpoint
        _setVenueValue(vault, idx, 10_500e6);
        vm.prank(guardian);
        vault.triggerEmergency();
        vm.prank(manager);
        vault.closeTrade(idx, _px(ETH));
        _fillLast(vault, _px(ETH) * 105 / 100);
        uint256 cp = vault.checkpointNav();
        assertLt(cp, vault.totalAssets());
        vm.prank(guardian);
        vault.settle();
        (, uint256 paid) = lens.claimable(vault, alice);
        assertLe(paid, cp / 10 + 1, "paid at the checkpoint, not the higher NAV");
    }

    function test_RedemptionOnlySettleCarriesInsiderDeposits() public {
        uint32 idx = _fundVenue(10_000e6);
        usdc.mint(manager, 1_000e6);
        vm.prank(manager);
        usdc.approve(address(vault), type(uint256).max);
        vm.prank(manager);
        vault.requestDeposit(500e6, manager); // an insider: deferred to the next epoch
        assertEq(vault.deferredDepositAssets(), 500e6);
        _redeem(alice, vault.balanceOf(alice) / 100);
        _passHold(); // GR2-KEY-01b: the manager's exit waits out the minimum hold (same UTC day as the baseline)
        vm.prank(manager);
        vault.reduceTrade(idx, 1_000e6, 0, _px(ETH));
        _fillLast(vault, _px(ETH)); // ~1,000 idle to pay the redemption
        _setVenueValue(vault, idx, 9_400e6 - vault.idleAssets()); // -6% on the day: daily loss breach
        vault.checkRisk();
        assertTrue(vault.breached());
        assertEq(uint8(vault.breachReason()), uint8(BreachReason.DAILY_LOSS));
        _skip(1 hours);
        vault.checkRisk();
        vm.prank(manager);
        vault.settle(); // redemption only: the insider deposit joins the carried queue, unpriced
        assertEq(vault.deferredDepositAssets(), 0);
        assertEq(vault.pendingDepositAssets(), 500e6);
        assertEq(vault.balanceOf(manager), 0, "nothing minted in a loss breach");
    }
}
