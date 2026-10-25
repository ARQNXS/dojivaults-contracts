# Sub-review 3.7: executor and online keys, Gains paths (audit/gains-r1)

Input: the earlier read-only review (`executor-gains.md`, suspected defects D-1..D-15) and AUDIT-R1-BRIEF.md 3.7.
Every verdict below rests on a vitest PoC in this folder that runs the real `server/src` code against fakes. Nothing
touches a network, and nothing under `server/` was edited.

## How to run

```
cd server
npm ci                      # node 22 (tested with 22.17.0); viem 2.57.3, vitest 5.0.3 from the lockfile
npx vitest run --config ../contracts/audit/gains/tools/executor/vitest.config.mjs          # all PoCs
npx vitest run --config ../contracts/audit/gains/tools/executor/vitest.config.mjs D-4      # one file
```

`vitest.config.mjs` sets the root to this folder. It resolves the bare imports in these test files (viem, pino, ...)
as if `server/src` imported them, so they load the same module instances from `server/node_modules`. Its vite cache
goes to `server/node_modules/.vite-audit-gains-executor`. Result at the time of writing: **9 files, 18 tests, all
passing.** The existing server suite still runs too (`npx vitest run test/gains-executor.test.ts`: 4/4).

Files: `fakes.ts` holds the shared fakes:
- a fake vault and diamond behind the `GainsVaultChain` surface, with real `PendingOrderStored` receipt logs;
- a dead fill tracker, a live fill tracker and a flaky store;
- a fake clock, so the 10-minute waits run instantly;
- a strict-nonce JSON-RPC node for `VaultChain.send`.

Each `D-*.test.ts` file is the PoC for one defect.

## Summary

| id | verdict | severity | PoC |
|---|---|---|---|
| D-1 | REFUTED (at viem 2.57.3; latent) | Info | D-1.test.ts |
| D-2 | CONFIRMED | Medium | D-2.test.ts |
| D-3 | CONFIRMED | Low | D-3.test.ts |
| D-4 | CONFIRMED | Medium | D-4.test.ts |
| D-5 | CONFIRMED | High | D-5.test.ts |
| D-6 | CONFIRMED | Low | D-6.test.ts |
| D-7 | PLAUSIBLE (open question, needs the fork) | Low (if true) | none |
| D-8 | CONFIRMED | Low | D-8.test.ts |
| D-9 | CONFIRMED | Low | D-9.test.ts |
| D-10 | CONFIRMED | Low | D-10-D-11.test.ts |
| D-11 | CONFIRMED | Medium | D-10-D-11.test.ts |
| S-1 (new) | CONFIRMED by reading (design) | Low | none (scenario below) |

The main finding: **D-2, D-4 and D-5 are three ways to send one executor order to Gains more than once.** The shared
root cause is that an outcome nobody knows ("no answer", "already known", a store error, a restart) is handled as
"not sent". The order is then re-sent under a fresh cloid or nonce, and `plan()` ignores pending MARKET_OPENs.

## Findings

### D-1: nonce wedge after a failed broadcast. REFUTED (Info, latent)

- **Claim.** A broadcast that fails for a reason other than a nonce error leaves viem's nonce manager one ahead of
  the chain. The next nonce is `previousNonce + 1`, the node refuses it, and nothing resets the manager.
- **Why refuted.** `GainsVaultChain.prepare` (venues/gains/chain.ts:168-182) and `VaultChain.prepare`
  (chain/vault.ts:950-952) call `wallet.prepareTransactionRequest` directly. In viem 2.57.3 that action only uses a
  `nonceManager` passed in the *request* (node_modules/viem/_esm/actions/wallet/prepareTransactionRequest.js:74,
  112-121, 275-282). `account.nonceManager`, which vault.ts:871 sets, is read only by `sendTransaction`.
  - So every send reads `eth_getTransactionCount(pending)` afresh.
  - The earlier scratch script called `nonceManager.consume` directly. That is not the code path the executor uses.
- **Proof.** `D-1.test.ts`:
  - "agent out of ETH once": the next sends use nonces 7 and 8 and land.
  - "a tx under the base fee": the same, no gap.
- **What is latent.** `createNonceManager` (vault.ts:243) and `nonces.reset` (vault.ts:934) do nothing. A nonce error
  such as "nonce too high" would never reset anything (`isNonceTooLow`, vault.ts:1125-1133; the third test pins it).
  If a viem upgrade, or a change to `prepare`, starts honouring `account.nonceManager`, D-1 becomes real exactly as
  described: the agent or keeper wallet is wedged until a restart. The first two tests are the regression guard.
- **Recommendation.**
  - Either delete the unused nonce manager, or pass it explicitly and reset it on any send error that did not land.
  - Add `nonce too high` to the reset rule.

### D-2: "already known" / "nonce too low" re-signs the order. CONFIRMED (Medium)

- **Where.**
  - chain/vault.ts:919-924: after a failed broadcast, `landed(hash)` is null for a tx not yet mined.
  - vault.ts:928-944: on `isNonceTooLow`, the code resets and runs `once()` again: re-simulate, re-prepare,
    re-sign.
  - vault.ts:1130: `already known` matches. The check on `before` never helps here, because Gains actions are
    unique per order (`gains:<cloid>:<seq>`, submitter.ts:207).
- **Scenario.**
  1. The public RPC forwards the openTrade to the sequencer, then answers with an error (20 s client timeout, 502).
  2. The fallback (primary) answers "already known", or "nonce too low" once the tx is sequenced while its receipt
     is not yet visible on the read gateway.
  3. `send` signs the same openTrade again with nonce n+1 and broadcasts it.
  4. Both are accepted, giving two market requests for one order. `onSigned` overwrites the stored hash, so the
     executor tracks only the second request; the first request's fill is booked as "outside the executor".
- **PoC.** `D-2.test.ts`, both tests: two accepted transactions, nonces 7 and 8, identical calldata.
- **Impact.** One duplicate of the order: 2x the intended size on the pair. The contract caps it at policy
  (`maxOrderNotional` per request, `maxLeverageBps` on the total, idle USDC). Example: a 25 k USD order on a 100 k NAV
  vault with a 3x cap. The extra 25 k is unintended exposure, and a 5% adverse move costs 1.25 k (1.25% NAV) plus
  about 0.1% round-trip fees.
- **Likelihood.** Low to medium: it needs a send transport that took the tx and then errored. That happens under
  load on public Arbitrum RPCs. Impact medium × likelihood low-medium gives Medium.
- **Fix.**
  - "already known", and "nonce too low" right after our own broadcast, mean "wait for this hash"
    (`waitForTransactionReceipt(hash)` with a timeout). Never re-sign a Gains request.
  - Re-signing is only safe for idempotent keeper calls (checkRisk, accrueFees).

### D-3: receipt timeout marks a landed request "failed". CONFIRMED (Low)

- **Where.**
  - venues/gains/chain.ts:264: the receipt wait is 60 s.
  - submitter.ts:219-224: on that error, the order is marked `failed` with no orderIndex.
  - fills.ts:438-461: fills are linked by orderIndex only.
  - tickets.ts:42-47: an unlinked fill is reported as "opened outside the executor".
  - `GainsStore.openOrders` has no caller, so nothing re-reads a stored hash.
- **PoC.** `D-3.test.ts`:
  - one openTrade, not retried (not `GAINS_RETRYABLE`), `filledSize 0`;
  - the stored row is `failed` with a txHash and a null orderIndex;
  - the tracker's fill is unlinked (`isExecutorKey` false), and the vault holds 1 ETH.
- **Impact.** No duplicate order. The position the signal asked for exists but is not on the ticket: the strategy's
  closing signal will not close it, and it stays until the manager acts on the alert. Exposure is the intended size,
  held longer than intended.
- **Likelihood.** Low: the receipt has to stay invisible for 60 s.
- **Fix.**
  - On a receipt timeout, keep the row `sent` and fetch the receipt by its stored hash, both in `wait()` and at
    boot over `openOrders()`.
  - Alternatively, link fills by request tx hash as well as by orderIndex.

### D-4: retry after "no answer from Gains" sends the order again. CONFIRMED (Medium)

- **Where.**
  - submitter.ts:257-258: after 600 s, `wait()` returns "no answer from Gains after 10 minutes" whatever the
    order's state.
  - venues/gains/index.ts:18: `GAINS_RETRYABLE` matches that text.
  - engine/executor.ts:174-178 and 104-105: the remainder is retried under a fresh cloid.
  - submitter.ts:122-123 and 144-147: `plan()` drops pending MARKET_OPENs and turns a trade it does not know about
    into an INCREASE.
- **PoC.** `D-4.test.ts`:
  - **Variant A (filled on Gains, fill tracker blind for 10 min).** `GainsFills.tick` swallows getLogs errors
    (fills.ts:218-221). Result: `openTrade, increaseTrade ×3`, **4 ETH long for a 1 ETH signal**, and the executor
    books 0.
  - **Variant B (oracle slow and `arbBlockNumber` unreadable,** so the self-cancel never runs, submitter.ts:251).
    Result: 4 market opens in flight.
- **Impact.** Up to `maxAttempts` = 4 times the order (3 extra copies), capped by policy leverage and idle. The
  ticket shows flat, so the extra exposure is orphaned.
- **Likelihood.** Low: it needs a getLogs or ArbSys outage of at least 10 minutes during an order. Impact high ×
  likelihood low gives Medium.
- **Fix.**
  - "No answer" must not be retryable.
  - Before any retry, re-read the diamond (`getPendingOrders` and `getTrades`) and net both pending MARKET_OPENs and
    trades opened since the first attempt.
  - Better: carry one idempotency key for the whole order across attempts, and refuse a new request while an
    earlier attempt of the same order is sent or pending.

### D-5: a request in flight is sent again (restart, or one store error). CONFIRMED (High)

- **Where.**
  - venues/gains/info.ts:120-127 (absolute 188-195): `orderState` returns `{known: true, status: "open"}` for a
    sent or pending row.
  - engine/executor.ts:119-126 and 161-169: `recoverFromExchange` returns `[]` (no fills yet), and
    `if (known)` is true for an empty array, so the loop moves on to the next attempt and submits.
  - main.ts:1084-1096: every QUEUED or PROCESSING signal is re-queued at boot.
  - submitter.ts:122-123: the pending first request is not netted.
- **PoC.** `D-5.test.ts`:
  - **Restart.** Attempt 0 is pending on Gains when the process dies. The re-run sends a fresh openTrade under the
    attempt-1 cloid, and the executor reports FILLED 1 ETH. When attempt 0 fills, the vault holds 2 ETH.
  - **In process.** One transient database network error on the first `getOrder` inside `wait()` makes `placeOrder` throw.
    The catch branch recovers `[]`, attempt 1 opens again, and the result is 2 ETH.
- **Impact.** A duplicate order of the full size (2x). The extra exposure is not on any ticket.
- **Likelihood.** Medium:
  - every executor restart or deploy that lands while a Gains request is in flight (the oracle round trip is
    seconds; a 10-minute wait window when the fill is unseen);
  - any single store error during the 10-minute wait (database primary step-downs, provider maintenance).
  - Impact medium-high × likelihood medium gives High.
- **Fix.**
  - In `Executor.execute`, treat `state.known && status === "open"` as "in flight": wait for it (Gains: poll
    `fillsForOrder` / `wait()` on the stored row) and never `continue` to a new attempt while it is open. The test
    must be `known !== null && known.length > 0` for "has fills", plus an explicit open branch.
  - At boot, resume every `sent` or `pending` row of `gains_orders` (receipt by hash, then `wait()`) before
    re-running its signal.

### D-6: the vault queue is held up to 20 minutes per order. CONFIRMED (Low)

- **Where.**
  - submitter.ts:111 and 257-258: a 600 s wait per step.
  - submitter.ts:265: `finish()` waits again on non-terminal rows.
  - Everything behind the vault's `runExclusive` waits too: the next signals, the watcher trims
    (risk/watcher.ts:240 and 288), and the free-margin reduce (treasury/service.ts:158).
- **PoC.** `D-6.test.ts`: `placeOrder` returns after 1,200 s of fake time.
- **Impact.** Level-1 trims and reduces are delayed up to 20 minutes. The contract `checkRisk` stays the backstop.
- **Fix.**
  - One bounded wait per order, not per step plus again in `finish()`.
  - Run risk trims outside, or ahead of, a waiting order.

### D-7: operator reduce sizes Gains may refuse. PLAUSIBLE (open question)

- **Where.** treasury/gainsOperator.ts:225-245: `keep` = 1 USDC, and the amount is `min(cap, collateral - 1)`.
- **Status.** Whether gTrade's `decreasePositionSize` refuses a remainder below its minimum position or collateral,
  or cancels in the callback, cannot be checked offline.
- **If true.** A stall, not a loop: the existing round counter (`maxReduceRounds` 3, gainsOperator.ts:195-202) stops
  it and hands over to the manager. Low.
- **To settle it.** A fork test in GainsForkTrading.t.sol style: operator `reduceTrade(index, collateral - 1e6)` on
  a BTC trade, checking the callback outcome.

### D-8: the free-margin plan double counts idle on Gains. CONFIRMED (Low)

- **Where.**
  - treasury/service.ts:102-118 calls `reductionFor` (treasury/reduce.ts:59), which adds
    `have = idle + pendingDeposit + spot + withdrawable`.
  - `GainsInfo.account` reports `withdrawable = idle` (venues/gains/info.ts:113).
  - The contract's shortfall (GainsVaultMath.sol:143-159; `idleAssets` 102-106) counts idle once and never counts
    queued deposits.
- **PoC.** `D-8.test.ts` (real `TreasuryService.plan` plus `GainsInfo.account`):

  | idle | queued deposits | trades | payout | plan | contract shortfall |
  |---|---|---|---|---|---|
  | 100 | 0 | 1,000 | 150 | fraction 0 | 50 |
  | 100 | 60 | 1,000 | 150 | 0 | 50 |
  | 300 | 0 | 1,000 | 800 | 209 | 500 |

- **Impact.** The manager's signed free-margin reduction is too small or 0%. The Gains operator runner
  (gainsOperator.ts:225-245) reduces automatically from the contract's own `redemptionShortfall`, so redemptions are
  still funded, but only after the operator runs. Low.
- **Fix.** For Gains, use `have = idle + spot` (`spot` is 0). Or simply read `vault.redemptionShortfall()` and use
  `marginUsed` = trade collateral.

### D-9: watcher leverage differs from the contract's. CONFIRMED (Low)

- **Where.**
  - risk/watcher.ts:212-216 computes leverage from `sum(|positionValue|)`.
  - `GainsInfo.account().positions` come from `booksByCoin` (venues/gains/nav.ts:51-73), which skips resting orders
    (`tradeType != 0`) and nets long against short per pair.
  - The contract uses `venue().notional` (GainsNav.sol:50-79): gross per trade, plus resting limit and stop orders
    at collateral × leverage, plus pending opens.
  - `account.totalNtlPos` (info.ts:111) already carries the contract's number, but the watcher does not use it.
- **PoC.** `D-9.test.ts`, policy max 3x:

  | scenario | contract | watcher | outcome |
  |---|---|---|---|
  | a resting limit | 3.25x, `LEVERAGE` breach | 1.5x | no trim |
  | long 6 / short 5 ETH | 3.3x, breach | 0.3x | no trim |

- **Impact.** No pre-emptive trim. The vault goes straight into a leverage breach (reduce-only, new opens refused)
  until it is cleared. No loss in itself. The executor never places limits or hedges itself; the manager, or D-12's
  edge case, can.
- **Fix.**
  - For Gains, measure the watcher with `account.totalNtlPos`.
  - When resting or pending notional is what pushes leverage over the line, cancel resting opens
    (`cancelOrder`: agent or sentinel), since a trim cannot reduce them.

### D-10: indexer lag at the deadline loses the agent. CONFIRMED (Low)

- **Where.**
  - tenants/launch.ts:277: `findPendingReservationByAgent(agent, now)` uses processing time
    (`expiresAt > now`, tenants/store.ts:120-125, the database module :219-223).
  - The on-chain deadline is `floor(expiresAt/1000)` (launch.ts:238), and the factory accepts up to it
    (GainsVaultFactory.sol:262).
- **PoC.** `D-10-D-11.test.ts`: a create mined 1 s before the 1 h deadline and indexed 30 s later is registered
  `MANUAL` with `encryptedKey: null`. The control, processed in time, gives `OWN_SIGNALS`.
- **Impact.** No automated trading for that vault. The `minAgentGas` that `create()` forwarded to the agent is lost
  with the purged key, and the owner must bind a new agent through the timelock.
- **Likelihood.** Low (the last seconds of a 1 h window, plus indexer lag).
- **Fix.**
  - Look the reservation up by agent regardless of expiry, and accept when the create's block timestamp is at or
    before `expiresAt`.
  - Or keep the server's `expiresAt` a few minutes after the signed deadline.

### D-11: a Safe (contract) owner can never bind. CONFIRMED (Medium)

- **Where.**
  - tenants/launch.ts:382-388: `creatorMatches` requires `ev.txFrom == owner`.
  - tenants/indexer.ts:157-163: `txFrom` is the transaction's EOA sender. For a Safe `execTransaction` that is the
    executing signer (or a relayer or bundler), never the Safe.
- **The flow exists.** The webapp ships this flow (webapp/src/pages/gainsLaunchSafe.test.tsx: one Safe batch of
  approve + create with the reserved agent and `agentSig`). The server gives contract owners a 24 h TTL for it
  (launch.ts:224).
- **PoC.** `D-10-D-11.test.ts`, with Safe = owner = manager, vault = predicted, and tx.from = the signer EOA:
  - the reservation is `expired` and its `encryptedKey` is null;
  - the tenant is `MANUAL`;
  - `unregister` is attempted, and reverts `LiveAgent` on Gains;
  - the error alert "was used by vault" fires.
- **Impact.**
  - 100% of Safe launches with a platform agent fail to bind, on both venues (shared code).
  - The vault is left with a live agent whose key is deleted, so nobody can trade for it, and the forwarded
    `minAgentGas` is lost.
  - The owner must revoke the agent and bind a new one through the timelock.
  - No depositor loss. A core launch flow is broken: Medium.
- **Fix.**
  - The scoped salt already binds `msg.sender`: `r.vault == ev.vault` and `predictVaultAddress(owner, salt)`
    imply that the creator is `owner`.
  - So accept `txFrom != owner` when `r.vault` matches and owner == manager == `r.owner`.
  - Or verify against the factory's `VaultCreated` creator field, if one is added.

### S-1 (new, design): no resting order is cancelled on a breach. Low

- **What the sentinel does.** The Gains sentinel only ever sends `revokeAgent`, and only when
  `getTradingDelegate != 0` (venues/gains/monitor.ts:106-121; wire.ts:424; `sentinelAction`'s `triggerBreach`,
  chain/vault.ts:1024, has no Gains caller). The sentinel never pauses, never triggers a breach and never cancels an
  order.
- **What the contract allows.** `triggerBreach` and `_stop` (GainsVaultGovernance.sol:221-235) revoke the agent but
  do not cancel resting LIMIT or STOP opens.
- **Consequence.** Gains triggers those orders by itself, so an order placed before a breach (by the manager, or by
  a compromised agent: `openTrade` accepts `tradeType <= STOP` with any tp and sl, GainsVaultLogic.sol:431-434) can
  still open new exposure during a breach or full stop.
- **Bound.** The resting order passed `checkOrder` when it was placed, so it is capped by policy.
- **Fix.** On a breach, the keeper or sentinel cancels every resting open: `cancelOrder` is open to the sentinel
  (GainsVaultLogic.sol:608-612), and `flatten` also cancels resting orders.

## Compromised online keys: what each can do on chain (contracts/src/gains)

### Agent key (one per vault)

**What it can do.** It trades like the manager (`_trader`, GainsVaultLogic.sol:694-697).

- **New exposure** (`openTrade` 431, `increaseTrade` 478, raising leverage with `updateLeverage` 518-548):
  - `_newRisk` (699-704) applies: not breached, not in emergency, not paused;
  - `MAX_POSITIONS`, and collateral ≤ idle;
  - `policy.checkOrder`: curated pair, slippage ≤ `maxSlippageBps`, expected price inside the Chainlink band on the
    adverse side, per-order notional ≤ `maxOrderNotional`, minimum collateral and position, and
    `(open + new) / NAV ≤ maxLeverageBps`.
  - It can also place LIMIT and STOP opens with any tp and sl.
  - Lowering leverage pulls idle USDC into a trade, and is allowed in a leverage breach (523-531).
- **Exits, not policy-bounded:**
  - `closeTrade` and `reduceTrade` on any trade at any time (`_mayExit`, 707-711);
  - `setSlTp` with TP anywhere, and SL anywhere outside a breach (591-605);
  - `cancelOrder` (608-612).

**What it cannot do.** It cannot move USDC out of the vault, change roles, the policy or fees, or set a Gains
delegate.

**Worst cases:**
- **Fee churn.** Open/close round trips at max leverage cost about 0.1-0.16% of notional each, about 0.3-0.5% of NAV
  at 3x. This stops at the daily-loss breach (`maxDailyLossBps`), after which `_newRisk` refuses new risk. So the
  loss is at most about `maxDailyLossBps` plus one round trip per day, until the agent is revoked.
- **Crystallising losses** by closing at market.
- **Blocking every settle.** Keeping a market order pending makes settle revert with `OrdersPending` (230). The
  revert sits after the mode checks, so it also blocks the emergency and exit-only settles, and redemptions wait
  until the agent is revoked.

**Detection.** Nothing in the executor detects churn or settle blocking: the monitor checks the delegate, a NAV move
of at least the NAV-move alert threshold, and agent gas. The owner, guardian or sentinel can revoke the agent instantly
(GainsVault.sol:282-290).

### Keeper / operator (`ARBITRUM_KEEPER_KEY`)

**Outside a breach:**
- `settle` in normal mode only, with NAV within `maxNavMoveBps` of the checkpoint (GainsVaultLogic.sol:212-230). The
  checkpoint is set by the permissionless `checkRisk`.
- `reduceTrade` for collateral only, capped at `operatorReduceCap(redemptionShortfall)` (576-583; GainsTypes.sol:29-31).
- `clearLeverageBreach`, `cancelTimedOut`, `accrueFees`, `checkRisk`: anyone may call these anyway.

**In a breach or emergency:**
- close or reduce any trade, uncapped (`_mayExit`);
- `flatten` at the policy slippage only (custom slippage is for the manager, or the guardian in emergency, 650-656);
- an exit-only settle once the epoch is overdue or in emergency.

**Worst case.** While a vault is in breach, close everything at market: crystallised loss plus fees plus up to
`maxFlattenSlippageBps` (≤ 3%). No theft. The operator role is removable by the owner, guardian or sentinel
(`revokeOperator`, GainsVaultGovernance.sol:117-120).

### Sentinel (`ARBITRUM_SENTINEL_KEY`)

This one key is factory-wide, so it covers every vault of the factory.

**Powers:** `revokeAgent`, `revokeOperator`, pausing deposits and trading, `triggerBreach`
(GainsVaultGovernance.sol:221-235: full stop, agent revoked, settle refused unless in emergency). Once breached it can
also close or reduce any trade, `flatten` at policy slippage, only tighten SL (but it can tighten it to the market),
`cancelOrder`, and an exit-only settle when overdue or in emergency.

**Worst case.** Freeze every vault at once (deposits and redemptions blocked until the guardian `clearBreach`es),
then market-close all positions: crystallised loss plus at most 3% flatten slippage. No theft.

**Recovery.** The guardian clears the breach, and the factory owner rotates the sentinel (GainsVaultFactory.sol:
404-414).

### Registrar (`ARBITRUM_REGISTRAR_KEY`)

- **Agent launch signatures.** It signs agent launch digests bound to chainId, factory, agent, predicted vault and
  deadline. Each is usable only by that vault's creator, once (GainsVaultFactory.sol:256-268).
- **`registerPlatformAgent`.** This works only for an existing vault (`isVault`, 331-341). It takes effect only
  after the vault owner's timelocked `setAgent`.
- **`unregisterPlatformAgent`.** On a live agent it reverts `LiveAgent` (344-356).
- **Worst case.** Griefing launches (refusing to sign) and marking useless agents. No exposure, no theft.

### One online key on both chains?

No.
- `distinctHotKeys` (hotKeys.ts:10-22) runs at boot over SENTINEL, REGISTRAR and KEEPER, their three Arbitrum
  keys, and every static strategy's agent key (main.ts:201-210). Any collision throws.
- Static strategies are always Hyperliquid (strategies.ts:78-79), and tenant agent keys are generated fresh per
  reservation (launch.ts:198-199).
- `routedChain` swaps a HyperEVM role key for that role's Arbitrum key per Gains vault, and throws when none is
  mapped (chain/router.ts:64-89).
- Within Arbitrum, the keeper key doubles as the "agent" of the operator's throw-away `GainsSubmitter`. That is
  shared nonce serialization only, and fine on chain.

### The sentinel and breaches

Confirmed: for Gains the sentinel only ever sends `revokeAgent` on a trading delegate, so it never cancels resting
limit orders on a breach (S-1).

## Self-challenge notes

- **D-4 and D-5 are capped by the contract.** The duplicates still pass `checkOrder`, so total exposure never
  exceeds `maxLeverageBps` × NAV, `maxOrderNotional` per request, or idle USDC. This sets the severity: it bounds the
  loss to market risk on unintended, in-policy exposure, never theft.
- **D-2's precondition** (a transport that took the tx and then errored) is real, but rare on Arbitrum. The
  "nonce too low with a lagging receipt" variant is the more likely shape there.
- **D-5's restart path is the most reachable one.** Executor deploys are manual, but every
  deploy restarts the process, and `resume unfinished signals` replays the signals in flight.
- **Not re-examined here:** D-12..D-15 from the earlier report. D-12 is the root of D-9's hedged case; D-14 is
  alert text; D-15 is design.
