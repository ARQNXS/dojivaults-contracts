// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// WP5 (round 2 fix round, internal, AI-assisted; not an independent audit): the limits that bound what the platform
// agent key can do on a Hyperliquid vault, asserted on the platform vault's live policy (5x, daily loss 20 %, drawdown
// 50 %, slippage band 1 %, 2.5M per order) with a 100k NAV. Defensive tests: each one asserts that a limit holds at
// its edge (accepted just inside, refused just outside), for findings WP5-HL-01 and WP5-BOTH-02 in WP5-RESULTS.md.
// Never block.timestamp / block.number here (via_ir rematerialisation): vm.getBlockTimestamp().

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {Base} from "../../Base.t.sol";
import {HyperVault} from "../../../src/HyperVault.sol";
import {HyperCore} from "../../../src/hypercore/HyperCore.sol";
import {IHyperVaultErrors, IHyperVaultEvents, BreachReason} from "../../../src/VaultTypes.sol";
import {VaultPolicy} from "../../../src/VaultPolicy.sol";

contract WP5_KeyBounds_HL is Base {
    address internal agent = makeAddr("platformAgent");
    uint128 internal cloid = 0x1234_5678_9abc_def0_1234_5678_9abc_def0;
    uint256 internal constant NAV = 100_000e6;

    /// @dev The platform vault's policy as read on HyperEVM on 2026-10-23.
    function _platformRisk() internal pure returns (VaultPolicy.RiskConfig memory) {
        return VaultPolicy.RiskConfig({
            maxLeverageBps: 50_000,
            maxDailyLossBps: 2_000,
            maxDrawdownBps: 5_000,
            maxSlippageBps: 100,
            maxOrderNotional: 2_500_000e6,
            maxEpochDuration: 7 days,
            maxNavMoveBps: 2_000,
            maxFlattenSlippageBps: 300
        });
    }

    function setUp() public override {
        super.setUp();
        uint32[] memory assets = new uint32[](2);
        assets[0] = BTC;
        assets[1] = ETH;
        policy = VaultPolicy(Clones.clone(address(policyImpl)));
        policy.initialize(owner, _platformRisk(), assets, 2 days, address(0));
        vault = HyperVault(Clones.clone(address(vaultImpl)));
        vault.initialize(_standaloneParams(policy));
        _setCoreUser(address(vault), true);
        _setCore(address(vault), 0, 0, 0);
        _setWithdrawable(address(vault), 0);
        _setPosition(address(vault), BTC, 0);
        _setPosition(address(vault), ETH, 0);
        vm.prank(alice);
        usdc.approve(address(vault), type(uint256).max);

        _setAgent(vault, agent);
        // alice's 100k: deposited, settled, bridged to Core; the first risk check sets the day and the peak
        _deposit(alice, NAV);
        _settle();
        _claim(alice);
        vm.prank(manager);
        vault.bridgeToCore(NAV);
        _skipBridgeWindow();
        _setCore(address(vault), int64(uint64(NAV)), 0, 0);
        _setWithdrawable(address(vault), uint64(NAV));
        // start at a clock hour, early in a UTC day, so the hourly and daily windows below are exact
        vm.warp((vm.getBlockTimestamp() / 1 days + 1) * 1 days + 1 hours);
        vault.checkRisk();
        assertFalse(vault.breached());
    }

    // ------------------------------------------------------------------ helpers
    function _agentOrder(bool isBuy, uint64 limitPx, uint64 sz, bool reduceOnly) internal {
        vm.prank(agent);
        vault.placeOrder(BTC, isBuy, limitPx, sz, reduceOnly, HyperCore.TIF_IOC, cloid++);
    }

    function _rejected(string memory reason) internal {
        vm.expectRevert(abi.encodeWithSelector(IHyperVaultErrors.OrderRejected.selector, reason));
    }

    /// @dev Core equity moves to `equity`; the keeper's (permissionless) risk check reads it.
    function _equity(uint256 equity) internal {
        _setCore(address(vault), int64(uint64(equity)), 0, 0);
        _setWithdrawable(address(vault), uint64(equity));
        vault.checkRisk();
    }

    function _nextDay() internal {
        vm.warp((vm.getBlockTimestamp() / 1 days + 1) * 1 days + 1 hours);
    }

    // ------------------------------------------------------------------ WP5-HL-01: the per-day bound
    /// @notice Per order, the worst price the key can trade at is the policy band: 1 % from mark (BTC mark 100,000).
    function test_HL01_agentOrderPriceBoundedByTheOnePercentBand() public {
        _agentOrder(true, 101_000e8, 1e6, false); // exactly at the band: accepted
        _rejected("price above band");
        _agentOrder(true, 101_000e8 + 1, 1e6, false);
        _agentOrder(false, 99_000e8, 1e6, false);
        _rejected("price below band");
        _agentOrder(false, 99_000e8 - 1, 1e6, false);
        // a reduce-only order is held to the same band
        _setPosition(address(vault), BTC, 1e6);
        _rejected("price below band");
        _agentOrder(false, 99_000e8 - 1, 1e6, true);
    }

    /// @notice Per rolling 24 h, the key opens at most 20x NAV (2M on 100k), however it splits the orders.
    function test_HL01_agentOpensAtMostTwentyTimesNavPerDay() public {
        // 0.99 BTC at the 101,000 band edge = 99,990 each: 20 fit in 2,000,000
        for (uint256 i; i < 20; ++i) {
            _agentOrder(true, 101_000e8, 99_000_000, false);
        }
        (uint256 used,) = vault.agentFlow();
        assertEq(used, 20 * 99_990e6);
        assertLe(used, 20 * NAV, "within 20x NAV");
        _rejected("turnover");
        _agentOrder(true, 101_000e8, 1_000_000, false); // 1,010 more is over 2,000,000
        // a sell that adds risk spends the same budget
        _rejected("turnover");
        _agentOrder(false, 99_000e8, 1_000_000, false);
    }

    /// @notice The key's own order runs the risk check before it is sent (HL-PROXY): with the day's loss over 20 % the
    ///         order is not sent (OrderRefused) and the stop is recorded, even when no keeper has checked the vault.
    function test_HL01_agentOrderRunsTheLossCheckBeforeItIsSent() public {
        _setCore(address(vault), int64(uint64(79_990e6)), 0, 0); // -20.01 %, nobody has called checkRisk
        assertFalse(vault.breached());
        uint256 sent = writer.count();
        vm.expectEmit(address(vault));
        emit IHyperVaultEvents.OrderRefused(BTC, cloid, agent);
        _agentOrder(true, 100_000e8, 1e6, false);
        assertEq(writer.count(), sent, "nothing sent to HyperCore");
        assertTrue(vault.breached());
        assertEq(uint8(vault.breachReason()), uint8(BreachReason.DAILY_LOSS));
    }

    /// @notice Within the UTC day, a loss over 20 % of the day's starting share price makes the vault reduce only at
    ///         the next risk check: the key cannot add risk again that day. Just under 20 % it still can.
    function test_HL01_dailyLossOverTwentyPercentStopsNewRisk() public {
        _equity(80_001e6); // -19.999 %
        assertFalse(vault.breached(), "under the limit");
        _agentOrder(true, 100_000e8, 1e6, false);

        _equity(79_990e6); // -20.01 % (2,001 bps; the loss is floored to whole bps)
        assertTrue(vault.breached());
        assertEq(uint8(vault.breachReason()), uint8(BreachReason.DAILY_LOSS));
        vm.prank(agent);
        vm.expectRevert(IHyperVaultErrors.ReduceOnlyMode.selector);
        vault.placeOrder(BTC, true, 100_000e8, 1e6, false, HyperCore.TIF_IOC, cloid++);
        // later the same day: still refused
        vm.warp(vm.getBlockTimestamp() + 20 hours);
        vault.checkRisk();
        vm.prank(agent);
        vm.expectRevert(IHyperVaultErrors.ReduceOnlyMode.selector);
        vault.placeOrder(BTC, true, 100_000e8, 1e6, false, HyperCore.TIF_IOC, cloid++);
        // closing stays open
        _setPosition(address(vault), BTC, 1e6);
        _agentOrder(false, 99_500e8, 1e6, true);
    }

    // ------------------------------------------------------------------ WP5-BOTH-02: the multi-day bound
    /// @notice A daily-loss stop lifts at the next UTC day with the agent kept, so a key can lose up to 20 % a day on
    ///         consecutive days. The drawdown limit (50 % from the peak share price) is the ceiling across days: once
    ///         crossed the vault stays reduce only on every later day, and only the owner's resume() (after its
    ///         cooldown) lifts it. Four days of -19 % (no daily stop) cross it on day 4 (-56.95 % from the peak).
    function test_BOTH02_drawdownCapsLossesAcrossDaysAndDoesNotLiftAtMidnight() public {
        uint256 e = NAV;
        for (uint256 d = 1; d <= 3; ++d) {
            _nextDay();
            vault.checkRisk(); // the day starts at the previous day's close
            e = e * 81 / 100;
            _equity(e);
            assertFalse(vault.breached(), "-19 %: under the daily limit, drawdown under 50 %");
            _agentOrder(true, 100_000e8, 1e6, false);
        }
        _nextDay();
        vault.checkRisk();
        e = e * 81 / 100; // 43,046.721: -56.95 % from the peak
        _equity(e);
        assertTrue(vault.breached());
        assertEq(uint8(vault.breachReason()), uint8(BreachReason.DRAWDOWN));
        assertEq(vault.agent(), agent, "the agent is kept (a risk breach derisks, it does not revoke)");

        for (uint256 d; d < 3; ++d) {
            _nextDay();
            vault.checkRisk();
            assertTrue(vault.breached(), "a drawdown stop does not lift at 00:00 UTC");
            vm.prank(agent);
            vm.expectRevert(IHyperVaultErrors.ReduceOnlyMode.selector);
            vault.placeOrder(BTC, true, 100_000e8, 1e6, false, HyperCore.TIF_IOC, cloid++);
        }
        // nobody but the owner lifts it
        vm.prank(agent);
        vm.expectRevert();
        vault.resume();
        vm.expectRevert();
        vault.clearLeverageBreach();
    }

    /// @notice The day the daily stop lifts, the next day's loss is measured from that day's opening share price: the
    ///         second day's stop again fires just over 20 % of the new day's start (the day bound restarts).
    function test_BOTH02_dailyStopLiftsAtMidnightAndRestartsFromTheNewDayStart() public {
        _equity(79_990e6);
        assertEq(uint8(vault.breachReason()), uint8(BreachReason.DAILY_LOSS));
        _nextDay();
        vault.checkRisk();
        assertFalse(vault.breached(), "lifted at the new UTC day (current behaviour, see WP5-BOTH-02)");
        assertEq(vault.agent(), agent);
        _equity(64_000e6); // -19.99 % of 79,990
        assertFalse(vault.breached());
        _equity(63_980e6); // -20.015 % of 79,990 (2,001 bps): over
        assertTrue(vault.breached());
        assertEq(uint8(vault.breachReason()), uint8(BreachReason.DAILY_LOSS));
    }
}
