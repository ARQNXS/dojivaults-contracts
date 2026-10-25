# hl-r2: liveness of exits (domain 3.8)

Internal, AI-assisted review (sub-reviewer "econ"), 2026-10-19. This is not an independent audit. Code: `contracts/src`
(not `gains/`) at the round 4 deploy sources (last src commit 2305cf2), branch `audit/hl-r2-econ`. Off-chain behaviour
quoted from `server/src/treasury/{operator,epochPlan,reduce}.ts` and `server/src/keeper.ts` on the same commit.

Tests: `contracts/test/audit/hl-r2/econ/Liveness.t.sol` (`HlR2Liveness`), `EconLate.t.sol`, `EconPoC.t.sol`. Run with
`forge test --match-path "test/audit/hl-r2/econ/*"`. Every row's test passes on the current code.

## Rule chain in one place

- `requestRedeem`, `cancelRedeemRequest`, `cancelDepositRequest`, `claim` are never gated by a breach or emergency and
  read no precompile (VaultLogic.sol:72-156).
- `settle` (VaultLogic.sol:205-326) is the only thing that turns a request into USDC:
  - reverts `ReduceOnlyMode` in a guardian-class full stop (`breachReason >= GUARDIAN`) outside emergency, **for every
    caller and every mode** (line 210);
  - normal mode: manager or operator only, outside any breach but leverage; all redemptions paid in full or the call
    reverts `InsufficientLiquidity` (line 264); NAV within `maxNavMoveBps` of a checkpoint younger than 1 day;
  - redemption-only (daily loss / drawdown breach): any listed role (owner, manager, operator, guardian, sentinel),
    no overdue needed, paid in full at min(NAV, previous checkpoint) or reverts;
  - exit-only: emergency (any listed role; partial fill + returned shares), or overdue + a non-treasury listed role
    (full liquidity needed outside emergency);
  - never inside a bridge window or while a transfer is unlanded (<= 300 blocks), and never when a NAV precompile
    (0x801, 0x80F, 0x810) reverts.
- `triggerEmergency`: owner or guardian at any time; anyone once the epoch is overdue (`epochStartedAt +
  maxEpochDuration`) with redemptions pending (VaultGovernance.sol:244-254).
- Bringing USDC home (`bridgeToEvm`): manager or operator at any time; owner / guardian / sentinel only in emergency.
  Reducing positions: the manager (`placeOrder` reduce only, `flatten`) and the guardian at any time; owner, operator
  and sentinel only in a breach or emergency (VaultLogic.sol:562-580).
- Off chain: the operator (keeper) settles once the epoch is 24 h old, brings back what redemptions need from Core free
  USDC within an 85% leverage headroom, and **never reduces positions** (that needs the manager's signed maximum,
  operator.ts:21, 197); in a guardian / sentinel breach or an emergency it **runs nothing** (epochPlan.ts:148-161), and
  the keeper sends no `checkRisk` in a full stop (risk/contractRisk.ts:253-254, keeper.ts:457). There is no automated emergency unwind and no
  emergency runbook in `docs/runbooks/` (clear-breach.md:60 refers to "other runbook", which does not exist).

Times: HyperEVM small blocks about 1 s, so the bridge window of 10 blocks is ~10 s and `MAX_UNLANDED_BLOCKS` 300 is
~5 min. The platform vault: `maxEpochDuration` 7 days, policy timelock 2 days.

## Table

| # | Condition | Who can still get out | Worst-case time (rule chain) | Test |
|---|---|---|---|---|
| 1 | Healthy, redemption covered by idle USDC | everyone | next settle: the operator settles when the epoch is 24 h old (EPOCH_DUE_SEC). If manager and operator never settle: `maxEpochDuration` (7 d), then owner / guardian / sentinel settle exit-only (no emergency needed when liquidity is on hand) | `test_HLR2_L05_operatorRemovedManagerAbsent` |
| 2 | Redemption larger than idle, Core free USDC enough | everyone | operator: bridgeToEvm (>= 10 blocks + landing, <= 300 blocks), then settle: about 1 to 5 min after the epoch is due | `test_HLR2_L03_insufficientLiquidityChain` (first half) |
| 3 | Redemption needs positions reduced (InsufficientLiquidity) | everyone, but only after someone reduces | the operator stops (`needs the manager`); only the manager can reduce outside a breach. If the manager does not: `maxEpochDuration` (7 d, up to 30 d), then **anyone** `triggerEmergency`, then a human with a platform role (guardian / sentinel / owner / operator / manager) flattens (one reduce-only IOC per call, policy band, or <= 3% for the guardian), bridges home and settles, one partial fill per bridge window (>= 11 blocks). Unbounded if no role acts (no automation in emergency) | `test_HLR2_L03_insufficientLiquidityChain`, `test_HLR2_L06_emergencyPartialFillsInRounds` (50k in 5 fills, 55 blocks) |
| 4 | Leverage breach | everyone | as rows 1-3 (normal settles continue, the operator clears the breach once leverage is back under the limit and 15 min passed) | covered by existing Round4 tests; operator side `test_HLR2_L07_operatorBounds` |
| 5 | Daily loss / drawdown breach | everyone (redemptions only; deposits carried, cancellable) | redemption-only settle by any listed role, no overdue; paid in full at min(NAV, previous checkpoint) or reverts InsufficientLiquidity: then as row 3 but the owner / operator / sentinel may also flatten (breached). Drawdown lasts until the owner's `resume()` (>= 24 h); daily loss until the next UTC day | `test_HLR2_L04_lossBreachRedemptionOnlyByAnyRole` |
| 6 | Guardian-class full stop (`triggerBreach` by the vault owner, the sentinel or the guardian) | **nobody** until it ends | no settle at all, any role, any mode, overdue or not. Ends by: guardian `clearBreach` / `triggerEmergency` (cold key, human), or `maxEpochDuration` after the last settle + anyone `triggerEmergency` + a role settles. The owner can make it 30 d: raising `maxEpochDuration` is a loosening behind the 2 d policy timelock, shorter than the running epoch. HLR2-E06 | `test_HLR2_E06_fullStopBlocksAllExitsUntilOverdue`, `test_HLR2_E06b_ownerLengthensTheWaitTo30Days` |
| 7 | Emergency | every redeemer, pro rata to the USDC on hand | one partial fill per settle; a settle needs a listed role (anyone may trigger, nobody else may settle); each round = flatten + bridgeToEvm + >= 11 blocks + settle. The executor runs nothing, so every round is manual. Paid at min(NAV, checkpoint) with no age bound on the checkpoint (HLR2-E01) | `test_HLR2_L06_emergencyPartialFillsInRounds`, `test_HLR2_E01a_*` |
| 8 | Overdue epoch (no breach) | everyone if liquidity is on hand | platform roles settle exit-only (deposits refunded) once overdue; otherwise row 3's emergency path. Paid at min(NAV, checkpoint), checkpoint up to the whole epoch old (HLR2-E01b) | `test_HLR2_L05_*`, `test_HLR2_E01b_*` |
| 9 | NAV precompile reverts (0x80F account margin, 0x801 spot, 0x810 core user) | **nobody** while it lasts | requests, cancels, claims of settled requests and `triggerEmergency` work; every settle (all modes), `checkRisk`, `accrueFees`, `requestDeposit` on a factory vault (non-zero cap reads NAV) and `bridgeToEvm` (0x801 directly; 0x80F / 0x810 through the window snapshot) revert. Duration = the outage. On real HyperEVM an invalid precompile call also burns the gas passed | `test_HLR2_L01_precompileOutage_*` (4) |
| 10 | Position precompile (0x813) or one index unreadable (delisted curated asset) | everyone | only `flatten` of that index reverts; NAV, checkRisk, settle and bridges do not read per-asset state. A delisted perp's position is settled by Hyperliquid; until then its margin is not withdrawable (row 3) | `test_HLR2_L01_precompileOutage_position`, `test_HLR2_L02_unreadableIndexBlocksOnlyItsFlatten` |
| 11 | Agent revoked (any reason) | everyone | no effect on exits: the agent only trades. Reductions fall to the manager (and platform roles in breach / emergency) | `test_HLR2_L05_operatorRemovedManagerAbsent` |
| 12 | Operator removed (owner `setOperator(0)`, or `revokeOperator` by owner / sentinel / guardian) | everyone | only the manager settles normally; without the manager: row 1 / row 3 overdue path (7 d) | `test_HLR2_L05_operatorRemovedManagerAbsent`, `test_HLR2_E06_*` (owner removes the operator too) |
| 13 | Manager never acts, operator present | everyone while Core free USDC covers the redemptions | the operator does everything except a position reduction; a redemption that needs one waits for row 3 (7 d + manual emergency) | `test_HLR2_L03_*` |
| 14 | Hyperliquid degraded: a Core -> EVM transfer lands late | everyone, but possibly at a phantom-loss NAV | settle waits up to 300 blocks; after that the missing amount counts as lost: a loss breach can fire and the operator's automatic redemption-only settle pays redeemers at the NAV that misses it (HLR2-E07). Hyperliquid fully halted: HyperEVM blocks stop with it (assumption: HyperEVM is produced by the same validators); nothing moves until it resumes | `test_HLR2_E07_lateLandingPaysRedeemersAtPhantomLoss` |
| 15 | Hostile operator (hot keeper key) | everyone, delayed | the operator cannot trade, flatten outside a breach, or take USDC, but can bridge the idle USDC the next settle needs to Core (`bridgeToCore` reserves only claimable / pending deposits, not pending redemptions) and push leverage over the limit by pulling free Core USDC home (no on-chain leverage bound): settles revert / a leverage breach. Ends with `revokeOperator` (owner, sentinel, guardian) | `test_HLR2_L07_operatorBounds`, `test_HLR2_L07b_operatorCanStarveTheNextSettle` |

## The operator's "reduce bound"

`server/src/treasury/operator.ts` never reduces positions: "A position reduction is never done here: it needs the
manager's signed maximum (Manage > To do)" (line 20-21, `canReduce: false` line 197). The bound is the manager's signed
percentage (`reductionFor` / `reductionNeeded`, the whole-percent `pct` the manager signs), and it is enforced off chain
only (the executor sends the reduce-only orders with the platform agent, not the operator key).

On chain the operator role is bounded as follows (`test_HLR2_L07_operatorBounds`):

| Action | Contract rule | Consistent with the off-chain bound? |
|---|---|---|
| `placeOrder` | manager only | yes: the operator cannot trade or reduce by order |
| `flatten` outside a breach / emergency | reverts `Unauthorized` | yes |
| `flatten` in a breach or emergency | allowed, **the whole position** at the policy band (custom slippage refused) | **no**: not bounded by any manager-signed maximum. A hot operator key can close every position at the band in any breach, including a leverage breach it caused itself (next row) |
| `bridgeToEvm` | any amount of Core free USDC, any time | **no**: the 85% leverage headroom (`bridgeSafe`, epochPlan.ts:106-113) is off chain only. Pulling 80k of a 200k account with 500k notional takes leverage from 2.5x to 4.2x and a permissionless `checkRisk` breaches the vault, after which the operator may flatten everything |
| `bridgeToCore` / `moveUsd` | idle only, refused in loss breach / full stop (to Core / to perp) | partly: can starve the next settle (row 15) |
| `settle` | normal and redemption-only only; never exit-only | yes |

Severity of the gap: Low (the operator is a platform online key whose compromise is in the trust model; no value leaves
the vault; a forced flatten at the policy band costs at most the band, 1% on the platform vault, of the closed notional). Fix
(describe): either accept and document that the operator may fully flatten in any breach, or drop the operator from
`flatten` (the sentinel already has the breach / emergency flatten), and bound `bridgeToEvm` for the operator by a
post-withdrawal leverage check (`ntlPos * BPS <= maxLeverageBps * (accountValue - amountFromPerp)`).

## Findings from this domain

- **HLR2-E06 (Medium)**: a guardian-class full stop blocks every exit for up to `maxEpochDuration` (7 d on the platform vault,
  30 d possible), and the vault owner can cause it. Details and fix in ECONOMICS.md (findings list).
- **HLR2-L01 (Low, Design)**: no automated or documented emergency unwind; every partial-fill round is manual.
- **HLR2-L02 (Low)**: operator contract bounds weaker than the off-chain reduce bound (section above).
- Row 9 (precompile outage) and row 3 (HLO-06) are known (lead's evidence 7, HLO-06); the times above are new.
