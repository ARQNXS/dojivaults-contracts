// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// WP5 (round 2 fix round, internal, AI-assisted; not an independent audit): the limits that bound what the platform
// agent key can do on a gTrade vault, asserted on the platform gTrade vault's live policy (5x, daily loss 15 %,
// drawdown 50 %, 250k per order) with a 100k NAV, mock diamond. Defensive tests: each one asserts that a limit holds at
// its edge, for findings WP5-BOTH-02 (and the Gains half of WP5-HL-01's bound) in WP5-RESULTS.md. Unlike the
// Hyperliquid vault, the loss limits here refuse new risk inline (GR2-KEY-01), before any checkRisk.
// Never block.timestamp / block.number here (via_ir rematerialisation): vm.getBlockTimestamp().

import {R1Base} from "../gains/R1Base.t.sol";
import {GainsVault} from "../../../src/gains/GainsVault.sol";
import {GainsVaultPolicy} from "../../../src/gains/GainsVaultPolicy.sol";
import {OpenParams, IGainsVaultErrors} from "../../../src/gains/GainsTypes.sol";
import {BreachReason} from "../../../src/VaultTypes.sol";

contract WP5_KeyBounds_Gains is R1Base {
    address internal agent = makeAddr("platformAgent");
    uint256 internal constant NAV = 100_000e6;
    GainsVault internal v;
    uint32 internal idx;

    /// @dev The platform gTrade vault's policy as read on Arbitrum on 2026-10-23, with a 7-day epoch so the test's
    ///      days stay inside one epoch (the live vault settles daily).
    function _platformRisk() internal pure returns (GainsVaultPolicy.RiskConfig memory) {
        return GainsVaultPolicy.RiskConfig({
            maxLeverageBps: 50_000,
            maxDailyLossBps: 1_500,
            maxDrawdownBps: 5_000,
            maxSlippageBps: 300,
            maxOrderNotional: 250_000e6,
            maxEpochDuration: 7 days,
            maxNavMoveBps: 2_000,
            maxFlattenSlippageBps: 300
        });
    }

    function setUp() public override {
        super.setUp();
        (v,) = _vaultWith(_platformRisk());
        _setAgent(v, agent);
        _depositTo(v, alice, NAV);
        _settleV(v);
        v.claim(alice);
        // 90k of the NAV in one 1x ETH long, its value pinned with the holding so NAV moves only when the test says
        idx = _open(v, ETH, true, 90_000e6, 1_000);
        _setVenueValue(v, idx, 90_000e6);
        _warp((vm.getBlockTimestamp() / 1 days + 1) * 1 days + 1 hours);
        v.checkRisk(); // the day and the peak start here
        assertFalse(v.breached());
    }

    // ------------------------------------------------------------------ helpers
    function _agentOpen() internal returns (bool ok) {
        OpenParams memory p = _params(BTC, true, 1_000e6, 1_000);
        vm.prank(agent);
        try v.openTrade(p) {
            ok = true;
        } catch (bytes memory err) {
            assertEq(bytes4(err), IGainsVaultErrors.ReduceOnlyMode.selector, "refused for the loss, nothing else");
        }
    }

    /// @dev NAV falls by `bps` of what it is now, on the venue (the idle USDC stays).
    function _lose(uint256 bps) internal {
        uint256 loss = v.totalAssets() * bps / 10_000;
        _setVenueValue(v, idx, v.venue().value - loss);
    }

    function _nextDay() internal {
        _warp((vm.getBlockTimestamp() / 1 days + 1) * 1 days + 1 hours);
    }

    // ------------------------------------------------------------------ the per-day bound
    /// @notice A loss over 15 % of the day's starting share price refuses the key's next open at once, before any
    ///         risk check runs; just under 15 % it is still accepted.
    function test_GAINS_dailyLossOverFifteenPercentRefusesNewRiskInline() public {
        _lose(1_490);
        assertTrue(_agentOpen(), "-14.9 %: accepted");
        _lose(20); // about -15.07 % from the day's start
        assertFalse(v.breached(), "no checkRisk has run");
        assertFalse(_agentOpen(), "over 15 %: refused inline");
        v.checkRisk();
        assertEq(uint8(v.breachReason()), uint8(BreachReason.DAILY_LOSS));
    }

    // ------------------------------------------------------------------ WP5-BOTH-02: the multi-day bound
    /// @notice The daily limit restarts every UTC day, so a key can take about 15 % a day on consecutive days. The
    ///         drawdown limit (50 % from the peak share price) is the ceiling across days: past it the key's opens are
    ///         refused inline on every later day, with or without a risk check, until the owner's resume().
    ///         Five days of -14 % (no daily stop) reach -52.96 % from the peak.
    function test_BOTH02_drawdownCapsLossesAcrossDaysAndDoesNotLiftAtMidnight() public {
        for (uint256 d = 1; d <= 4; ++d) {
            _nextDay();
            v.checkRisk();
            _lose(1_400);
            assertTrue(_agentOpen(), "-14 % a day, drawdown under 50 %: accepted");
        }
        _nextDay();
        v.checkRisk();
        _lose(1_400);
        assertFalse(_agentOpen(), "past 50 % from the peak: refused inline");
        v.checkRisk();
        assertEq(uint8(v.breachReason()), uint8(BreachReason.DRAWDOWN));
        assertEq(v.agent(), agent, "the agent is kept (a risk breach derisks, it does not revoke)");
        for (uint256 d; d < 3; ++d) {
            _nextDay();
            assertFalse(_agentOpen(), "a new UTC day does not lift it, before the risk check");
            v.checkRisk();
            assertTrue(v.breached(), "nor after it");
            assertFalse(_agentOpen());
        }
    }
}
