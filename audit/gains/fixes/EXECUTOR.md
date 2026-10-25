# Gains round 1 fixes: the executor (TypeScript)

Branch `fix/gains-r1`. Scope: `server/` plus the executor PoCs (`contracts/audit/gains/tools/executor/`,
`contracts/test/audit/gains/xreview2/`). The contracts half is the lead's (FIXES-R1.md). Nothing was deployed, sent
or pushed.

## The design for GR1-05, GR1-06 and GR1-07

One idea runs through all three findings: **an outcome nobody knows is never treated as "not sent".**

- **Idempotency key per order intent.** The engine gives every order an intent key, `strategy|ticket|type`
  (`OrderRequest.intent`, engine/executor.ts:107). It is the same for every attempt of one signal's order and
  survives restarts. Attempt cloids still differ.
  - Each `gains_orders` row stores, before the broadcast: the intent, the attempt cloid, and `targetTokens`.
    `targetTokens` is the vault's signed position on the pair, trades plus pending orders, that the intent ends at.
    (`GainsOrder.intent` / `targetTokens`, store.ts:24; database index `{intent, createdAt}`.)
- **The submitter is the authority (submitter.ts:109 placeOrder).**
  1. A cloid that was already sent is waited for, never sent again.
  2. An earlier attempt of the same intent that is still `sent` or `pending` is waited on. Nothing new goes out next
     to it. If it stays unresolved, the result is an error and nothing is sent.
  3. A new attempt is netted on chain first (plan, :191). The size sent is the distance from the vault's current
     position to the intent's target, never more than the engine asks.
     - The position is read from `getTrades` + `getPendingOrders`: opens and increases count up, closes and partial
       closes count down, and partial orders are matched to their trade by index (GR1-28).
     - Within 2%, the earlier attempts already did the job, so nothing is sent.
- **A stored hash is reconciled by its receipt (reconcileReceipt, :329).** A `sent` row without an order index gets
  its receipt by the stored hash, which yields the order index. This runs inside every wait, before the fill tracker
  runs, so the fill is linked to the executor at once.
- **"No answer from Gains" means reconcile, never retry.**
  - It is no longer in `GAINS_RETRYABLE` (index.ts:23).
  - At the deadline, `finish` / `reconcileOnChain` (:392, :425) checks the order:
    - still pending on the diamond, or never seen on chain: an unresolved error, not retried;
    - gone from the diamond with the vault at the order's target: a fill the tracker has not seen yet. It is booked at
      the request's mark and the row is marked `filled` ("reconciled on chain").
- **The engine never starts a new attempt beside an open one (engine/executor.ts:130).** An `open` order state is
  IN_FLIGHT:
  - a submitter with `resumesInFlight` (Gains) is called again with the SAME cloid and waits for it;
  - Hyperliquid stops instead.
  - The catch branch does the same: a store error inside the wait resumes the same cloid, bounded to 3 resumes (:184).
  - An unreadable order state is treated as in flight for Gains.
- **Boot.** The resume job (main.ts:1102) puts a dead run's PROCESSING signals back to QUEUED. The processor then only
  processes a signal still QUEUED (processor.ts:309). Each resumed signal reaches its stored rows through its cloid: the
  receipt by hash, then the wait, before anything new. There is deliberately no separate boot sweep of `gains_orders`:
  the per-signal path reconciles exactly the rows of the signal being re-run, before it can send.
- **Shutdown (shutdown.ts:22 drainThenRelease, used by main.ts:2035).** The steps, in this order:
  1. Intake closes: static queue flag, `registry.closeIntake()`, `server.close()`, copy engine stop.
  2. The queues drain WHILE the lease is held and renewed.
  3. The jobs and chains stop.
  4. The lease is released last.
  - There is no drain timeout on purpose. If the platform kills the instance first, the lease expires on its TTL, and
    the new leader waits on the stored row (GR1-05). XR_LEASE test 2 covers that case.

## Findings

Every reverted check reverted one fix in a copy of the file (the PoC / test file untouched), ran the regression test
(it must FAIL), restored the file and ran it again (it must PASS). Script:
`scratchpad/r1/revert-checks.sh` (base for "file reverted" = e850c3d, the commit before the fixes); raw results below
the table.

| finding | fix (file:line) | regression test(s) | reverted check |
|---|---|---|---|
| GR1-05 in-flight resubmit (Medium) | engine/executor.ts:130 (IN_FLIGHT resume, same cloid), :184 (catch branch, max 3 resumes), :107 (intent); venues/gains/submitter.ts:109 (cloid already sent: wait), :121 (earlier attempt in flight: wait, never send beside it), :329 (receipt by stored hash); store.ts:24 (intent, targetTokens); main.ts:1102 (resume PROCESSING as QUEUED) | server `gains-r1-idempotency.test.ts` "GR1-05" (5 tests); PoC D-5 (2); xreview2 XR_D5 (3) | engine reverted to e850c3d: FAILED `expected [ {...} ] to have a length of +0 but got 1` (restart sends a second open) and, in process, `expected [ 'openTrade', 'increaseTrade' ] to deeply equal [ 'openTrade' ]`. Receipt-by-hash disabled: XR_D5 FAILED `expected 'REJECTED' to be 'FILLED'`, server FAILED `expected +0 to be close to 1`. All passed after restore |
| GR1-06 lease released before the drain (Medium) | shutdown.ts:22 drainThenRelease; main.ts:2035 (used by shutdown), main.ts `intakeClosed`, tenants/registry.ts:382 closeIntake; engine/processor.ts:309 (only QUEUED is processed) | server "GR1-06" (3 tests); xreview2 XR_LEASE (2: deploy mid-queue; killed before the drain ends) | lease released first (old order): XR_LEASE and server FAILED `expected true to be false` (the standby is leader during the drain). Processor re-check reverted: FAILED `expected { status: 'REJECTED', ... } to deeply equal { status: 'DONE', ... }`. Passed after restore |
| GR1-07 no answer retried (Medium) | venues/gains/index.ts:23 (not retryable); submitter.ts:392 finish / :425 reconcileOnChain (pending / unseen: unresolved; at target: filled); :191 plan (netting on getTrades + getPendingOrders) | server "GR1-07" (4 tests, incl. netting after a cancelled attempt); PoC D-4 (2) | submitter.ts + index.ts reverted: D-4 and server FAILED `expected true to be false` (no answer retryable), plus the 4x / 4 pending opens. Passed after restore |
| GR1-17 re-sign on already known / nonce too low (Low) | chain/vault.ts:929 (`resign: false`: wait for this hash), chain.ts vaultTx `resign`; submitter.ts:301 (orders sent with resign: false) | server "GR1-17" (3); PoC D-2 (3, incl. the keeper control) | vault.ts reverted: D-2 FAILED `expected [ 'public:7', 'primary:7', 'public:8' ] to deeply equal [ 'public:7', 'primary:7' ]`, server FAILED `expected [ 7, 8 ] to deeply equal [ 7 ]`. Passed after restore |
| GR1-18 receipt timeout marked failed (Low) | submitter.ts:315 (signed + unknown outcome stays "sent"), :329 reconcileReceipt before the tracker runs | server "GR1-18"; PoC D-3 | branch disabled: D-3 and server FAILED `expected 'REJECTED' to be 'FILLED'`. Passed after restore |
| GR1-19 20 minutes per order (Low) | submitter.ts:109 (one deadline per order), :392 (finish never waits again) | server "GR1-19"; PoC D-6 | fresh deadline per step plus a re-wait in finish: FAILED `expected 1200 to be less than 610`. Passed after restore |
| GR1-20 free-margin double count (Low) | treasury/service.ts:110 (`isGains`: idle once, no queued deposits); main.ts wires `isGains` | server `gains-r1-lows.test.ts` "GR1-20" (2); PoC D-8 (3) | service.ts reverted: FAILED `expected 0 to be greater than or equal to 50`. Passed after restore |
| GR1-21 watcher leverage (Low) | risk/watcher.ts:219 (`contractNotional`: account.totalNtlPos); venues/gains/wire.ts:390 | server "GR1-21"; PoC D-9 (2) | watcher.ts reverted: FAILED `expected 0 to be greater than 0` (no trim). Passed after restore |
| GR1-22 launch binding (Low) | tenants/launch.ts:15 BIND_GRACE_MS (15 min, lookup and sweep); :393 creatorMatches (predicted vault proves the creator; an unreadable sender still fails closed) | server "GR1-22" (2); PoC D-10-D-11 (3); AUDIT_S3 and the launch / launch-v2 sweep tests updated | launch.ts reverted: PoC FAILED `expected 1 to be +0` (key swept), server FAILED `expected 'MANUAL' to be 'OWN_SIGNALS'`. Passed after restore |
| GR1-16 resting orders in a breach, executor half (Low) | venues/gains/monitor.ts:171 restingInBreach (breached or in emergency: the sentinel cancels each resting limit / stop open with cancelOrder); wire.ts:434 cancelResting | server "GR1-16" (2) | check disabled: FAILED `expected [] to deeply equal [ 1, 2 ]`. Passed after restore |
| GR1-11 mitigation, reduce rate (Low) | venues/gains/reduceRate.ts:28 ReduceRateAlarm (more than 10 ReduceRequested from one caller on one vault in 10 min: error alert, hourly throttle); wire.ts:516 log stream consumer | server "GR1-11" (2) | alarm disabled: FAILED `expected [] to have a length of 1 but got +0`. Passed after restore |
| GR1-43 unused nonce manager (Info) | chain/vault.ts:240 (removed) | server "GR1-43" | vault.ts reverted: FAILED `expected { ...(4) } to be undefined`. Passed after restore |
| Task 6: minimum = the executor minimum-trade setting only | core/minimums.ts:23; info.ts coinMeta; symbols.ts / index.ts (minNotionalUsd 5); env.ts / processor.ts comments | `gains-min-trade.test.ts` (rewritten), `gains-units.test.ts` | minimums.ts reverted: FAILED `expected 'SKIPPED' not to be 'SKIPPED'`. Passed after restore |
| Task 7: round 1 vault interface | venues/gains/abi.ts (flattenIndices, notes); chain/contractErrors.ts (4 errors); gainsOperator.ts:68; wire.ts:353 | server "the round 1 vault interface" (2) | abi.ts + contractErrors.ts reverted: FAILED `expected [ 'AboveMax', ...(198) ] to include 'EpochOverdue'`. Passed after restore |

All reverted checks: 26 cases (52 runs), plus the in-process GR1-05 case re-run with the oracle answering only after
the engine's first recovery look. Each one FAILED on the reverted code and PASSED on the fix. The raw log is in the
scratchpad (`r1/revert-results.txt`), not committed.

## Not fixed, and why

- **GR1-22, the "compare the create's block time" variant.** `VaultCreatedEvent` carries no block timestamp. The fix
  uses a 15 minute bind grace instead (`BIND_GRACE_MS`, launch.ts:15; `sweep()` keeps the key that long).
  - This is safe: the factory enforces the agent deadline on chain, so any VaultCreated naming our reserved agent was
    accepted in time.
  - A create indexed more than 15 minutes late is still MANUAL. That would take an indexer outage of over 15 minutes
    right at the deadline.
- **GR1-22, an unreadable tx sender.** It still fails closed (REAUDIT_S3_unknown_tx_sender_fails_closed). The relaxed
  S-03 rule takes the predicted vault (scoped CREATE2 salt) as the proof of the creator, but only when the sender was
  read.
- **GR1-19, "trims ahead of waiting orders".** Not done. The fix bounds the wait (at most 10 minutes per order instead
  of 20), but a risk trim still queues behind an order that is waiting.
  - Running trims outside the vault's queue would let a trim and an order act on the same trade concurrently. Gains
    takes one pending order per trade, and the new PendingOrderExists revert makes the second one fail.
  - The contract's `checkRisk` remains the backstop.
- **GR1-18, "link fills by request tx hash".** Not needed. The receipt by hash gives the order index before the
  tracker runs, and the tracker's existing late link (fills.ts linkLate) covers the rest. Gains' fill event comes in the
  oracle's callback transaction, not in the request's, so a tx-hash link would not match anyway.
- **GR1-17, a "nonce too low" caused by another transaction of ours on the same nonce.** The receipt wait for our hash
  times out. The request stays `sent` and becomes unresolved at the deadline: no duplicate, but no fill either.
  - It needs two instances signing with one agent key at once, which the lease prevents.
  - The outcome is conservative by design.
- **Booking of an unresolved order that fills later.** Its fill carries the executor's key, so GainsTicketSync skips
  it, and it is not booked on the ticket automatically.
  - The engine records the order REJECTED with "... unresolved; not retried (reconcile)", and the processor alerts.
  - The manager reconciles that ticket.
  - This is the price of never sending twice. The common blind-tracker case is booked by the on-chain reconcile.
- **flattenIndices in the sentinel.** Added to the ABI but not used, because the executor never calls `flatten` on
  Gains. The sentinel only revokes agents (delegate check) and now cancels resting orders (GR1-16). So there is no
  `DiamondLayoutChanged` fallback to add.

## GR1-43 triage: FIXED

The viem nonce manager is removed (chain/vault.ts:240). It was attached to every hot-wallet account, but at viem
2.57.3 only `sendTransaction` reads it, and the executor never calls that. `prepare()` reads
`eth_getTransactionCount(pending)` for every send, and sends of one wallet are serialized.

Removing it changes no behaviour: the D-1 tests still pass. It removes the latent wedge: if a viem upgrade started to
honour `account.nonceManager`, a failed broadcast would have left it one ahead with no reset on "nonce too high".
Regression: `gains-r1-lows.test.ts` "GR1-43", which checks that the signing account has no `nonceManager`.

## Contract interface changes (lead's round 1) in the executor

- `abi.ts`: `flattenIndices(uint32[],uint256,uint64) returns (uint256)` added.
- Errors `EpochOverdue()`, `DiamondLayoutChanged()`, `PendingOrderExists(uint32)` (and the lead's
  `OwnershipFollowsVault()`) were added to `chain/contractErrors.ts`, in gen-errors' format and sort order. Regenerate
  with `cd contracts && forge build && cd ../server && npm run gen-errors` once the contracts are final. The
  artifact-comparison test in `contract-errors.test.ts` fails until then (the `contracts/out` artifacts in the worktree
  are older than the sources).
- `venue()`: the decoder keeps the four Snapshot fields on purpose. `valueHigh` and `blocking` are appended after them,
  so the same decoder reads vaults from before and after round 1. A six-field ABI would fail on a deployed vault's
  four-word answer.
- `EpochOverdue()` / `ReduceOnlyMode()`: not retryable (GAINS_RETRYABLE never matched either; now pinned by a test).
  They are recorded REJECTED with the decoded name, and the processor alerts.
- `ordersPending()` now counts only orders that hold collateral:
  - The operator's wait message says so (gainsOperator.ts:68).
  - Its shortfall reduce skips trades that already have a pending order (wire.ts:353), because settle no longer waits
    for closes, so the planner can reach the reduce while a close is pending.
- Executor minimum (task 6): the executor minimum-trade setting only. `orderMinimums` (minimums.ts:23) no longer takes the max with
  `pairMinPositionSizeUsd`. `GainsInfo.coinMeta` stops reading the pair minimum. `GAINS_RULES.minNotionalUsd` is 5
  (no $300 fallback). The comments in env.ts, processor.ts and symbols.ts are updated.

## Housekeeping (not a finding)

`version.ts executorSha` now resolves a worktree's `.git` file (`gitdir:`, plus refs in `commondir`). The baseline
failure `exec-context.test.ts` "config hashes are canonical..." came only from running the suite in a git worktree.

## Counts

| suite | baseline (e850c3d, before any change) | final |
|---|---|---|
| `npm test` (vitest, everything except startup) | 75 files: 879 passed, 1 failed, 7 skipped (887). The failure: exec-context executorSha in a worktree | 77 files: 909 passed, **1 failed**, 6 skipped (916). The failure: contract-errors "the generated file matches the current forge artifacts" (see below) |
| `test/startup.test.ts` (second half of `npm test`) | 2 passed (run on its own) | 2 passed (run on its own) |
| `tsc --noEmit` | clean | clean |
| executor PoCs (`tools/executor/vitest.config.mjs`) | 9 files, 18 passed | 9 files, 20 passed |
| xreview2 (`xreview2/vitest.config.mjs`) | 2 files, 3 passed | 2 files, 5 passed |

The one remaining `npm test` failure is not in the executor.
- `contracts/out` holds an older forge build (it has no `EpochOverdue`), and this test compares the generated error
  list against `contracts/out`.
- Against the lead's current build (`contracts/out-lead`), the hand-maintained `contractErrors.ts` matches exactly:
  203 errors, same signatures, same order.
- It goes green once `contracts/out` is rebuilt from the final sources (`forge build`). If any error changes after
  that, run `npm run gen-errors` too.

The earlier pre-existing failure, exec-context, is gone (the housekeeping fix). dojipad-ec once failed mid-way on a
10 s afterAll database hook timeout under machine load; it passed in the final run.
