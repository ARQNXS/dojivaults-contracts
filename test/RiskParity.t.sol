// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Base} from "./Base.t.sol";
import {BreachReason} from "../src/VaultTypes.sol";

/// @notice Parity fixtures for the executor's off-chain checkRisk (server/src/risk/contractRisk.ts). Each scenario
///         builds a vault state, records what the keeper reads (the vault's storage and the HyperCore values), runs
///         the real checkRisk() and records what it computed and stored. test/fixtures/risk-parity.json holds the
///         result: this test fails when the contract no longer produces it, server/test/risk-parity.test.ts fails
///         when the mirror no longer does. Regenerate after an intended contract change:
///         RISK_PARITY_WRITE=true forge test --match-contract RiskParity
contract RiskParityTest is Base {
    string internal constant PATH = "test/fixtures/risk-parity.json";
    uint256 internal constant SCENARIOS = 23;

    bool internal writing;
    string internal committed;

    // HyperCore values of the scenario's final state
    int64 internal av;
    uint64 internal ntl;
    uint64 internal spot;

    function _core(int64 accountValue, uint64 ntlPos, uint64 spotUsdc) internal {
        av = accountValue;
        ntl = ntlPos;
        spot = spotUsdc;
        _setCore(address(vault), accountValue, ntlPos, spotUsdc);
    }

    /// @dev alice deposits, the epoch settles, everything goes to Core and lands; the day reference is set.
    function _fund(uint256 amount) internal {
        _deposit(alice, amount);
        _settle();
        _claim(alice);
        vm.prank(manager);
        vault.bridgeToCore(amount);
        _core(int64(uint64(amount)), 0, 0);
        vault.syncBridge();
        _skipBridgeWindow();
        vault.checkRisk();
    }

    function _nextDay() internal {
        vm.warp((vm.getBlockTimestamp() / 1 days + 1) * 1 days + 1);
        vm.roll(vm.getBlockNumber() + 1);
    }

    function _later() internal {
        vm.warp(vm.getBlockTimestamp() + 2 hours);
        vm.roll(vm.getBlockNumber() + 1);
    }

    /// @dev Builds scenario `i` and returns its name; the final HyperCore values are in av / ntl / spot.
    function _scenario(uint256 i) internal returns (string memory) {
        av = 0;
        ntl = 0;
        spot = 0;
        if (i == 0) {
            _fund(100_000e6);
            _later();
            return "calm";
        }
        if (i == 1) {
            _fund(100_000e6);
            _core(95_050e6, 0, 0);
            return "daily_loss_under_limit";
        }
        if (i == 2) {
            _fund(100_000e6);
            _core(95_000e6, 0, 0);
            return "daily_loss_at_limit";
        }
        if (i == 3) {
            _fund(100_000e6);
            _core(94_900e6, 0, 0);
            return "daily_loss_over_limit";
        }
        if (i == 4) {
            _fund(100_000e6);
            _core(100_000e6, 285_000e6, 0);
            return "leverage_in_margin";
        }
        if (i == 5) {
            _fund(100_000e6);
            _core(100_000e6, 301_000e6, 0);
            return "leverage_over_limit";
        }
        if (i == 6) {
            _fund(100_000e6);
            _core(-5e6, 1_000e6, 0);
            return "leverage_no_account_value";
        }
        if (i == 7) {
            _fund(100_000e6);
            _nextDay();
            _core(84_000e6, 0, 0);
            return "drawdown_over_limit_next_day";
        }
        if (i == 8) {
            _fund(100_000e6);
            _nextDay();
            _core(85_100e6, 0, 0);
            return "drawdown_in_margin_next_day";
        }
        if (i == 9) {
            _fund(100_000e6);
            _later();
            _core(103_000e6, 0, 0);
            return "new_high";
        }
        if (i == 10) {
            // the day's first check comes after the loss: it becomes the baseline (why the keeper writes one early)
            _fund(100_000e6);
            _nextDay();
            _core(93_000e6, 0, 0);
            return "stale_day_loss_rolls_into_baseline";
        }
        if (i == 11) {
            // no shares: only leverage counts
            _core(500e6, 2_000e6, 0);
            return "no_shares_leverage";
        }
        if (i == 12) {
            _fund(100_000e6);
            _core(99_000e6, 300_100e6, 0);
            vault.checkRisk(); // leverage breach
            _core(94_000e6, 0, 0);
            return "escalate_leverage_to_daily_loss";
        }
        if (i == 13) {
            _fund(100_000e6);
            _core(94_000e6, 0, 0);
            vault.checkRisk(); // daily loss breach
            _nextDay();
            return "daily_breach_cleared_next_day";
        }
        if (i == 14) {
            _fund(100_000e6);
            _core(500_000, 0, 0); // 0.5 USDC left
            return "dust_nav_ignored";
        }
        if (i == 15) {
            _fund(100_000e6);
            vm.prank(guardian);
            vault.triggerBreach();
            _core(80_000e6, 0, 0);
            return "guardian_stop_untouched";
        }
        if (i == 16) {
            _fund(100_000e6);
            _later();
            _core(110_000e6, 0, 0);
            vault.checkRisk(); // peak raised
            _core(99_000e6, 0, 0);
            return "peak_then_drop_same_day";
        }
        if (i == 17) {
            _fund(100_000e6);
            _core(90_000e6, 0, 4_970e6);
            return "spot_usdc_counts";
        }
        if (i == 18) {
            // 300_001 / 100_000 floors to exactly the limit: not over
            _fund(100_000e6);
            _core(100_000e6, 300_001e6, 0);
            return "leverage_at_limit_floored";
        }
        if (i >= 19 && i <= 22) {
            // Flat at 00:00 UTC (yesterday closed 2% down), first open of the day at 10:00. The keeper sends the
            // day's first check right before that open (reason first-fill), so the baseline is the pre-trade price.
            _fund(100_000e6);
            _core(98_000e6, 0, 0);
            vault.checkRisk();
            _nextDay();
            vm.warp(vm.getBlockTimestamp() + 10 hours);
            vm.roll(vm.getBlockNumber() + 1);
            if (i == 19) return "flat_before_first_open_10utc"; // the pre-trade check itself
            if (i != 22) vault.checkRisk(); // pre-trade: stores the day's baseline
            _core(98_000e6, 196_000e6, 0); // the open
            vm.roll(vm.getBlockNumber() + 1);
            if (i == 20) {
                _core(94_080e6, 196_000e6, 0); // 4% down from the pre-trade price
                return "flat_open_10utc_loss_4pct";
            }
            if (i == 21) {
                _core(93_002e6, 196_000e6, 0); // 5.1% down: over the 5% daily limit
                return "flat_open_10utc_loss_over_limit";
            }
            // without the pre-trade check the day's first check lands after the loss: it is the baseline, 0 counted
            _core(94_080e6, 196_000e6, 0);
            return "flat_open_10utc_no_check_before";
        }
        revert("no scenario");
    }

    function _rec(string memory name, string memory field, uint256 value) internal {
        _recStr(name, field, vm.toString(value));
    }

    function _recInt(string memory name, string memory field, int256 value) internal {
        _recStr(name, field, vm.toString(value));
    }

    function _recStr(string memory name, string memory field, string memory value) internal {
        if (writing) {
            vm.serializeString(name, field, value);
        } else {
            assertEq(value, vm.parseJsonString(committed, string.concat(".", name, ".", field)), string.concat(name, ".", field));
        }
    }

    function test_riskParityFixtures() public {
        writing = vm.envOr("RISK_PARITY_WRITE", false);
        if (!writing) committed = vm.readFile(PATH);
        (uint256 maxLev, uint256 maxDaily, uint256 maxDd) = policy.riskLimits();
        // in memory: revertToState also rolls back this contract's storage
        string memory root;

        for (uint256 i; i < SCENARIOS; ++i) {
            uint256 snap = vm.snapshotState();
            string memory name = _scenario(i);

            // what the keeper reads before deciding
            _recStr(name, "gen", "r4");
            _rec(name, "now", vm.getBlockTimestamp());
            _rec(name, "idle", vault.idleAssets());
            _rec(name, "coreEquityView", vault.coreEquity());
            _recInt(name, "accountValue", av);
            _rec(name, "ntlPos", ntl);
            _rec(name, "spotUsdc", spot);
            _rec(name, "totalSupply", vault.totalSupply());
            _rec(name, "riskDay", vault.riskDay());
            _rec(name, "dayStartSharePrice", vault.dayStartSharePrice());
            _rec(name, "peakSharePrice", vault.peakSharePrice());
            _rec(name, "breached", vault.breached() ? 1 : 0);
            _rec(name, "breachReason", uint8(vault.breachReason()));
            _rec(name, "emergency", vault.emergency() ? 1 : 0);
            _rec(name, "maxLeverageBps", maxLev);
            _rec(name, "maxDailyLossBps", maxDaily);
            _rec(name, "maxDrawdownBps", maxDd);

            // what the contract computes and stores
            vm.prank(stranger);
            (uint256 lev, uint256 daily, uint256 dd) = vault.checkRisk();
            _rec(name, "out_leverageBps", lev);
            _rec(name, "out_dailyLossBps", daily);
            _rec(name, "out_drawdownBps", dd);
            _rec(name, "out_riskDay", vault.riskDay());
            _rec(name, "out_dayStartSharePrice", vault.dayStartSharePrice());
            _rec(name, "out_peakSharePrice", vault.peakSharePrice());
            _rec(name, "out_breached", vault.breached() ? 1 : 0);
            string memory last;
            if (writing) last = vm.serializeString(name, "out_breachReason", vm.toString(uint8(vault.breachReason())));
            else _rec(name, "out_breachReason", uint8(vault.breachReason()));
            if (writing) root = vm.serializeString("root", name, last);

            vm.revertToState(snap);
        }
        if (writing) vm.writeJson(root, PATH);
    }

    /// @dev The fixture file covers both sides of every limit (a parity that never breaches proves nothing).
    function test_riskParityCoversBreaches() public {
        string memory json = vm.readFile(PATH);
        uint256 breaches;
        uint256 quiet;
        for (uint256 i; i < SCENARIOS; ++i) {
            uint256 snap = vm.snapshotState();
            string memory name = _scenario(i);
            vm.revertToState(snap);
            uint256 before = vm.parseUint(vm.parseJsonString(json, string.concat(".", name, ".breachReason")));
            uint256 afterR = vm.parseUint(vm.parseJsonString(json, string.concat(".", name, ".out_breachReason")));
            if (afterR > before) breaches++;
            else quiet++;
        }
        assertGe(breaches, 5, "breach fixtures");
        assertGe(quiet, 5, "no breach fixtures");
        assertEq(uint8(BreachReason.DRAWDOWN), 3);
    }
}
