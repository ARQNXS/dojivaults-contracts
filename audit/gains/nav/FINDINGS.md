# Gains round 1, domain 3.1 (NAV and share pricing): findings

Internal review (sub-reviewer 3.1), not an independent audit. Code at 5dd1344. Tests in `contracts/test/audit/gains/nav/`
(unit on the mock harness; fork on Arbitrum One against the real gTrade v10 diamond with the oracle emulation). 32 tests.
Differential results: DIFF-RESULTS.md (inputs in data/, tool in diff/).

| Id | Title | Verdict | Severity (proposed) | Test |
|---|---|---|---|---|
| NAV-01 | Near-liquidation zero rule counts the band twice: a trader zeroes a trade's NAV at the open (200x), ~2x the NAVBIAS transfer, deterministic | CONFIRMED | Medium | NavEconForkTest.test_NAVCLIFF_fork_highLeverageTradeValuedZeroButPays, test_NAVCLIFF_fork_confederateExtractsFromHolders (control test_NAVCLIFF_fork_controlSameNotionalAt6x) |
| NAV-02 | Lead's NAVBIAS re-checked on the fork with real Gains fees; it also takes from every honest redemption while trades are open | CONFIRMED | Medium (lead's id) | NavEconForkTest.test_NAVBIAS_fork_realFees_3x, _10x |
| NAV-03 | Feed decimals cached at curation: a proxy moving to fewer decimals misprices 10^k with no revert | CONFIRMED | Low | NavUnitTest.test_NAVDEC_decimalsChangeMispricesWithoutRevert |
| NAV-04 | SOL maxAge 88,200 s trusts a halted feed for a day; normal settles price at the frozen NAV | CONFIRMED | Low | NavUnitTest.test_HALTEDFEED_solFrozenForADayStillSettles |
| NAV-05 | Anyone executes setPairFeed: the executor picks when a NAV step of Δband x notional happens | CONFIRMED | Low | NavUnitTest.test_NAVROTATION_bandCutStepsNavAtAnExecutorChosenMoment |
| NAV-06 | Requests and cancels are free until the settle tx: a free option on Chainlink lag | CONFIRMED | Low | NavUnitTest.test_CANCELOPTION_freeCancelUntilSettle |
| NAV-07 | Pending partial opens / leverage updates valued with pair 0's gov fee | CONFIRMED, no impact at current params | Info | NavEconForkTest.test_GOVFEEPAIR_fork_pendingSolIncreaseUsesPair0Fee |
| NAV-08 | Opening cost plus the band is booked as a daily loss at once | CONFIRMED | Info | NavEconForkTest.test_DAILYLOSS_fork_navDropAtOpenPerNotional |
| NAV-09 | Management fee rounds to 0 under per-second accrueFees calls on small vaults | CONFIRMED | Info | NavUnitTest.test_fees_managementFeeDustUnderPerSecondAccrual |
| NAV-10 | priceAfterImpact truncates to uint64 | REFUTED as an exploit | Info | NavUnitTest.test_priceAfterImpactTruncation_unreachableForInflation |
| NAV-11 | tradeValuePure panics on absurd inputs | CONFIRMED, liveness only | Info | NavUnitTest.test_valueMath_absurdInputsPanicNotMisvalue |
| OQ-1 | Chainlink vs Gains oracle gap in fast markets (T3 rests on 19 calm fills) | OPEN QUESTION | | |
| OQ-2 | Whether the vault earns a Gains fee tier | OPEN QUESTION | | |

**Differential NAV (task 1):** TypeScript implementation from @gainsnetwork/sdk pieces and the verified facet source vs
GainsNav: max divergence 0.005 bp (1e-6 USDC rounding) over 79 valuations (49 random fork trades over 3 seeds, a SOL
protection-factor case, 30 rows from real mainnet closes). By pair max BTC 0.0050 / ETH 0.0016 / SOL 0.0008 bp; by
leverage 2-10x 0.0050 / 10-50x 0.0013 / 50-150x 0.0024 bp. TS vs the USDC Gains paid on every market close <= 0.0024 bp.
No divergence above 1 bp. (The SDK's own close-impact pass decision uses pnl > 0 without fees / skew, unlike the v10
contract; the TS follows the contract.)

## NAV-01 (Medium)
GainsNav.sol:88, :120. Zero when the long's P x 1e4 <= L x (1e4 + B) with P already C(1 − B): the band counts twice, a
trade is zeroed whenever C is within ~2B of liquidation, true at the open at Gains' max leverage (200x BTC/ETH, 150x SOL).
The policy has no per-trade leverage cap. Fork: ETH 200x long, 1,350 USDC collateral (270k notional, 2.7x vault leverage)
has venue().value == 0 right after the fill; closing at C pays 1,134.0 USDC (84% of collateral): an understatement of
42 bps of notional vs B = 20 bps (SPEC N5 bound 2B = 40 bps). The random differential found a SOL 131x trade valued 0
that paid 98.03 of 195.22. Exploit (fork): alice deposits 100k; manager opens the 200x trade; a non-insider confederate
deposits 1M, keeper settles (NAV −1.35%: passes maxNavMoveBps and daily loss); manager closes at C; all redeem: bob
+1,027.4 USDC, alice −1,248.1 USDC (control, same 270k notional at 6x: bob +488.9, alice −709.6). Repeatable every two
settles; per cycle bounded by maxLeverage x NAV / Lmax and the daily-loss limit (~9x vault leverage of 200x trades
trips 5%). Fix: zero only when P itself is past L (P already includes the band); optionally cap per-trade leverage
(e.g. 0.9 / (4B) = 112x at B = 20 bps).

## NAV-02 (Medium, lead's NAVBIAS)
GainsNav.sol:59 adverse edge used for both deposits and redemptions in settle. Fork, open and close at the same C, 2%
management and 20% performance fees:

| Vault leverage | Trade | bob (100k in while open, out after) | alice (holder) |
|---|---|---|---|
| 2.7x | ETH 45k x 6 | +270.8 (+27 bps) | −489.4 (−49 bps) |
| 9x | ETH 90k x 10 | +911.2 (+91 bps) | −1,641.1 (−164 bps) |

NAV drop at open 27 bps of notional (20 band + 7 fees); at 9x the bias is 1,790 of the 2,520 USDC drop, the rest real
fees. The same bias takes ~1.79% at 9x from every honest redemption while trades are open (remaining holders keep it).
Fix: two prices: deposits mint at the favourable edge (or C), redemptions pay at the adverse edge.

## NAV-03 (Low)
GainsVaultFactory.sol:447 caches decimals; GainsPrice.sol:57-63 scales by it. 8 → 6 decimals reads 100x low with no
revert: a 3x short vault's NAV 99,940 → 129,699; NavMoved blocks the first settle but checkRisk walks the checkpoint up
(3 calls over 3 hours), then alice redeemed 10% of her shares for 12,375.9 USDC against ~9,994 fair (+24%). 8 → 18 fails
closed (test_NAVDEC_decimalsIncreaseFailsClosed). Very low likelihood (phase 2, 8 decimals today). Fix: read decimals()
on every read and revert PriceStale on a change.

## NAV-04 (Low, trust T4)
DeployGains.s.sol:31, GainsPrice.sol:53. A frozen feed keeps NAV at the checkpoint, so NavMoved never fires; a settle
23 h later paid a redeemer of half the shares 49,684.9 USDC against 37,500 fair after a −10% move on a 5x SOL trade.
BTC/ETH have the same exposure for 44 minutes. Fix: settles and deposits require a fresh round (<= 1-2 h); exits
unaffected.

## NAV-05 (Low)
GainsVaultGovernance.sol:345, GainsVault.sol:399, GainsVaultPolicy.sol:361. A queued band cut steps NAV by Δband x
notional when anyone chooses to execute it: 15 bps x 300k = 450 USDC; bob, settled 100k just before, took 225.7 USDC.
Bounded by the leverage x 8 x B bound. Fix: restrict the executor or apply the rotation inside settle after flows.

## NAV-06 (Low)
GainsVaultLogic.sol:52, :106, :123 (no cutoff, no fee). With 5 bps of Chainlink lag at 3x, bob's 100k gained +75.1 USDC
once Chainlink caught up; otherwise the cancel returned every wei. Bounded by the deviation threshold (5 bps BTC/ETH,
10 bps SOL) x vault leverage. The same freedom times NAV-02 releases and NAV-05 steps. Fix: a request / cancel cutoff
before settle, or a cancel fee.

## NAV-07 (Info)
GainsNav.sol:76 uses o.trade.pairIndex (0 on MARKET_PARTIAL_OPEN / UPDATE_LEVERAGE). minGovFee is 42,505 for pairs 0,
1 and 33 today. Fix: getTrade(this, o.trade.index).pairIndex. A pending close / partial close / leverage increase that
the callback cancels also costs 0.0425 USDC, not reserved (settle is blocked while pending, no pricing effect).

## NAV-08 (Info)
NAV drop at the open in bps of notional: BTC 27, ETH 27, SOL 35. 3x vault leverage books 91 bps of daily loss at once;
at the 10x bound 2.7-3.5% of the 5% default. 200x trades lose their whole collateral in NAV (NAV-01), ~9x of them trips
the daily-loss breach.

## NAV-09 (Info)
GainsVaultLogic.sol:353 rounds down and accrueFees is public: on a 500 USDC vault at 2%, 600 per-second calls minted
nothing; one call over the same 10 minutes mints the fee. Erased whenever assets x bps < 3.15e11 (vaults below 1,577
USDC at 2%).

## NAV-10 (refuted as an exploit)
GainsNav.sol:192 cast wraps only once P >= 2^64 / (1 + impact); a short is then already in the near-liquidation band
(value 0) and a long's close impact is negative (wrap gives 0). Fix with ADVERSETRUNC (cap the price in read / SafeCast).

## NAV-11 (Info)
Overflow only on absurd inputs (6e-10 USD open price with a 1.8e9 USD answer and 1.8e20 USDC collateral). Safe for open
price >= 0.01 USD, any uint64 valuation price, any leverage, collateral <= 1e9 USDC (fuzz). A revert, never a wrong value.

## Checked and sound
- Per-trade value matches independent implementations (spread, v10 skew, two-pass cumulative impact incl. SOL's 20x
  protection factor, pnl floor, untiered min-basis closing fee, holding fees at P, realized pnl, liquidation input):
  TS vs GainsNav <= 0.005 bp; TS vs payout <= 0.0024 bp (NavDiffFork / NavReplayFork + diff.ts). Liquidation price
  <= 0.0019 bp, skew <= 1e-10 %, realized pnl exact; funding sign over 21 received-funding rows. GainsNav never above
  the payout on any exact row.
- Pending order fields on the real diamond (NavPendingForkTest, 3 tests) and NAV continuity across a leverage decrease
  (only the 0.0426 gov fee).
- GainsPrice.read named errors (stale incl. maxAge boundary, zero, negative, future, updatedAt 0, reverting, short
  returndata, no code, no feed), answeredInRound ignored (fine for OCR2; updatedAt guards), huge answers bounded, no
  panic; sequencer down / grace (<=) / startedAt 0 / future / reverting / malformed all SequencerDown.
- Donation / first-depositor inflation unprofitable (1e6 virtual shares: victim lost 0.0099 USDC on 10k; attacker's
  share unit recovers 1 USDC of a 1M donation) — test_inflation_donationAttackUnprofitable.
- Rounding: deposit → redeem round trip never returns more (testFuzz_roundTripNeverProfits, 512 runs); conversions
  round toward the vault (testFuzz_conversionRoundingFavoursTheVault).
- Breach settles: management fee only, no performance fee, HWM frozen (test_fees_breachSettleChargesNoPerformanceAndKeepsHwm).
- By inspection: notional positionSizeToken x mid cannot overflow; GainsNav reads only address(this).
