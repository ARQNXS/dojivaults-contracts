# Gains round 1: async order lifecycle (3.2) and exits / liveness (3.3)

Internal review (sub-reviewer), not an independent audit. Source: contracts/src/gains/* at audit/gains-r1. Evidence:
fork tests on the real gTrade v10 diamond (Arbitrum One block 515,219,884, oracle answers emulated by pranking the
diamond's Chainlink nodes; harness test/audit/gains/lifecycle/LifecycleForkBase.sol). Run:
`forge test --match-path 'test/audit/gains/lifecycle/*'` with ARBITRUM_RPC_URL set. 52 tests. Gas: GAS.md.

| ID | Title | Verdict | Severity (proposed) | Test |
|---|---|---|---|---|
| LC-01 | Pending leverage-only increase adds 0 notional: several increases bypass maxLeverageBps (7.88x under a 3x policy) | CONFIRMED (fork) | Medium | LC_PendingFork::test_lc_LC01_leverageOnlyIncreasesBypassVaultLeverage (+ `_control_`) |
| LC-02 | Close / reduce decoys keep the emergency settle blocked; manager, owner, operator, sentinel can all do it | CONFIRMED (fork) | Medium | LC_GriefFork::test_lc_LC02_* (4) |
| LC-03 | Anyone blocks setSlTp (incl. the sentinel's breach SL tightening) and cancelOrder for 1 LINK per 20-block trigger window | CONFIRMED | Low | LC_GriefFork::test_lc_LC03_* (3) |
| LC-04 | flatten has one expectedPrice for longs and shorts: a hot role in a breach can make one side always fail (a gov fee per trade) | CONFIRMED | Low | LC_LivenessFork::test_lc_flattenExpectedPrice_guaranteedFailureCostsGovFees |
| LC-05 | flatten returns remaining = 0 while trades sit behind a timed-out close or a decoy | CONFIRMED | Info | LC_LifecycleFork::test_lc_timedOutClose_blocksNewCloseAndFlattenReportsZeroRemaining |
| LC-06 | Venue liveness: Gains PAUSED / CLOSE_ONLY, a pair no longer served, USDC blacklist (trust T2 / T5) | CONFIRMED | Info / Design | LC_LivenessFork::test_lc_gainsPaused_*, test_lc_gainsCloseOnly_whatStillWorks, test_lc_pairNoLongerServed_*, test_lc_usdcBlacklistsVault_whatStillWorks |
| LC-07 | GainsNav prices pending partial-open / leverage gov fees on pair 0 (Gains leaves pairIndex 0) | equal fees today | Info | LC_PendingFork::test_lc_updateLeverageDecrease_solFeeOnPairZero |
| Q-1 | Limit / stop / TP / SL far from market as a value transfer to Gains LPs | REFUTED | n/a | LC_LimitStopFork (7) |

## LC-01
GainsNav.sol:68-70 adds `positionSize(o.trade.collateralAmount, o.trade.leverage)` for a pending MARKET_PARTIAL_OPEN.
Gains stores a leverage-only increase as collateralAmount 0, leverage = leverageDelta (fork-verified,
test_lc_increaseLeverageOnly_pendingNotionalIsZero), so it counts 0 while pending although the fill adds
trade.collateral x leverageDelta. Every later check (increaseTrade GainsVaultLogic.sol:489/506, openTrade 436/454,
leverage raise 534/548) sees the stale notional. One increase per trade (Gains refuses a second market order on a
trade). PoC: NAV 9,984, 3x policy, 3 trades of 1,000 at 2x (notional 6,000); three +23.7x leverage-only increases in
one block all pass checkOrder; after the fills vault leverage 78,834 bps vs 30,000. A 10% adverse move then costs ~79%
of NAV instead of the 30% the policy allows; the N5 NAV error bound is exceeded by the same factor. Reachable leverage
≈ n_trades x max (up to MAX_POSITIONS 20), bounded per increase by maxOrderNotional and the pair maximum.
Fix: for a partial open with collateralAmount == 0 add positionSize(getTrade(idx).collateralAmount, o.trade.leverage).

## LC-02
GainsVaultLogic.sol:230 (OrdersPending), GainsVaultMath.sol:133-135, _mayExit 707-711. A decoy closeTrade(idx, 2 x C)
on a long costs 1,406,722 gas (~2.8e-5 ETH at 0.02 gwei); Gains cancels it SLIPPAGE and books its min gov fee 0.042505
USDC on the vault's trade. Two decoys staggered by 2 blocks kept an order in flight through 6 consecutive answers;
settle reverted for guardian, sentinel and operator each time; guardian flatten returned (0, 0). Strangers cannot
create vault pending orders (all request paths Unauthorized; bot triggers filed under the bot). The guardian wins only
by landing a close in the gap after an answer; once every trade is closed no decoy is possible in emergency
(test_lc_LC02_guardianWinsTheRace_thenSettle). An Arbitrum Timeboost express-lane holder wins every race; a cold Safe
guardian cannot race. Fix: block settle only on pending orders that hold collateral (MARKET_OPEN, MARKET_PARTIAL_OPEN
with collateral, UPDATE_LEVERAGE decrease); pending closes / partial closes / leverage increases hold nothing and the
trade is valued as open (continuous to 1 wei at the valuation price). At minimum for exit-only settles.

## LC-03
setSlTp (GainsVaultLogic.sol:591-605) and cancelOrder (608-612) have no fallback. Anyone pays 1 LINK to file an SL / TP
/ LIMIT_OPEN / STOP_OPEN trigger on the vault's trade (no price check at request); until the oracle answers NOT_HIT
(<= 20 blocks, triggerTimeoutBlocks) Gains reverts PendingTrigger on the sentinel's SL tightening, resting-order
cancels and flatten's limit cancel (counted as sent, so the limit survives the flatten). Closes, reduces and settle are
not affected. Fix: retry after PendingTrigger; prefer close / flatten over SL tightening in a breach; do not count a
refused cancel against maxTrades.

## LC-04
GainsVaultLogic.sol:681; Gains' close slippage check is one-sided. 10 longs + 10 shorts on ETH, sentinel flattens in a
breach at expectedPrice C/2: all longs execute at C (no effective bound), all shorts are cancelled (0.042505 USDC gov
fee each) and stay open; settle blocked while they are in flight. No bad fill can be forced (fills are at the oracle
price). Fix: separate expected prices per side, or a sanity floor against the trade's own open price.

## LC-05
GainsVaultLogic.sol:666-670: a trade whose close timed out (Gains keeps the pending flag; a new close reverts
ConflictingPendingOrder) or sits behind a decoy is skipped and not counted in `remaining`. Fix: return the in-flight
count, or sweep timeouts before flattening.

## LC-06 (trust T2 / T5)
Trading state set through diamond storage slot 301 byte 0. CLOSE_ONLY: close, reduce, flatten, cancelOrder,
cancelTimedOut, requestRedeem, claim work; openTrade, setSlTp (the sentinel's SL tightening) and the margin-adding
leverage decrease are refused; a pending open cannot fill (callback reverts) and waits for cancelTimedOut. PAUSED:
every exit reverts including cancelTimedOut; flatten reverts as a whole (closeTradeMarket not try/caught); settle runs
only if nothing is pending. Pair no longer served: closes time out and are cancelled, value locked; a normal settle
reverts InsufficientLiquidity; the emergency settle pays pro rata from idle (5,001 of ~10,000 USDC), the rest returned
as shares. USDC blacklists the vault: close fills fail; cancelTimedOut of a pending OPEN reverts (refund transfer), so
settle is permanently OrdersPending while that open exists. The LC-02 fix also lets settle run through a Gains pause
when only closes are in flight.

## LC-07
GainsNav.sol:76 uses o.trade.pairIndex (0 for partial and leverage orders). Same min gov fee on every pair today
(SOL leverage decrease: reserved 0.042505 = realized 0.042505). Fix: use getTrade(idx).pairIndex.

## Q-1 (refuted)
LIMIT long at 2 x C executes at C (+3.1 bps); LIMIT short at C/2 at C (−1.3 bps); STOP long at C/2 and STOP short at
2 x C are cancelled SLIPPAGE (collateral intact); LIMIT long at C + 4 bps (inside the ±5 bps oracle range) executes
exactly at the trigger; a long TP at 0.9 x C executes as a market close at C; a long SL at 1.1 x C is cancelled
SLIPPAGE. Executions are at the oracle's price or a price the lookback range touched: no transfer to Gains LPs.

## Checked and sound
- Pending-order field semantics on the real diamond (LC_PendingFork test_lc_partialClose*, test_lc_updateLeverage*,
  test_lc_increaseWithCollateral*): MARKET_PARTIAL_CLOSE collateral reduce = (delta, leverage 0, pairIndex 0), the
  field GainsVaultMath.sol:156 relies on; leverage reduce = (0, delta); UPDATE_LEVERAGE = (delta, new absolute
  leverage); MARKET_PARTIAL_OPEN with collateral counted while pending.
- NAV continuity request → pending → fill at the valuation price: closes / reduces unchanged; opens, increases,
  leverage decreases −0.042505 USDC (the min gov fee); fills exact or ±1 wei; approvals back to 0 after every request.
- Timeouts and cancels (LC_LifecycleFork): fill after timeout before cancel opens the trade and the later cancel
  reverts; double cancel, cancel of a filled order, late answer after a cancel: revert or no-op, no USDC moved.
- Gains acting while a vault order is pending: SL executes during a pending reduce (paid to the vault, the reduce later
  fills NO_TRADE, no fee); liquidation during a pending leverage decrease refunds the 100 USDC margin in full (GainsNav
  counts 99.957 meanwhile); liquidation during a pending increase: full refund.
- Trade indexes are counters, never reused; a pending MARKET_OPEN (trade.index 0) never shields trade 0 from flatten.
- No payout can arrive inside settle (it calls only views).
- X1 static (call graph by line) and dynamic (`vm.expectCall(policy, price/navPrice/checkOrder, 0)`,
  test_lc_exitsNeverCallPolicyPrices) and under a full outage (test_lc_exitsWorkWithEveryPriceSourceDown).
- X2: MAX_POSITIONS never blocks an exit (22 items, test_lc_maxPositionsNeverBlocksExits). X3: GAS.md.

## Open questions
1. Is the sentinel expected to win flatten races against a Timeboost express-lane holder (how long LC-02 lasts unfixed)?
2. How does Gains delist a pair; can governance make closeTradeMarket revert per pair (exit-less trades)?
3. triggerTimeoutBlocks (20) is a Gains parameter; LC-03's window scales with it.
