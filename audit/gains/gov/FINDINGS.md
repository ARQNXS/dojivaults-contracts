# Gains round 1, sub-reviewer 3.4 + 3.6: access control, governance, diff against round 4

Internal review (sub-reviewer), not an independent audit. Source at 5dd1344. Tests in `contracts/test/audit/gains/gov/`
(GovBase, PolicyMatrix 5, FactoryMatrix 12, Governance 16, OperatorBound 6, HLRetest 15); every GOV PoC passes while
its issue exists. HL retest per id: HL-RETEST.md (96 contract ids: 54 hold, 0 regressed, 29 N/A, 13 handed to the
other domains or the lead).

| Id | Title | Verdict | Severity (proposed) | Test |
|---|---|---|---|---|
| GOV-01 | reduceTrade has no minimum size: every partial close pays >= 0.10 USD (min-basis fee), so operator (under its cap) and agent (any time, even in a loss breach) can grind collateral into fees | CONFIRMED | Low | OperatorBound test_GOV_01_operatorGrindsCollateralIntoMinFees, test_GOV_01_agentGrindsEvenInADailyLossBreach, test_GOV_OB_cancelledReducesRestoreTheCapWithoutLimit |
| GOV-02 | registerPlatformAgent binds any number of agents to an existing vault and overwrites / deletes agentOfVault | CONFIRMED | Info | HLRetest test_GOV_02_manyAgentsPerVault_agentOfVaultDesyncs |
| GOV-03 | The policy has its own owner: after a vault transfer the old owner can instantly force a permanent leverage breach, make emergency triggerable by anyone (maxEpochDuration 1 h) and disallow every pair; the new owner cannot touch the policy | CONFIRMED | Low | Governance test_GOV_03_vaultTransferLeavesPolicyWithOldOwner |
| GOV-04 | The policy keeps renounceOwnership: config frozen, a pending loosening cannot be cancelled and anyone applies it | CONFIRMED | Info | Governance test_GOV_04_* |
| GOV-05 | _checkNavBound skips listed-but-disallowed pairs with exposure: leverage can exceed such a pair's NAV bound and its feed rotation reverts until leverage is lowered | CONFIRMED | Info | Governance test_GOV_05_* |
| GOV-06 | The sequencer uptime feed cannot be rotated (immutable on the factory, copied into each policy): if it dies, no vault with open trades can settle, checkRisk, take deposits or open | CONFIRMED | Low | Governance test_GOV_06_sequencerFeedCannotBeRotated |
| GOV-07 | KNOWN-ISSUES I3-02 recovery is wrong: cancelDepositRequest keeps r.epoch = current + 1, so the victim's requestRedeem reverts until the next settle (HL identical) | CONFIRMED | Info | HLRetest test_HL_I302_* |
| GOV-08 | redemptionShortfall prices pending redemptions at the checkpoint: a stale checkpoint after a 9% NAV drop overstates the need by > 400 of ~5,000 USDC (surplus stays idle) | CONFIRMED (design) | Info | OperatorBound test_GOV_OB_staleCheckpointOverstatesTheNeed |
| GOV-Q1 | Feed decimals cached at curation vs rotation latency (>= 1 day timelock) while checkRisk ratchets the checkpoint | OPEN QUESTION | | |
| GOV-Q2 | The registrar signature does not bind creation params (hosted, policy): a creator with a hosted signature can create hosted = false (10% instead of 33% protocol share) and keep the agent | OPEN QUESTION | | |

## GOV-01 (Low)
GainsVaultLogic.sol:568-586, GainsTypes.sol:25-31, :707-711. Gains charges a partial close on max(delta size,
pairMinPositionSizeUsd) = 0.10 USD for any delta under ~286 USD of size on BTC/ETH (STAGE0 B3: 0.100014); a reduce
whose payout would be negative is cancelled and the min gov fee (~0.0425) is realized on the trade. reduceTrade
accepts any collateralDelta > 0; the operator cap limits each request, not their number or fees. Operator: a 0.11 USDC
reduce frees ~0.01 and burns ~0.10, the shortfall barely moves (40 reduces: 3.979 USDC burned, 0.397 freed). Cancelled
reduces free nothing and leave the cap untouched. Agent / manager: a reduce is an exit at any time (also in a loss
breach). Worst case ~1 USDC/s of NAV across 20 trades (a fill every ~2 s), attacker pays ~0.5 USD/s of gas, bounded by
the trades' collateral, no gain to the attacker. Needs a compromised online key and hours without reaction.
Fix: require collateralDelta x leverage >= pairMinPositionSizeUsd (unless it closes the rest) for every caller; for the
operator one reduce in flight per trade and a per-epoch total; alert on ReduceRequested frequency.

## GOV-02 (Info)
GainsVaultFactory.sol:331-340 (the check at :336 only guards non-vaults), :353-354. The registrar registers agents x
and y for a live vault; both map to it; agentOfVault is overwritten and later deleted while the live agent trades. The
owner can switch among bound agents through the timelock. Fix: one pending replacement per vault, or document
GainsVault.agent() as the only source of truth.

## GOV-03 (Low)
GainsVaultFactory.sol:284, GainsVaultPolicy.sol:25, :303-315. Scenario: the vault owner transfers the vault; the old
owner sets maxLeverageBps = 1 and maxEpochDuration = 1 h (instant tightenings) and disallows BTC/ETH; checkRisk puts
the vault in a leverage breach that never clears while a trade is open; one hour after any redemption request a
stranger triggers emergency (agent revoked, deposits refunded, only the guardian can exit); the new owner gets
OwnableUnauthorizedAccount on every policy call. Fix: policy onlyOwner = GainsVault(vault).owner(), or move the policy
with the vault's ownership; at minimum document it and show the policy owner in the UI.

## GOV-04 (Info)
GainsVaultPolicy.sol:25 (vault :362 and factory :434 disable renounce, the policy does not). Queue a loosening, renounce:
nobody can cancel it, a stranger applies it at eta, nothing can be tightened again. Fix: override to revert.

## GOV-05 (Info)
GainsVaultPolicy.sol:426-431, :361-369. SOL allowed (10x bound), a SOL trade open, SOL disallowed, leverage raised to
12x (accepted, only BTC/ETH 12.5x checked): SOL NAV error 2 x 0.25% x 12 = 6% > maxNavMove/4 = 5%; rotating the SOL
feed reverts LeverageAboveNavBound until an instant tightening. Fix: check every listed pair with exposure; skip the
bound in setPairFeed for a disallowed pair.

## GOV-06 (Low)
GainsVaultFactory.sol:50-51, GainsVaultPolicy.sol:148-149, GainsPrice.sol:72-78. If 0xFdB6…697D reverts or reports down,
every vault with open trades cannot settle (any mode), checkRisk, take deposits or open. Exits work; the guardian must
close every trade, then a flat vault settles. Very low likelihood. Fix: a timelocked setSequencerFeed accepting only the
factory's current value, plus a factory setter for the cold owner.

## GOV-07 (Info)
GainsVaultLogic.sol:106-120, :94; KNOWN-ISSUES.md:18. Insider deposits with controller = victim; the victim cancels and
gets the USDC; requestRedeem still reverts RequestPending until the next settle. Fix: reset r.epoch when the request is
empty, and correct KNOWN-ISSUES.

## GOV-08 (Info, design)
GainsVaultMath.sol:143-159. ETH −10% on a 4,500 USDC 2x trade (NAV −9%): before the next checkRisk the need priced at the
checkpoint is overstated by > 400 of ~5,000 USDC; the surplus stays idle. Fix: checkRisk before reducing (keeper).

## Refuted
- R1 owner-queued clearBreach vs resume: both need >= 24 h; clearBreach keeps the peak and the next checkRisk
  re-breaches DRAWDOWN (test_GOV_CB_ownerClearVsResumeOnDrawdown).
- R2 operator freeing more than the cap: N reduces in one block total exactly shortfall + 2% of the last residual + 1
  USDC (asserted to the wei); deferred insider deposits correctly excluded; claimable reserve neutral.
- R3 bad fill via expectedPrice / slippage: Gains fills at its oracle price; the check is one-sided and only cancels.
- R4 duplicate queue ids: extra / missing bytes and extra padding refused; dirty upper bits queue a new id that fails at
  execute with CallFailed(""), no state change; re-queuing overwrites.
- R5 signature replay, malleability, salt front-running: other salt / creator / factory / chain, expired, high-s,
  64-byte compact, wrong signer all rejected; replay stopped by the CREATE2 collision / AgentAlreadyBound; salts scoped
  per creator; the registrar cannot pre-bind a predicted address.

## Checked and sound
ACCESS-MATRIX section 3 (policy, every cell, PolicyMatrix.t.sol) and section 4 (factory, every cell,
FactoryMatrix.t.sol); curation, cap and NAV bound at create, config change (both stages) and allowAsset; maxDepositCap
rules (lowering max later leaves caps alone, N-13); role collisions incl. pending owner; clones initialize once, a
third party's clone cannot adopt another vault's policy, libraries refuse direct calls; timelock whitelist, exact
lengths, window, failed calls stay queued, cancel rights; clear-breach rules (queued before or in the breach block
refused, a sentinel re-breach invalidates a queued clear I2-01, never in emergency); setPairFeed follows the factory's
curation at execute, blocked while de-curated, never-listed pairs refused, expires; instant owner levers enumerated.

## Diff against round 4
Everything removed is HyperCore-only (bridge window, equityAtBridge, syncBridge, Core gas, syncAgent, placeOrder). The
depositor flow, settle modes, insider deferral, carry, checkpoint rule, emergency-exit rule and fee logic are textually
identical apart from reading the venue once. Four meanings changed: (1) HL froze the day roll and peak during a bridge;
Gains values pending orders instead; (2) the operator's unbounded bridgeToEvm became a capped reduceTrade (GOV-01,
GOV-08); (3) settle reads Chainlink in every mode (N-02 analog, GOV-06, lead STALESETTLE); (4) the manager trades
directly, so the insider set is a trader set (C-01 / R-1 residual; lead NAVBIAS).
