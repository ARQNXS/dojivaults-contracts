# WP5 uncross review: WP3's three follow-ups and WP2's three judged test ports

Release candidate `fix/r2-release` at 3d75366. Worktree `dv-r2rel-uncross`, branch `wp5/uncross`. The review itself
was read-only on `server/src` and `contracts/src`; the fixes in section "Fixes" below were made afterwards on the
coordinator's instruction. Internal review, not an independent audit.

## Fixes (on `wp5/uncross`, one commit per fix)

| Finding | Commit | What changed | Tests |
|---|---|---|---|
| P1 (Medium) | dbae328 | `nonceDead` reads the mined count, the head, the receipt and the OrderSent logs on **one RPC URL** (`RpcGateway.pinned` / `VaultChain.pinnedReads`: the first read's round-robin pick, no fail over). The order is "dead" only when the receipt is still absent once that URL's head is **2 blocks past** the block the count was read at; the OrderSent logs up to that head are read again and a hit is waited for instead of a resend. Any unreadable step, or a head that does not move within `deadConfirmMs` (15 s), is "unknown": waited for, never resent. | P1 test green; new: a receipt the node indexes late, a stalled head, a logs hit by another tx, the plain re-sign, the gateway pin. `wp3-hl`'s node mock answers `eth_getLogs` (an unreadable logs step is now unknown, not "not sent"); the O5 restart tests stay green. |
| B3 (Low) | a91775d | The trip (with its trigger) is stored **before** `act()` and again after. A store that cannot be written before the sends is logged and never holds them back. | B3 test green; new: the stored state while the sends are in flight; a failed pre-send save still sends. |
| B1 (Low) | 790bfe7 | The breaker stores `checkedAt` on each run that evaluates the loss triggers. The gate keeps refusing a pause past its 00:00 UTC end until `checkedAt >= until` (the breaker then renews or ends it), and fails open `3 x BREAKER_INTERVAL_MS` past the end as before (main.ts passes the interval). | B1 test green; new: the pause ends on the re-check, fail open after the grace, a state saved before the fix. `wp3-breaker`'s line that asserted the old "gate opens at 00:00 alone" now expects the wait. |
| G2 (Low) | d9d9b86 | A watched event that does not decode is logged and alerted (event name, tx, block), once per topic per UTC day. | G2 test green; new: dedupe within the day, again the next day, good events still alert. |
| G1 (Low) | 6346d7d | Watched: `ExemptOnOpenUpdated`, `BorrowingRatePerSecondPUpdated`, `AbsoluteRatePerSecondCapUpdated`, `AbsoluteVelocityPerYearCapUpdated`, `ThetaThresholdUsdUpdated`, `AprMultiplierEnabledUpdated`, `PairFlagsUpdated` (per pair); `UserPriceImpactUpdated` only for a live Gains vault we follow (wire.ts passes `liveVaults`); `BorrowingGroupUpdated` mapped to the curated pairs like fee groups. The shipped diamond ABI has no read for a pair's borrowing group, so the mapping is learned from `BorrowingPairParamsUpdated` / `BorrowingPairGroupUpdated` (in memory); while it is unknown for a collateral the change is alerted as "not yet known". | G1 tests green (9); new: one test per group (per pair, per trader, borrowing group). |
| B2 (Low) | not fixed | Left to the owner: hysteresis changes D20's behaviour. Its test is now `it.fails` (the suite stays green while the defect stands; it flips when a hysteresis lands). | |

Notes on the fixes:
- B1: `breakerPublic` (the vault page's breaker state) still shows "ok" from 00:00 until the breaker's re-check (at most
  the grace, 3 minutes by default) while the gate already refuses; cosmetic.
- G1: after a restart, the first `BorrowingGroupUpdated` per collateral alerts as "not yet known" until the curated
  pairs' groups are seen again (conservative). A read of the pair's borrowing group would remove this once the ABI has
  one.
- P1: the decision now waits up to 2 blocks (about 2 s on HyperEVM) on the vault's queue before a re-sign; it runs only
  for a resumed order whose recorded nonce was already used.

Gate after the fixes (code head 6346d7d), logs in `contracts/audit/fix-round/wp5-logs/uncross/fix-*.txt`:

| Check | Result |
|---|---|
| `npm test` in `server/` (the parallel run, then the three serial startup / cluster files; under the lock wrapper) | **1,273 passed, 0 failed, 1 expected fail (B2), 9 skipped** (112 files, 2 skipped) + **8 / 8** serial; exit 0 |
| `npx tsc --noEmit -p .` | clean |

Against the release candidate's last gate (server 1,244 + 8 on 3d75366): +30, exactly the three WP5 test files
(29 passed + the B2 expected fail); `wp3-breaker` and `wp3-hl` changed only as noted above. The 9 skips are the same
gated tests.

## Part A: WP3 follow-ups (server)

Baseline: the WP3 follow-up tests pass on 3d75366 (`wp3-breaker`, `wp3-hl`, `wp3-gains-params`: 79/79,
`contracts/audit/fix-round/wp5-logs/uncross/server-wp3-followups.txt`). The new WP5 tests fail on 3d75366 by design
(each failure is the defect); two passing controls sit beside them
(`contracts/audit/fix-round/wp5-logs/uncross/server-wp5-uncross.txt`: 14 failed, 2 passed).

### A1. D20 breaker split (55679ad): verdict OK on the main questions, three Low defects

What holds:
- Precedence: the theft trigger (opened notional) is evaluated first on every run; a trip clears the loss pause, and a
  tripped vault skips the loss logic. A theft signature never ends as a loss pause only.
- A loss pause sends nothing, so it can never block the revoke / pause sends.
- The gate (`breakerGate`) sits only on the open paths (signal open, copy-mirror open, queued D19 open). Closes,
  reduces, the reduce runs (withdrawals, risk trims, mode switch) never call it. Increases go through the OPEN path and
  are gated.
- Fails open only when the state is unreadable or absent (never watched), as documented.
- Both venues share one `breaker_state` store (main.ts passes it to the Gains wiring); both breakers filter `owns(v)`.
- Restart keeps the pause (persisted). Renewal at 00:00 UTC works when the breaker runs (control test passes).

Defects:

| ID | Severity | What | Test | Proposed fix |
|---|---|---|---|---|
| B1 | Low | At 00:00 UTC the gate lifts on the clock alone (`now < until`), before the breaker re-checks. Until its next run (60 s; longer if a facts read fails) a vault whose loss still holds takes new opens. Daily-candle signals fire at exactly 00:00 UTC, so they land in this gap. | `server/test/wp5-uncross-breaker.test.ts` (B1; plus a passing control showing the breaker's own renewal) | Store `checkedAt` with the state; the gate keeps refusing an expired pause until the breaker has evaluated at or after `until`, with a bounded grace (e.g. 3 x BREAKER_INTERVAL_MS) after which it fails open as today. |
| B2 | Low | No hysteresis: a loss hovering at the trigger ends and restarts the pause on alternate runs. Ten runs at -2.1 % / -1.9 %: 10 pause/end alerts and the gate open on 5 of them. | same file (B2) | End a pause only below a lower threshold (e.g. half the trigger) or after a minimum pause (e.g. 30 min); one start alert per vault per UTC day. |
| B3 | Low | The trip is saved after the sentinel's sends. While revokeAgent / setTradingPaused wait for receipts (up to 120 s each) the gate still lets the executor's own opens through, and a crash between a send and the save drops the trip record (re-detected on the next run, alert repeated). | same file (B3) | Save the state with `tripped` set (revoked/paused false) before `act()`, then save again after. |

Info (no test):
- I1. A 1 h-trigger pause ends when the hour's high slides out of the window, without any price recovery (seen while
  building B1). The end alert says "no loss trigger holds any more" (accurate), but the warn alert and the public text
  say "until the loss recovers". Wording, or keep the pause to 00:00 for a 1 h trigger.
- I2. While an HL transfer is pending (`bridgeBusy`) the theft trigger is not evaluated either (pre-existing D17
  behaviour, avoids false trips on a short NAV). Under D20 it is now the only revoke path; worth stating in the docs.
- I3. `MongoBreakerStore.save` replaces the whole state: during a lease handover two workers can overwrite each other's
  `riskPause` / `tripped`. Re-detected on the next run; a version field or `$set` of only the changed fields avoids it.
- O1a/O1b (WP3) confirmed as described; not re-reported.

### A2. Persisted proxy orders (8437f00): verdict sound design, one Medium defect

What holds:
- Record before broadcast in both send paths (lean: `onSigned` before `sendRawTransaction`; full `send`: inside the
  pre-broadcast try, nonce reset on throw). A failed record stops the broadcast and does not consume the lean nonce.
- Crash windows: before the record, nothing exists (a fresh send); between record and broadcast, the resume waits 120 s
  and ends in reconcile (O5a, bounded, does not block the vault's queue for longer); after broadcast, the resume waits
  for the recorded hash. A lean "nonce too low" re-sign overwrites the record with the new hash and nonce.
- A re-signed (fee-bumped) hash that loses to the first one is caught by the OrderSent log lookup.
- Two workers: the fence is read before `onSigned` in the lean path; the record is shared through database, so the new
  owner waits for the old owner's hash. HyperEVM finality makes reorgs a non-issue. TTL 7 days >> resume horizon.
- Fills are looked up from the first signing time (`prior.at`).

| ID | Severity | What | Test | Proposed fix |
|---|---|---|---|---|
| P1 | Medium | `nonceDead` reads the signer's mined count and the receipt as two calls; VaultChain reads go round robin over the HyperEVM URLs. Count from a node with the new block (8 > 7) and receipt from a node one block behind (not found) = "dead"; `sentOnChain`'s head/logs can hit the lagging node too, and the cloid is signed and sent again: a doubled order (the contract does not dedupe cloids). Most likely exactly on the in-process resume right after a lost broadcast answer, when the transaction is just mining. | `server/test/wp5-uncross-proxy-orders.test.ts` (fails; a passing control with one consistent node) | Confirm "dead" twice: read the count, then the receipt, then wait N blocks (e.g. until head >= count block + 2) and read the receipt again, and scan OrderSent logs up to that head before re-signing; or pin all three reads to one upstream (no round robin for this check). |

Info (no test):
- I4. Pre-existing, not in 8437f00: when the lean fee quote is above the cap, `sendLean` falls back to `send(...)`
  without the fence, and `lean: false` uses `send` without it too; the GR2-EXE-06 fence holds only on the lean path.
- I5. Pre-existing: `HlContractSubmitter.sent` grows by one entry per order for the life of the process.

### A3. Gains parameter alert (24fa198): verdict works for what it lists, two Low defects

What holds: own cursor, starts at head (O2b); a handler failure marks only this consumer failed (the shared stream
and the other consumers move on; the range is retried for it alone); pair ids BTC 0, ETH 1, SOL 33 match
`GAINS_PAIRS`; the `pairs()` ABI returns the tuple with `feeIndex`, so the fee group mapping reads correctly; one alert
per transaction; the per-trade events (OI windows, acc fees, PairOiAfterV10Updated) are not listed, so no spam path
was found (not checked against live traffic: no RPC); adding the diamond to the shared getLogs pulls no other
consumer's topics from it (the 36 history topics and the vault topics collide with no diamond event selector).

| ID | Severity | What | Test | Proposed fix |
|---|---|---|---|---|
| G1 | Low | Coverage: fee / impact events in the shipped diamond ABI that reach a curated pair are not watched: `UserPriceImpactUpdated` (per-trader impact multiplier and fixed spread, settable for a vault's own address), `ExemptOnOpenUpdated`, the v10 borrowing rate and funding parameters beside the two funding events it does watch (`BorrowingRatePerSecondPUpdated`, `AbsoluteRatePerSecondCapUpdated`, `AbsoluteVelocityPerYearCapUpdated`, `ThetaThresholdUsdUpdated`, `AprMultiplierEnabledUpdated`), `PairFlagsUpdated` (fee tier multiplier flags), `BorrowingGroupUpdated` (group fee, the FeeUpdated analogue). | `server/test/wp5-uncross-gains-params.test.ts` (G1, 9 cases) | Add them; `UserPriceImpactUpdated` only when `trader` is a followed vault; `BorrowingGroupUpdated` via `pairs(i).groupIndex` / the borrowing group of a curated pair as for FeeUpdated. |
| G2 | Low | A listed event whose layout changed (a facet upgrade, the change this alert exists for) fails `decodeDiamondLog`, returns null and is skipped with no alert and no log line; the cursor moves past it. | same file (G2) | On a decode failure of a watched topic, send one warn alert naming the topic and tx ("undecodable Gains parameter event"). |

## Part B: WP2's three judged ports (contracts)

All three ports (796a5f0) keep the outcome the original checked, but each is weaker in a way a regression could slip
through. The stronger version of each was written and run on the release build's `out` and `cache` (through the lock
wrapper): **4/4 pass** (`contracts/audit/fix-round/wp5-logs/uncross/forge-wp5-port.txt`). So nothing is hidden today,
and these tests close the gap for later changes. I suggest adding them to the suite.

| Port | Judgement | Stronger test (passes) |
|---|---|---|
| XReview GR1-02 intraday cycles | **Weakened.** The loop ends at the first `OrderRejected("turnover")` and needs only 3 cycles; the cost to bob and the bound on alice's loss are checked only in total. A regression that made later cycles profitable, or the turnover budget refusing after 3 cycles, would still pass. | `contracts/test/audit/fix-round/WP5-PORT-XReviewIntraday.t.sol`: on a turnover refusal the manager waits (one hour at a time) and tries again, so all **10 cycles** run (1 hour of waiting in total). After every cycle: bob lost, alice ≥ start − rounding, no breach. Bob −9,762.70 USDC; alice's 100k at 109,762. |
| OperatorBound GOV-01 (baseline day) | **Weakened.** `_passHold()` before the agent's first reduce moves the daily-loss breach after the hold, so the test no longer shows that a breach exit is never held. The same UTC day holds only by slack: START 22:13:20 UTC + 1 h epoch age + 10 min = 23:23:20, 37 min before the day changes. | `contracts/test/audit/fix-round/WP5-PORT-OperatorBoundBreachInHold.t.sol`: inside the hold and outside a breach, the agent's reduce is refused `"min hold"`. After `checkRisk` records the daily-loss breach, the agent keeps its key and 10 reduces go, all inside the hold, and the timestamp is checked to be on the baseline's UTC day. |
| GainsPositions exits at the ceiling (timed-out pending open) | **Weakened.** `_passHold()` rolls 2,400 blocks, past the mock's 200-block market order timeout. The setUp's pending market open has already timed out when the exits run; in the original it was live. Exits that are never held were also not tested inside the hold. | `contracts/test/audit/fix-round/WP5-PORT-GainsPositionsPendingOpen.t.sol`: the timeout is set to 3,400 blocks, so the open is still pending through the manager's close, reduce and cancel (`cancelTimedOut` reverts `WaitTimeout` before and after them); then the guardian flattens and a stranger cancels after the timeout. Second test, inside the hold at the ceiling: the manager's close is refused `"min hold"` (never `TooManyPositions`), while the guardian's flatten and close go. |

## Commits

Branch `wp5/uncross`, not pushed or merged: 5913484 (review tests and logs), 184ecc4 (forge port tests, log, report),
dbae328 (P1), a91775d (B3), 790bfe7 (B1), d9d9b86 (G2), 6346d7d (G1), then the commit with the gate logs and this
report update.
