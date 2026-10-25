// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Base} from "./Base.t.sol";
import {HyperVault} from "../src/HyperVault.sol";
import {HyperVaultFactory} from "../src/HyperVaultFactory.sol";
import {VaultPolicy} from "../src/VaultPolicy.sol";
import {BreachReason, IHyperVaultErrors as E, IHyperVaultEvents} from "../src/VaultTypes.sol";
import {HyperCore, ICoreDepositWallet} from "../src/hypercore/HyperCore.sol";

/// @notice Round 4: risk on the share price (R-01), breach = derisk not shutdown, restricted unwind, the treasury
///         operator, insider deposits in the next epoch, X-01 / V-04 (other suites), late bridge landings (R-02).
contract Round4Test is Base {
    address internal bot = makeAddr("bot");

    /// @dev The epoch just settled minted no deposit shares (fee shares are normal and allowed).
    function _noDepositMint() internal view {
        (uint256 depA, uint256 depS,,,,,,) = vault.epochs(vault.currentEpoch() - 1);
        assertEq(depA + depS, 0, "no deposit priced or minted in a redemption-only epoch");
    }

    // ------------------------------------------------------------------
    // helpers
    // ------------------------------------------------------------------
    /// @dev alice deposits, the epoch settles, everything goes to Core and lands; the day reference is set.
    function _fund(uint256 amount) internal {
        _deposit(alice, amount);
        _settle();
        _claim(alice);
        vm.prank(manager);
        vault.bridgeToCore(amount);
        _setCore(address(vault), int64(uint64(amount)), 0, 0);
        vault.syncBridge();
        _skipBridgeWindow();
        vault.checkRisk();
    }

    /// @dev Bring `amount` home from perp and land it on HyperEVM.
    function _home(uint256 amount, int64 perpLeft) internal {
        _setWithdrawable(address(vault), uint64(amount));
        vm.prank(vault.emergency() ? guardian : manager); // HLR2-H04: only the platform bridges in emergency
        vault.bridgeToEvm(amount);
        usdc.mint(address(vault), amount);
        _setCore(address(vault), perpLeft, 0, 0);
        _setWithdrawable(address(vault), 0);
        vault.syncBridge();
        vm.roll(vm.getBlockNumber() + vault.BRIDGE_SETTLE_BLOCKS() + 1);
    }

    function _reason() internal view returns (uint8) {
        return uint8(vault.breachReason());
    }

    function _nextDay() internal {
        vm.warp((vm.getBlockTimestamp() / 1 days + 1) * 1 days + 1);
    }

    // ==================================================================
    // R-01: risk on the share price; deposits, withdrawals and fee mints never move it
    // ==================================================================
    /// @dev $100k vault, 1% down, $98k withdrawn: the daily loss stays 1%. (Before: the dollar baseline netted the
    ///      payout and read 33%.)
    function test_R01_withdrawalOnARedDayKeepsTheDailyLoss() public {
        _fund(100_000e6);
        _setCore(address(vault), 99_000e6, 0, 0); // -1%
        (, uint256 before,) = vault.checkRisk();
        assertApproxEqAbs(before, 100, 1);

        _redeem(alice, (vault.balanceOf(alice) * 98_990) / 100_000); // ~$98k at the current price
        _home(98_100e6, 900e6);
        vault.checkRisk();
        vm.prank(manager);
        vault.settle();
        _claim(alice);
        assertApproxEqAbs(usdc.balanceOf(alice), 1_000_000e6 - 100_000e6 + 98_000e6, 100e6, "alice paid ~98k");

        (, uint256 afterFlow,) = vault.checkRisk();
        assertApproxEqAbs(afterFlow, before, 1, "the withdrawal does not move the daily loss");
        assertFalse(vault.breached());
    }

    /// @dev A full redemption on a red day (4% down, inside the 5% limit) never breaches.
    function test_R01_fullRedemptionOnARedDayNeverBreaches() public {
        _fund(100_000e6);
        _setCore(address(vault), 96_000e6, 0, 0); // -4%
        vault.checkRisk();
        assertFalse(vault.breached());
        _redeem(alice, vault.balanceOf(alice));
        _home(96_000e6, 0);
        vault.checkRisk();
        vm.prank(manager);
        vault.settle();
        (, uint256 daily, uint256 dd) = vault.checkRisk();
        assertEq(daily, 0);
        assertEq(dd, 0);
        assertFalse(vault.breached(), "an emptied vault never breaches on the payout");
    }

    /// @dev A deposit that doubles the vault neither resets the peak nor hides the drawdown.
    function test_R01_depositDoublingTheVaultNeverResetsThePeak() public {
        _fund(100_000e6);
        uint256 peak = vault.peakSharePrice();
        _setCore(address(vault), 90_000e6, 0, 0); // -10% from the peak (limit 15%)
        _nextDay(); // keep the daily loss out of it
        (,, uint256 dd0) = vault.checkRisk();
        assertApproxEqAbs(dd0, 1_000, 1);

        _deposit(bob, 90_000e6);
        vm.prank(manager);
        vault.settle();
        _claim(bob);
        (,, uint256 dd1) = vault.checkRisk();
        // Only the fee dilution rescale of the settle moves it (by the same factor as the price), never a reset.
        assertApproxEqRel(vault.peakSharePrice(), peak, 1e14, "peak not reset by the deposit");
        assertApproxEqAbs(dd1, dd0, 1, "drawdown unchanged by the deposit");
    }

    /// @dev Fee mints dilute the price, never the loss metrics: both references are rescaled.
    function test_R01_feeMintsDoNotMoveTheMetrics() public {
        _fund(100_000e6);
        _setCore(address(vault), 97_000e6, 0, 0); // -3% today and from the peak
        (, uint256 d0, uint256 dd0) = vault.checkRisk();
        vm.warp(vm.getBlockTimestamp() + 20 hours); // same UTC day only if early; force same day below
        vm.warp(vm.getBlockTimestamp() - 20 hours + 3 hours);
        vault.accrueFees(); // management fee shares (2%/yr over 3h)
        (, uint256 d1, uint256 dd1) = vault.checkRisk();
        assertApproxEqAbs(d1, d0, 1, "daily loss unchanged by the fee mint");
        assertApproxEqAbs(dd1, dd0, 1, "drawdown unchanged by the fee mint");
    }

    /// @dev Any deposit / redemption mix at any loss within the limits: the settle moves neither metric.
    function testFuzz_R01_flowsNeverMoveTheMetrics(uint256 lossBps, uint256 redeemPct, uint256 depositAmt) public {
        lossBps = bound(lossBps, 0, 450);
        redeemPct = bound(redeemPct, 0, 100);
        depositAmt = bound(depositAmt, 0, 200_000e6);
        if (depositAmt > 0 && depositAmt < 10e6) depositAmt = 10e6; // MIN_DEPOSIT (0 = no deposit)
        _fund(100_000e6);
        uint256 nav = 100_000e6 - (100_000e6 * lossBps) / 10_000;
        _setCore(address(vault), int64(uint64(nav)), 0, 0);
        (, uint256 d0, uint256 dd0) = vault.checkRisk();

        uint256 shares = (vault.balanceOf(alice) * redeemPct) / 100;
        if (shares > 0) _redeem(alice, shares);
        if (depositAmt > 0) _deposit(bob, depositAmt);
        uint256 owed = vault.convertToAssets(shares) + 2e6;
        if (owed > nav) owed = nav;
        if (shares > 0) _home(owed, int64(uint64(nav - owed)));
        vault.checkRisk();
        vm.prank(manager);
        vault.settle();
        (, uint256 d1, uint256 dd1) = vault.checkRisk();
        if (vault.totalAssets() < 1e6) {
            // emptied to dust: rounding dominates the price, the metrics read 0 (MIN_RISK_NAV)
            assertEq(d1, 0);
            assertEq(dd1, 0);
        } else {
            assertApproxEqAbs(d1, d0, 1, "daily loss");
            assertApproxEqAbs(dd1, dd0, 1, "drawdown");
        }
        assertFalse(vault.breached());
    }

    /// @dev The dust case the fuzzer found: a vault emptied to a few micro USDC never breaches on rounding.
    ///      (MIN_DEPOSIT: the dust holder now gets there by redeeming all but 11 micro shares of a 10 USDC deposit.)
    function test_R01_dustVaultNeverBreachesOnRounding() public {
        _fund(100_000e6);
        _setCore(address(vault), 99_510e6, 0, 0);
        vault.checkRisk();
        _redeem(alice, vault.balanceOf(alice));
        _deposit(bob, 10e6);
        _home(99_510e6, 0);
        vault.checkRisk();
        vm.prank(manager);
        vault.settle();
        _claim(bob);
        _redeem(bob, vault.balanceOf(bob) - 11e6); // keeps ~11 micro USDC of shares
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        vault.checkRisk();
        vm.prank(manager);
        vault.settle();
        assertGt(vault.totalSupply(), 0, "shares outstanding: the metrics are actually computed");
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
        _setCore(address(vault), 10_000e6, 31_000e6, 0); // 3.1x > 3x
        vault.checkRisk();
        assertTrue(vault.breached());
        assertEq(_reason(), uint8(BreachReason.LEVERAGE));
        assertEq(vault.agent(), bot, "agent stays");
        vm.prank(manager);
        vm.expectRevert(E.ReduceOnlyMode.selector);
        vault.placeOrder(BTC, true, 100_000e8, 0.01e8, false, 2, 0);
        vm.prank(manager);
        vault.syncAgent(); // HL-PROXY: the account-mode pin is safe in a risk breach (a role pins at any time)

        // Still over: cannot clear. Too early: cannot clear.
        vm.prank(stranger);
        vm.expectRevert(E.NotReady.selector);
        vault.clearLeverageBreach();
        vm.warp(vm.getBlockTimestamp() + vault.LEVERAGE_CLEAR_COOLDOWN());
        vm.prank(stranger);
        vm.expectRevert(E.NotClearable.selector);
        vault.clearLeverageBreach();

        // Trimmed back under the limit: anyone clears it.
        _setCore(address(vault), 10_000e6, 25_500e6, 0);
        vm.prank(stranger);
        vault.clearLeverageBreach();
        assertFalse(vault.breached());
        assertEq(_reason(), 0);
        assertEq(vault.agent(), bot);
    }

    function test_LeverageBreach_cannotBeClearedWhenAnotherLimitIsOver() public {
        _fund(10_000e6);
        _setCore(address(vault), 10_000e6, 31_000e6, 0);
        vault.checkRisk();
        vm.warp(vm.getBlockTimestamp() + vault.LEVERAGE_CLEAR_COOLDOWN());
        // leverage back under, but the price fell 6% today: the breach escalates to daily loss
        _setCore(address(vault), 9_400e6, 20_000e6, 0);
        vm.expectRevert(E.NotClearable.selector);
        vault.clearLeverageBreach();
        vault.checkRisk();
        assertEq(_reason(), uint8(BreachReason.DAILY_LOSS), "escalated");
    }

    function test_DrawdownBreach_untilTheOwnerResumes_peakReset() public {
        _setAgent(vault, bot);
        _fund(10_000e6);
        _setCore(address(vault), 8_000e6, 0, 0); // -20% (limit 15%)
        _nextDay();
        vault.checkRisk();
        assertEq(_reason(), uint8(BreachReason.DRAWDOWN));
        assertEq(vault.agent(), bot);
        // The next day does not clear it, neither does the leverage path.
        _nextDay();
        vault.checkRisk();
        assertTrue(vault.breached());
        vm.expectRevert(E.NotClearable.selector);
        vault.clearLeverageBreach();
        // Deposits stay closed; a settle is redemption-only (decision 4) and mints nothing.
        vm.prank(bob);
        vm.expectRevert(E.DepositsClosed.selector);
        vault.requestDeposit(10e6, bob);
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        vault.checkRisk();
        vm.prank(manager);
        vault.settle();
        _noDepositMint();
        // Only the owner resumes; the peak restarts from here.
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
        _setCore(address(vault), 8_000e6, 30_000e6, 0); // -20% and 3.75x
        _nextDay();
        vault.checkRisk();
        assertEq(_reason(), uint8(BreachReason.DRAWDOWN));
        vm.warp(vm.getBlockTimestamp() + vault.RESUME_COOLDOWN());
        vm.prank(owner);
        vm.expectRevert(E.NotClearable.selector);
        vault.resume();
    }

    function test_SettleInARiskBreach_leverageSettles_dailyLossIsRedemptionOnly() public {
        _fund(10_000e6);
        _setCore(address(vault), 10_000e6, 31_000e6, 0);
        vault.checkRisk();
        assertEq(_reason(), uint8(BreachReason.LEVERAGE));
        vm.prank(manager);
        vault.settle(); // a leverage breach says nothing about the NAV
        _setCore(address(vault), 9_400e6, 0, 0);
        vault.checkRisk();
        assertEq(_reason(), uint8(BreachReason.DAILY_LOSS));
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        vault.checkRisk();
        vm.prank(manager);
        vault.settle(); // decision 4: redemption-only
        _noDepositMint();
    }

    function test_GuardianBreachAndEmergencyAreFullStops() public {
        _setAgent(vault, bot);
        _fund(10_000e6);
        vm.prank(guardian);
        vault.triggerBreach();
        assertEq(_reason(), uint8(BreachReason.GUARDIAN));
        assertEq(vault.agent(), address(0), "full stop revokes");
        // HL-PROXY: nothing is ever approved on HyperCore; syncAgent only re-pins the vault's own account mode
        vm.prank(guardian);
        vault.syncAgent();
        (, uint24 pinId,) = _decode(writer.last());
        assertEq(pinId, 16);
        vm.prank(manager);
        vm.expectRevert(E.ReduceOnlyMode.selector);
        vault.settle();
        // checkRisk never downgrades a full stop
        _setCore(address(vault), 10_000e6, 31_000e6, 0);
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
        _setCore(address(vault), 10_000e6, 31_000e6, 0);
        vault.checkRisk();
        assertEq(vault.agent(), bot);
        vm.prank(guardian); // standalone vault: the guardian is also the sentinel
        vault.triggerBreach();
        assertEq(_reason(), uint8(BreachReason.GUARDIAN));
        assertEq(vault.agent(), address(0));
        vm.warp(vm.getBlockTimestamp() + 1 days);
        _setCore(address(vault), 10_000e6, 0, 0);
        vm.expectRevert(E.NotClearable.selector);
        vault.clearLeverageBreach();
    }

    function test_LensExposesTheBreachReason() public {
        _fund(10_000e6);
        _setCore(address(vault), 10_000e6, 31_000e6, 0);
        vault.checkRisk();
        assertEq(lens.status(vault).breachReason, uint8(BreachReason.LEVERAGE));
    }

    // ==================================================================
    // Depositors keep their exits in every mode
    // ==================================================================
    function test_DepositorsRequestAndClaimInBreachAndEmergency() public {
        _fund(10_000e6);
        _setCore(address(vault), 8_000e6, 0, 0);
        _nextDay();
        vault.checkRisk();
        assertTrue(vault.breached());
        _redeem(alice, vault.balanceOf(alice) / 2);
        vm.prank(guardian);
        vault.triggerEmergency();
        _home(8_000e6, 0);
        vm.prank(guardian);
        vault.settle();
        _claim(alice);
        assertGt(usdc.balanceOf(alice), 1_000_000e6 - 10_000e6, "paid out in emergency");
        _redeem(alice, vault.balanceOf(alice));
    }

    // ==================================================================
    // R-02: a late bridge landing
    // ==================================================================
    function test_R02_lateLandingIsNeitherANavDropNorSettledAround() public {
        _fund(10_000e6);
        _redeem(alice, vault.balanceOf(alice) / 2);
        _setWithdrawable(address(vault), 5_000e6);
        vm.prank(manager);
        vault.bridgeToEvm(5_000e6);
        _setCore(address(vault), 5_000e6, 0, 0); // left Core, not on HyperEVM yet
        _setWithdrawable(address(vault), 0);
        vm.roll(vm.getBlockNumber() + 50); // well past the 10 block window
        assertTrue(vault.bridgeInFlight(), "the window waits for the landing");
        assertEq(vault.totalAssets(), 10_000e6, "no false NAV drop");
        (, uint256 daily, uint256 dd) = vault.checkRisk();
        assertEq(daily, 0);
        assertEq(dd, 0);
        assertFalse(vault.breached());
        vm.prank(manager);
        vm.expectRevert(E.BridgeInFlight.selector);
        vault.settle();

        usdc.mint(address(vault), 5_000e6); // lands 50 blocks late
        assertFalse(vault.bridgeInFlight());
        vault.syncBridge();
        vm.prank(manager);
        vault.settle();
        assertApproxEqAbs(vault.totalAssets(), 5_000e6, 1e6, "half paid out, the rest still there");
    }

    function test_R02_boundedByTheMaximumWait() public {
        _fund(10_000e6);
        _setWithdrawable(address(vault), 5_000e6);
        vm.prank(manager);
        vault.bridgeToEvm(5_000e6);
        _setCore(address(vault), 5_000e6, 0, 0);
        vm.roll(vm.getBlockNumber() + vault.MAX_BRIDGE_WAIT_BLOCKS());
        assertTrue(vault.bridgeInFlight());
        vm.roll(vm.getBlockNumber() + 1);
        assertFalse(vault.bridgeInFlight(), "after the cap, what is missing counts as missing");
        assertEq(vault.totalAssets(), 5_000e6);
    }

    /// @dev The landing is read on the destination side, never from the total: a loss after the landing is not
    ///      taken for a missing transfer and is never masked.
    function test_R02_aLossAfterTheLandingIsNotMasked() public {
        _fund(10_000e6);
        vm.warp(vm.getBlockTimestamp() + 2 hours);
        _deposit(bob, 5_000e6);
        vault.checkRisk();
        vm.prank(manager);
        vault.settle();
        vm.prank(manager);
        vault.bridgeToCore(5_000e6);
        _setCore(address(vault), 10_000e6, 0, 5_000e6); // landed on Core spot
        vm.roll(vm.getBlockNumber() + 11);
        // then -4k (27%), unrealised: rawUsd (cash minus entry notional) does not move with the mark (HLR2-A04)
        _resp(
            HyperCore.PRECOMPILE_ACCOUNT_MARGIN_SUMMARY,
            abi.encode(uint32(0), address(vault)),
            abi.encode(HyperCore.AccountMarginSummary(6_000e6, 0, 0, 10_000e6))
        );
        assertFalse(vault.bridgeInFlight(), "spot shows the landing");
        vault.checkRisk();
        assertTrue(vault.breached(), "the loss is seen");
    }

    function test_R02_moveUsdWaitsForTheWindow() public {
        _fund(10_000e6);
        _deposit(bob, 1_000e6);
        vm.warp(vm.getBlockTimestamp() + 2 hours);
        vault.checkRisk();
        vm.prank(manager);
        vault.settle();
        vm.prank(manager);
        vault.bridgeToCore(1_000e6);
        vm.prank(manager);
        vm.expectRevert(E.BridgeInFlight.selector);
        vault.moveUsd(1_000e6, true);
    }
}

/// @notice Restricted unwind and the treasury operator, on a factory vault (distinct sentinel and guardian).
contract Round4FactoryTest is Base {
    HyperVaultFactory internal factory;
    HyperVault internal v;
    address internal keeper = makeAddr("keeper");
    address internal creator = makeAddr("creator");
    address internal treasury = makeAddr("treasury");

    function setUp() public override {
        super.setUp();
        factory = new HyperVaultFactory(
            owner, address(vaultImpl), address(policyImpl), IERC20(address(usdc)), ICoreDepositWallet(address(depositWallet)), treasury, guardian, sentinel
        );
        vm.startPrank(owner);
        factory.setLauncherAllowed(creator, true);
        factory.setAssetCurated(BTC, true);
        factory.setAssetCurated(ETH, true);
        vm.stopPrank();
        uint32[] memory assets = new uint32[](2);
        assets[0] = BTC;
        assets[1] = ETH;
        usdc.mint(creator, 10e6);
        vm.deal(creator, 1 ether);
        vm.prank(creator);
        usdc.approve(address(factory), 10e6);
        vm.prank(creator);
        (address va,) = factory.create{value: 0.01 ether}(
            HyperVaultFactory.CreateParams({
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
                seedUsdc: 2e6,
                salt: bytes32(0)
            }),
            HyperVaultFactory.PermitData(0, 0, 0, bytes32(0), bytes32(0))
        );
        v = HyperVault(va);
        _setCoreUser(va, true);
        _setCore(va, 1e6, 0, 0);
        _setWithdrawable(va, 0);
        _setPosition(va, BTC, 0);
        _setPosition(va, ETH, 5_0000);
        vm.roll(vm.getBlockNumber() + 400);
        vm.prank(alice);
        usdc.approve(va, type(uint256).max);
        vm.prank(alice);
        v.requestDeposit(10_000e6, alice);
        v.checkRisk();
    }

    /// @dev Decision 2 after STOP 3: the 10 USDC minimum is a platform constant, readable on the factory.
    function test_D2_factoryMinimumDeposit() public view {
        assertEq(factory.MIN_DEPOSIT(), 10e6);
    }

    function test_OperatorGrantedAtLaunch_runsTheTreasuryOnly() public {
        assertEq(v.operator(), keeper);
        vm.startPrank(keeper);
        v.settle(); // normal settle: mints alice
        v.bridgeToCore(10_000e6);
        vm.stopPrank();
        _setCore(address(v), 1e6, 0, 10_000e6);
        v.syncBridge();
        vm.roll(vm.getBlockNumber() + 11);
        vm.startPrank(keeper);
        v.moveUsd(10_000e6, true);
        _setCore(address(v), 10_001e6, 0, 0);
        _setWithdrawable(address(v), 1_000e6);
        v.bridgeToEvm(1_000e6);

        // Nothing else.
        vm.expectRevert(E.Unauthorized.selector);
        v.placeOrder(BTC, true, 100_000e8, 0.01e8, false, 2, 0);
        vm.expectRevert(E.Unauthorized.selector);
        v.setDepositsPaused(true);
        vm.expectRevert(E.Unauthorized.selector);
        v.lowerFees(0, 0);
        vm.expectRevert(E.Unauthorized.selector);
        v.queue(abi.encodeCall(HyperVault.setManager, (keeper)));
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
        v.cancelOrder(BTC, 1);
        vm.expectRevert(E.Unauthorized.selector);
        v.leaveHosted();
        vm.expectRevert(E.Unauthorized.selector);
        v.flatten(ETH, 0); // outside a breach only the manager and the guardian flatten
        vm.stopPrank();
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
        vm.prank(sentinel);
        v.triggerBreach();
        address[2] memory outsiders = [stranger, alice];
        for (uint256 i; i < 2; ++i) {
            vm.prank(outsiders[i]);
            vm.expectRevert(E.Unauthorized.selector);
            v.flatten(ETH, 0);
        }
        address[5] memory roles = [creator, manager, keeper, sentinel, guardian];
        for (uint256 i; i < 5; ++i) {
            vm.prank(roles[i]);
            v.flatten(ETH, 0);
        }
    }

    function test_EmergencyUnwind_listedRolesOnly() public {
        vm.prank(keeper);
        v.settle();
        v.claim(alice);
        uint256 sh = v.balanceOf(alice);
        vm.prank(alice);
        v.requestRedeem(sh, alice, alice); // depositors always request
        vm.prank(guardian);
        v.triggerEmergency();
        _setWithdrawable(address(v), 1e6);
        address[2] memory outsiders = [stranger, alice];
        for (uint256 i; i < 2; ++i) {
            vm.startPrank(outsiders[i]);
            vm.expectRevert(E.Unauthorized.selector);
            v.flatten(ETH, 0);
            vm.expectRevert(E.Unauthorized.selector);
            v.bridgeToEvm(1e6);
            vm.expectRevert(E.Unauthorized.selector);
            v.settle();
            vm.stopPrank();
        }
        vm.prank(sentinel);
        v.flatten(ETH, 0);
        vm.prank(creator);
        v.settle(); // the owner settles (exit only): alice is paid from what is idle
        v.claim(alice); // depositors always claim
    }
}

/// @notice Decisions 2 and 4: redemption-only settles in a daily loss / drawdown breach, and the resume cooldown.
contract Round4DecisionsTest is Base {
    address internal sybil = makeAddr("sybil");

    function setUp() public override {
        super.setUp();
        usdc.mint(sybil, 1_000_000e6);
        vm.prank(sybil);
        usdc.approve(address(vault), type(uint256).max);
    }

    function _fund(uint256 amount) internal {
        _deposit(alice, amount);
        _settle();
        _claim(alice);
        vm.prank(manager);
        vault.bridgeToCore(amount);
        _setCore(address(vault), int64(uint64(amount)), 0, 0);
        vault.syncBridge();
        _skipBridgeWindow();
        vault.checkRisk();
    }

    /// @dev A drawdown breach with the checkpoint ratcheted down to the deflated NAV (the keeper's hourly checks):
    ///      the bound passes, so a redemption-only settle really runs.
    function _drawdownBreach(int64 navAfter) internal {
        vm.warp((vm.getBlockTimestamp() / 1 days + 1) * 1 days + 60); // fresh day: the drawdown is the reason
        _setCore(address(vault), navAfter, 0, 0);
        for (uint256 i; i < 3; ++i) {
            vm.warp(vm.getBlockTimestamp() + 1 hours);
            vault.checkRisk();
        }
        assertEq(uint8(vault.breachReason()), uint8(BreachReason.DRAWDOWN));
    }

    function _home(uint256 amount, int64 perpLeft) internal {
        _setWithdrawable(address(vault), uint64(amount));
        vm.prank(vault.emergency() ? guardian : manager); // HLR2-H04: only the platform bridges in emergency
        vault.bridgeToEvm(amount);
        usdc.mint(address(vault), amount);
        _setCore(address(vault), perpLeft, 0, 0);
        _setWithdrawable(address(vault), 0);
        vault.syncBridge();
        vm.roll(vm.getBlockNumber() + 11);
    }

    /// @dev C-01 stays closed: a deposit queued before a (possibly faked) drawdown is never minted at the deflated
    ///      NAV. It is carried and priced only once the breach has cleared, at the recovered NAV.
    function test_D4_C01_noMintAtADeflatedNav() public {
        _fund(100_000e6);
        vm.prank(sybil);
        vault.requestDeposit(100_000e6, sybil); // queued before the drop
        _drawdownBreach(80_000e6); // 20% "lost" (funds hidden)
        vm.prank(manager);
        vault.settle(); // redemption-only
        (uint256 depA, uint256 depS,,,,,,) = vault.epochs(vault.currentEpoch() - 1);
        assertEq(depA + depS, 0, "nothing priced or minted for the deposit at the deflated NAV");
        assertEq(vault.balanceOf(sybil), 0);
        assertEq(vault.pendingDepositAssets(), 100_000e6, "the deposit stays queued");
        (uint256 cf, uint256 pi) = vault.carry(vault.currentEpoch() - 1);
        assertGt(cf, 0, "carried");
        assertEq(pi, 0);
        vm.expectRevert(E.RequestNotSettled.selector);
        vault.claim(sybil);

        // The funds come back; the owner resumes after the cooldown; the next settle prices the carried deposit.
        _setCore(address(vault), 100_000e6, 0, 0);
        vm.warp(vm.getBlockTimestamp() + 24 hours);
        vm.prank(owner);
        vault.resume();
        for (uint256 i; i < 2; ++i) {
            vm.warp(vm.getBlockTimestamp() + 1 hours);
            vault.checkRisk();
        }
        vm.prank(manager);
        vault.settle();
        vault.claim(sybil);
        uint256 v = vault.convertToAssets(vault.balanceOf(sybil));
        assertApproxEqRel(v, 100_000e6, 1e15, "priced at the recovered NAV, not the deflated one");
        assertApproxEqRel(vault.convertToAssets(vault.balanceOf(alice)), 100_000e6, 1e15, "alice untouched");
    }

    /// @dev A depositor exits in full during a drawdown breach, through each kind of allowed role.
    function test_D4_depositorFullyExitsDuringADrawdownBreach() public {
        _fund(100_000e6);
        _drawdownBreach(80_000e6);
        uint256 shares = vault.balanceOf(alice);
        _redeem(alice, shares);
        _home(80_000e6, 0);
        vm.prank(stranger);
        vm.expectRevert(E.Unauthorized.selector);
        vault.settle();
        vm.prank(guardian); // a platform role may run it too (owner / manager / operator / sentinel / guardian)
        vault.settle();
        _claim(alice);
        // paid the current NAV in full (less the normal management fee accrued since the last settle)
        assertApproxEqRel(usdc.balanceOf(alice), 1_000_000e6 - 100_000e6 + 80_000e6, 1e14, "paid the current NAV in full");
        assertEq(vault.balanceOf(alice), 0);
        assertTrue(vault.breached(), "the breach itself is unchanged");
    }

    /// @dev Several redemption-only epochs in a row: the carried deposit can be cancelled at any time, is never
    ///      claimable while carried, and resolves in one lookup once priced.
    function test_D4_carriedDepositAcrossEpochs() public {
        _fund(100_000e6);
        vm.prank(sybil);
        vault.requestDeposit(10_000e6, sybil);
        _deposit(bob, 5_000e6);
        _drawdownBreach(82_000e6);
        for (uint256 i; i < 3; ++i) {
            vm.warp(vm.getBlockTimestamp() + 1 hours);
            vault.checkRisk();
            vm.prank(manager);
            vault.settle();
        }
        assertEq(vault.pendingDepositAssets(), 15_000e6);
        // bob takes his back while carried
        uint256 b = usdc.balanceOf(bob);
        vm.prank(bob);
        vault.cancelDepositRequest();
        assertEq(usdc.balanceOf(bob), b + 5_000e6);
        assertEq(vault.pendingDepositAssets(), 10_000e6);
        // clear; a carried depositor may add to the carried request (it rejoins the current epoch)
        vm.warp(vm.getBlockTimestamp() + 24 hours);
        vm.prank(owner);
        vault.resume();
        vm.prank(sybil);
        vault.requestDeposit(1_000e6, sybil);
        (uint256 rEp, uint256 rDep,) = vault.requests(sybil);
        assertEq(rEp, vault.currentEpoch());
        assertEq(rDep, 11_000e6);
        vm.warp(vm.getBlockTimestamp() + 1 hours);
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
        vm.warp(vault.breachedAt() + vault.RESUME_COOLDOWN());
        vm.expectEmit(false, false, false, false, address(vault));
        emit IHyperVaultEvents.Resumed(0, 0);
        vm.prank(owner);
        vault.resume();
        assertEq(vault.lastResumeAt(), vm.getBlockTimestamp());
        assertEq(lens.status(vault).lastResumeAt, vm.getBlockTimestamp());
    }
}

/// @notice Exits are never gated by a carried deposit.
contract Round4CarryExitTest is Base {
    function test_D4_carriedDepositorCanStillRedeem() public {
        // alice holds shares and queues another deposit; a drawdown breach carries the deposit
        _deposit(alice, 100_000e6);
        _settle();
        _claim(alice);
        vm.prank(manager);
        vault.bridgeToCore(100_000e6);
        _setCore(address(vault), 100_000e6, 0, 0);
        vault.syncBridge();
        _skipBridgeWindow();
        vault.checkRisk();
        _deposit(alice, 5_000e6);
        vm.warp((vm.getBlockTimestamp() / 1 days + 1) * 1 days + 60);
        _setCore(address(vault), 82_000e6, 0, 0);
        for (uint256 i; i < 3; ++i) {
            vm.warp(vm.getBlockTimestamp() + 1 hours);
            vault.checkRisk();
        }
        assertEq(uint8(vault.breachReason()), uint8(BreachReason.DRAWDOWN));
        vm.prank(manager);
        vault.settle(); // redemption-only: alice's 5k carried
        // she can still ask to exit with her shares
        uint256 sh = vault.balanceOf(alice);
        vm.prank(alice);
        vault.requestRedeem(sh, alice, alice);
        (uint256 ep, uint256 dep, uint256 red) = vault.requests(alice);
        assertEq(ep, vault.currentEpoch());
        assertEq(dep, 5_000e6, "the carried deposit stays queued");
        assertEq(red, sh);
        // paid in the next redemption-only settle; the deposit still waits
        _setWithdrawable(address(vault), 82_000e6);
        vm.prank(manager);
        vault.bridgeToEvm(82_000e6);
        usdc.mint(address(vault), 82_000e6);
        _setCore(address(vault), 0, 0, 0);
        _setWithdrawable(address(vault), 0);
        vault.syncBridge();
        vm.roll(vm.getBlockNumber() + 11);
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

/// @notice REAUDIT3 fixes: R3-02 (insider minimum epoch age), R3-04 (margin only in a leverage breach).
contract Round4AuditFixesTest is Base {
    function _fund(uint256 amount) internal {
        _deposit(alice, amount);
        _settle();
        _claim(alice);
        vm.prank(manager);
        vault.bridgeToCore(amount);
        _setCore(address(vault), 0, 0, uint64(amount));
        vault.syncBridge(); // landed on spot
        _setCore(address(vault), int64(uint64(amount)), 0, 0);
        vm.roll(vm.getBlockNumber() + 11);
        vault.checkRisk();
    }

    /// @dev R3-04: adding margin lowers leverage, so it stays allowed in a leverage breach.
    function test_R304_marginStillAllowedInALeverageBreach() public {
        _fund(10_000e6);
        _deposit(bob, 1_000e6);
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        vault.checkRisk();
        vm.prank(manager);
        vault.settle();
        _setCore(address(vault), 10_000e6, 31_000e6, 0);
        vault.checkRisk();
        assertEq(uint8(vault.breachReason()), uint8(BreachReason.LEVERAGE));
        vm.prank(manager);
        vault.bridgeToCore(1_000e6);
        _setCore(address(vault), 10_000e6, 31_000e6, 1_000e6);
        vault.syncBridge();
        vm.roll(vm.getBlockNumber() + 11);
        vm.prank(manager);
        vault.moveUsd(1_000e6, true);
    }

    /// @dev R3-02 never delays an exit: with insider deposits queued, a redemption-only or emergency settle runs at
    ///      once; only the settle that would PRICE the insiders waits the hour.
    function test_R302_insiderAgeNeverDelaysExits() public {
        _fund(100_000e6);
        vm.warp(vm.getBlockTimestamp() + 2 hours);
        vault.checkRisk();
        usdc.mint(manager, 10_000e6);
        vm.prank(manager);
        usdc.approve(address(vault), 10_000e6);
        vm.prank(manager);
        vault.requestDeposit(10_000e6, manager);
        vm.prank(manager);
        vault.settle(); // the insider deposit is now the queue
        // same block: a pricing settle is refused...
        vm.prank(manager);
        vm.expectRevert(E.EpochTooYoung.selector);
        vault.settle();
        // ...but an emergency (exit-only) settle in the same block runs and pays.
        _redeem(alice, vault.balanceOf(alice) / 10);
        vm.prank(guardian);
        vault.triggerEmergency();
        _setWithdrawable(address(vault), 20_000e6);
        vm.prank(guardian); // HLR2-H04: only the platform bridges in emergency
        vault.bridgeToEvm(20_000e6);
        usdc.mint(address(vault), 20_000e6);
        _setCore(address(vault), 80_000e6, 0, 0);
        vault.syncBridge();
        vm.roll(vm.getBlockNumber() + 11);
        vm.prank(guardian);
        vault.settle();
        vault.claim(alice);
        vault.claim(manager); // the insider deposit was refunded by the exit-only settle
        assertEq(usdc.balanceOf(manager), 10_000e6);
    }

    /// @dev R3-03: every trigger restarts breachedAt.
    function test_R303_retriggerRestartsBreachedAt() public {
        _fund(10_000e6);
        vm.prank(guardian);
        vault.triggerEmergency();
        uint64 t0 = vault.breachedAt();
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        vm.prank(guardian);
        vault.triggerEmergency();
        assertEq(vault.breachedAt(), t0 + 1 hours);
    }
}

/// @notice (b) fees in a breach settle: management fee only, never a performance fee.
contract Round4BreachFeesTest is Base {
    function test_breachSettleChargesManagementFeeOnlyNeverPerformance() public {
        // 100k in, a +20% run (price well above the high water mark), then a -6% day: daily loss breach above the HWM.
        _deposit(alice, 100_000e6);
        _settle();
        _claim(alice);
        vm.prank(manager);
        vault.bridgeToCore(100_000e6);
        _setCore(address(vault), 0, 0, 100_000e6);
        vault.syncBridge();
        _setCore(address(vault), 100_000e6, 0, 0);
        vm.roll(vm.getBlockNumber() + 11);
        vault.checkRisk();
        for (uint256 i; i < 2; ++i) {
            vm.warp(vm.getBlockTimestamp() + 1 hours);
            _setCore(address(vault), int64(uint64(100_000e6 + (i + 1) * 10_000e6)), 0, 0);
            vault.checkRisk();
        }
        vm.warp((vm.getBlockTimestamp() / 1 days + 1) * 1 days + 60);
        vault.checkRisk(); // new day starts at 120k
        _setCore(address(vault), 112_800e6, 0, 0); // -6%
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        vault.checkRisk();
        assertEq(uint8(vault.breachReason()), uint8(BreachReason.DAILY_LOSS));
        uint256 hwm = vault.highWaterMark();
        assertGt(vault.sharePrice(), hwm, "still above the high water mark");

        uint256 elapsed = vm.getBlockTimestamp() - vault.lastFeeAccrual();
        uint256 supply = vault.totalSupply();
        uint256 nav = vault.totalAssets();
        // The lens previews the same settle: management fee only (it once added the performance fee in a breach).
        uint256 preview = lens.sharePriceAfterFees(vault);
        (uint256 previewFee,) = lens.pendingFeeShares(vault);
        vm.prank(manager);
        vault.settle(); // redemption-only
        uint256 fee = vault.balanceOf(feeRecipient);
        assertApproxEqAbs(vault.sharePrice(), preview, 1, "lens price preview = settle price");
        assertEq(fee, previewFee, "lens fee preview = fee minted");
        // management fee only: 2%/yr on NAV for the elapsed time, as shares
        uint256 mgmtAssets = (nav * 200 * elapsed) / (10_000 * 365 days);
        uint256 expected = (mgmtAssets * (supply + 1e6)) / (nav - mgmtAssets);
        assertApproxEqRel(fee, expected, 1e12, "management fee only");
        assertEq(vault.highWaterMark(), hwm, "no performance fee, HWM untouched");
    }
}

/// @notice R3-01 residual (decision 4): a real Core -> EVM transfer that lands after the 60 block window must not
///         read as a loss in the permissionless risk check (nor be priced by a settle), while a transfer that never
///         lands, and any trading loss meanwhile, still counts.
contract Round4LateLandingTest is Base {
    function _fund(uint256 amount) internal {
        _deposit(alice, amount);
        _settle();
        _claim(alice);
        vm.prank(manager);
        vault.bridgeToCore(amount);
        _setCore(address(vault), 0, 0, uint64(amount));
        vault.syncBridge(); // landed on spot
        _setCore(address(vault), int64(uint64(amount)), 0, 0);
        vm.roll(vm.getBlockNumber() + 11);
        vm.warp(vm.getBlockTimestamp() + 2 hours);
        vault.checkRisk();
    }

    /// @dev Core sent 50k home; HyperEVM has not credited it yet when the 60 block window ends.
    function _lateBridgeHome() internal {
        _setWithdrawable(address(vault), 50_000e6);
        vm.prank(manager);
        vault.bridgeToEvm(50_000e6);
        _setCore(address(vault), 50_000e6, 0, 0);
        _setWithdrawable(address(vault), 0);
        vm.roll(vm.getBlockNumber() + vault.MAX_BRIDGE_WAIT_BLOCKS() + 1);
        assertFalse(vault.bridgeInFlight(), "the NAV window itself stays capped at 60 blocks (R3-05)");
    }

    function test_lateLandingIsNotALoss() public {
        _fund(100_000e6);
        _lateBridgeHome();
        (, uint256 daily, uint256 dd) = vault.checkRisk();
        assertEq(daily + dd, 0, "the unlanded amount is in transit, not lost");
        assertFalse(vault.breached(), "no daily loss / drawdown breach from a late landing");
        // settle waits for it too: it would price redemptions at a NAV short by the transfer
        _redeem(alice, vault.balanceOf(alice) / 10);
        vm.prank(manager);
        vm.expectRevert(E.BridgeInFlight.selector);
        vault.settle();
        // it lands: everything is back to normal
        usdc.mint(address(vault), 50_000e6);
        vault.checkRisk();
        assertFalse(vault.breached());
        assertApproxEqAbs(vault.totalAssets(), 100_000e6, 1e6);
        vm.prank(manager);
        vault.settle();
    }
}

/// @notice Decisions after STOP 3: late landings (cont.), redemption-only pricing at min(NAV, checkpoint), and the
///         10 USDC minimum deposit.
contract Round4Stop3DecisionsTest is Base {
    function _fund(uint256 amount) internal {
        _deposit(alice, amount);
        _settle();
        _claim(alice);
        vm.prank(manager);
        vault.bridgeToCore(amount);
        _setCore(address(vault), 0, 0, uint64(amount));
        vault.syncBridge();
        _setCore(address(vault), int64(uint64(amount)), 0, 0);
        vm.roll(vm.getBlockNumber() + 11);
        vm.warp(vm.getBlockTimestamp() + 2 hours);
        vault.checkRisk();
    }

    function _lateBridgeHome() internal {
        _setWithdrawable(address(vault), 50_000e6);
        vm.prank(manager);
        vault.bridgeToEvm(50_000e6);
        _setCore(address(vault), 50_000e6, 0, 0);
        _setWithdrawable(address(vault), 0);
        vm.roll(vm.getBlockNumber() + vault.MAX_BRIDGE_WAIT_BLOCKS() + 1);
    }

    // ---------------------------------------------------------------- decision 4
    function test_D4b_aTradingLossWhileUnlandedStillBreaches() public {
        _fund(100_000e6);
        _lateBridgeHome();
        _setCore(address(vault), 40_000e6, 0, 0); // a real 10k loss on what stayed on Core
        vault.checkRisk();
        assertTrue(vault.breached(), "only the bridged amount is carried as in transit");
        assertEq(uint8(vault.breachReason()), uint8(BreachReason.DAILY_LOSS));
    }

    function test_D4c_aTransferThatNeverLandsCountsAsLostAfterTheCap() public {
        _fund(100_000e6);
        _lateBridgeHome();
        vault.checkRisk();
        assertFalse(vault.breached());
        assertTrue(vault.bridgePending());
        vm.roll(vm.getBlockNumber() + vault.MAX_UNLANDED_BLOCKS());
        assertFalse(vault.bridgePending(), "bounded: at most MAX_UNLANDED_BLOCKS");
        vault.checkRisk();
        assertTrue(vault.breached(), "missing after the cap: a real loss");
    }

    function test_D4d_noNewBridgeWhileTheLastOneIsLate() public {
        _fund(100_000e6);
        _lateBridgeHome();
        _setWithdrawable(address(vault), 50_000e6);
        vm.prank(manager);
        vm.expectRevert(E.BridgeInFlight.selector);
        vault.bridgeToEvm(10_000e6);
    }

    // ---------------------------------------------------------------- decision 1
    /// @dev Drawdown breach at 80k; the NAV is then pushed to 84k (inside the per-settle bound) and a redemption-only
    ///      settle runs at once: the redeemer is paid at the 80k checkpoint, and the lens preview says exactly that.
    function test_D1_redemptionOnlyPaysAtMinOfNavAndCheckpoint() public {
        _fund(100_000e6);
        _setWithdrawable(address(vault), 20_000e6);
        vm.prank(manager);
        vault.bridgeToEvm(20_000e6);
        usdc.mint(address(vault), 20_000e6);
        _setCore(address(vault), 80_000e6, 0, 0);
        _setWithdrawable(address(vault), 0);
        vault.syncBridge();
        vm.roll(vm.getBlockNumber() + 11);
        vm.warp((vm.getBlockTimestamp() / 1 days + 1) * 1 days + 60);
        _setCore(address(vault), 60_000e6, 0, 0); // NAV 80k: 20% drawdown
        for (uint256 i; i < 3; ++i) {
            vm.warp(vm.getBlockTimestamp() + 1 hours);
            vault.checkRisk();
        }
        assertEq(uint8(vault.breachReason()), uint8(BreachReason.DRAWDOWN));
        assertEq(vault.checkpointNav(), 80_000e6);

        _setCore(address(vault), 64_000e6, 0, 0); // NAV 84k, still in the drawdown breach
        uint256 shares = vault.balanceOf(alice) / 10;
        _redeem(alice, shares);
        uint256 preview = lens.previewRedeem(vault, shares);
        uint256 atLive = (shares * (84_000e6 + 1)) / (vault.totalSupply() + 1e6);
        assertLt(preview, atLive, "the preview uses the checkpoint, not the higher live NAV");
        uint256 before = usdc.balanceOf(alice);
        uint256 supplyBefore = vault.totalSupply();
        vm.prank(manager);
        vault.settle(); // redemption-only
        _claim(alice);
        uint256 paid = usdc.balanceOf(alice) - before;
        assertEq(paid, preview, "lens preview = payout");
        assertApproxEqRel(paid, (shares * 80_000e6) / supplyBefore, 1e15, "priced at the 80k checkpoint");
    }

    // ---------------------------------------------------------------- decision 2
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

    /// @dev I3-07: a stranger arming the insider delay for the owner now pays at least 10 USDC (credited to the owner).
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
