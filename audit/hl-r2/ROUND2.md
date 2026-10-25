# Hyperliquid contracts: internal review, round 2 (hl-r2)

**This is an internal, AI-assisted review. It is not an independent audit and must not be presented as one.**

Branch `audit/hl-r2` from `origin/main` 4ec6feb, run 2026-10-19 to 2026-10-21. Nothing deployed, no transaction
sent, nothing pushed or merged to main. `contracts/src` and `server/src` are unchanged on this branch: every fix is a
patch file, proven in throwaway worktrees (A4).

## 1. On your phone

- **Can value leave a vault other than by trading, a fair redemption, or capped fees?**
  - **On chain: no.** Money only moves to the vault's own Core account, back to EVM, or to a redeemer. There is no
    arbitrary call, no foreign destination, no leftover approval, and the live bytecode matches the source
    (FUND-FLOW.md).
  - **The real exposures are three:**
    - **Timing traps:** a rule change can apply before a depositor can get out (H01).
    - **Pricing at a wrong NAV:** stale or short NAV at an exit settle (E01, A08) or at a deposit (K03, A02).
    - **The trading key's off-chain powers:** the Hyperliquid API wallet bypasses the policy (X05, D-1).
- **Findings:**
  - **High (2):**
    - **H01, the timelock trap:** ALERT, shared fix with Gains GR2-CFG-01, proven.
    - **A08, new and conditional:** an exit settle at a short NAV burns redeemers for about 0. Fixed on 2026-10-21
      (`fixes/patches/a-series/`): settles wait while a late transfer leaves the NAV short, for at most a day. Proven on
      the fix tests and the one-job full suite (887 pass, only superseded PoCs fail). The executor half and the
      supply-0 rule (a late arrival at supply 0 goes to the guardian, not the next depositor) are patched too.
  - **Medium (18):** all 18 have a patch, proven on the one-job full suite.
- **Live today: nothing is exploitable.** You closed open launch (both factories read `openLaunch = false`,
  2026-10-20 14:02 UTC). The only HL money is the platform vault (about 171 USDC, platform-owned) and about 1 USDC in the
  round 3 test vaults.
- **Fix round, all patches stacked:**
  - **Contracts (with the A-series, 2026-10-21):** 887 pass, 28 skip. The 25 failures are exactly the old PoCs of
    fixed bugs. 56/56 fix tests pass.
  - **Executor:** 89/89 fix tests pass, the 461 touched tests pass, and tsc is clean. With the A-series executor
    patch: 9 new tests pass, and 988 of the server's 1,002 tests (§7 lists the 4 failures and why).
  - **HL proxy:** agent orders go through the contract under VaultPolicy, the API wallet is removed, and the account
    mode is pinned. It costs about 2 s extra per order on mainnet, under 0.01 USD a day on the platform vault and 2–32 USD a day
    on a 1M vault.
  - **Gains `openTrade`:** depth cap, turnover budget, minimum hold and loss gate. The GR2-KEY-01 PoC now fails.
- **Mutation score:** 81.2% before, 98.9% with the 85 new tests. 51 past fixes checked; 4 had no test that caught
  their revert, and now do.
- **Before deploying the fix round, decide:**
  1. the behaviour changes listed in §6;
  2. that live vaults stay on the old code: clones cannot be upgraded, so the fix needs new factories and a platform vault
     migration;
  3. the guardian to a Safe (one cold EOA is today the owner of both factories and the guardian of every vault).

## 2. Summary table

Severity per the scale in `notes/CONTEXT.md`. "Proven" = the patch and fix test pass in a throwaway, the original
PoC fails with the patch, and the rest of the suite stays green (`fixes/results/`).

| ID | Finding | Sev | Fix | Status |
|---|---|---|---|---|
| HLR2-H01 | Policy loosening (2 d) applies before a redeemer can force an exit (7–30 d); the loosening can push the deadline itself | **High** (ALERT; live precondition removed) | exit-before-effect: stored epoch deadline + eta ≥ epoch + 1 d (`fixes/EXIT-BEFORE-EFFECT.md`), same patch pattern for Gains GR2-CFG-01/02 | proven |
| HLR2-A08 | Exit-only settle at a short NAV (bridge home written off after 300 blocks) burns every redeemer for ≈0; the late arrival goes to the next depositor | **High** (conditional, low likelihood) | no settle (exits included) and no bridge while the transfer is late past 300 blocks, HyperCore shows it missing in PnL-free cash (latched by the first sync) **and** the NAV reads short by at least half of it; at most 86,400 blocks (about a day); guardian `writeOffBridge()`; strict EVM->Core landing signal (spot **and** spot + perp cash) (`fixes/patches/a-series/`) | **proven on fix tests + the one-job full suite (887 pass; the 25 failures are all superseded PoCs; fix tests 56/56)** (alice paid 100,000.83 instead of 0); executor half and the supply-0 rule patched (`patches/a-series/`) |
| HLR2-E01 (+XB01) | Exit-only settles pay at min(NAV, checkpoint) with no bound on the checkpoint's age; an instant epoch tightening opens that price | Medium | `CheckpointBehind` + executor walks the checkpoint (XF-04) | proven |
| HLR2-E06 | An owner's full stop blocks every settle for up to the epoch | Medium | owner stop = redemption-only; `platformHold` only for guardian/sentinel | proven |
| HLR2-H04 | In emergency the manager chains bridges so the exit settle only lands if first in a block | Medium | 330-block bridge cooldown in emergency (XF01 version) + executor tip | proven |
| HLO-07 | Leaked registrar key binds a self-held agent on a new vault | Medium | 24 h agent warm-up with veto | proven (the automatic veto is not built) |
| HLR2-XA01 | A monitor revoke does not stop the keeper's settle at the deflated NAV | Medium | `depositHold` on platform revoke; ACT = revoke on new vaults (XF-03) | proven |
| HLR2-XF-01 | Regression of the first H04 fix: exits needed a platform key forever | Medium | cooldown design above | proven |
| HLR2-XF-03 | Regression: the monitor's ACT as `triggerBreach` froze exits under E06 | Medium | revoke first, breach fallback; no settle hold under `depositHold` | proven |
| HLR2-XF-04 | Keeper sends no `checkRisk` in emergency, so E01 settles revert | Medium | `checkRisk` in emergency / stop / overdue, retry on `CheckpointBehind` | proven |
| HLR2-XF-05 | Planner never settles an owner stop; counts held deposits as cash | Medium | planner reads `platformHold` / `depositHold` (server + webapp copy) | proven |
| HLR2-XF-06 | UNEXPLAINED_OUTFLOW sums read noise, so it fires on an honest vault in ~20 h | Medium (worse reading) | net rises against drops | proven |
| HLR2-X01 | Copy mirror sizes from a stale account: duplicate opens, missed closes | Medium (not live) | fresh read on the order lane | proven |
| HLR2-X03 | Lost submit answer + unreadable status sends a second order | Medium | GR1-05 rule for HL: re-read, never a new cloid | proven |
| HLR2-X04 | Hosted fan-out stops at the first tenant whose guard read throws | Medium (Low today) | per-tenant isolation | proven |
| HLR2-X05 (+K12) | Agent-only value moves never ACT | Medium | UNEXPLAINED_OUTFLOW ACT; root fix = HL proxy | proven |
| HLR2-X07 | One FIFO "order" weight tier for every vault | Medium | least-served first; per owner (XF-08) | proven |
| HLR2-H06 | Sybil spam vault exhausts shared operator/fee gas budgets | Medium | per-vault and per-owner budgets | proven (counters in memory) |
| GUARDIAN ALERT (decision c, XB02) | No alert on queued loosening / timelock lowering / `OperatorSet(0)` | Low (XB02), owner request | `chain/governanceAlerts.ts` + runbook | proven |
| HLR2-A01 | A dropped burn approval leaves the agent live on Core through a full stop; no retry | Medium | the revoke always re-sends the burn, also with the agent already 0; `AgentRevokeResent` event (`fixes/patches/a-series/`) | **proven on fix tests + the one-job full suite (887 pass; the 25 failures are all superseded PoCs; fix tests 56/56)**; the sentinel re-sends a dropped revoke (executor patch); the HL proxy removes the API wallet on new vaults |
| HLR2-A02 | A transfer landing after 300 blocks is written off; settles price at the deflated NAV | Medium (low likelihood) | the A08 hold (`fixes/patches/a-series/`) | **proven on fix tests + the one-job full suite (887 pass; the 25 failures are all superseded PoCs; fix tests 56/56)** (carol 84,999.99 for 85k instead of 92,500) |
| HLO-02 / 03 / 06 / 08 | earlier open items | Low | HLO-DEFERRED.md | confirmed, not patched |
| HLR2-X02, X06, X08, H03, E02, E03, E07, L01, L02, F01, F02, K10, A03, A04, A05, XF-02, XF-07, XF-08 | see the domain reports | Low | XF-02 / XF-07 / XF-08 proven; the rest are described | — |
| HLR2-M01–M09 | Test gaps found by mutation (rescueToken, bridge trackers, exit pricing, depositor guards, governance negatives, 4 past fixes) | Low | the 85 kill tests in `test/audit/hl-r2/mut/` | done (tests in the suite) |
| HLR2-K03 | Agent deflation priced into a non-insider deposit | Design (= R-1 / I3-01) | HL proxy (NAV only moves by real trading) | proven for new vaults |
| Info | X09, E04/05/08/09, F03–F05, F07, F08, XB03, XB04, A06, A07, KN01, KN02, HAL01, M10–M12 | Info | — | — |
| Open questions | H05 (agent-address pre-emption), K11 (stolen agent blocks its revocation ≤ 24 h) | ≤ Medium if confirmed | the HL proxy removes the API wallet, which closes both for new vaults | undocumented HL behaviour (A3) |

Earlier items: HLO-02 Low, HLO-03 Low, HLO-06 Low (Design), HLO-07 Medium (the creator co-sign fix does not work;
commit-then-veto does), HLO-08 Low (process). hl-open questions 1–7: `HLO-OPEN-QUESTIONS.md`.

## 3. Findings in detail

Each finding is written up in full in its domain report: location, scenario with numbers, PoC, impact ×
likelihood, fix.

| Domain (brief §) | Report |
|---|---|
| 3.1 fund flow, encodings | FUND-FLOW.md, COREWRITER-ENCODING.md |
| 3.2 async | ASYNC.md |
| 3.3 conservation, Medusa, sensitivity | INVARIANTS.md |
| 3.4 keys | KEYS.md |
| 3.5 hostile vaults, 3.6 upgrades / timelock | HOSTILE-AND-CONFIG.md |
| 3.7 multi-epoch economics | ECONOMICS.md (differential: 650 scenarios, max divergence 5.13 USDC on 50M) |
| 3.8 exit liveness | LIVENESS.md |
| 3.9 executor | EXECUTOR.md |
| 3.10 mutation, past fixes, Halmos | MUTATION.md, PAST-FIXES.md, HALMOS.md |
| §4 static analysis | STATIC.md (Slither: 155 results triaged; Aderyn has no Windows build) |
| §5 challenges | XREVIEW-A.md, XREVIEW-B.md, fixes/XREVIEW-FIXES.md |
| Known exploit classes | KNOWN-EXPLOITS.md |
| HLO items | HLO-DEFERRED.md, HLO-OPEN-QUESTIONS.md |

The fixes are in `fixes/`:
- EXIT-BEFORE-EFFECT.md;
- CONTRACT-MEDIUMS.md and EXECUTOR-MEDIUMS.md;
- INTEGRATION.md, the stacked patches in `integrated/`;
- HL-PROXY.md and GAINS-OPENTRADE.md;
- XREVIEW-FIXES.md.

PoCs are in `contracts/test/audit/hl-r2/`.

## 4. Per-key worst case (today's code, from KEYS.md §(c); "after the fix round" = with the integrated patches + HL proxy)

| Key (stolen) | Worst case today (1M vault) | Reach | After the fix round |
|---|---|---|---|
| Vault agent (API wallet) | ~110k per settle by deflation (K03), up to the whole vault by vaultTransfer / sendAsset / wash trading before a revoke (X05) | its own vault | no API wallet: trades curated perps within the policy until the daily loss / drawdown gate; reduce-only and cancels |
| Operator / keeper | 0 direct; enables K03 together with an agent | all it operates | same; emergency exits no longer need it (XF01) |
| Sentinel (hot) | 0 theft; DoS of all factory vaults (full stop) | all factory vaults | an ACT now revokes instead of a full stop; a sentinel full stop still freezes settles (`platformHold`) until the guardian clears |
| Registrar (hot) | ~110k+ per settle via a self-agent on a new vault (HLO-07) | new vaults | 24 h warm-up with veto; the veto needs the alert to be watched |
| Manager | insider path, deferred deposits; ~110k-class per settle with a sybil | its own vault | + loss gate on orders |
| Vault owner | new agent after 2 d; with an agent, full C-01; loosening trap (H01) | its own vault | every widening waits epoch + 1 d; the owner's stop pays redeemers |
| Guardian (cold EOA) | ≤ 3% per flatten; DoS via emergency | all factory vaults | same (XF-02 caps the band in breach) |
| Factory owner (same cold EOA) | rotates every role + HLO-07 theft on a new vault | all factory vaults | same until the guardian-to-Safe runbook is executed |

Today owner = guardian = factory owner is one EOA `0x1A7a…D7ff`, the largest single blast radius.

## 5. Checked and sound (with the test)

- **Fund flow:**
  - no path sends USDC or shares outside the vault, its own Core account or a redeemer;
  - exact approvals only;
  - all 12 deployed contracts match the source byte for byte;
  - FUND-FLOW.md, `test/audit/hl-r2/flow/`.
- **CoreWriter encodings** (actions 1, 7, 9, 10, 13): byte for byte against the docs, and A-07 checked on mainnet.
  COREWRITER-ENCODING.md.
- **Known classes not exposed:**
  - **Share inflation:** a 1M donation cannot steal the second depositor's funds (`test_KNOWN_01`).
  - **Reentrancy:** `test_KNOWN_03a/b`.
  - **Rounding:** existing fuzz.
  - **Access control:** 53 privileged calls refuse a stranger (`test_KNOWN_07`).
  - **Arbitrary call / approvals:** `test/audit/hl-r2/flow/`.
  - **Clone initialisation / self-destruct:** `test_KNOWN_09a/b`.
  - **Signature replay:** across chains and factories, high-s (`test_KNOWN_10`).
- **Conservation:**
  - invariant campaigns at 2,048 × 500 pass, after A08 and the A04 classifier fix (INVARIANTS.md);
  - Medusa run 2 passes all 6 properties over 3 h (8.4M calls).
- **Proved by Halmos** (also re-proved on the integrated fix source):
  - the checkpoint ratchet (P1), the settle bound (P2), and that an honest in-band move always settles (P3);
  - request / cancel conservation on the real vault (V3–V5);
  - `toSigFigs5` for 6-digit prices.
- **Past fixes:** all 51 closing tests exist and pass, and every revert is caught (PAST-FIXES.md).
- **Economics:** the differential model agrees within 5.13 USDC on 50M NAV over 37,823 epochs (ECONOMICS.md).

## 6. Fix round: what it changes (owner approval needed)

1. **Rule changes wait longer.** Every change that widens exposure waits max(timelock, epoch + 1 day). For example,
   a fee raise or new agent on a 7-day-epoch vault waits 8 days. Each epoch's deadline is fixed at its start.
2. **An owner's full stop pays redeemers** (redemption-only). Only a guardian or sentinel stop freezes settles.
3. **Platform revoke of a key puts deposits on hold** until the guardian clears. Withdrawals keep settling.
4. **New vaults with a platform agent take deposits 24 h after launch.**
5. **Exit settles can wait** for the checkpoint walk: 1 h at the platform vault's 20% band, up to 14 h at the 5% floor.
6. **In emergency, bridges have a 330-block cooldown.** The executor bridges from the sentinel key, with a tip.
7. **HL proxy:**
   - no API wallet; agent orders go through `placeOrder` (IOC only), a pre-trade `checkRisk` and the account-mode
     pin;
   - about 2 s extra per order today (0.6 s with a leaner sender);
   - older vaults keep the API path behind `HL_LEGACY_API_ORDERS`.
8. **Gains:**
   - 5% skew-depth cap per pair;
   - opens up to 20 × NAV per day;
   - profitable manager / agent closes held for 790 L2 blocks on pairs where Gains' protection factor costs
     something (SOL today, not BTC / ETH);
   - loss gate inside `openTrade`.
9. **Executor:**
   - new env switches: `MONITOR_*`, `OPERATOR_HOLD_MS`, `OPERATOR_EXIT_TIP_GWEI`, `GAS_BUDGET_*`,
     `HL_LEGACY_API_ORDERS`;
   - the guardian alerts with the runbook line.
10. **Webapp and docs:** the wording and reads are listed in INTEGRATION.md §5 and the follow-up notes of each fix
    document. The webapp's `epochPlan` copy must ship with the server patch (a test checks they are identical).
11. **A transfer missing on HyperCore holds settles and bridges** (A02 / A08) for up to 86,400 blocks (about a day),
    until it lands or the guardian calls `writeOffBridge()`. **Approved by the owner 2026-10-21**, as is the seed
    bridge's exemption. The operator waits and alerts once a day, and the monitor reports `TRANSFER_UNRESOLVED`.
12. **NAV left in a vault with no shares goes to the guardian** (A08 part 3 / E01e, `HLR2-A08-SUPPLY0`). It must be
    over 10 USDC (`ORPHAN_DUST`) and the vault must have minted before. At the next first mint the leftover is minted
    to the guardian as shares, at 1 USDC per share, and the depositor is priced against it. **Needs owner approval:**
    the guardian then holds that value and returns it off chain to the redeemers it belongs to. The other choice is a
    burn address: the value stays locked, nobody can recover it, and nobody can take it either.

Deployment needs new factories (clones of immutable implementations cannot be upgraded), and the platform vault must move to a
vault from the new factory.

## 7. Open items

- **Fixes described but not proven** (the sub-reviewers stopped on an API usage limit that resets 2026-10-26):
  - HLR2-A08, A02, A01 (and A04, A05): patched 2026-10-21 (`fixes/patches/a-series/README.md`) and proven:
    15 fix tests, and the one-job full suite with Gains, the scripts and the invariant campaigns (887 pass, 28 skip,
    25 fail, all superseded PoCs; fix tests 56/56; `fixes/results/integrated-contracts.log`). The first attempt was
    rejected (`fixes/patches/a08/README.md`).
  - The "spot + rawUsd" landing signal suggested in ASYNC.md is wrong: on mainnet rawUsd moves by the notional of
    every fill (`evidence/async/rawusd-2026-10-21.txt`). The patch uses rawUsd + signed entry notional, and spot.
  - A03 stays Low (liveness, 300 blocks, agent only; gone on HL proxy vaults). The A04 residual (a perp->spot move
    plus a realised gain of the amount) is agent only too.
  - The A-series executor half is patched (`patches/a-series/HLR2-A-SERIES.executor.patch`, on the integrated
    executor stack):
    - the operator sends nothing while `bridgeUnresolved()` and alerts once a day;
    - the monitor reports `TRANSFER_UNRESOLVED` (alert only);
    - the sentinel re-sends `revokeAgent()` while the revoked agent still holds the `dojipad` slot: every 2 minutes,
      at most 5 times, then an error alert asks for a person. The XA01 settle hold applies meanwhile.
    - Proven with 9 new tests, plus tests-exec 89/89, XFIX-fix 4/4 and tsc. Whole server suite: 988 pass, 10 skip,
      4 fail. Two of the failures are `dojipad-ec` timeouts under the forge proof's load (52/52 when run alone). The
      other two, `AUDIT_M1` and `REAUDIT_HK1`, also fail on the integrated executor stack without this patch: the
      earlier fix round never updated them, and `verify-integrated.sh exec` does not run them. They must be updated
      in the fix round.
    - Residual: the monitor learns the old agent from its own looks. If it restarts between the revoke and the
      next look, it does not know the old agent and cannot retry.
    - Webapp: Manage > Do all needs a Lens field for `bridgeUnresolved()` and the regenerated ABIs (the new error
      and event). Until then it shows the `TransferUnresolved` revert.
  - A08 part 3 / E01e, NAV at supply 0, is patched (`HLR2-A08-SUPPLY0`, §6 item 12): carol's 10 USDC buys 10.00
    of value instead of the late 100,001. Proven on the one-job full suite with it (889 pass; the 25 failures are
    all superseded PoCs; fix tests 58/58; `fixes/results/integrated-contracts-s0.log`). Residual: after a write-off, a late landing in a vault where fee holders
    still hold shares goes to them pro rata. The guardian accepted that loss when it wrote the transfer off.
  - The async and Medusa harnesses: the HLO-07 warm-up is in `patches/a-series/` (SimBase and the Medusa harness).
  - The automatic sentinel veto for HLO-07.
  - XF-08's reserved share for vaults with outside deposits.
  - The emergency settle when the owner has removed the platform keeper as operator.
- **Needs a testnet transaction** (outside this brief):
  - whether HL accepts action 16 from a contract, and with open positions;
  - the CoreWriter delay in big blocks;
  - EVM→Core and Core→EVM timing under load (hl-open Q1, Q7).
- **Undocumented HL behaviour (A3):** H05, K11, whether CoreWriter actions count against the request budget, and
  whether unified mode can be detected on chain.
- **Mutation:** 18 boundary mutants are documented, not killed.
- **Halmos:** the settle and claim mulDiv properties timed out or ran out of memory, so there is no symbolic proof
  of the settle math. It is covered by the invariants and kill tests M18–M21.

## 8. Test suites at the end of this branch

Run on this branch at 34a58a8, unpatched `src`, on 2026-10-21. Logs are in `results-final/`.

- **Full `forge test`** (one compiler job, Gains included, as the README does): 879 tests, 851 passed, 24 skipped,
  4 failed.
  - **The 4 failures** were this review's own coverage probes (`test_coverage` in the async suites). They need a
    raised gas limit (INVARIANTS.md §5) and hit forge's default limit of 1.07e9.
  - **The change:** the probe now runs only with `HLR2_PROBE=true`, and is skipped otherwise. With
    `HLR2_PROBE=true FOUNDRY_GAS_LIMIT=2^64-1` all 4 pass (about 4.5e9 gas each, `results-final/coverage-probe.log`).
  - **After the change:** in default mode the 4 are skipped (`coverage-default.log`), so the full suite is
    **851 passed, 0 failed, 28 skipped**.
  - **Not a fresh full run:** the full suite was not re-run end to end after this one-line test change (83 min); only
    the 4 affected tests were.
- **Executor suite** (`cd server && npm ci && npm test`): 984 tests passed, 9 skipped, 0 failed in 92 files. One file
  (`dojipad-ec.test.ts`) was reported failed because its `afterAll` hook, which stops the in-memory database, timed out
  at 10 s under machine load. Run alone, it passes 52/52 (`server-dojipad-ec-rerun.log`).
- **Fix-round stack:** the results are in §1 and `fixes/results/integrated-*`.

## 9. Caps, limits and interruptions

- **Medusa:** about 6 h 25 min in total, against the 12 h cap; the cap was not hit.
  - Run 1 stopped after 3 h 25 min on the A04-variant failure.
  - Run 2 ran its 3 h timeout and passed.
- **Mutation:** 4.24 h of lock time, against the 12 h cap; not hit. 1,748 mutants, no timeouts.
  - Runs used an unoptimized via-IR build, fuzz 64 and invariants 16×50, so the score is a lower bound.
- **Halmos:** no property reached the 2 h cap.
  - Properties stopped at the sub-reviewer's own per-property limit (≤ 40 min), not by the cap: H1, H1s, H5s, H6r,
    H6s, H7, H7d12, H7d19, H9; H8 on the integrated re-run.
  - H5r and V1 ran out of solver memory.
  - V2 was stopped by hand at 17 min (two solver processes at 13.8 GB each; the memory limit is not enforced on
    Windows).
  - H2–H4 and H7d9 were not run.
- **Invariant campaigns at 2,048 × 500:** the first two platform-vault campaigns stopped early, at run 380 (dust
  tolerance) and run 500 (A08, a real finding). The third and the Tight configuration passed in full.
- **Interruptions:**
  - The machine was off overnight on 2026-10-20 and rebooted at 12:51 UTC. All runs died, including Halmos pass C;
    about 4 h of lock time was lost. The lead released the stale lock.
  - An API overload stopped one sub-reviewer once; it was retried.
  - The account's weekly API limit stopped the async, integration and Gains sub-reviewers at about 01:00 UTC on
    2026-10-21. The lead committed their finished work from the logs.
- **Incident:** a sub-reviewer's cleanup emptied the main checkout's `server/node_modules` at about 02:43 UTC on
  2026-10-20 (a junction followed by `git worktree remove`). It was restored with `npm ci` (192 entries); no
  tracked file was touched.
- **Gains in scope:** only where the owner asked (GR2-CFG-01, `openTrade`, the gTrade side of KNOWN-EXPLOITS).

## Appendix A. Assumptions

- **A1.** The live HyperEVM bytecode equals the current `contracts/src`: there is no src commit since the round 4
  deploy, and the byte check is in FUND-FLOW.md.
- **A2.** "Exploitable on a live vault" for ALERT.md means exploitable with today's keys and configuration, without
  assuming a stolen key.
  - Stolen-key scenarios are rated in KEYS.md and listed in the table.
  - They trigger an ALERT only if the key is an online key that is already exposed in a way this review can show.
- **A3.** Hyperliquid behaviour not stated in its docs or the official SDK is unverified. A finding that depends on
  it says so and is rated on the worse reading.
- **A4.** Fixes: the brief forbids editing `contracts/src` and `server/src`.
  - Each fix is a patch file under `fixes/` plus a fix test outside `test/`.
  - It is proven by applying both in a throwaway worktree; the logs are in `fixes/results/`.
  - This branch's `src` stays unchanged and its suite stays green.
- **A5.** The order-path design input (HL proxy, Gains `openTrade`) is delivered like the other fixes.
- **A6.** Latency is measured read-only from public data. Figures that cannot be measured that way come from the HL
  docs and are marked.
- **A7.** HLR2-A08 is High but not an ALERT under A2.
  - It needs a Hyperliquid delivery delay above 300 blocks on the emergency bridge, or a stolen agent key (an
    abstraction-mode under-read), so nobody can trigger it at will.
  - No live vault holds outside deposits.

## Appendix B. Owner decisions and brief additions

- **2026-10-20, after the ALERT:**
  - **(a) Close open launch on the round 4 factory:** done by the owner. Both factories read
    `openLaunch = false` (lead's read-only check, 2026-10-20 14:02 UTC). It stays closed until the fix ships.
  - **(b) the platform vault policy timelock to 9 days:** skipped. The platform vault holds only platform money.
  - **(c) Guardian alert:** goes into the fix round (patched: `governanceAlerts.ts`).
- **The owner's requests:**
  - one fix pattern for H01 and GR2-CFG-01, delivered as EXIT-BEFORE-EFFECT;
  - an exact fix and a proving test for every High and Medium. A08, A01, A02: proven on fix tests, the near-full suite and the one-job full suite (2026-10-21).
- **Brief addition, KNOWN-EXPLOITS.md** (merged 320dbc3):
  - **HL, 21 classes:** 4 exposed, 10 partly, 7 not exposed.
  - **Gains, 18 rows:** 3 exposed, 6 partly, 9 not exposed.
  - Two new Info findings (KN01, KN02); no new ALERT. The seed-list corrections are in the deliverable.
- **2026-10-21, after the A-series patch:**
  - the hold of up to a day for a missing transfer, which the guardian can end with `writeOffBridge()`: approved;
  - the seed bridge's exemption from the hold: approved;
  - added to the fix list: the executor half (the operator skips settles while a transfer is unresolved, the
    sentinel retries the revoke) and the first mint into a vault with no shares. Both were patched on this branch
    (§7), and the recipient of the supply-0 rule is still for the owner to approve (§6 item 12);
  - the action 16 testnet check: approved, for the fix round's verification step, not this branch.
- **Brief addition, order-path design input** (HL proxy, Gains `openTrade`): HL-PROXY.md and GAINS-OPENTRADE.md.
  Every design claim was checked in code. The verdict tables are in each document.
