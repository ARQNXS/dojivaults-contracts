# hl-r2 cross-review A: KEYS.md and EXECUTOR.md challenged

**Internal, AI-assisted review. Not an independent audit.** Branch `audit/hl-r2-xa` (from 2b826cd). Source unchanged.
Nothing was sent to any chain or to Hyperliquid.

What was re-run here:

- `forge test --match-path "test/audit/hl-r2/keys/*"`: 7 pass.
- `cd server && npm ci && npx vitest run --config ../contracts/audit/hl-r2/exec/vitest.config.mjs`: 7 files, 19 tests,
  all pass.
- New counter-PoC `contracts/test/audit/hl-r2/xreview/XreviewA.t.sol`: 2 pass (`forge test --match-path
  "test/audit/hl-r2/xreview/*" -vv`).

## Assumptions (conservative readings, written down)

- **XA-A1.** A stolen agent key or agent key store is the accepted risk D-1 / D-5 (REPORT section 4; REAUDIT:51, 157, 187;
  hl-open REVIEW:108). A finding that needs one only counts as new where it breaks a mitigation earlier rounds relied on.
  Its severity is then set by what that broken mitigation was worth, not by the whole stolen-key loss.
- **XA-A2.** Production layout = today's hosting configuration: one service running every executor role, so the monitor, risk
  watcher, keeper, operator and mirror share one process and one CoreReader `prefetched` map (memory note,
  executor-workers).
- **XA-A3.** HL behaviour that is not in the saved docs or SDK is an open question, not a finding (CONTEXT evidence
  standard: "Unprovable = open question").

## Verdict table

| ID | Original | Verdict | Final | One-line reason |
|---|---|---|---|---|
| HLR2-K03 | High | DOWNGRADE + MERGE (REAUDIT R-1 / I3-01, HLO-07 numbers) | Design (accepted residual) | Same mechanism and bound as R-1 ("deflate NAV by up to maxDailyLossBps per day, ratchet the checkpoint, settle a sybil deposit at the discount"). The sybil was already non-insider (N-09) and the settle already routine. PoC numbers are right (11.04%/round). The new part is XA01. |
| HLR2-K04 | Design | DROP (restated) | Design (accepted) | REAUDIT2:191 and :380 already accept "a compromised sentinel is a denial of service". PoC fine. |
| HLR2-K06 | Design/High | MERGE with HLO-07 | Medium (as HLO-07) + Design (rotation) | The theft half is HLO-07 verbatim (hl-open REVIEW:85, Medium, open). The role rotation is cold-key power covered by the guardian-to-Safe runbook. It is not High. |
| HLR2-K07 | Design | MERGE with N2-03 | Design | REAUDIT2:251 N2-03 (custom-slippage flatten as a guardian lever), since capped at 3%. Restated. |
| HLR2-K10 | Medium | DOWNGRADE | Low | "Mode wrong forever" is overstated: the replacement agent can sign `agentSetAbstraction` back. The 2-day gap is the H-01 timelock on `setAgent`, and it applies the same way to every agent-misplaced balance (other dex, subaccount, HL vault). The PoC only proves `setAgent` is `onlySelf`. |
| HLR2-K11 | High | DOWNGRADE to open question | Open question (Medium at most if confirmed) | No PoC. It rests on three undocumented premises. Even on the worse reading the stated loss does not need the revoke to fail (see below). |
| HLR2-K12 | Medium | MERGE into HLR2-X05 | (see X05) | A strict subset of X05 (the abstraction switch is one of X05's six non-ACT moves), and consistent with it: both read `monitor.ts` the same way. |
| HLR2-X01 | High | DOWNGRADE | Medium (not live) | The mechanism is real: no position check, no cloid dedupe, no ledger use in the LIVE planner, no prefetch invalidation. But the 60 s staleness is not production's: the risk watcher refills the same map every 15 s for every served vault, copy included. Exposure stays inside the on-chain policy (85% of max leverage, breakers). |
| HLR2-X02 | Medium | DOWNGRADE | Low | Real (same root as X01). The cost is taker fees plus slippage on the excess trimmed (about 0.1 to 0.4% of equity in the PoC's case), and only at trim-line crossings. It reduces risk, never adds it. |
| HLR2-X03 | Medium | STANDS | Medium | Confirmed in `engine/executor.ts:276-285`: a read that throws returns `null` and the loop moves to attempt + 1 with a new cloid. GR1-05 covers only `resumesInFlight` venues. |
| HLR2-X04 | Medium | STANDS | Medium (latent; Low today with one hosted vault) | `fanOutHosted` awaits `guard.check` with no try/catch (`registry.ts:376`). `app.ts:446` only logs the rejection. |
| HLR2-X05 | High | DOWNGRADE (absorbs K12) | Medium | The loss is D-1 (agent power), not the monitor gap. A one-shot `vaultTransfer` or `agentSendAsset` of 100% lands before any 60 s look, and a revoke recovers nothing. Even a firing ACT does not stop the C-01 settle (XA01). The real content: the ACT coverage that I3-01 calls a required mitigation is narrower than assumed. |
| HLR2-X06 | Low (Design) | STANDS | Low (Design) | Bound arithmetic checks out. Answers hl-open open question 2. |
| HLR2-X07 | Medium | STANDS | Medium | Fairness gap in the HLO-E02 weight budget: one FIFO `order` tier for all vaults. Related to HLO-E02 but not a duplicate. |
| HLR2-X08 | Low (scenario) | STANDS | Low (scenario, no PoC) | No same-nonce fee bump in `chain/vault.ts`. Not covered by GR1-17 (that one is nonce-too-low handling). |
| HLR2-X09 | Info | STANDS | Info | The peak ratchet is the permissionless-checkRisk design. Static-key sharing is config only. |
| **HLR2-XA01** | new | NEW | **Medium** | The monitor's only ACT is `revokeAgent`. A revoke is not a breach, and neither the keeper nor the operator looks at findings, so the scheduled settle still mints at the deflated NAV. PoC below. |

## Reasoning per finding

### HLR2-K03 → Design, merged with R-1 / I3-01

- **Already stated.**
  - REAUDIT.md:157 (R-1): "a *compromised platform agent* (server) can still deflate NAV (agentSendAsset, spot) by up to
    `maxDailyLossBps` per day without a breach, ratchet the checkpoint, and settle a sybil deposit at the discount."
  - REAUDIT.md:32: "The insider gate is cosmetic (a sybil address deposits freely, N-09)".
  - REAUDIT3.md:243-248 (I3-01) widened it with the daily auto-clear.
  - hl-open REVIEW.md:119 has the same 81%-NAV PoC (1M confederate worth 1.105M, 10.5%) for the registrar-leak variant
    (HLO-07).
  - K03's "new framing" (an honest, non-insider settler) is the framing R-1 already had: the insider deferral only ever
    applied to manager / owner / feeRecipient, and nobody claimed it covered a sybil.
- **The PoC is sound.** The deflation is modelled as a precompile answer, and 19.9% stays under daily 20% and
  maxNavMove 20%. My re-run gives the same 1104 bps.
- **Can the operator or keeper notice?** No, confirmed:
  - `treasury/operator.ts` `runVault` / `input()` reads only epoch facts, balances and breach flags. It never reads
    monitor findings or a revoked agent.
  - `keeper.ts` `skipReason` is the bridge / empty / daily-loss guard. `checkRisk()` refreshes the checkpoint and
    breaches only at a limit.
  - The monitor's NAV_MOVE is alert-only at > the NAV-move alert threshold = 10% between two 60 s looks (`env.ts:180`,
    `monitor.ts:375-381`), so an agent stepping < 10% per minute never raises it.
  - NAV_MOVE's reaction is a `checkRisk`, which does not breach below the 20% daily limit.
- **Severity.** On the scale this is a "conditional loss" only if a stolen agent key counts as a condition. Earlier rounds
  rated exactly this residual Info/Design (R-1, I3-01) under accepted D-1 / D-5, and nothing in the bound changed (still
  ≤ maxDailyLossBps and ≤ maxNavMoveBps per settle). So Design, with the numbers kept as the quantified R-1 (≈ 11% of
  honest value per daily settle at a 1:1 sybil). What does change is that the mitigation I3-01 names ("monitor ACT must
  stay on") does not bound it even when it fires: that is XA01, filed separately.

### HLR2-K11 → open question (worse reading: Medium at most)

**What the saved docs actually say** (`keys/evidence/docs/`):

- `trading_account-abstraction-modes.md:20`: "Portfolio margin and unified account are limited to 50k user actions per
  day. Standard mode has no such restrictions." That is the whole text.
  - It does not define "user action".
  - It does not say what happens at the cap (reject, fall back, throttle).
  - It names no reset time. KEYS.md's "until 00:00 UTC" is not in any quoted source. The only UTC-reset text in the
    docs is `scheduleCancel`'s trigger count (`exchange-endpoint.md:236`).
- `for-developers_api_rate-limits-and-user-limits.md:27-29`: "Address-based limits apply per user ... 1 request per 1
  USDC traded cumulatively since address inception ... initial buffer of 10000 requests ... When rate limited, an
  address is allowed one request every 10 seconds ... Cancels have cumulative limit `min(limit + 100000, limit * 2)` ...
  this rate limit only applies to actions, not info requests." This page is in the **API** section and describes
  requests to the exchange endpoint.
- `for-developers_hyperevm_interacting-with-hypercore.md:23,34`: CoreWriter "emits a log to be processed by HyperCore as
  an action". Orders and vault transfers "are delayed onchain for a few seconds". **Nothing** says CoreWriter actions
  count against the address limit or the 50k cap. Those actions are paid in EVM gas and enter HyperCore from the EVM
  block, not through the API.
- `exchange-endpoint.md:1011-1015`: `reserveRequestWeight` exists (0.0005 USDC per request). It is **not in the SDK**
  (`evidence/hl-sdk/exchange.py` has no `reserve` method), so whether an agent can sign it is unknown. This premise does
  not matter much: about 40k USDC of wash volume (≈ 18 USDC in fees) buys the same allowance.
- PM entry needs "account value > $10k or > $5M weighted volume" (`trading_portfolio-margin.md:13-15`). Unified has no
  stated requirement, and the cap applies to both modes, so K11 does not hinge on PM eligibility.

**Why the worse reading is speculative and, even if true, does not deliver the stated loss:**

1. **Three premises are undocumented.** (a) CoreWriter action 9 counts against the account's 50k/day. (b) Exceeding the
   cap rejects actions instead of reverting the account to standard behaviour (compare "Portfolio margin accounts will
   fall back to non-portfolio margin behavior when caps are hit", `trading_portfolio-margin.md:13`, which is the only
   cap behaviour HL documents in this area). (c) The window ends at 00:00 UTC.
2. **The loss K11 quotes does not depend on the revoke landing.**
   - K11 claims one K03 round inside the freeze (~1.1k / 11k / 110k). That settle happens whether or not the revoke
     lands: a revoke has never blocked a settle (`VaultLogic.settle` has no agent check; XA01 PoC).
   - What *does* stop the mint is `triggerBreach` / `triggerEmergency`. They are pure HyperEVM state changes (`hardStop`
     → `settle` reverts unless emergency; an emergency settle refunds deposits). No HL action is involved, so no HL
     quota can block them.
   - The frozen agent cannot act either: K11 says so itself.
3. **The residual worth keeping is on the worse reading only:**
   - Core-side liveness: CoreWriter `usdClassTransfer`, `sendAsset` and flatten orders would be rejected too, so
     redemptions cannot be funded from Core for up to a day, possibly repeatable daily.
   - A race at the reset: the agent, still approved on Core if the revoke was dropped, acts before the sentinel
     re-revokes (FOREIGN_AGENT is read every 10 min for served vaults).
   - That is Medium at most (temporary lock with an exit at the next window, no theft beyond R-1).
   - **To settle it:** a testnet experiment (unified-mode account, burn 50k actions, then send CoreWriter action 9 and
     check `extraAgents`). It is not provable here without sending transactions.

### HLR2-K10 → Low

- The "forever" claim:
  - It is true that the vault never emits action 16 (`hypercore/HyperCore.sol`: no setAbstraction helper).
  - But `agentSetAbstraction` is agent-signable (SDK `exchange.py:1166-1172`), so the replacement platform agent, set
    through the 2-day timelock, restores the mode.
  - The timelock on `setAgent` is the deliberate H-01 fix (REPORT H-01).
  - The same 2-day gap applies to USDC parked on another dex, a subaccount or an HL vault: nothing in the vault recovers
    any of them without an agent.
- The harm during the gap: redemption-only or exit settles priced at min(NAV, checkpoint) under-pay redeemers who exit
  in that window. That is bounded, and at the depositor's choice. Low.
- The PoC demonstrates only `setAgent` being `onlySelf`.

### HLR2-K04 / K06 / K07 → restated

- **K04.** REAUDIT2.md:191 ("A compromised sentinel is a denial of service: it can re-breach every hour") and :380 (hot
  keys are risk-reducing, compromise = DoS). There is an exit: an overdue epoch lets anyone `triggerEmergency` with
  redemptions pending (`VaultGovernance.sol:244-246`).
- **K06.** The theft half equals HLO-07 (hl-open REVIEW.md:85, Medium). The rotation half is the single-EOA cold key
  already tracked by the guardian-to-Safe runbook. Not High: no theft from an existing vault without a launch plus a
  depositor.
- **K07.** N2-03 (REAUDIT2.md:251), with the hard cap now 3%.

### HLR2-X01 → Medium (mechanism confirmed, magnitude overstated)

**Guards that would stop a re-open, checked and absent:**

- The planner's book (`copy/engine.ts:711-722`) uses `account.positions` in LIVE. Tickets feed only the `managed` set.
- The processor's mirror path (`engine/processor.ts:805-1000`) reads the account at `order` priority, fresh, but uses it
  only for `guardOrder` leverage and margin, capped at 85% of max leverage.
- The opposite-ticket check blocks only the opposite side. A same-side `mine` ticket is topped up, not refused.
- Cloid = `MIRROR:<runId>:<kind>` with a per-run id, so it cannot dedupe across runs.
- Nothing invalidates `prefetched` after an order (no `invalidate` in `copy/` or `venues/hl/`).

**Staleness in production is ≤ ~15 s, not 60 s:**

- `RiskWatcher.runOnce` prefetches every served vault, copy included (`main.ts:480`), every `RISK_WATCH_MS` = 15 s
  (`env.ts:354`; `risk/watcher.ts:371`) into the same `prefetched` map as the monitor.
- Each write replaces the value with a fresh read, so the snapshot's age is bounded by the most frequent writer.
- The PoC's "4 opens in 45 s" assumes only the monitor's 60 s prefetch. Under XA-A2 the realistic duplicates come from
  multi-event source fills a few seconds apart: the PoC's 3x for 3 websocket events still holds. A 15 s reconcile tick
  then races the 15 s refresh.

**Severity.**

- The worst exposure is bounded by the on-chain policy the depositor accepted: 85% of `maxLeverageBps`, plus the daily /
  drawdown breakers.
- No theft. No copy vault is live.
- The unwind overshoot and re-open can repeat (fees and slippage per cycle), but at ≤ 15 s staleness a cycle needs a
  fresh source event.

Medium. The fix in EXECUTOR.md is right: read `book()` fresh, and invalidate the prefetch for a vault after any order on
it.

### HLR2-X02 → Low

The mechanism is confirmed: `onMids` estimates from the round's prefetch, and nothing drops the book after an action.
The cost is bounded and one-directional: it closes more than intended, at taker fee plus slippage. In the PoC's case the
excess 34% of a 2.8x book costs about 0.1 to 0.4% of equity. It happens only when the trim line is crossed, and it
lowers risk. Low.

### HLR2-X03 / X04 / X06 / X07 / X08 / X09 → stand

Each was checked against the cited lines, and every PoC passes.

- **X03.** The window is wider than stated: an orderStatus that *succeeds* but answers "unknown" for an order HL has not
  yet indexed also takes the `!state.known → null` path. Hyperliquid answers within seconds, and the first status read
  comes only 300 ms after the throw.
- **X04.** Today's impact is one hosted vault, the platform vault, which only drops its own signal. The cross-vault part grows with
  the number of hosted vaults.

### HLR2-X05 (+ K12) → Medium

**Consistency with K12.** Both say the abstraction switch shows only as NAV_MOVE (alert) plus a `checkRisk`. X05 adds
`vaultTransfer`, `subAccountTransfer`, spot buys, other-dex moves masked by an inflow, and dribbles. No contradiction:
merge.

**Why not High:**

1. The total-loss path does not depend on the monitor. One `vaultTransfer` (or `agentSendAsset`) of 100% is one HL
   action. It lands before the next 60 s look, and after a revoke nothing recovers an HL-vault deposit until a new agent
   is set through the 2-day timelock. By then the attacker-led HL vault has been traded out. That is D-1 / D-5 itself
   (REAUDIT:187: "any trade on every served vault; value moved by wash trades or agentSendAsset").
2. Where a revoke would help (stopping a slow drain), a 9%/min drain is a choice the attacker would not make when a
   one-shot is available.

**What is new and real:** I3-01 lists the monitor ACT as a required mitigation of the R-1 residual, and its coverage is
far narrower than the agent's power. With XA01 it bounds nothing. Medium: a broken mitigation, with the conditional loss
already accepted.

## New items

### HLR2-XA01 (Medium): the monitor's ACT is revoke-only; the scheduled settle still mints at the deflated NAV

**Code.**

- `monitor.ts` `react`: an ACT finding sends `checkRisk` then `actions.revokeAgent`, which is `sentinelAction(v,
  "revokeAgent")` (`main.ts:1532`).
- `HyperVault.revokeAgent` → `VaultLogic.revokeAgent` sets no breach. Only `_stop` (triggerBreach / triggerEmergency)
  sets `hardStop` (`VaultGovernance.sol:234-240`).
- `VaultLogic.settle` has no agent check.
- The operator (`treasury/operator.ts:121-205`) settles a due epoch from epoch facts and breach flags only, never from
  monitor findings.

**Scenario (PoC `XreviewA.t.sol::test_HLR2_XA01_revokeOnlyActStillLetsTheKeeperSettleAtTheDeflatedNav`).**

1. A stolen agent `agentSendAsset`s 19.9% of a 100k vault with the platform vault's policy to another dex. This is the one deflation the
   monitor *does* ACT on (OTHER_DEX from own).
2. A sybil queues 100k.
3. The sentinel revokes within a minute.
4. The keeper refreshes the checkpoint and settles on schedule: no revert, deposit priced at 80.1%.
5. The owner's replacement agent (2-day timelock) moves the parked USDC home.
6. The sybil's 100k is worth 111,049.54 USDC: **+1104 bps**. The honest holder loses the same.

Control `test_HLR2_XA01_control_triggerBreachBlocksTheSettle`: the same detection answered with the sentinel's
`triggerBreach` makes the keeper's `settle` revert `ReduceOnlyMode`.

**Impact x likelihood.**

- Impact: the R-1 bound (≈ 11% of honest value per settle at 1:1). The point is that the ACT path detects the attack and
  still does not prevent it.
- Likelihood: low, since it needs a stolen platform agent (accepted D-1 / D-5). But this is the mitigation I3-01 relies
  on, so Medium as a broken mitigation, with no live exposure beyond R-1 (the platform vault holds ~171 USDC).

**Fix (describe).** Pick one or more:

- Make the monitor's ACT a `triggerBreach` (sentinel power; the guardian clears it after review).
- Have the operator refuse a deposit-pricing settle while any ACT or NAV_MOVE finding is open, or the agent was revoked
  in the running epoch. Settle redemption-only instead (not possible from outside a loss breach today, so the breach
  route is simpler).
- Contract side (round 2): a revoke during the epoch marks it redemption-only.

### Agent-key extraction pass (no new finding)

Checked:

- `tenants/registry.ts:245-256`: decrypt, then an address match against the reserved agent.
- `engine/processor.ts:270-300`: `configFor` whitelists fields and never copies `agentKey` into the stored config.
- `app.ts`: no route serialises a `StrategyConfig`.
- Log calls passing whole strategy or config objects: none found by pattern.

One defensive note, with no path found: `logger.ts:9-10` redacts `*.privateKey` and `*.key` but not `*.agentKey` or
`*.encryptedKey`, and `alerts/sanitize.ts` scrubs URLs, not 64-hex strings. A future `log.info({ cfg })` would leak an
agent key. Info, no PoC. Not filed as an XA item.

## Duplicates and restated risks (summary for the lead)

- K03 = REAUDIT R-1 / I3-01 (numbers = hl-open HLO-07 PoC).
- K04 = REAUDIT2:191, :380.
- K06 = HLO-07.
- K07 = N2-03.
- K12 ⊂ X05.
- K10 is the generic post-revoke 2-day gap from the H-01 timelock.
- X07 is the fairness half of HLO-E02.
- X06 answers hl-open open question 2.

## Files

- `contracts/audit/hl-r2/XREVIEW-A.md` (this file)
- `contracts/test/audit/hl-r2/xreview/XreviewA.t.sol` (2 tests, pass)
