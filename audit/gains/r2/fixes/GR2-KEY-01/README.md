# GR2-KEY-01 fix: per-pair notional capped by Gains' skew depth; loss limits enforced before new risk

**Internal, AI-assisted review. Not an independent audit.** Proposed patch for the fix round; nothing in
`contracts/src` was changed. Patch against 4ec6feb, applies with `git apply` from the repo root (checked with
`git apply --check` on the worktree).

## What changes (`fix.diff`)

1. **Per-pair cap.** In `openTrade` and `increaseTrade`, after `policy.checkOrder`:
   `pairNotional(open + resting + pending + this order) <= MAX_PAIR_SKEW_DEPTH_BPS × skewDepthUsd`, with
   `skewDepthUsd = getPairSkewDepth(collateralIndex, pair) × Chainlink price / 1e22` (USD in collateral units, the same
   conversion GainsNav uses for notional). Refusal: `OrderRejected("pair depth")`. A pair Gains reports no skew depth
   for (0) takes no new risk: `OrderRejected("no skew depth")` (fail closed; assumption: every curated v10 pair has a
   depth, true for pairs 0, 1, 33 on the live diamond).
2. **Loss gate.** `openTrade`, `increaseTrade` and a leverage raise (`updateLeverage` up) compute the daily loss and the
   drawdown at the NAV the order was already checked against (no second NAV read) with `checkRisk`'s formulas (R-01;
   a new UTC day counts from the current price) and revert `ReduceOnlyMode` when either is over the policy limit. It
   only refuses; the breach itself is still recorded by the next `checkRisk` (the keeper's). Exits are untouched.
3. **Plumbing.** `IGainsDiamond.getPairSkewDepth(uint8,uint16)` (verified: `PriceImpactUtils.getPairSkewDepth`, returns
   `pairSkewDepths[collateralIndex][pair]` = the 1 % depth in tokens, 1e18; selector `0xf0f045a7`, present on facet
   `0xDCAD09f7682e045d235FCf4Aa9f1B47AB2054e55` of the Arbitrum diamond per the saved facet table). `GainsNav.Snapshot`
   gains `pairNotional`; `snapshot` gets a 5-argument overload with the pair (the 4-argument one is kept, so fork tests
   that call it directly still compile); `GainsVaultMath.venueFor(pair)`. Constant `MAX_PAIR_SKEW_DEPTH_BPS = 500` in
   `GainsTypes.sol`.
4. **Test doubles.** `MockGainsDiamond.getPairSkewDepth` (unset = a depth no test reaches, `setSkewDepth` to set one) and
   `IntegrationMock.t.sol`'s `EvilDiamond.getPairSkewDepth` (same).

## Why 5 % of the 1 % skew depth

Gains' skew impact (`PriceImpactUtils.getTradeSkewPriceImpactP`, divider 2) moves the pair by size / (2 × depth) per 1 %.
An opposite trader of size A who holds across a vault round trip of size V captures at most V × A / (200 × depthUsd)
(KEYS.md, 96.7–99.98 % of it measured). With V ≤ f × depthUsd the capture is at most f / 200 of A per round trip, i.e.
**2.5 bps of A at f = 5 %**, against the opposite account's own round-trip cost measured at 8.0 bps (BTC, ETH) and
13.6–17.5 bps (SOL). Measured break-even ratios V*/depth: ETH 2.2M / 13.76M = 0.16, SOL 1.47M / 4.07M = 0.36; 5 % is a
third of the lowest, so the route stays loss-making for the opposite account even with a ~2/3 fee discount
(assumption: no Gains fee tier gives more than that; to verify against Gains' fee-tier table). Vault-side effect at
live depths: at most **BTC 1.63M, ETH 688k, SOL 203k** of vault notional per pair. A 1M vault can still use its 5x, but
spread over pairs; a ≥ 41k vault cannot put 5x into SOL alone. A constant keeps the patch small (no `RiskConfig`
change, no ABI break for every test that builds a config); the fix round may move it to the factory's curation per pair.

## Side effects

- `openTrade` / `increaseTrade` / leverage raise: one extra diamond read (`getPairSkewDepth`), one Chainlink read
  through the policy and one `riskLimits` call; the per-trade NAV loop gains a compare-and-add. No second NAV pass (the
  gas cost at 20 positions stays dominated by the existing snapshot; not measured on a fork).
- `GainsVaultLogic` runtime size 21,919 → 23,252 bytes (limit 24,576): 1.3 KB of headroom left for the fix round.
- A pair whose depth Gains lowers below the vault's existing notional: new risk on it is refused, exits are not.
- Executor: surface `OrderRejected("pair depth")` / `("no skew depth")` as a strategy limit, and keep the recommended
  alarm on open/close churn per caller (GR2-EXE-01).

## Fix tests

`FixTest.t.sol` (`KEY01FixTest`, mock diamond; `getPairSkewDepth` set with `vm.mockCall` so it runs on both trees):

| Test | Asserts | Unfixed | Fixed |
|---|---|---|---|
| `test_KEY01_fix_perPairNotionalCappedAtFivePercentOfSkewDepth` | cap 600k on ETH: 250k filled + 250k pending + 250k → refused `"pair depth"`; 100k more fits (600k); 10k more refused; BTC unaffected | FAIL | PASS |
| `test_KEY01_fix_increaseCountsAgainstThePairCap` | `increaseTrade` +100k over a 300k cap refused, +50k (exactly 300k) accepted | FAIL | PASS |
| `test_KEY01_fix_noSkewDepthRefused` | depth 0 → `"no skew depth"` | FAIL | PASS |
| `test_KEY01_fix_dailyLossOverLimitRefusesNewRiskBeforeCheckRisk` | −18 % NAV, no `checkRisk` yet: `openTrade` and `increaseTrade` revert `ReduceOnlyMode`; `closeTrade` works | FAIL | PASS |
| `test_KEY01_fix_lossWithinLimitStillTrades` | −12 % NAV (limit 15 %): new risk accepted | PASS (regression guard) | PASS |

`KEY01ForkFixTest.t.sol` (real diamond, XR_08's vault side: 250k ETH longs on a ~1.06M vault at the live caps; the
first order past 5 % of ETH's depth must be refused `"pair depth"`, at most ~688k opened; on 4ec6feb all 20 open):
see `run-fork.txt` for whether it ran (needs the machine-wide heavy lock for fork work and a public-RPC block within
~15 minutes of the tip).

## Existing tests

Regression run in the patched scratch tree (40 suites, 405 tests incl. this fix test): **405 pass, 0 fail**, after
the `EvilDiamond` addition in the patch (without it `IntegrationMock.t.sol::test_INT_diamondRequestReentryReachesOnlyPermissionless`
reverts: that hand-written diamond has no `getPairSkewDepth`). Fork suites were not run; any fork test that opens
more than ~688k of ETH, ~1.63M of BTC or ~203k of SOL notional on one pair through a patched vault (e.g.
`r2/XReviewKeySkewFork.t.sol::test_GR2_XR_05..08`, `KeysSkewFork.t.sol::test_GR2_KEY_01_*`, `LivenessGasFork.t.sol`'s 20
positions if on one pair) must lower its sizes or spread pairs; those PoCs are expected to stop working.
