// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {GainsVault} from "../../../src/gains/GainsVault.sol";
import {IGainsDiamond} from "../../../src/gains/IGainsDiamond.sol";
import {LedgerUSDC} from "../gains/r2/ConservationMocks.sol";
import {CIWorld} from "../gains/r2/ConservationWorld.sol";
import {CIHandler, CIValuer} from "../gains/r2/ConservationHandler.sol";
import {CIChecker} from "../gains/r2/ConservationChecker.sol";
import {WP5GainsWorld} from "./WP5-INV-GainsWorld.sol";
import {WP5GainsStolenAgentHandler} from "./WP5-INV-GainsStolenAgent.sol";

/// @notice WP5 (fix round): the Gains round 2 conservation campaign (CONSERVATION.md: C1-C3, T4, F1-F3, R, N1,
///         unchanged, through CIChecker) with a stolen agent added, on the release candidate. World: CIWorld's live
///         set-up plus finite skew depth on BTC / ETH (the 1 % pair cap binds) and a third policy pair without a skew cap.
///
///  Stolen-agent properties (inv-report.md):
///   SA1 every agent action loses at most notional x (PUSH_MAX + 2 x fee rate + spread) + the minimum-position fee
///       floor + the gov fee a cancel keeps + 10 % of the collateral (liquidation) + rounding, valued at the mid;
///   SA2 agent opened notional in a UTC day <= 2 x 20 x NAV (the token bucket: full, plus one day of refill); the
///       vault's notional on BTC / ETH stays within 1 % of skew depth after every agent request; an agent close or
///       reduce outside a breach never goes through inside the 10-minute hold of its own last new-risk request or the
///       trade's 2,400-block hold;
///   SA3 (the daily form) value the depositors lose to the agent in a UTC day <= maxDailyLossBps x NAV + the sum of the
///       per-action churn bounds of that day;
///   SA4 no value to anyone else: the agent never holds USDC or shares and the vault never pays it (strayOut in C1
///       covers every other address); no agent order on a pair outside the policy or on the uncapped pair; no
///       role-gated call goes through for the agent.
contract WP5GainsStolenAgentInvariants is Test {
    WP5GainsWorld internal w5;
    CIWorld internal w;
    WP5GainsStolenAgentHandler internal h;
    CIChecker internal c;
    GainsVault internal vault;
    LedgerUSDC internal usdc;
    address internal A;
    uint256 internal constant PUSH_MAX_BPS = 300; // = the policy's maxSlippageBps (3 %)

    function setUp() public {
        w5 = new WP5GainsWorld();
        w = CIWorld(address(w5));
        h = new WP5GainsStolenAgentHandler(w, new CIValuer(), PUSH_MAX_BPS, w5.policy().config().maxDailyLossBps);
        vault = w.vault();
        usdc = w.usdc();
        A = w.AGENT();
        vault.checkRisk();
        h.seed();
        c = new CIChecker(w, CIHandler(address(h)));
        targetContract(address(h));
        targetSelector(FuzzSelector({addr: address(h), selectors: _selectors()}));
    }

    function _selectors() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](52);
        // the round 2 CI actions, unchanged
        s[0] = CIHandler.deposit.selector;
        s[1] = CIHandler.redeem.selector;
        s[2] = CIHandler.cancelDeposit.selector;
        s[3] = CIHandler.cancelRedeem.selector;
        s[4] = CIHandler.claim.selector;
        s[5] = CIHandler.donate.selector;
        s[6] = CIHandler.settle.selector;
        s[7] = CIHandler.settleKeeper.selector;
        s[8] = CIHandler.accrue.selector;
        s[9] = CIHandler.feeGov.selector;
        s[10] = CIHandler.openTrade.selector;
        s[11] = CIHandler.increaseTrade.selector;
        s[12] = CIHandler.updateLeverage.selector;
        s[13] = CIHandler.close.selector;
        s[14] = CIHandler.slTp.selector;
        s[15] = CIHandler.cancelResting.selector;
        s[16] = CIHandler.cancelTimedOut.selector;
        s[17] = CIHandler.flatten.selector;
        s[18] = CIHandler.operatorReduce.selector;
        s[19] = CIHandler.gFill.selector;
        s[20] = CIHandler.gCallbackCancel.selector;
        s[21] = CIHandler.gFillAll.selector;
        s[22] = CIHandler.gTrigger.selector;
        s[23] = CIHandler.gRetype.selector;
        s[24] = CIHandler.gRestore.selector;
        s[25] = CIHandler.gFees.selector;
        s[26] = CIHandler.gHolding.selector;
        s[27] = CIHandler.move.selector;
        s[28] = CIHandler.crash.selector;
        s[29] = CIHandler.stress.selector;
        s[30] = CIHandler.bankRun.selector;
        s[31] = CIHandler.wait.selector;
        s[32] = CIHandler.check.selector;
        s[33] = CIHandler.govern.selector;
        // the stolen agent
        s[34] = WP5GainsStolenAgentHandler.saOpen.selector;
        s[35] = WP5GainsStolenAgentHandler.saOpen.selector;
        s[36] = WP5GainsStolenAgentHandler.saOpen.selector;
        s[37] = WP5GainsStolenAgentHandler.saOpen.selector;
        s[38] = WP5GainsStolenAgentHandler.saClose.selector;
        s[39] = WP5GainsStolenAgentHandler.saClose.selector;
        s[40] = WP5GainsStolenAgentHandler.saClose.selector;
        s[41] = WP5GainsStolenAgentHandler.saIncrease.selector;
        s[42] = WP5GainsStolenAgentHandler.saLeverage.selector;
        s[43] = WP5GainsStolenAgentHandler.saSlTp.selector;
        s[44] = WP5GainsStolenAgentHandler.saCancelResting.selector;
        s[45] = WP5GainsStolenAgentHandler.saCancelTimedOut.selector;
        s[46] = WP5GainsStolenAgentHandler.saPublic.selector;
        s[47] = WP5GainsStolenAgentHandler.saSettle.selector;
        s[48] = WP5GainsStolenAgentHandler.saForbidden.selector;
        s[49] = WP5GainsStolenAgentHandler.saRebind.selector;
        s[50] = WP5GainsStolenAgentHandler.saRebind.selector;
        s[51] = WP5GainsStolenAgentHandler.saOpen.selector;
    }

    /// forge-config: default.invariant.fail-on-revert = false
    /// forge-config: default.invariant.show-metrics = true
    function invariant_conservationAndStolenAgent() public view {
        // ---- round 2 CI properties (ConservationInvariants.t.sol, unchanged)
        (bool ok, string memory why) = c.fairness();
        assertTrue(ok, why);
        (ok, why) = c.ledger();
        assertTrue(ok, why);
        (ok, why) = c.reserves();
        assertTrue(ok, why);
        (ok, why) = c.nav();
        assertTrue(ok, why);

        // ---- stolen agent
        assertEq(h.vActionOverBound(), 0, "SA1 an agent action lost more than its churn bound");
        assertEq(h.vTurnover(), 0, "SA2 agent opened notional above 2 x 20 x NAV in a UTC day");
        assertEq(h.vPairCap(), 0, "SA2 pair notional above 1 % of skew depth after an agent request");
        assertEq(h.vHold(), 0, "SA2 agent exit inside the minimum hold");
        uint256 n = h.daysCount();
        for (uint256 i; i < n; ++i) {
            uint256 d = h.dayAt(i);
            uint256 limit = (h.navMaxDay(d) * h.dailyLossBps()) / 10_000;
            assertLe(h.lossDay(d), limit + h.boundDay(d), "SA3 agent loss in a UTC day above daily loss limit + churn bound");
        }
        assertEq(usdc.balanceOf(A), 0, "SA4 agent holds USDC");
        assertEq(usdc.paidTo(A), 0, "SA4 the vault paid the agent");
        assertEq(vault.balanceOf(A), 0, "SA4 agent holds shares");
        assertEq(h.vOutsidePolicy(), 0, "SA4 agent order on a pair outside the policy");
        assertEq(h.vUncappedPair(), 0, "SA4 agent order on a pair without a skew cap");
        assertEq(h.vForbidden(), 0, "SA4 agent got a role-gated call through");
    }

    function afterInvariant() external {
        emit log_named_uint("settles", h.nSettles());
        emit log_named_uint("  exit-only", h.nSettleExitOnly());
        emit log_named_uint("claims (deliveries)", h.nClaims());
        emit log_named_uint("fee mints", h.nFeeMints());
        emit log_named_uint("SA calls", h.saCalls());
        emit log_named_uint("SA opens accepted", h.saOpens());
        emit log_named_uint("SA fills at a pushed price", h.saFills());
        emit log_named_uint("SA closes accepted", h.saCloses());
        emit log_named_uint("SA close fills", h.saCloseFills());
        emit log_named_uint("SA increases", h.saIncreases());
        emit log_named_uint("SA leverage updates", h.saLeverageUpdates());
        emit log_named_uint("SA TP/SL set", h.saSlTps());
        emit log_named_uint("SA TP/SL executed", h.saTriggers());
        emit log_named_uint("SA callback cancels", h.saCallbackCancels());
        emit log_named_uint("SA reverted", h.saReverted());
        emit log_named_uint("SA settles", h.saSettles());
        emit log_named_uint("SA public ok", h.saPublicOk());
        emit log_named_uint("SA forbidden reverted", h.saForbiddenReverted());
        emit log_named_uint("SA rebinds", h.saRebinds());
        emit log_named_uint("SA loss total (6 dec)", h.lossTotal());
        emit log_named_uint("SA max action loss (6 dec)", h.maxActionLoss());
        emit log_named_uint("SA max day loss / NAV (bps)", h.maxDayLossBps());
    }

    /// @dev Coverage: a short deterministic drive of the actor (invariant after every call); the agent must trade.
    function test_saCoverage() public {
        for (uint256 i; i < 200; ++i) {
            uint256 r = uint256(keccak256(abi.encode(i, "wp5-gsa")));
            uint256 k = r % 12;
            uint256 a = uint256(keccak256(abi.encode(r, 1)));
            uint256 b = uint256(keccak256(abi.encode(r, 2)));
            if (k < 4) {
                h.saOpen(
                    WP5GainsStolenAgentHandler.OpenIn({
                        pairSeed: a,
                        long: b % 2 == 0,
                        pct: (a >> 16) | 1,
                        lev: (b >> 16) | 1,
                        kind: a >> 32,
                        pxSeed: b >> 32,
                        slip: (a >> 48) | 1,
                        tpsl: b >> 48,
                        outcome: a >> 64,
                        push: b >> 64
                    })
                );
            } else if (k < 7) {
                h.saClose(a, b % 3 == 0, b >> 8, a >> 8, b >> 16, a >> 16, (b >> 24) | 2);
            } else if (k == 7) {
                h.saIncrease(a, b, a >> 8, b >> 8, a >> 16, b >> 16, a >> 24);
            } else if (k == 8) {
                h.saSlTp(a, b, a >> 8, b % 2 == 0);
            } else if (k == 9) {
                h.saPublic(a);
            } else if (k == 10) {
                h.saForbidden(a, b);
            } else {
                h.move(a % 2 == 0, int256(b % 801) - 400);
            }
            invariant_conservationAndStolenAgent();
        }
        emit log_named_uint("SA opens", h.saOpens());
        emit log_named_uint("SA fills", h.saFills());
        emit log_named_uint("SA closes", h.saCloses());
        emit log_named_uint("SA close fills", h.saCloseFills());
        emit log_named_uint("SA loss total (6 dec)", h.lossTotal());
        assertGt(h.saFills(), 0, "the stolen agent never got a fill");
        assertGt(h.saCloseFills(), 0, "the stolen agent never closed");
        assertGt(h.lossTotal(), 0, "the agent's actions never gave value away");
    }
}

/// @notice Replay of the shrunk sequence of smoke-gains-32x100-b (SA1): a leverage decrease on a trade past its
///         liquidation price after a crash. The mock filled it (pulling fresh collateral into a trade worth less than
///         it); Gains cancels a position update once the liquidation price is reached, and the handler now does too.
contract WP5GainsStolenAgentReplay is WP5GainsStolenAgentInvariants {
    function test_replay_SA1_smoke_b() public {
        h.saOpen(
            WP5GainsStolenAgentHandler.OpenIn({
                pairSeed: 3,
                long: false,
                pct: 89791707941981818064848584554904756452274595931397851515593682722913400018057,
                lev: 49571,
                kind: 403,
                pxSeed: 2195,
                slip: 6255,
                tpsl: 190684828,
                outcome: 132,
                push: 2483
            })
        );
        h.crash(20000);
        h.gTrigger(6165, 66667000000000000000000, true);
        h.gFillAll();
        h.saClose(600, false, 300, 32, 5592, 242, 200);
        h.settleKeeper(115792089237316195423570985008687907853269984665640564039457584007913129639933);
        h.saLeverage(100000000000000000, 16561, 15692);
        emit log_named_uint("SA max action loss (6 dec)", h.maxActionLoss());
        invariant_conservationAndStolenAgent();
    }

    /// heavy-gains-2048x500: SA1 (an agent action lost more than its churn bound)
    function test_replay_SA1_heavy() public {
        h.donate(10000000000000000000000);
        h.flatten(true, 3756888417, true);
        h.settleKeeper(10565);
        h.redeem(9694, 1000000000000);
        h.saOpen(WP5GainsStolenAgentHandler.OpenIn({pairSeed: 16020, long: true, pct: 2036432959, lev: 17246, kind: 10353, pxSeed: 15975, slip: 700, tpsl: 19677, outcome: 3000000000000, push: 160}));
        h.saOpen(WP5GainsStolenAgentHandler.OpenIn({pairSeed: 10000000000000000, long: true, pct: 40, lev: 2000, kind: 8077, pxSeed: 13020, slip: 49585, tpsl: 15564, outcome: 190684828, push: 130}));
        h.settleKeeper(94);
        h.openTrade(false, false, false, 10000000000000, 12271, 1028795546763190773216146674202552, 5592);
        h.openTrade(true, false, false, 44480498963, 741226619246757126049500389815253881728256581954142750472872, type(uint256).max, 3);
        h.stress(8);
        h.gFees(true, 200, 3977, 308431671074);
        h.gFillAll();
        h.crash(10000000000000);
        h.saLeverage(20000, 80000000000, 17438);
        emit log_named_uint("over bound after saLeverage", h.vActionOverBound());
        emit log_named_uint("max action loss", h.maxActionLoss());
        _dumpTrades();
        h.saSlTp(15472, 38878206584692966203415385907871375197469080758325516314230789535345649042548, 60000, true);
        emit log_named_uint("over bound after saSlTp", h.vActionOverBound());
        emit log_named_uint("max action loss", h.maxActionLoss());
        // harness fixes: Gains refuses the leverage update beyond the pair's max leverage / below the minimum
        // collateral (no 1-wei trade at 779x), and the bound carries the mock's per-action rounding (DUST)
        invariant_conservationAndStolenAgent();
    }

    /// Public-export forge gate (unseeded run): SA1 on a TP/SL trigger. A holding credit (3,573.6 USDC) on the ETH
    /// long, a leverage raise 3x -> 41.8x (collateral 80,000 -> 5,738), then a trigger 2.81 % against it. The mock
    /// liquidated at the plain -90 % distance (-2.15 %) and the credit was lost with the trade (9,142 USDC). gTrade
    /// carries fees and the holding balance in the liquidation price (-3.6 % here), so the trade is not liquidated.
    function test_replay_SA1_holdingCredit() public {
        h.gHolding(785622163410273768474171736761930, 4426365060);
        h.saLeverage(300000000, 3140724058, 4774);
        h.saSlTp(1316766852, 9980, 16234, true);
        emit log_named_uint("SA max action loss (6 dec)", h.maxActionLoss());
        // harness fix: the mock's liquidation price carries the trade's fees and holding balance (gTrade v10)
        invariant_conservationAndStolenAgent();
    }

    /// heavy-gains-2048x500, seed 0xdeadbeef: SA1. A BTC short market open at 29.25x (collateral 7,610) filled 2.99 %
    /// below the mid: back at the mid that is 3.08 % of the open price, -90.15 %, liquidated, the whole collateral lost.
    /// The bound counted the push against the mid (13 USDC short); it now counts p / (1 - p), the move against the fill.
    function test_replay_SA1_shortPush() public {
        h.saOpen(
            WP5GainsStolenAgentHandler.OpenIn({
                pairSeed: 155026784580528078354952499341246779164107981395,
                long: false,
                pct: 5504695994954652147892443118443470085284488375163387411617738,
                lev: 8348827927559509787670559649549558752131986238,
                kind: 3084226178617292997035893664090719178543631727851351602,
                pxSeed: 36220236226625547037838731962070820149208335666129296831934280891676,
                slip: 115792089237316195423570985008687907853269984665640564039457584007913129639935,
                tpsl: 137325626233679497580808532,
                outcome: 2367776428855553326015312184487861596752439816883726422693444654577336830,
                push: 115792089237316195423570985008687907853269984665640564039457584007913129639934
            })
        );
        emit log_named_uint("SA max action loss (6 dec)", h.maxActionLoss());
        invariant_conservationAndStolenAgent();
    }

    function _dumpTrades() internal {
        IGainsDiamond.Trade[] memory t = w.diamond().getTrades(address(vault));
        for (uint256 i; i < t.length; ++i) {
            emit log_named_uint("trade index", t[i].index);
            emit log_named_uint("  pair", t[i].pairIndex);
            emit log_named_uint("  long", t[i].long ? 1 : 0);
            emit log_named_uint("  type", t[i].tradeType);
            emit log_named_uint("  coll", t[i].collateralAmount);
            emit log_named_uint("  lev", t[i].leverage);
            emit log_named_uint("  openPrice", t[i].openPrice);
            emit log_named_uint("  sl", t[i].sl);
            emit log_named_uint("  tp", t[i].tp);
            emit log_named_uint("  closeValue mid", w.diamond().closeValue(address(vault), t[i].index, t[i].pairIndex == 0 ? h.btcPx() : h.ethPx()));
        }
        emit log_named_uint("btcPx", h.btcPx());
        emit log_named_uint("ethPx", h.ethPx());
    }
}
