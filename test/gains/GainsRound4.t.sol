// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {GainsBase} from "./GainsBase.t.sol";
import {GainsVault} from "../../src/gains/GainsVault.sol";
import {GainsVaultFactory} from "../../src/gains/GainsVaultFactory.sol";
import {GainsVaultPolicy} from "../../src/gains/GainsVaultPolicy.sol";
import {GainsPrice} from "../../src/gains/GainsPrice.sol";
import {IGainsDiamond} from "../../src/gains/IGainsDiamond.sol";
import {IGainsVaultErrors as E, IGainsVaultEvents, OpenParams, operatorReduceCap} from "../../src/gains/GainsTypes.sol";
import {BreachReason, DECIMALS_OFFSET} from "../../src/VaultTypes.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @dev Round 4 helpers on a Gains vault. The HL tests move NAV with _setCore; here the vault holds one 1x ETH long
///      (collateral = the funded amount) whose value is set exactly through its holding fee, and whose notional is set
///      through its size. "Bringing USDC home" is a partial close filled at the valuation price, so the NAV moves by
///      exactly the payout (no band jump) and the round 4 metrics can be checked to the bps.
abstract contract GainsRound4Base is GainsBase {
    uint32 internal tradeIdx;

    function _fund(uint256 amount) internal {
        tradeIdx = _fundVenue(amount);
    }

    /// @dev NAV on the venue = `nav` (the vault holds nothing idle after _fund).
    function _nav(uint256 nav) internal {
        _setVenueValue(vault, tradeIdx, nav);
    }

    /// @dev Venue value `nav` with open notional `notional` (the trade's leverage rewritten).
    function _navNtl(uint256 nav, uint256 notional) internal {
        uint256 coll = diamond.getTrade(address(vault), tradeIdx).collateralAmount;
        diamond.setTradeSize(address(vault), tradeIdx, uint24((notional * 1_000) / coll), _px(ETH));
        _setVenueValue(vault, tradeIdx, nav);
    }

    /// @dev The adverse band edge for the long: the price GainsNav values it at.
    function _valuationPx() internal view returns (uint64) {
        return uint64((uint256(_px(ETH)) * (10_000 - 20)) / 10_000);
    }

    /// @dev Reduces the trade so that ~`amount` USDC comes back, filled at the valuation price (closes it if `amount`
    ///      is the whole value).
    function _home(uint256 amount) internal returns (uint256 paid) {
        uint256 value = vault.venue().value;
        IGainsDiamond.Trade memory t = diamond.getTrade(address(vault), tradeIdx);
        uint64 p = _valuationPx();
        if (amount >= value) {
            vm.prank(manager);
            vault.closeTrade(tradeIdx, p);
        } else {
            uint120 delta = uint120((uint256(t.collateralAmount) * amount) / value);
            vm.prank(manager);
            vault.reduceTrade(tradeIdx, delta, 0, p);
        }
        (, paid) = _fillLast(vault, p);
    }

    function _reason() internal view returns (uint8) {
        return uint8(vault.breachReason());
    }

    function _nextDay() internal {
        _warp((vm.getBlockTimestamp() / 1 days + 1) * 1 days + 1);
    }

    function _noDepositMint() internal view {
        (uint256 depA, uint256 depS,,,,,,) = vault.epochs(vault.currentEpoch() - 1);
        assertEq(depA + depS, 0, "no deposit priced or minted in a redemption-only epoch");
    }
}

/// @notice Mirrors test/Round4.t.sol (Round4Test): risk on the share price (R-01), breach = derisk not shutdown,
///         exits in every mode; the R-02 bridge-landing tests become pending-order tests.
contract GainsRound4Test is GainsRound4Base {
    address internal bot = makeAddr("bot");

    // ==================================================================
    // R-01
    // ==================================================================
    function test_R01_withdrawalOnARedDayKeepsTheDailyLoss() public {
        _fund(100_000e6);
        // GR2-KEY-01b: the manager's exit (_home) waits out the minimum hold. Waited here, before the first metric
        // read, so the red day is measured as before: _fund ends 47 min before UTC midnight, this stays in that day
        _passHold();
        _nav(99_000e6); // -1%
        (, uint256 before,) = vault.checkRisk();
        assertApproxEqAbs(before, 100, 1);

        _redeem(alice, (vault.balanceOf(alice) * 98_990) / 100_000);
        _home(98_100e6);
        vault.checkRisk();
        vm.prank(manager);
        vault.settle();
        _claim(alice);
        assertApproxEqAbs(usdc.balanceOf(alice), 1_000_000e6 - 100_000e6 + 98_000e6, 100e6, "alice paid ~98k");

        (, uint256 afterFlow,) = vault.checkRisk();
        assertApproxEqAbs(afterFlow, before, 1, "the withdrawal does not move the daily loss");
        assertFalse(vault.breached());
    }

    function test_R01_fullRedemptionOnARedDayNeverBreaches() public {
        _fund(100_000e6);
        _passHold(); // before the first metric read, same UTC day
        _nav(96_000e6);
        vault.checkRisk();
        assertFalse(vault.breached());
        _redeem(alice, vault.balanceOf(alice));
        _home(96_000e6);
        vault.checkRisk();
        vm.prank(manager);
        vault.settle();
        (, uint256 daily, uint256 dd) = vault.checkRisk();
        assertEq(daily, 0);
        assertEq(dd, 0);
        assertFalse(vault.breached(), "an emptied vault never breaches on the payout");
    }

    function test_R01_depositDoublingTheVaultNeverResetsThePeak() public {
        _fund(100_000e6);
        uint256 peak = vault.peakSharePrice();
        _nav(90_000e6);
        _nextDay();
        (,, uint256 dd0) = vault.checkRisk();
        assertApproxEqAbs(dd0, 1_000, 1);

        _deposit(bob, 90_000e6);
        _ageEpoch(vault); // GR1-02
        vm.prank(manager);
        vault.settle();
        _claim(bob);
        (,, uint256 dd1) = vault.checkRisk();
        assertApproxEqRel(vault.peakSharePrice(), peak, 1e14, "peak not reset by the deposit");
        // GR1-02: bob mints at the favourable band edge of the open trade, so the holders gain that edge and the
        // drawdown can only shrink (about 2 x band x 1x here), never grow
        assertLe(dd1, dd0 + 1, "the deposit never deepens the drawdown");
        assertApproxEqAbs(dd1, dd0, 50, "by at most the band edge");
    }

    function test_R01_feeMintsDoNotMoveTheMetrics() public {
        _nextDay(); // three hours later must still be the same UTC day
        _fund(100_000e6);
        _nav(97_000e6);
        (, uint256 d0, uint256 dd0) = vault.checkRisk();
        _skip(3 hours);
        vault.accrueFees();
        (, uint256 d1, uint256 dd1) = vault.checkRisk();
        assertApproxEqAbs(d1, d0, 1, "daily loss unchanged by the fee mint");
        assertApproxEqAbs(dd1, dd0, 1, "drawdown unchanged by the fee mint");
    }

    function testFuzz_R01_flowsNeverMoveTheMetrics(uint256 lossBps, uint256 redeemPct, uint256 depositAmt) public {
        lossBps = bound(lossBps, 0, 450);
        redeemPct = bound(redeemPct, 0, 100);
        depositAmt = bound(depositAmt, 0, 200_000e6);
        if (depositAmt > 0 && depositAmt < 10e6) depositAmt = 10e6;
        _fund(100_000e6);
        _passHold(); // before the first metric read, same UTC day; the _ageEpoch below warps to the same absolute time
        uint256 nav = 100_000e6 - (100_000e6 * lossBps) / 10_000;
        _nav(nav);
        (, uint256 d0, uint256 dd0) = vault.checkRisk();

        uint256 shares = (vault.balanceOf(alice) * redeemPct) / 100;
        if (shares > 0) _redeem(alice, shares);
        if (depositAmt > 0) _deposit(bob, depositAmt);
        uint256 owed = vault.convertToAssets(shares) + 2e6;
        if (owed > nav) owed = nav;
        if (shares > 0) _home(owed);
        _ageEpoch(vault); // GR1-02
        vault.checkRisk();
        vm.prank(manager);
        vault.settle();
        (, uint256 d1, uint256 dd1) = vault.checkRisk();
        if (vault.totalAssets() < 1e6) {
            assertEq(d1, 0);
            assertEq(dd1, 0);
        } else {
            // GR1-02: a deposit mints at the favourable band edge of the open trade and can only lift the holders
            // share price; flows never worsen either metric
            assertLe(d1, d0 + 1, "daily loss");
            assertLe(dd1, dd0 + 1, "drawdown");
            if (depositAmt == 0) {
                assertApproxEqAbs(d1, d0, 1, "daily loss, no deposit");
                assertApproxEqAbs(dd1, dd0, 1, "drawdown, no deposit");
            }
        }
        assertFalse(vault.breached());
    }

    function test_R01_dustVaultNeverBreachesOnRounding() public {
        _fund(100_000e6);
        _passHold(); // before the first metric read, same UTC day; the _ageEpoch below warps to the same absolute time
        _nav(99_510e6);
        vault.checkRisk();
        _redeem(alice, vault.balanceOf(alice));
        _deposit(bob, 10e6);
        _home(99_510e6);
        _ageEpoch(vault); // GR1-02
        vault.checkRisk();
        vm.prank(manager);
        vault.settle();
        _claim(bob);
        _redeem(bob, vault.balanceOf(bob) - 11e6);
        _skip(1 hours);
        vault.checkRisk();
        vm.prank(manager);
        vault.settle();
        assertGt(vault.totalSupply(), 0);
        assertLt(vault.totalAssets(), 1e6);
        (, uint256 d, uint256 dd) = vault.checkRisk();
        assertEq(d + dd, 0);
        assertFalse(vault.breached());
    }

    // ==================================================================
    // Breach = derisk, not shutdown
    // ==================================================================
    function test_LeverageBreach_reduceOnly_agentKept_clearedByAnyoneOnceBackUnder() public {
        _setAgent(vault, bot);
        _fund(10_000e6);
        _navNtl(10_000e6, 31_000e6); // 3.1x > 3x
        vault.checkRisk();
        assertTrue(vault.breached());
        assertEq(_reason(), uint8(BreachReason.LEVERAGE));
        assertEq(vault.agent(), bot, "agent stays");
        OpenParams memory p = _params(BTC, true, 1_000e6, 2_000);
        vm.prank(bot);
        vm.expectRevert(E.ReduceOnlyMode.selector);
        vault.openTrade(p);

        vm.prank(stranger);
        vm.expectRevert(E.NotReady.selector);
        vault.clearLeverageBreach();
        _skip(vault.LEVERAGE_CLEAR_COOLDOWN());
        vm.prank(stranger);
        vm.expectRevert(E.NotClearable.selector);
        vault.clearLeverageBreach();

        // The agent trims back under the limit (reduce-only is honoured by the vault itself): anyone clears it.
        vm.prank(bot);
        vault.reduceTrade(tradeIdx, 2_000e6, 0, _valuationPx());
        _fillLast(vault, _valuationPx());
        _navNtl(10_000e6, 25_500e6);
        vm.prank(stranger);
        vault.clearLeverageBreach();
        assertFalse(vault.breached());
        assertEq(_reason(), 0);
        assertEq(vault.agent(), bot);
    }

    function test_LeverageBreach_cannotBeClearedWhenAnotherLimitIsOver() public {
        _fund(10_000e6);
        _navNtl(10_000e6, 31_000e6);
        vault.checkRisk();
        _skip(vault.LEVERAGE_CLEAR_COOLDOWN());
        _navNtl(9_400e6, 20_000e6);
        vm.expectRevert(E.NotClearable.selector);
        vault.clearLeverageBreach();
        vault.checkRisk();
        assertEq(_reason(), uint8(BreachReason.DAILY_LOSS), "escalated");
    }

    function test_DrawdownBreach_untilTheOwnerResumes_peakReset() public {
        _setAgent(vault, bot);
        _fund(10_000e6);
        _nav(8_000e6);
        _nextDay();
        vault.checkRisk();
        assertEq(_reason(), uint8(BreachReason.DRAWDOWN));
        assertEq(vault.agent(), bot);
        _nextDay();
        vault.checkRisk();
        assertTrue(vault.breached());
        vm.expectRevert(E.NotClearable.selector);
        vault.clearLeverageBreach();
        vm.prank(bob);
        vm.expectRevert(E.DepositsClosed.selector);
        vault.requestDeposit(10e6, bob);
        _skip(1 hours);
        vault.checkRisk();
        vm.prank(manager);
        vault.settle();
        _noDepositMint();
        vm.prank(guardian);
        vm.expectRevert(E.Unauthorized.selector);
        vault.resume();
        vm.prank(owner);
        vault.resume();
        assertFalse(vault.breached());
        assertEq(vault.peakSharePrice(), vault.sharePrice());
        (,, uint256 dd) = vault.checkRisk();
        assertEq(dd, 0);
    }

    function test_Resume_refusedWhileLeverageIsOver() public {
        _fund(10_000e6);
        _navNtl(8_000e6, 30_000e6);
        _nextDay();
        vault.checkRisk();
        assertEq(_reason(), uint8(BreachReason.DRAWDOWN));
        _skip(vault.RESUME_COOLDOWN());
        vm.prank(owner);
        vm.expectRevert(E.NotClearable.selector);
        vault.resume();
    }

    function test_SettleInARiskBreach_leverageSettles_dailyLossIsRedemptionOnly() public {
        _fund(10_000e6);
        _navNtl(10_000e6, 31_000e6);
        vault.checkRisk();
        assertEq(_reason(), uint8(BreachReason.LEVERAGE));
        vm.prank(manager);
        vault.settle();
        _navNtl(9_400e6, 10_000e6);
        vault.checkRisk();
        assertEq(_reason(), uint8(BreachReason.DAILY_LOSS));
        _skip(1 hours);
        vault.checkRisk();
        vm.prank(manager);
        vault.settle();
        _noDepositMint();
    }

    function test_GuardianBreachAndEmergencyAreFullStops() public {
        _setAgent(vault, bot);
        _fund(10_000e6);
        vm.prank(guardian);
        vault.triggerBreach();
        assertEq(_reason(), uint8(BreachReason.GUARDIAN));
        assertEq(vault.agent(), address(0), "full stop revokes");
        vm.prank(bot);
        vm.expectRevert(E.Unauthorized.selector);
        vault.closeTrade(tradeIdx, _px(ETH)); // a revoked agent is nobody
        vm.prank(manager);
        vm.expectRevert(E.ReduceOnlyMode.selector);
        vault.settle();
        _navNtl(10_000e6, 31_000e6);
        vault.checkRisk();
        assertEq(_reason(), uint8(BreachReason.GUARDIAN));
        vm.prank(guardian);
        vault.triggerEmergency();
        assertEq(_reason(), uint8(BreachReason.EMERGENCY));
        vm.prank(guardian);
        vault.triggerBreach();
        assertEq(_reason(), uint8(BreachReason.EMERGENCY), "an emergency stays an emergency");
    }

    function test_RiskBreachEscalatesToAFullStopOnTriggerBreach() public {
        _setAgent(vault, bot);
        _fund(10_000e6);
        _navNtl(10_000e6, 31_000e6);
        vault.checkRisk();
        assertEq(vault.agent(), bot);
        vm.prank(guardian);
        vault.triggerBreach();
        assertEq(_reason(), uint8(BreachReason.GUARDIAN));
        assertEq(vault.agent(), address(0));
        _skip(1 days);
        _navNtl(10_000e6, 10_000e6);
        vm.expectRevert(E.NotClearable.selector);
        vault.clearLeverageBreach();
    }

    function test_LensExposesTheBreachReason() public {
        _fund(10_000e6);
        _navNtl(10_000e6, 31_000e6);
        vault.checkRisk();
        assertEq(lens.status(vault).breachReason, uint8(BreachReason.LEVERAGE));
    }

    function test_DepositorsRequestAndClaimInBreachAndEmergency() public {
        _fund(10_000e6);
        _nav(8_000e6);
        _nextDay();
        vault.checkRisk();
        assertTrue(vault.breached());
        _redeem(alice, vault.balanceOf(alice) / 2);
        vm.prank(guardian);
        vault.triggerEmergency();
        _home(8_000e6);
        vm.prank(guardian);
        vault.settle();
        _claim(alice);
        assertGt(usdc.balanceOf(alice), 1_000_000e6 - 10_000e6, "paid out in emergency");
        _redeem(alice, vault.balanceOf(alice));
    }

    // ==================================================================
    // R-02 analog: collateral in flight on the diamond
    // ==================================================================
    function test_R02_aPendingCloseIsNeitherANavDropNorSettledAround() public {
        _fund(10_000e6);
        _redeem(alice, vault.balanceOf(alice) / 2);
        _passHold();
        vm.prank(manager);
        vault.reduceTrade(tradeIdx, 5_000e6, 0, _valuationPx());
        vm.roll(vm.getBlockNumber() + 50);
        assertEq(vault.totalAssets(), 10_000e6, "no false NAV drop: the trade stays valued until the fill");
        (, uint256 daily, uint256 dd) = vault.checkRisk();
        assertEq(daily, 0);
        assertEq(dd, 0);
        assertFalse(vault.breached());
        // GR1-04: a pending partial close holds no collateral and no longer blocks settle (was OrdersPending). The
        // trade is still valued as open, so the settle prices the redemption at the full NAV and waits for the USDC.
        assertFalse(vault.ordersPending());
        vm.prank(manager);
        // (needs just under 5,000: the minimum hold's 10 minutes of management fee dilute the redeemed half, fix round WP2)
        vm.expectPartialRevert(E.InsufficientLiquidity.selector);
        vault.settle();

        _fillLast(vault, _valuationPx()); // fills 50 blocks late
        vm.prank(manager);
        vault.settle();
        assertApproxEqAbs(vault.totalAssets(), 5_000e6, 1e6, "half paid out, the rest still there");
    }

    function test_R02_aLossWhileAnOrderIsPendingIsNotMasked() public {
        _fund(10_000e6);
        _skip(2 hours);
        vault.checkRisk();
        _passHold();
        vm.prank(manager);
        vault.reduceTrade(tradeIdx, 1_000e6, 0, _valuationPx());
        _nav(6_000e6); // -40% while the reduce is in flight
        vault.checkRisk();
        assertTrue(vault.breached(), "the loss is seen");
    }
}

/// @notice Mirrors Round4FactoryTest: restricted unwind and the treasury operator on a factory vault.
contract GainsRound4FactoryTest is GainsBase {
    GainsVaultFactory internal factory;
    GainsVault internal v;
    address internal keeper = makeAddr("keeper");
    address internal creator = makeAddr("creator");
    address internal treasury = makeAddr("treasury");

    function setUp() public override {
        super.setUp();
        factory = new GainsVaultFactory(
            owner,
            address(vaultImpl),
            address(policyImpl),
            IERC20(address(usdc)),
            IGainsDiamond(address(diamond)),
            address(sequencer),
            SEQ_GRACE,
            treasury,
            guardian,
            sentinel
        );
        vm.startPrank(owner);
        factory.setLauncherAllowed(creator, true);
        factory.setAssetCurated(BTC, true, address(btcFeed), BTC_MAX_AGE, 20);
        factory.setAssetCurated(ETH, true, address(ethFeed), BTC_MAX_AGE, 20);
        vm.stopPrank();
        // GR2-KEY-01b: a pair never set takes no new exposure on factory vaults
        vm.startPrank(guardian);
        factory.setPairSkewCap(BTC, 100);
        factory.setPairSkewCap(ETH, 100);
        vm.stopPrank();
        uint32[] memory assets = new uint32[](2);
        assets[0] = BTC;
        assets[1] = ETH;
        usdc.mint(creator, 10e6);
        vm.prank(creator);
        usdc.approve(address(factory), 10e6);
        vm.prank(creator);
        (address va,) = factory.create(
            GainsVaultFactory.CreateParams({
                name: "R4",
                symbol: "r4",
                owner: creator,
                manager: manager,
                feeRecipient: feeRecipient,
                managementFeeBps: 0,
                performanceFeeBps: 0,
                timelockDelay: 2 days,
                depositCap: 50_000e6,
                risk: _defaultRisk(),
                assets: assets,
                agent: address(0),
                agentSig: "",
                agentDeadline: 0,
                operator: keeper,
                hosted: false,
                seedUsdc: 1e6,
                salt: bytes32(0)
            }),
            GainsVaultFactory.PermitData(0, 0, 0, bytes32(0), bytes32(0))
        );
        v = GainsVault(va);
        vm.prank(alice);
        usdc.approve(va, type(uint256).max);
        vm.prank(alice);
        v.requestDeposit(10_000e6, alice);
        _ageEpoch(v); // GR1-02: a settle that prices deposits runs an hour into the epoch
        v.checkRisk();
    }

    function test_D2_factoryMinimumDeposit() public view {
        assertEq(factory.MIN_DEPOSIT(), 10e6);
    }

    function test_OperatorGrantedAtLaunch_runsTheTreasuryOnly() public {
        assertEq(v.operator(), keeper);
        vm.prank(keeper);
        v.settle(); // normal settle: mints alice
        uint32 idx = _open(v, ETH, true, 5_000e6, 2_000);
        // The operator frees USDC for redemptions (the bridgeToEvm analog), only up to the shortfall ...
        v.claim(alice);
        uint256 out = v.balanceOf(alice) * 8 / 10;
        vm.prank(alice);
        v.requestRedeem(out, alice, alice);
        uint256 shortfall = v.redemptionShortfall();
        assertGt(shortfall, 0);
        vm.prank(keeper);
        v.reduceTrade(idx, uint120(shortfall), 0, _px(ETH));
        _fillLast(v, _px(ETH));
        // ... and cancels timed-out orders like anyone.
        _request(v, BTC, true, 1_000e6, 2_000);
        vm.roll(vm.getBlockNumber() + 200);
        vm.prank(keeper);
        v.cancelTimedOut(diamond.orderCount(address(v)) - 1);

        OpenParams memory p = _params(BTC, true, 1_000e6, 2_000);
        uint64 px = _px(ETH);
        vm.startPrank(keeper);
        vm.expectRevert(E.Unauthorized.selector);
        v.openTrade(p);
        vm.expectRevert(E.Unauthorized.selector);
        v.increaseTrade(idx, 100e6, 2_000, px, SLIP);
        vm.expectRevert(E.Unauthorized.selector);
        v.updateLeverage(idx, 1_000);
        vm.expectRevert(E.Unauthorized.selector);
        v.setSlTp(idx, px / 2, 0);
        vm.expectRevert(E.Unauthorized.selector);
        v.closeTrade(idx, px); // outside a breach only the manager, agent and guardian close
        vm.expectRevert(E.Unauthorized.selector);
        v.setDepositsPaused(true);
        vm.expectRevert(E.Unauthorized.selector);
        v.lowerFees(0, 0);
        vm.expectRevert(E.Unauthorized.selector);
        v.queue(abi.encodeCall(GainsVault.setManager, (keeper)));
        vm.expectRevert(E.Unauthorized.selector);
        v.setOperator(stranger);
        vm.expectRevert(E.Unauthorized.selector);
        v.triggerBreach();
        vm.expectRevert(E.Unauthorized.selector);
        v.clearBreach();
        vm.expectRevert(E.Unauthorized.selector);
        v.setDepositCap(1);
        vm.expectRevert(E.Unauthorized.selector);
        v.revokeAgent();
        vm.expectRevert(E.Unauthorized.selector);
        v.cancelOrder(idx);
        vm.expectRevert(E.Unauthorized.selector);
        v.leaveHosted();
        vm.expectRevert(E.Unauthorized.selector);
        v.flatten(ETH, 0, px, type(uint256).max);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------ operator reduce: redemption shortfall only
    /// @dev alice holds ~10,000 USDC of NAV with 9,000 on one ETH trade (1,001 idle with the seed).
    function _opSetup() internal returns (uint32 idx) {
        vm.prank(keeper);
        v.settle();
        v.claim(alice);
        idx = _open(v, ETH, true, 9_000e6, 2_000);
    }

    function test_OperatorReduce_noShortfall_refused() public {
        uint32 idx = _opSetup();
        assertEq(v.redemptionShortfall(), 0, "no redemption pending");
        uint64 px = _px(ETH);
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(E.ReduceAboveShortfall.selector, 0, 1e6));
        v.reduceTrade(idx, 1e6, 0, px);
        // a small redemption the idle USDC covers: still no shortfall
        uint256 small = v.balanceOf(alice) / 20;
        vm.prank(alice);
        v.requestRedeem(small, alice, alice);
        assertEq(v.redemptionShortfall(), 0, "idle covers 5%");
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(E.ReduceAboveShortfall.selector, 0, 1e6));
        v.reduceTrade(idx, 1e6, 0, px);
    }

    function test_OperatorReduce_upToTheShortfallOnly() public {
        uint32 idx = _opSetup();
        uint256 shares = v.balanceOf(alice) / 2;
        vm.prank(alice);
        v.requestRedeem(shares, alice, alice);
        // owed = the shares at the checkpoint NAV (no price read on an exit); available = the idle USDC
        uint256 owed = Math.mulDiv(shares, uint256(v.checkpointNav()) + 1, v.totalSupply() + 10 ** DECIMALS_OFFSET);
        uint256 shortfall = v.redemptionShortfall();
        assertEq(shortfall, owed - usdc.balanceOf(address(v)));
        uint64 px = _px(ETH);
        vm.startPrank(keeper);
        // above the shortfall plus the fee allowance (2% + 1 USDC): refused
        uint256 cap = operatorReduceCap(shortfall);
        assertEq(cap, shortfall + shortfall / 50 + 1e6, "cap");
        vm.expectRevert(abi.encodeWithSelector(E.ReduceAboveShortfall.selector, shortfall, cap + 1));
        v.reduceTrade(idx, uint120(cap + 1), 0, px);
        // a leverage-only reduce returns no collateral: refused
        vm.expectRevert(abi.encodeWithSelector(E.ReduceAboveShortfall.selector, shortfall, 0));
        v.reduceTrade(idx, 0, 500, px);
        // a close stays breach only
        vm.expectRevert(E.Unauthorized.selector);
        v.closeTrade(idx, px);
        // part of it now: the in-flight reduce counts as returned, so only the rest remains
        v.reduceTrade(idx, uint120(shortfall / 2), 0, px);
        vm.stopPrank();
        uint256 rest = v.redemptionShortfall();
        assertEq(rest, shortfall - shortfall / 2);
        _fillLast(v, px);
        vm.prank(keeper);
        v.reduceTrade(idx, uint120(rest), 0, px);
        _fillLast(v, px);
        assertEq(v.redemptionShortfall(), 0);
        // and the redemption is paid in full by the next settle
        _skip(1 hours);
        v.checkRisk();
        vm.prank(keeper);
        v.settle();
        v.claim(alice);
        assertGt(usdc.balanceOf(alice), 1_000_000e6 - 10_000e6 + owed - 50e6, "paid about half of NAV");
    }

    /// Stage 3 fork gate: a reduce of exactly the shortfall comes back short by Gains' closing fee. The allowance lets
    /// one reduce cover it; what it frees beyond the redemptions stays idle on the vault.
    function test_OperatorReduce_feeAllowance_coversTheFee() public {
        uint32 idx = _opSetup();
        uint256 shares = v.balanceOf(alice) / 2;
        vm.prank(alice);
        v.requestRedeem(shares, alice, alice);
        uint256 shortfall = v.redemptionShortfall();
        uint256 cap = operatorReduceCap(shortfall);
        uint64 px = _px(ETH);
        vm.prank(keeper);
        v.reduceTrade(idx, uint120(cap), 0, px);
        // in flight it counts as returned: no shortfall left, so no second reduce
        assertEq(v.redemptionShortfall(), 0);
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(E.ReduceAboveShortfall.selector, 0, 1));
        v.reduceTrade(idx, 1, 0, px);
        _fillLast(v, px);
        assertEq(v.redemptionShortfall(), 0);
        _skip(1 hours);
        v.checkRisk();
        vm.prank(keeper);
        v.settle();
        assertEq(v.pendingRedeemShares(), 0, "redemptions settled");
    }

    function test_OperatorReduce_inBreach_unchanged() public {
        uint32 idx = _opSetup();
        assertEq(v.redemptionShortfall(), 0);
        vm.prank(sentinel);
        v.triggerBreach();
        uint64 px = _px(ETH);
        // in breach the operator unwinds like the owner and the sentinel: any reduce, and a close
        vm.prank(keeper);
        v.reduceTrade(idx, 5_000e6, 0, px);
        _fillLast(v, px);
        vm.prank(keeper);
        v.closeTrade(idx, px);
        _fillLast(v, px);
        assertEq(lens.openPositions(v), 0);
    }

    function test_OperatorGrantRevoke() public {
        vm.prank(stranger);
        vm.expectRevert(E.Unauthorized.selector);
        v.setOperator(stranger);
        vm.prank(stranger);
        vm.expectRevert(E.Unauthorized.selector);
        v.revokeOperator();
        vm.prank(sentinel);
        v.revokeOperator();
        assertEq(v.operator(), address(0));
        vm.prank(keeper);
        vm.expectRevert(E.Unauthorized.selector);
        v.settle();
        vm.prank(creator);
        v.setOperator(keeper);
        vm.prank(guardian);
        v.revokeOperator();
        vm.prank(creator);
        v.setOperator(keeper);
        vm.prank(creator);
        v.revokeOperator();
        assertEq(v.operator(), address(0));
    }

    function test_BreachFlatten_listedRolesOnly_depositorsIncluded() public {
        vm.prank(keeper);
        v.settle();
        uint32 idx = _open(v, ETH, true, 5_000e6, 2_000);
        vm.prank(sentinel);
        v.triggerBreach();
        uint64 px = _px(ETH);
        address[2] memory outsiders = [stranger, alice];
        for (uint256 i; i < 2; ++i) {
            vm.prank(outsiders[i]);
            vm.expectRevert(E.Unauthorized.selector);
            v.flatten(ETH, 0, px, type(uint256).max);
            vm.prank(outsiders[i]);
            vm.expectRevert(E.Unauthorized.selector);
            v.closeTrade(idx, px);
        }
        address[5] memory roles = [creator, manager, keeper, sentinel, guardian];
        for (uint256 i; i < 5; ++i) {
            vm.prank(roles[i]);
            v.flatten(ETH, 0, px, type(uint256).max); // the first one requests the close, the rest skip the trade in flight
        }
        assertEq(diamond.getPendingOrders(address(v)).length, 1);
        _fillLast(v, px);
        assertEq(diamond.getTrades(address(v)).length, 0);
    }

    function test_EmergencyUnwind_listedRolesOnly() public {
        vm.prank(keeper);
        v.settle();
        v.claim(alice);
        uint32 idx = _open(v, ETH, true, 5_000e6, 2_000);
        uint256 sh = v.balanceOf(alice);
        vm.prank(alice);
        v.requestRedeem(sh, alice, alice);
        vm.prank(guardian);
        v.triggerEmergency();
        uint64 px = _px(ETH);
        address[2] memory outsiders = [stranger, alice];
        for (uint256 i; i < 2; ++i) {
            vm.startPrank(outsiders[i]);
            vm.expectRevert(E.Unauthorized.selector);
            v.flatten(ETH, 0, px, type(uint256).max);
            vm.expectRevert(E.Unauthorized.selector);
            v.reduceTrade(idx, 1_000e6, 0, px);
            vm.expectRevert(E.Unauthorized.selector);
            v.settle();
            vm.stopPrank();
        }
        vm.prank(sentinel);
        v.flatten(ETH, 0, px, type(uint256).max);
        // GR1-04: the flatten close in flight holds no collateral and no longer holds the exit-only settle (was
        // OrdersPending): the owner settles at once, alice is paid pro rata from what is idle, the rest comes back
        assertFalse(v.ordersPending());
        uint256 bal = usdc.balanceOf(alice);
        vm.prank(creator);
        v.settle();
        v.claim(alice);
        assertGt(usdc.balanceOf(alice), bal, "paid from what is idle");
        _fillLast(v, px);
    }
}

/// @notice Mirrors Round4DecisionsTest: redemption-only settles in a daily loss / drawdown breach, and the resume.
contract GainsRound4DecisionsTest is GainsRound4Base {
    address internal sybil = makeAddr("sybil");

    function setUp() public override {
        super.setUp();
        usdc.mint(sybil, 1_000_000e6);
        vm.prank(sybil);
        usdc.approve(address(vault), type(uint256).max);
    }

    function _drawdownBreach(uint256 navAfter) internal {
        _warp((vm.getBlockTimestamp() / 1 days + 1) * 1 days + 60);
        _nav(navAfter);
        for (uint256 i; i < 3; ++i) {
            _skip(1 hours);
            vault.checkRisk();
        }
        assertEq(uint8(vault.breachReason()), uint8(BreachReason.DRAWDOWN));
    }

    function test_D4_C01_noMintAtADeflatedNav() public {
        _fund(100_000e6);
        vm.prank(sybil);
        vault.requestDeposit(100_000e6, sybil);
        _drawdownBreach(80_000e6);
        vm.prank(manager);
        vault.settle();
        (uint256 depA, uint256 depS,,,,,,) = vault.epochs(vault.currentEpoch() - 1);
        assertEq(depA + depS, 0, "nothing priced or minted for the deposit at the deflated NAV");
        assertEq(vault.balanceOf(sybil), 0);
        assertEq(vault.pendingDepositAssets(), 100_000e6, "the deposit stays queued");
        (uint256 cf, uint256 pi) = vault.carry(vault.currentEpoch() - 1);
        assertGt(cf, 0, "carried");
        assertEq(pi, 0);
        vm.expectRevert(E.RequestNotSettled.selector);
        vault.claim(sybil);

        _nav(100_000e6);
        _skip(24 hours);
        vm.prank(owner);
        vault.resume();
        for (uint256 i; i < 2; ++i) {
            _skip(1 hours);
            vault.checkRisk();
        }
        vm.prank(manager);
        vault.settle();
        vault.claim(sybil);
        uint256 val = vault.convertToAssets(vault.balanceOf(sybil));
        // GR1-02: with the 1x ETH trade open, deposits mint at the favourable band edge (20 bps x 1x): sybil holds a
        // little under what he paid, never more, and alice gains that edge
        assertApproxEqRel(val, 100_000e6, 3e15, "priced at the recovered NAV, not the deflated one");
        assertLe(val, 100_000e6, "never above the price paid");
        uint256 aliceVal = vault.convertToAssets(vault.balanceOf(alice));
        assertApproxEqRel(aliceVal, 100_000e6, 3e15, "alice untouched");
        assertGe(aliceVal, 100_000e6 - 1, "alice never diluted");
    }

    function test_D4_depositorFullyExitsDuringADrawdownBreach() public {
        _fund(100_000e6);
        _drawdownBreach(80_000e6);
        uint256 shares = vault.balanceOf(alice);
        _redeem(alice, shares);
        _home(80_000e6);
        vm.prank(stranger);
        vm.expectRevert(E.Unauthorized.selector);
        vault.settle();
        vm.prank(guardian);
        vault.settle();
        _claim(alice);
        assertApproxEqRel(usdc.balanceOf(alice), 1_000_000e6 - 100_000e6 + 80_000e6, 1e14, "paid the current NAV in full");
        assertEq(vault.balanceOf(alice), 0);
        assertTrue(vault.breached(), "the breach itself is unchanged");
    }

    function test_D4_carriedDepositAcrossEpochs() public {
        _fund(100_000e6);
        vm.prank(sybil);
        vault.requestDeposit(10_000e6, sybil);
        _deposit(bob, 5_000e6);
        _drawdownBreach(82_000e6);
        for (uint256 i; i < 3; ++i) {
            _skip(1 hours);
            vault.checkRisk();
            vm.prank(manager);
            vault.settle();
        }
        assertEq(vault.pendingDepositAssets(), 15_000e6);
        uint256 b = usdc.balanceOf(bob);
        vm.prank(bob);
        vault.cancelDepositRequest();
        assertEq(usdc.balanceOf(bob), b + 5_000e6);
        assertEq(vault.pendingDepositAssets(), 10_000e6);
        _skip(24 hours);
        vm.prank(owner);
        vault.resume();
        vm.prank(sybil);
        vault.requestDeposit(1_000e6, sybil);
        (uint256 rEp, uint256 rDep,) = vault.requests(sybil);
        assertEq(rEp, vault.currentEpoch());
        assertEq(rDep, 11_000e6);
        _skip(1 hours);
        vault.checkRisk();
        vm.prank(manager);
        vault.settle();
        uint256 g = gasleft();
        vault.claim(sybil);
        assertLt(g - gasleft(), 200_000, "O(1) claim");
        assertGt(vault.balanceOf(sybil), 0);
        (uint256 shares,) = lens.claimable(vault, sybil);
        assertEq(shares, 0, "delivered once");
    }

    function test_D2_resumeCooldownAndTimestamp() public {
        _fund(100_000e6);
        _drawdownBreach(80_000e6);
        vm.prank(owner);
        vm.expectRevert(E.NotReady.selector);
        vault.resume();
        _warp(vault.breachedAt() + vault.RESUME_COOLDOWN());
        vm.expectEmit(false, false, false, false, address(vault));
        emit IGainsVaultEvents.Resumed(0, 0);
        vm.prank(owner);
        vault.resume();
        assertEq(vault.lastResumeAt(), vm.getBlockTimestamp());
        assertEq(lens.status(vault).lastResumeAt, vm.getBlockTimestamp());
    }
}

/// @notice Mirrors Round4CarryExitTest: exits are never gated by a carried deposit.
contract GainsRound4CarryExitTest is GainsRound4Base {
    function test_D4_carriedDepositorCanStillRedeem() public {
        _fund(100_000e6);
        _deposit(alice, 5_000e6);
        _warp((vm.getBlockTimestamp() / 1 days + 1) * 1 days + 60);
        _nav(82_000e6);
        for (uint256 i; i < 3; ++i) {
            _skip(1 hours);
            vault.checkRisk();
        }
        assertEq(uint8(vault.breachReason()), uint8(BreachReason.DRAWDOWN));
        vm.prank(manager);
        vault.settle();
        uint256 sh = vault.balanceOf(alice);
        vm.prank(alice);
        vault.requestRedeem(sh, alice, alice);
        (uint256 ep, uint256 dep, uint256 red) = vault.requests(alice);
        assertEq(ep, vault.currentEpoch());
        assertEq(dep, 5_000e6, "the carried deposit stays queued");
        assertEq(red, sh);
        _home(82_000e6);
        vm.prank(manager);
        vault.settle();
        uint256 before = usdc.balanceOf(alice);
        vault.claim(alice);
        assertApproxEqRel(usdc.balanceOf(alice) - before, 82_000e6, 1e14, "redemption paid");
        (, uint256 dep2,) = vault.requests(alice);
        assertEq(dep2, 5_000e6, "deposit still queued");
        vm.prank(alice);
        vault.cancelDepositRequest();
    }
}

/// @notice Mirrors Round4AuditFixesTest: R3-04 (margin only in a leverage breach), R3-02, R3-03.
contract GainsRound4AuditFixesTest is GainsRound4Base {
    /// @dev R3-04: adding margin (lowering a trade's leverage) lowers risk, so it stays allowed in a leverage breach,
    ///      and is refused in a daily loss / drawdown breach.
    function test_R304_marginStillAllowedInALeverageBreach() public {
        _fund(10_000e6);
        _deposit(bob, 1_000e6);
        _skip(1 hours);
        vault.checkRisk();
        vm.prank(manager);
        vault.settle();
        _navNtl(10_000e6, 34_000e6); // 34k on 11k NAV: 3.09x
        vault.checkRisk();
        assertEq(uint8(vault.breachReason()), uint8(BreachReason.LEVERAGE));
        uint24 lev = diamond.getTrade(address(vault), tradeIdx).leverage;
        vm.prank(manager);
        vm.expectRevert(E.ReduceOnlyMode.selector);
        vault.updateLeverage(tradeIdx, lev + 100); // raising: new risk
        vm.prank(manager);
        vault.updateLeverage(tradeIdx, 3_200); // lowering pulls 625 USDC of margin from idle
        _fillLast(vault, _px(ETH));
        assertEq(diamond.getTrade(address(vault), tradeIdx).collateralAmount, 10_625e6);

        _nav(9_800e6); // about -8% today, under the 15% drawdown
        vault.checkRisk();
        assertEq(uint8(vault.breachReason()), uint8(BreachReason.DAILY_LOSS));
        vm.prank(manager);
        vm.expectRevert(E.ReduceOnlyMode.selector);
        vault.updateLeverage(tradeIdx, 3_100);
    }

    function test_R302_insiderAgeNeverDelaysExits() public {
        _fund(100_000e6);
        _skip(2 hours);
        vault.checkRisk();
        usdc.mint(manager, 10_000e6);
        vm.prank(manager);
        usdc.approve(address(vault), 10_000e6);
        vm.prank(manager);
        vault.requestDeposit(10_000e6, manager);
        vm.prank(manager);
        vault.settle();
        vm.prank(manager);
        vm.expectRevert(E.EpochTooYoung.selector);
        vault.settle();
        _redeem(alice, vault.balanceOf(alice) / 10);
        vm.prank(guardian);
        vault.triggerEmergency();
        _home(20_000e6);
        vm.prank(guardian);
        vault.settle();
        vault.claim(alice);
        vault.claim(manager);
        assertEq(usdc.balanceOf(manager), 10_000e6);
    }

    function test_R303_retriggerRestartsBreachedAt() public {
        _fund(10_000e6);
        vm.prank(guardian);
        vault.triggerEmergency();
        uint64 t0 = vault.breachedAt();
        _skip(1 hours);
        vm.prank(guardian);
        vault.triggerEmergency();
        assertEq(vault.breachedAt(), t0 + 1 hours);
    }
}

/// @notice Mirrors Round4BreachFeesTest: management fee only in a breach settle, never a performance fee.
contract GainsRound4BreachFeesTest is GainsRound4Base {
    function test_breachSettleChargesManagementFeeOnlyNeverPerformance() public {
        _fund(100_000e6);
        for (uint256 i; i < 2; ++i) {
            _skip(1 hours);
            _nav(100_000e6 + (i + 1) * 10_000e6);
            vault.checkRisk();
        }
        _warp((vm.getBlockTimestamp() / 1 days + 1) * 1 days + 60);
        vault.checkRisk();
        _nav(112_800e6);
        _skip(1 hours);
        vault.checkRisk();
        assertEq(uint8(vault.breachReason()), uint8(BreachReason.DAILY_LOSS));
        uint256 hwm = vault.highWaterMark();
        assertGt(vault.sharePrice(), hwm, "still above the high water mark");

        uint256 elapsed = vm.getBlockTimestamp() - vault.lastFeeAccrual();
        uint256 supply = vault.totalSupply();
        uint256 nav = vault.totalAssets();
        uint256 preview = lens.sharePriceAfterFees(vault);
        (uint256 previewFee,) = lens.pendingFeeShares(vault);
        vm.prank(manager);
        vault.settle();
        uint256 fee = vault.balanceOf(feeRecipient);
        assertApproxEqAbs(vault.sharePrice(), preview, 1, "lens price preview = settle price");
        assertEq(fee, previewFee, "lens fee preview = fee minted");
        uint256 mgmtAssets = (nav * 200 * elapsed) / (10_000 * 365 days);
        uint256 expected = (mgmtAssets * (supply + 1e6)) / (nav - mgmtAssets);
        assertApproxEqRel(fee, expected, 1e12, "management fee only");
        assertEq(vault.highWaterMark(), hwm, "no performance fee, HWM untouched");
    }
}

/// @notice Mirrors Round4Stop3DecisionsTest (decisions 1 and 2). The late-landing cases (D4b-d) have no Gains
///         counterpart; their analog (a pending order) is covered in GainsRound4Test and GainsVaultTest.
contract GainsRound4Stop3DecisionsTest is GainsRound4Base {
    function test_D1_redemptionOnlyPaysAtMinOfNavAndCheckpoint() public {
        _fund(100_000e6);
        _skip(2 hours);
        vault.checkRisk();
        _passHold(); // GR2-KEY-01b: the manager's exit waits out the minimum hold (the next warp is absolute)
        _home(20_000e6); // 20k idle, 80k on the venue
        _warp((vm.getBlockTimestamp() / 1 days + 1) * 1 days + 60);
        _nav(60_000e6); // NAV 80k: 20% drawdown
        for (uint256 i; i < 3; ++i) {
            _skip(1 hours);
            vault.checkRisk();
        }
        assertEq(uint8(vault.breachReason()), uint8(BreachReason.DRAWDOWN));
        assertApproxEqAbs(vault.checkpointNav(), 80_000e6, 2);

        _nav(64_000e6); // NAV 84k, still in the drawdown breach
        uint256 shares = vault.balanceOf(alice) / 10;
        _redeem(alice, shares);
        uint256 preview = lens.previewRedeem(vault, shares);
        uint256 atLive = (shares * (vault.totalAssets() + 1)) / (vault.totalSupply() + 1e6);
        assertLt(preview, atLive, "the preview uses the checkpoint, not the higher live NAV");
        uint256 before = usdc.balanceOf(alice);
        uint256 supplyBefore = vault.totalSupply();
        vm.prank(manager);
        vault.settle();
        _claim(alice);
        uint256 paid = usdc.balanceOf(alice) - before;
        assertEq(paid, preview, "lens preview = payout");
        assertApproxEqRel(paid, (shares * 80_000e6) / supplyBefore, 1e15, "priced at the 80k checkpoint");
    }

    function test_D2_minimumDeposit() public {
        assertEq(vault.MIN_DEPOSIT(), 10e6);
        usdc.mint(bob, 100e6);
        vm.prank(bob);
        usdc.approve(address(vault), type(uint256).max);
        vm.prank(bob);
        vm.expectRevert(E.DepositTooSmall.selector);
        vault.requestDeposit(10e6 - 1, bob);
        vm.prank(bob);
        vault.requestDeposit(10e6, bob);
    }

    function test_D2_insiderDelayGriefingCostsTenUsdc() public {
        usdc.mint(bob, 100e6);
        vm.prank(bob);
        usdc.approve(address(vault), type(uint256).max);
        vm.prank(bob);
        vm.expectRevert(E.DepositTooSmall.selector);
        vault.requestDeposit(1, owner);
        vm.prank(bob);
        vault.requestDeposit(10e6, owner);
        assertEq(vault.deferredDepositAssets(), 10e6, "an insider deposit, credited to the owner");
    }
}
