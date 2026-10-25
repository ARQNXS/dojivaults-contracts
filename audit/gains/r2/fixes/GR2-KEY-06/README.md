# GR2-KEY-06 (and GR2-ECON-02, GR2-CFG-02) fix: no stale or dip checkpoint prices an exit; epoch deadline fixed at its start

**Internal, AI-assisted review. Not an independent audit.** Proposed patch for the fix round; nothing in
`contracts/src` was changed. Patch against 4ec6feb, applies with `git apply` from the repo root (checked with
`git apply --check` on the worktree).

## The problem in one line

Exit-only and redemption-only settles pay at `min(NAV, checkpoint)`. Anyone can set the checkpoint at a dip
(`checkRisk`), nobody can raise it for an hour, and a key that chooses the settle moment (guardian or owner through an
emergency, owner through an instant `maxEpochDuration` tightening, sentinel through a forced emergency) pays the
redeemers the dip after the market came back (XR-01..04: 4,990 USDC of a 50k redemption).

## Why min(NAV, checkpoint) exists, and what must be kept

Audit C-01 / REAUDIT3 question (a): "a NAV pushed up inside the per-settle bound is never paid out in a loss breach".
The cap protects the holders who stay from an inflated reading. Two facts decide the design:

1. Against a **stale** checkpoint (older than `CHECKPOINT_INTERVAL`, 1 h) the protection is already void in 4ec6feb:
   anyone can call `checkRisk` right before the settle, which ratchets the checkpoint up to `maxNavMoveBps` toward the
   live NAV, and the settle then pays that. Using "the ratchet the checkpoint would take now" as the cap therefore
   removes only the stale-low case and lets nothing through that a `checkRisk` could not already let through.
2. Against a **fresh** checkpoint the protection is real: nobody can move it inside the hour. But a fresh checkpoint
   is exactly what the attack sets at the dip. A NAV reading alone cannot tell a pump from a rebound, so the cap must
   not go below a level the vault had confirmed within the same interval. The patch keeps, for one interval, the value
   the last ratchet replaced (`priorCheckpointNav`) and caps at `max(checkpointNav, priorCheckpointNav)`.

Resulting rule (`GainsVaultMath.redemptionCap`, used by exit-only and redemption-only settles, `emergencyFillBps`,
the vault view `redemptionNav()` and the lens previews):

| Checkpoint | Cap | Effect |
|---|---|---|
| Fresh (`checkRisk` may not move it yet) | `max(checkpoint, value its last ratchet replaced)` | A dip checkpoint does not price the redemption at the dip; a NAV above both values is still never paid (C-01 kept) |
| Stale | what `checkRisk` would ratchet it to at this NAV (at most `maxNavMoveBps` toward it) | Same as 4ec6feb plus a `checkRisk` first; a stale low checkpoint is no cap |
| None (0) | NAV | unchanged |

A settle sets `priorCheckpointNav` to its own post-flow checkpoint (a new NAV scale), so the prior value never spans a
settle.

**Epoch deadline fixed at the epoch's start.** `epochDeadline = epochStartedAt + maxEpochDuration` is stored when the
epoch starts (initialize, every settle); `epochOverdue()` reads it. Choice among the brief's options:

- *Timelock maxEpochDuration reductions*: delays a protective change (a shorter epoch is the depositors' faster forced
  exit) by the full policy timelock, and still lets the reduction make a running epoch overdue the moment it applies.
- *Floor* `maxEpochDuration` (e.g. 1 day): removes a legitimate configuration and does not address CFG-02.
- *Deadline fixed at epoch start* (chosen): the tightening stays instant in the policy but applies from the next epoch,
  so the owner cannot make the running epoch overdue at will (XR-03's route is refused: `Unauthorized`); a loosening
  that raises the epoch cannot lift an overdue epoch either, which closes GR2-CFG-02 with the same change; and
  `epochOverdue` no longer makes an external call to the policy. It mirrors the existing rule that a performance fee
  raise applies from the next epoch (N2-02). In the next epoch the owner of a 1 h epoch can still settle exit-only
  after the hour, but with the cap rule above that settle pays the live NAV (fix test `XR03_nextEpoch...`).

## What changes (`fix.diff`)

| File | Change |
|---|---|
| `GainsTypes.sol` | `VaultStorage` gets two fields at the end: `uint192 priorCheckpointNav`, `uint64 epochDeadline` (new implementation; clones of 4ec6feb are not upgradeable, so no layout migration is involved) |
| `GainsVaultMath.sol` | `epochOverdue` reads `epochDeadline`; new `startEpoch`, `redemptionCap`; `emergencyFillBps` uses the cap |
| `GainsVaultLogic.sol` | settle: exit-only and redemption-only price at `redemptionCap`; `_checkpoint` keeps the replaced value; `_setCheckpoint` resets it; `startEpoch` at settle |
| `GainsVaultGovernance.sol` | `initialize` calls `startEpoch` |
| `GainsVault.sol` | views `priorCheckpointNav()`, `redemptionNav()`, `epochDeadline()` |
| `GainsVaultLens.sol` | `_postFeeRedeem` and `previewEmergencyRedeem` use `redemptionNav()`; `epochOverdue` / `status` use `epochDeadline()` |

## Side effects and residuals

- **Residual (documented):** a dip that lasts at least one full interval and is checkpointed twice (≥ 1 h apart) caps
  redemptions at the dip until the next ratchet, i.e. the checkpoint still lags a rebound by up to an hour after a
  sustained dip. This is REAUDIT3's accepted lag; it no longer needs only one transaction at the attacker's moment.
- **Weakening of C-01 (bounded):** inside the hour after a downward ratchet, a NAV pushed back up to the replaced value
  is paid. The overpayment is at most the last ratchet's step (≤ `maxNavMoveBps`, 20 % live) and only up to a level
  the vault itself had at a checkpoint one interval earlier, never above it. The C-01 regression tests
  (`GainsRound4.t.sol::test_D1_redemptionOnlyPaysAtMinOfNavAndCheckpoint`, `test_D4_C01_noMintAtADeflatedNav`) pass.
  In the fix test's pump case the payout is the settle-time checkpoint (100k NAV level), 0.8 % above the post-open
  checkpoint (99.2k), never the pumped NAV.
- `redemptionShortfall` (operator reduce cap) still prices pending redemptions at the raw checkpoint: conservative
  (smaller reduce), left as is.
- Executor / webapp: read `epochDeadline()` instead of `epochStartedAt + maxEpochDuration` (the lens does).
- Alerts still recommended: `EmergencyTriggered`, `ConfigApplied` that shortens the epoch, `checkRisk` sent by a role
  key outside the keeper.

## Fix test

`FixTest.t.sol` (`KEY06FixTest`, runs from `contracts/test/audit/gains/r2/fixes/`). Same market path as
`XReviewKey.t.sol` (100k vault, thief 50k, victim 50k redeeming, 4x ETH long, ETH −2.5 % then a full rebound inside
the hour).

| Test | Asserts | Unfixed | Fixed |
|---|---|---|---|
| `test_KEY06_fix_XR01_guardianEmergencyAtTheRebound_movesNothing` | victim and thief equal the normal settle (±1 USDC) | FAIL (victim −4,990) | PASS |
| `test_KEY06_fix_XR02_ownerManagerEmergencyAtTheRebound_movesNothing` | same, owner == manager | FAIL (−4,990) | PASS |
| `test_KEY06_fix_XR03_epochTighteningAppliesFromTheNextEpoch` | owner's exit-only settle after the instant 1 h tightening: `Unauthorized`; treasury settle pays live NAV | FAIL (no revert) | PASS |
| `test_KEY06_fix_XR03_nextEpochExitOnlyAtTheRebound_movesNothing` | in the 1 h epoch that follows, the owner's overdue exit-only settle after a dip checkpoint pays the normal settle's amount | FAIL (−4,990) | PASS |
| `test_KEY06_fix_XR04_sentinelForcedEmergencyAtTheRebound_paysLiveNav` | sentinel full stop → overdue → stranger's emergency → owner's settle pays the live NAV after the sentinel's dip checkpoint | FAIL (44,610 vs 49,600) | PASS |
| `test_KEY06_fix_ECON02_staleLowCheckpointIsNotACap` | a 2 h old dip checkpoint does not cap the exit-only payout | FAIL (44,610 vs 49,600) | PASS |
| `test_KEY06_fix_C01_pumpAboveTheFreshCheckpointIsStillCapped` | +10 % NAV above both checkpoints of the interval: paid at the higher checkpoint, ≥ 3,000 USDC below the live NAV share | FAIL (paid the lower checkpoint, 49,600 vs 50,000; the C-01 half holds on both) | PASS |
| `test_KEY06_fix_lensPreviewMatchesTheExitOnlyPayout` | `previewEmergencyRedeem` = payout | PASS | PASS |
| `test_KEY06_fix_CFG02_epochRaiseDoesNotLiftAnOverdueEpoch` | E 1 d → 30 d applied while overdue: still overdue, a stranger's `triggerEmergency` works | FAIL (not overdue) | PASS |

## Existing tests

Regression run in the patched scratch tree (same 40 suites as GR2-ECON-03, 409 tests with this fix test):
**402 pass, 7 fail**; every failure is a round 2 PoC that asserts the bug and must be retired or inverted:

| Test | Why it fails now |
|---|---|
| `r2/XReviewKey.t.sol::test_GR2_XR_01_guardianKeyAlone_emergencyExitOnlyAtTheDip_movesRedeemerValueToThief` | victim paid in full (0 moved) |
| `r2/XReviewKey.t.sol::test_GR2_XR_02_ownerEqualsManagerKey_triggerEmergencyExitOnlyAtTheDip` | same |
| `r2/XReviewKey.t.sol::test_GR2_XR_03_ownerKey_instantEpochTightening_exitOnlyWithoutEmergency` | owner's settle `Unauthorized` (epoch not overdue) |
| `r2/EconPoC.t.sol::test_GR2_ECON_02_overdueExitOnlySettleByOwnerPaysTheDip` | paid at the live NAV |
| `r2/EconPoC.t.sol::test_GR2_ECON_02_redemptionOnlySettlePaysTheDipNotTheRebound` | paid at the higher checkpoint of the interval |
| `r2/XReviewEconCfg.t.sol::test_GR2_XR_ECON02_ownerEmergencyGivesTheExitOnlyDipAnyTime` | paid at the live NAV |
| `r2/ConfigTimelock.t.sol::test_GR2_CFG_02_epochRaiseInLooseningLiftsAnOverdueEpoch` | the epoch stays overdue (GR2-CFG-02 closed) |

`XReviewKey.t.sol::test_GR2_XR_04_*` (liveness only) passes. Every C-01, D1/D4, R1/R2 regression, governance and
liveness suite passes unchanged.
