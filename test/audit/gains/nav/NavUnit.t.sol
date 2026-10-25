// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {console2} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {GainsBase} from "../../../gains/GainsBase.t.sol";
import {MockChainlinkFeed} from "../../../gains/mocks/GainsMocks.sol";
import {GainsVault} from "../../../../src/gains/GainsVault.sol";
import {GainsVaultPolicy} from "../../../../src/gains/GainsVaultPolicy.sol";
import {GainsPrice} from "../../../../src/gains/GainsPrice.sol";
import {GainsNav} from "../../../../src/gains/GainsNav.sol";
import {GainsVaultMath} from "../../../../src/gains/GainsVaultMath.sol";
import {IGainsVaultErrors} from "../../../../src/gains/GainsTypes.sol";

/// @dev GainsPrice.read / checkSequencer exposed as externals (they are internal library functions).
contract PriceHarness {
    function read(GainsPrice.Feed memory f, address seq, uint256 grace, uint256 pair) external view returns (uint64) {
        return GainsPrice.read(f, seq, grace, pair);
    }

    function adverse(uint64 mid, uint16 band, bool long) external pure returns (uint64) {
        return GainsPrice.adverse(mid, band, long);
    }

    function priceAfterImpact(uint64 p, int256 impact) external pure returns (uint64) {
        return GainsNav.priceAfterImpact(p, impact);
    }

    function pnlPercent(uint64 o, uint64 c, bool long, uint24 lev) external pure returns (int256) {
        return GainsNav.pnlPercent(o, c, long, lev);
    }

    function tradeValuePure(uint256 coll, int256 pnlP, int256 fees, uint128 pd) external pure returns (uint256) {
        return GainsNav.tradeValuePure(coll, pnlP, fees, pd);
    }
}

/// @dev Returns `len` bytes from latestRoundData (malformed feed).
contract ShortFeed {
    uint256 internal immutable len;

    constructor(uint256 l) {
        len = l;
    }

    function decimals() external pure returns (uint8) {
        return 8;
    }

    fallback() external {
        uint256 l = len;
        assembly {
            mstore(0, 1)
            mstore(32, 3000)
            return(0, l)
        }
    }
}

/// @dev A feed with a round where answeredInRound < roundId (pre-OCR2 "carried over" round).
contract OldRoundFeed {
    int256 public answer;
    uint256 public updatedAt;

    function set(int256 a, uint256 u) external {
        answer = a;
        updatedAt = u;
    }

    function decimals() external pure returns (uint8) {
        return 8;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (10, answer, updatedAt, updatedAt, 9);
    }
}

/// @notice Round 1 review (3.1, NAV and share pricing): unit PoCs and soundness checks on the mock harness.
contract NavUnitTest is GainsBase {
    PriceHarness internal ph;
    /// @dev GainsPrice.MAX_PRICE (internal): the highest price read accepts (GR1-24).
    uint256 internal constant MAX_PRICE = (uint256(type(uint64).max) * 10_000) / 11_000;

    function setUp() public override {
        super.setUp();
        ph = new PriceHarness();
    }

    function _f(address feed, uint32 maxAge, uint8 dec) internal pure returns (GainsPrice.Feed memory) {
        return GainsPrice.Feed({feed: feed, maxAge: maxAge, bandBps: 20, decimals: dec});
    }

    // ================================================================== feed edge cases (GainsPrice.read)
    function test_feed_staleZeroNegativeFutureAndMissingAllRevertPriceStale() public {
        GainsPrice.Feed memory f = _f(address(ethFeed), BTC_MAX_AGE, 8);
        uint256 t = vm.getBlockTimestamp();
        assertEq(ph.read(f, address(sequencer), SEQ_GRACE, 1), 3_000e10, "fresh: 1e10");

        ethFeed.set(3_000e8, t - BTC_MAX_AGE); // exactly maxAge old: still accepted
        assertEq(ph.read(f, address(sequencer), SEQ_GRACE, 1), 3_000e10);
        ethFeed.set(3_000e8, t - BTC_MAX_AGE - 1);
        vm.expectRevert(abi.encodeWithSelector(GainsPrice.PriceStale.selector, 1));
        ph.read(f, address(sequencer), SEQ_GRACE, 1);

        ethFeed.set(0, t);
        vm.expectRevert(abi.encodeWithSelector(GainsPrice.PriceStale.selector, 1));
        ph.read(f, address(sequencer), SEQ_GRACE, 1);
        ethFeed.set(-1, t);
        vm.expectRevert(abi.encodeWithSelector(GainsPrice.PriceStale.selector, 1));
        ph.read(f, address(sequencer), SEQ_GRACE, 1);
        ethFeed.set(3_000e8, t + 1);
        vm.expectRevert(abi.encodeWithSelector(GainsPrice.PriceStale.selector, 1));
        ph.read(f, address(sequencer), SEQ_GRACE, 1);
        ethFeed.set(3_000e8, 0);
        vm.expectRevert(abi.encodeWithSelector(GainsPrice.PriceStale.selector, 1));
        ph.read(f, address(sequencer), SEQ_GRACE, 1);

        ethFeed.set(3_000e8, t);
        ethFeed.setReverts(true);
        vm.expectRevert(abi.encodeWithSelector(GainsPrice.PriceStale.selector, 1));
        ph.read(f, address(sequencer), SEQ_GRACE, 1);

        // malformed return data (< 160 bytes) and a feed address with no code
        address shortFeed = address(new ShortFeed(64));
        address eoa = makeAddr("eoa");
        vm.expectRevert(abi.encodeWithSelector(GainsPrice.PriceStale.selector, 1));
        ph.read(_f(shortFeed, BTC_MAX_AGE, 8), address(sequencer), SEQ_GRACE, 1);
        vm.expectRevert(abi.encodeWithSelector(GainsPrice.PriceStale.selector, 1));
        ph.read(_f(eoa, BTC_MAX_AGE, 8), address(sequencer), SEQ_GRACE, 1);
        vm.expectRevert(abi.encodeWithSelector(GainsPrice.NoPriceFeed.selector, 1));
        ph.read(_f(address(0), BTC_MAX_AGE, 8), address(sequencer), SEQ_GRACE, 1);
    }

    /// @notice answeredInRound is not read. For OCR2 aggregators (the curated BTC / ETH / SOL proxies) it equals the
    ///         round id, and staleness is fully covered by updatedAt + maxAge. A round carried over with an old
    ///         answeredInRound but a fresh updatedAt is accepted: the age check is the guard that matters.
    function test_feed_answeredInRoundIgnored_updatedAtIsTheGuard() public {
        OldRoundFeed o = new OldRoundFeed();
        o.set(3_000e8, vm.getBlockTimestamp());
        assertEq(ph.read(_f(address(o), BTC_MAX_AGE, 8), address(0), 0, 1), 3_000e10);
        o.set(3_000e8, vm.getBlockTimestamp() - BTC_MAX_AGE - 1);
        vm.expectRevert(abi.encodeWithSelector(GainsPrice.PriceStale.selector, 1));
        ph.read(_f(address(o), BTC_MAX_AGE, 8), address(0), 0, 1);
    }

    /// @dev Fix round (GR1-24): the bound is MAX_PRICE = uint64.max x 1e4 / (1e4 + MAX_BAND_BPS), so the adverse edge
    ///      of any accepted price fits uint64 (was uint64.max).
    function test_feed_hugeAnswersBoundedAtMaxPrice() public {
        GainsPrice.Feed memory f = _f(address(ethFeed), BTC_MAX_AGE, 8);
        uint256 t = vm.getBlockTimestamp();
        int256 maxOk = int256(MAX_PRICE / 100);
        ethFeed.set(maxOk, t);
        assertEq(ph.read(f, address(sequencer), SEQ_GRACE, 1), uint64(uint256(maxOk) * 100));
        ethFeed.set(maxOk + 1, t);
        vm.expectRevert(abi.encodeWithSelector(GainsPrice.PriceStale.selector, 1));
        ph.read(f, address(sequencer), SEQ_GRACE, 1);
        ethFeed.set(int256(uint256(type(uint64).max) / 100), t); // accepted before the fix round
        vm.expectRevert(abi.encodeWithSelector(GainsPrice.PriceStale.selector, 1));
        ph.read(f, address(sequencer), SEQ_GRACE, 1);
        ethFeed.set(type(int256).max, t); // aggregator maxAnswer is 2^176 - 1: no panic, a named error
        vm.expectRevert(abi.encodeWithSelector(GainsPrice.PriceStale.selector, 1));
        ph.read(f, address(sequencer), SEQ_GRACE, 1);
        // decimals above 10 scale down; an 18-decimal answer that rounds to 0 is stale
        ethFeed.set(1, t);
        vm.expectRevert(abi.encodeWithSelector(GainsPrice.PriceStale.selector, 1));
        ph.read(_f(address(ethFeed), BTC_MAX_AGE, 18), address(sequencer), SEQ_GRACE, 1);
    }

    function test_sequencer_downGraceStartedAtZeroFutureAndBrokenAllRevert() public {
        GainsPrice.Feed memory f = _f(address(ethFeed), BTC_MAX_AGE, 8);
        uint256 t = vm.getBlockTimestamp();
        sequencer.setStatus(1, t - 30 days);
        vm.expectRevert(GainsPrice.SequencerDown.selector);
        ph.read(f, address(sequencer), SEQ_GRACE, 1);
        sequencer.setStatus(0, t - SEQ_GRACE); // back up exactly `grace` ago: still inside (<=)
        vm.expectRevert(GainsPrice.SequencerDown.selector);
        ph.read(f, address(sequencer), SEQ_GRACE, 1);
        sequencer.setStatus(0, t - SEQ_GRACE - 1);
        assertEq(ph.read(f, address(sequencer), SEQ_GRACE, 1), 3_000e10);
        sequencer.setStatus(0, 0);
        vm.expectRevert(GainsPrice.SequencerDown.selector);
        ph.read(f, address(sequencer), SEQ_GRACE, 1);
        sequencer.setStatus(0, t + 1);
        vm.expectRevert(GainsPrice.SequencerDown.selector);
        ph.read(f, address(sequencer), SEQ_GRACE, 1);
        sequencer.setStatus(0, t - 30 days);
        sequencer.setReverts(true);
        vm.expectRevert(GainsPrice.SequencerDown.selector);
        ph.read(f, address(sequencer), SEQ_GRACE, 1);
        address shortSeq = address(new ShortFeed(96));
        vm.expectRevert(GainsPrice.SequencerDown.selector);
        ph.read(f, shortSeq, SEQ_GRACE, 1);
    }

    // ================================================================== halted feed within maxAge
    /// @notice SOL's staleness limit is its 86,400 s heartbeat + 1,800 s. A feed that stops updating (DON outage) is
    ///         trusted for 24.5 h. With the feed frozen NAV does not move, so NavMoved never fires: a normal settle
    ///         23 h later pays a redeemer at the frozen price while Gains would pay 10% less on the trade.
    function test_HALTEDFEED_solFrozenForADayStillSettles() public {
        uint32[] memory a = new uint32[](1);
        a[0] = SOL;
        GainsVaultPolicy p2 = GainsVaultPolicy(Clones.clone(address(policyImpl)));
        GainsVault v2 = GainsVault(Clones.clone(address(vaultImpl)));
        p2.initialize(owner, _defaultRisk(), a, 2 days, address(platform), address(v2));
        v2.initialize(_standaloneParams(p2));
        vm.prank(alice);
        usdc.approve(address(v2), type(uint256).max);
        vm.prank(alice);
        v2.requestDeposit(100_000e6, alice);
        _ageEpoch(v2); // fix round: a settle that prices deposits runs 1 h into the epoch (GR1-02)
        v2.checkRisk();
        vm.prank(manager);
        v2.settle();
        v2.claim(alice);
        uint32 idx = _open(v2, SOL, true, 50_000e6, 5_000); // 2.5x
        v2.checkRisk();
        uint256 navFrozen = v2.totalAssets();
        // 23 hours pass; the SOL feed never updates (BTC / ETH irrelevant here); the market is 10% lower
        vm.warp(vm.getBlockTimestamp() + 23 hours);
        assertEq(v2.totalAssets(), navFrozen, "still accepted, NAV frozen");
        uint256 trueValue = diamond.closeValue(address(v2), idx, (_px(SOL) * 90) / 100);
        console2.log("NAV with the frozen feed / value of the trade at the market", navFrozen, trueValue);
        uint256 sh = v2.balanceOf(alice) / 2;
        vm.prank(alice);
        v2.requestRedeem(sh, alice, alice);
        v2.checkRisk();
        vm.prank(manager);
        v2.settle(); // NAV == checkpoint: no NavMoved
        uint256 b = usdc.balanceOf(alice);
        v2.claim(alice);
        uint256 got = usdc.balanceOf(alice) - b;
        uint256 fair = (v2.idleAssets() + got + trueValue) / 2;
        console2.log("redeemer paid / fair half at the market", got, fair);
        assertGt(got, fair + 5_000e6, "paid the frozen NAV: ~6k above the realizable half");
    }

    // ================================================================== NAV-DECIMALS
    /// @notice Was the GR1-13 PoC `test_NAVDEC_decimalsChangeMispricesWithoutRevert` (Feed.decimals cached at
    ///         curation: a proxy moving to a 6-decimal aggregator was read 100x too low with no revert, a short showed
    ///         ~+297% and a normal settle paid redemptions at the inflated NAV). GainsPrice.read now checks the feed's
    ///         live decimals() against the cached value: PriceStale, so NAV, checkRisk and the pricing settle stop,
    ///         and the redemption waits instead of being paid at a wrong price.
    function test_GR1_13_decimalsChangeRevertsPriceStale() public {
        _deposit(alice, 100_000e6);
        _settle();
        _claim(alice);
        _open(vault, ETH, false, 10_000e6, 3_000); // 3x short, 30k notional
        vault.totalAssets();
        // the proxy moves to an aggregator with 6 decimals: the same 3,000 USD now reads as 3,000e6
        vm.mockCall(address(ethFeed), abi.encodeWithSignature("decimals()"), abi.encode(uint8(6)));
        ethFeed.set(3_000e6, vm.getBlockTimestamp());
        bytes memory stale = abi.encodeWithSelector(GainsPrice.PriceStale.selector, uint256(ETH));
        vm.expectRevert(stale);
        policy.price(ETH);
        vm.expectRevert(stale);
        vault.totalAssets();
        vm.expectRevert(stale);
        vault.checkRisk();
        _redeem(alice, vault.balanceOf(alice) / 10);
        _skip(1 hours + 1);
        ethFeed.set(3_000e6, vm.getBlockTimestamp());
        vm.prank(manager);
        vm.expectRevert(stale);
        vault.settle();
        // a feed whose decimals() reverts is stale too
        vm.mockCallRevert(address(ethFeed), abi.encodeWithSignature("decimals()"), "");
        vm.expectRevert(stale);
        policy.price(ETH);
        // back to 8 decimals: priced again
        vm.clearMockedCalls();
        ethFeed.set(3_000e8, vm.getBlockTimestamp());
        assertEq(policy.price(ETH), 3_000e10);
    }

    /// @notice The other direction (8 -> 18 decimals) fails closed for every curated pair: the answer scaled by 100
    ///         overflows uint64 and reads PriceStale.
    function test_NAVDEC_decimalsIncreaseFailsClosed() public {
        ethFeed.set(3_000e18, vm.getBlockTimestamp());
        vm.expectRevert(abi.encodeWithSelector(GainsPrice.PriceStale.selector, 1));
        policy.price(ETH);
    }

    // ================================================================== unchecked casts
    /// @notice Was `test_priceAfterImpactTruncation_unreachableForInflation` (GR1-24: GainsNav.priceAfterImpact cast
    ///         to uint64 silently and wrapped). It saturates at uint64.max now, and read caps the feed at MAX_PRICE so
    ///         the adverse edge of an accepted price always fits: a short at the highest accepted price is valued 0
    ///         (past its liquidation price), never at a wrapped close price; one unit above is PriceStale.
    function test_GR1_24_priceAfterImpactSaturatesAndReadCapsAtMaxPrice() public {
        uint64 p = type(uint64).max - 1e15;
        int256 impact = 1e8; // +0.01%
        assertEq(ph.priceAfterImpact(p, impact), type(uint64).max, "GR1-24: saturates, no wrap");
        assertEq(ph.priceAfterImpact(type(uint64).max, 1e12), type(uint64).max, "large impact saturates too");
        assertEq(ph.priceAfterImpact(1e10, -200e10), 0, "a negative result floors at 0");
        diamond.setPair(ETH, 0, 285.7e18, 0.1e18, 1e9); // 0.1% spread: +0.05% close impact for a short
        _deposit(alice, 100_000e6);
        _settle();
        _claim(alice);
        _open(vault, ETH, false, 1_000e6, 2_000);
        uint256 mid = MAX_PRICE / 100; // 8 decimals
        ethFeed.set(int256(mid), vm.getBlockTimestamp());
        uint64 adv = ph.adverse(uint64(mid * 100), 1_000, false); // the widest band
        assertGt(adv, uint64(mid * 100), "the adverse edge at MAX_PRICE and a 10% band does not wrap");
        assertEq(vault.venue().value, 0, "short at that price: past liquidation, 0, not an inflated value");
        ethFeed.set(int256(mid + 1), vm.getBlockTimestamp());
        vm.expectRevert(abi.encodeWithSelector(GainsPrice.PriceStale.selector, uint256(ETH)));
        vault.totalAssets();
    }

    /// @notice pnlPercent never overflows (any uint64 prices, any uint24 leverage). tradeValuePure does not overflow
    ///         for an open price >= 1e8 (0.01 USD), any uint64 valuation price, any uint24 leverage and collateral up
    ///         to 1e15 units (1e9 USDC). Outside that (e.g. open 6e-10 USD with a 1.8e9 USD feed answer and 1.8e20 USDC
    ///         of collateral, fuzz counterexample) the multiplication panics: a revert of the NAV read (liveness), never
    ///         a wrong value.
    function testFuzz_valueMathNeverOverflows(uint64 o, uint64 c, bool long, uint24 lev, uint64 coll) public view {
        o = uint64(bound(o, 1e8, type(uint64).max));
        coll = uint64(bound(coll, 0, 1e15));
        int256 p = ph.pnlPercent(o, c, long, lev);
        assertGe(p, -100e10);
        ph.tradeValuePure(coll, p, 0, 1e12);
    }

    function test_valueMath_absurdInputsPanicNotMisvalue() public {
        int256 p = ph.pnlPercent(6, type(uint64).max, true, 3_231_711);
        vm.expectRevert(); // arithmetic panic 0x11
        ph.tradeValuePure(180614119051695846668146900 * 1e6, p, 0, 1e12);
    }

    // ================================================================== NAV-ROTATION
    /// @notice setPairFeed (vault timelock, executed by anyone after eta) changes the band of a pair with open
    ///         trades: NAV steps by delta-B x notional at a moment the executor chooses. A depositor who settled
    ///         before executing a band cut captures his share of the step.
    function test_NAVROTATION_bandCutStepsNavAtAnExecutorChosenMoment() public {
        _deposit(alice, 100_000e6);
        _settle();
        _claim(alice);
        _open(vault, ETH, true, 30_000e6, 10_000); // 300k notional, 3x
        // factory curation of ETH moves to band 5 bps (same feed); the vault owner queues the rotation
        vm.prank(platformOwner);
        platform.setAssetCurated(ETH, true, address(ethFeed), BTC_MAX_AGE, 5);
        bytes memory call_ = abi.encodeCall(GainsVault.setPairFeed, (ETH, address(ethFeed), BTC_MAX_AGE, uint16(5)));
        vm.prank(owner);
        vault.queue(call_);
        _warp(vault.queuedEta(keccak256(call_))); // hl-r2 exit-before-effect: wait for the stored eta
        // bob deposits and settles while the band is still 20 bps
        _deposit(bob, 100_000e6);
        _settle();
        _claim(bob);
        uint256 navBefore = vault.totalAssets();
        uint256 bobBefore = vault.convertToAssets(vault.balanceOf(bob));
        vm.prank(bob);
        vault.execute(call_); // anyone
        uint256 navAfter = vault.totalAssets();
        console2.log("NAV before / after the rotation", navBefore, navAfter);
        assertApproxEqRel(navAfter - navBefore, 450e6, 0.02e18, "15 bps x 300k notional");
        uint256 bobValue = vault.convertToAssets(vault.balanceOf(bob));
        console2.log("bob's shares worth before / after the rotation", bobBefore, bobValue);
        // fix round: bob minted at the favourable band edge (GR1-02), so the step is measured across the execution
        assertGt(bobValue - bobBefore, 200e6, "bob took ~half of the step");
    }

    // ================================================================== CANCELOPTION
    /// @notice Was the GR1-15 PoC `test_CANCELOPTION_freeCancelUntilSettle` (requests and cancels are free until the
    ///         settle: with the market 5 bps above a lagging Chainlink and a 3x long open, bob kept his request and was
    ///         up ~15 bps once Chainlink caught up). Cancels are still free, but deposits now mint at the favourable
    ///         band edge (GR1-02): the 2 x 20 bps x 3x two-sided cost exceeds what the lag (5 bps x 3x) can return,
    ///         so keeping the request is no longer profitable.
    function test_GR1_15_cancelOptionNoLongerProfitable() public {
        _deposit(alice, 100_000e6);
        _settle();
        _claim(alice);
        _open(vault, ETH, true, 30_000e6, 10_000); // 3x vault leverage
        // world A: market below Chainlink -> bob cancels in the block before the settle, at no cost
        _deposit(bob, 100_000e6);
        uint256 b0 = usdc.balanceOf(bob);
        vm.prank(bob);
        vault.cancelDepositRequest();
        assertEq(usdc.balanceOf(bob) - b0, 100_000e6, "cancel returns every wei");
        // world B: market 5 bps above Chainlink -> bob keeps the request, the settle prices it at the lagging feed
        _deposit(bob, 100_000e6);
        _settle();
        _claim(bob);
        uint256 v0 = vault.convertToAssets(vault.balanceOf(bob));
        _setPrice(ETH, (_px(ETH) * 10_005) / 10_000); // Chainlink catches up after the settle
        uint256 v1 = vault.convertToAssets(vault.balanceOf(bob));
        console2.log("bob's shares worth, at settle / after Chainlink caught up", v0, v1);
        assertGt(v1, v0 + 60e6, "the lag still moves bob's value ~ 5 bps x 300k x his share");
        assertLt(v1, 100_000e6, "GR1-15: but bob is still below his deposit: the option costs more than it pays");
    }

    // ================================================================== first depositor / inflation / rounding
    /// @notice Classic donation inflation is unprofitable with the 1e6 virtual shares: the attacker reduces the supply
    ///         to 1 share unit, donates 1M USDC, a victim deposits 10k; the victim loses less than 1 USDC to rounding
    ///         and the attacker cannot recover the donation.
    function test_inflation_donationAttackUnprofitable() public {
        _deposit(alice, 10e6); // attacker
        _settle();
        _claim(alice);
        _redeem(alice, vault.balanceOf(alice) - 1); // keep 1 share unit
        _settle();
        _claim(alice);
        assertEq(vault.balanceOf(alice), 1);
        usdc.mint(address(this), 1_000_000e6);
        usdc.transfer(address(vault), 1_000_000e6); // donation
        _deposit(bob, 10_000e6);
        _skip(1 days);
        // fix round (GR1-23): a dust checkpoint (below MIN_RISK_NAV) no longer bounds the settle, so the attack gets
        // to a settle now (it used to revert NavMoved): the 1e6 virtual shares still make it unprofitable
        vault.checkRisk();
        vm.prank(manager);
        vault.settle();
        _claim(bob);
        uint256 shares = vault.balanceOf(bob);
        uint256 bobValue = vault.convertToAssets(shares);
        uint256 aliceValue = vault.convertToAssets(1);
        console2.log("victim deposit 10k, worth", bobValue, "attacker's 1 unit worth", aliceValue);
        assertGt(bobValue, 10_000e6 - 1e6, "victim loses < 1 USDC to rounding");
        assertLt(aliceValue, 2e6, "attacker's 1 share unit recovers ~nothing of the 1M donation");
    }

    /// @notice Deposit then redeem in the next epoch never returns more than deposited when NAV does not move.
    function testFuzz_roundTripNeverProfits(uint64 a0, uint64 a1) public {
        uint256 first = bound(uint256(a0), 10e6, 500_000e6);
        uint256 amt = bound(uint256(a1), 10e6, 500_000e6);
        _deposit(alice, first);
        _settle();
        _claim(alice);
        _deposit(bob, amt);
        _skip(1 hours);
        _settle();
        _claim(bob);
        _redeem(bob, vault.balanceOf(bob));
        _skip(1 hours);
        _settle();
        uint256 b = usdc.balanceOf(bob);
        _claim(bob);
        assertLe(usdc.balanceOf(bob) - b, amt, "rounding never pays the redeemer more than he put in");
    }

    /// @notice Conversion rounding directions: shares for a deposit and assets for a redemption round down; a claim's
    ///         returned shares round down (burnedForMe up).
    function testFuzz_conversionRoundingFavoursTheVault(uint128 assets, uint128 nav, uint128 supply) public pure {
        vm.assume(supply > 0 && nav > 0 && assets > 0);
        uint256 s = GainsVaultMath.toShares(assets, nav, supply, Math.Rounding.Floor);
        uint256 back = GainsVaultMath.toAssets(s, uint256(nav) + assets, uint256(supply) + s, Math.Rounding.Floor);
        assertLe(back, assets);
    }

    // ================================================================== fees
    /// @notice A daily-loss breach settle mints the management fee only; the high water mark and the performance fee
    ///         wait for a normal settle (no fee on a NAV that may be deflated).
    function test_fees_breachSettleChargesNoPerformanceAndKeepsHwm() public {
        _deposit(alice, 100_000e6);
        _settle();
        _claim(alice);
        uint32 idx = _open(vault, ETH, true, 50_000e6, 2_000);
        _setPrice(ETH, (_px(ETH) * 110) / 100); // +20% on 50k: NAV +10%
        _skip(1 days);
        vault.checkRisk();
        uint256 hwm0 = vault.highWaterMark();
        // a loss today: -12% on the long -> NAV -6%, past the 5% daily loss
        _setPrice(ETH, (_px(ETH) * 88) / 100);
        vault.checkRisk();
        assertTrue(vault.breached(), "daily loss breach");
        uint256 feeBal0 = vault.balanceOf(feeRecipient);
        _skip(1 hours);
        vm.prank(manager);
        vault.settle();
        assertEq(vault.highWaterMark(), hwm0, "HWM frozen in a breach");
        uint256 minted = vault.balanceOf(feeRecipient) - feeBal0;
        assertGt(minted, 0, "management fee still accrues");
        idx;
    }

    /// @notice Calling accrueFees every second rounds the management fee of a small vault to 0 (floor in
    ///         GainsVaultLogic._accrueFees): 2% on 1,000 USDC accrues 634 wei per second... below 1 unit per call
    ///         at 500 USDC. Informational: a griefer pays ~86,400 transactions a day to erase cents.
    function test_fees_managementFeeDustUnderPerSecondAccrual() public {
        _deposit(alice, 500e6);
        _settle();
        _claim(alice);
        uint256 s0 = vault.totalSupply();
        for (uint256 i; i < 600; i++) {
            _skip(1);
            vault.accrueFees();
        }
        assertEq(vault.totalSupply(), s0, "10 minutes of per-second accruals: no fee at all");
        _skip(600);
        vault.accrueFees();
        assertGt(vault.totalSupply(), s0, "one accrual over the same 10 minutes mints the fee");
    }
}
