# Gains contracts: access matrix (round 1 internal review)

Expected result of every external / public state-changing function of every Gains contract, per actor and per vault
state. The vault matrix is verified cell by cell by `test/audit/gains/AccessMatrix.t.sol`: it builds each state from
a snapshot, calls each function as each actor, and compares the outcome (success or the exact revert selector) with
the rule table encoded in the test from this document. Views are not listed (no access control).

**Result (round 1): 4,428 cells (41 functions x 9 actors x 12 states), all match** (`test_accessMatrix_<state>`, 12 tests).

**Result (round 1 fix, `fix/gains-r1`): 4,752 cells (44 functions x 9 actors x 12 states), all match.** Added:
`flattenIndices` (slippage 0 and custom: the same rules as `flatten`, GR1-08) and `setSequencerFeed` (self, GR1-10).
Cells changed against round 1 (all intended, listed in `test/audit/gains/fixes/TESTS-A2.md`):

| Function | State | Callers | Round 1 | Round 1 fix | Finding |
|---|---|---|---|---|---|
| settle | OP | Mgr, Opr (treasury) | OrdersPending | ✓ (a pending partial close holds no collateral) | GR1-04 |
| openTrade / increaseTrade / updateLeverage up | OD | Mgr, Agt | ✓ | EpochOverdue | GR1-04 |
| updateLeverage down | OD | Mgr, Agt | ✓ | EpochOverdue | GR1-04 |
| increaseTrade / updateLeverage up / updateLeverage down | OP | Mgr, Agt | Gains' `PendingMarketOrder` (diamond) | PendingOrderExists (the vault) | GR1-01 |
| cancelOrder (the resting limit) | BG, EM | Mgr, Sen | ✓ | already cancelled by the full stop (the diamond refuses) | GR1-16 |

`flatten(slippage 0)` now uses min(maxSlippageBps, maxFlattenSlippageBps) (GR1-41); with the matrix's config (1% / 3%)
the value is the same, so no cell moves.

Actors: **Str** stranger, **Dep** depositor (holds shares, has requests), **Mgr** manager, **Own** vault owner,
**Agt** agent, **Opr** operator, **Sen** sentinel (factory), **Grd** guardian (factory), **Fac** the factory contract,
**Self** the vault itself (through `execute`).

Vault states: **N** normal; **DP** deposits paused; **TP** trading paused; **BL** leverage breach; **BD** daily-loss
breach; **BW** drawdown breach; **BG** guardian full stop (triggerBreach); **EM** emergency; **OD** epoch overdue with
redemptions pending; **OP** an order pending on the diamond; **FS** the ETH feed stale while the vault holds an ETH
trade; **SD** the sequencer down.

Legend: ✓ allowed; ✗ `Unauthorized`; **b** only while breached or in emergency (else ✗); **e** only in emergency;
**od** only when overdue (else ✗); **c** only up to the operator cap (else `ReduceAboveShortfall`); **s** SL only
(a TP change is ✗); **self** only through the timelock (`execute`), ✗ for every direct caller.

## 1. GainsVault: who (state N)

| Function | Str | Dep | Mgr | Own | Agt | Opr | Sen | Grd | Fac |
|---|---|---|---|---|---|---|---|---|---|
| requestDeposit | ✓ | ✓ | ✓ deferred | ✓ deferred | ✓ | ✓ | ✓ | ✓ | n/a |
| requestRedeem (own shares, or allowance) | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | n/a |
| cancelDepositRequest / cancelRedeemRequest (own) | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | n/a |
| claim(any controller) | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| settle | ✗ | ✗ | ✓ | od | ✗ | ✓ | od | od | ✗ |
| accrueFees | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| openTrade / increaseTrade / updateLeverage up | ✗ | ✗ | ✓ | ✗ | ✓ | ✗ | ✗ | ✗ | ✗ |
| updateLeverage down | ✗ | ✗ | ✓ | ✗ | ✓ | ✗ | ✗ | ✗ | ✗ |
| closeTrade | ✗ | ✗ | ✓ | b | ✓ | b | b | ✓ | ✗ |
| reduceTrade | ✗ | ✗ | ✓ | b | ✓ | b, else c | b | ✓ | ✗ |
| setSlTp | ✗ | ✗ | ✓ | ✗ | ✓ | ✗ | b, s | ✗ | ✗ |
| cancelOrder | ✗ | ✗ | ✓ | ✗ | ✓ | ✗ | ✓ | ✗ | ✗ |
| cancelTimedOut | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| flatten(slippage 0) | ✗ | ✗ | ✓ | b | ✗ | b | b | ✓ | ✗ |
| flatten(custom slippage) | ✗ | ✗ | ✓ | ✗ | ✗ | ✗ | ✗ | e | ✗ |
| flattenIndices(slippage 0) | ✗ | ✗ | ✓ | b | ✗ | b | b | ✓ | ✗ |
| flattenIndices(custom slippage) | ✗ | ✗ | ✓ | ✗ | ✗ | ✗ | ✗ | e | ✗ |
| checkRisk / clearLeverageBreach | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| triggerBreach | ✗ | ✗ | ✗ | ✓ | ✗ | ✗ | ✓ | ✓ | ✗ |
| triggerEmergency | od | od | od | ✓ | od | od | od | ✓ | od |
| clearBreach | ✗ | ✗ | ✗ | ✗ (self) | ✗ | ✗ | ✗ | ✓ | ✗ |
| resume (drawdown) | ✗ | ✗ | ✗ | ✓ | ✗ | ✗ | ✗ | ✗ | ✗ |
| exitEmergency | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ | ✓ | ✗ |
| setOperator | ✗ | ✗ | ✗ | ✓ | ✗ | ✗ | ✗ | ✗ | ✗ |
| revokeOperator | ✗ | ✗ | ✗ | ✓ | ✗ | ✗ | ✓ | ✓ | ✗ |
| revokeAgent | ✗ | ✗ | ✗ | ✓ | ✗ | ✗ | ✓ | ✓ | ✓ |
| setDepositsPaused(true) / setTradingPaused(true) | ✗ | ✗ | ✗ | ✓ | ✗ | ✗ | ✓ | ✓ | ✗ |
| setDepositsPaused(false) / setTradingPaused(false) | ✗ | ✗ | ✗ | ✓ | ✗ | ✗ | ✗ | ✓ | ✗ |
| setDepositCap / lowerFees / rescueToken / setOperator / leaveHosted | ✗ | ✗ | ✗ | ✓ | ✗ | ✗ | ✗ | ✗ | ✗ |
| renounceOwnership | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ |
| queue | ✗ | ✗ | ✗ | ✓ | ✗ | ✗ | ✗ | ✗ | ✗ |
| execute (after eta) | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| cancel(id) | ✗ | ✗ | ✗ | ✓ | ✗ | ✗ | ✗ | ✓ | ✗ |
| setAgent / setManager / setFees / setFeeRecipient / setTimelockDelay / setPairFeed / setSequencerFeed | self | self | self | self | self | self | self | self | self |
| lowerProtocolShare | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ | ✓ |
| initialize (clone after create, implementation) | ✗ `InvalidInitialization` for everyone |

## 2. GainsVault: when (an allowed caller, per state)

✓ = succeeds; otherwise the expected revert. FS / SD mean "reads a price".

| Function | N | DP | TP | BL | BD | BW | BG | EM | OD | OP | FS | SD |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| requestDeposit (factory vault: cap ≠ 0 reads NAV) | ✓ | DepositsClosed | ✓ | DepositsClosed | DepositsClosed | DepositsClosed | DepositsClosed | DepositsClosed | ✓ | ✓ | PriceStale | SequencerDown |
| requestRedeem / cancelRedeemRequest / claim | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| settle (manager) | ✓ normal | ✓ | ✓ | ✓ normal | ✓ redemption-only | ✓ redemption-only | ReduceOnlyMode | ✓ exit-only | ✓ | ✓ (OrdersPending only for an order that holds collateral, GR1-04) | PriceStale | SequencerDown |
| settle (guardian / sentinel / owner) | ✗ | ✗ | ✗ | ✗ | ✓ redemption-only | ✓ redemption-only | ReduceOnlyMode | ✓ exit-only | ✓ exit-only | ✗ | PriceStale | SequencerDown |
| openTrade | ✓ | ✓ | TradingIsPaused | ReduceOnlyMode | ReduceOnlyMode | ReduceOnlyMode | ReduceOnlyMode | ReduceOnlyMode | EpochOverdue | ✓ | PriceStale | SequencerDown |
| increaseTrade / leverage up (the trade with the pending order) | ✓ | ✓ | TradingIsPaused | ReduceOnlyMode | ReduceOnlyMode | ReduceOnlyMode | ReduceOnlyMode | ReduceOnlyMode | EpochOverdue | PendingOrderExists | PriceStale | SequencerDown |
| updateLeverage down (the trade with the pending order) | ✓ | ✓ | ✓ | ✓ | ReduceOnlyMode | ReduceOnlyMode | ReduceOnlyMode | ReduceOnlyMode | EpochOverdue | PendingOrderExists | ✓ | ✓ |
| closeTrade / reduceTrade / cancelTimedOut / flatten / flattenIndices | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ (other trades) | ✓ | ✓ |
| cancelOrder (a resting limit / stop) | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | already cancelled (GR1-16) | already cancelled (GR1-16) | ✓ | ✓ | ✓ | ✓ |
| setSlTp (SL tighten) | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| setSlTp (SL widen / remove) | ✓ | ✓ | ✓ | SlNotTighter | SlNotTighter | SlNotTighter | SlNotTighter | SlNotTighter | ✓ | ✓ | ✓ | ✓ |
| checkRisk / accrueFees | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | PriceStale | SequencerDown |
| clearBreach (guardian) | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | InEmergency | ✓ | ✓ | PriceStale | SequencerDown |
| exitEmergency (guardian) | ✓ (no-op) | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ unless redemptions pending | RedemptionsPending | ✓ | ✓ | ✓ |
| execute(setAgent) | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | CallFailed(ReduceOnlyMode) | CallFailed(ReduceOnlyMode) | ✓ | ✓ | ✓ | ✓ |
| triggerEmergency (stranger) | NotOverdue | NotOverdue | NotOverdue | NotOverdue | NotOverdue | NotOverdue | NotOverdue | NotOverdue | ✓ | NotOverdue | ✓ | ✓ |

## 3. GainsVaultPolicy (who)

Owner = `GainsVault(vault).owner()`, read live (GR1-12): a vault transfer moves the policy with it.

| Function | Owner (vault owner) | Vault | Anyone |
|---|---|---|---|
| initialize | once, by the factory in `create` (implementation: `InvalidInitialization`) | | ✗ |
| proposeConfig / cancelPendingConfig / disallowAsset / queueAllowAsset / proposeTimelockDelay | ✓ | ✗ | ✗ (OwnableUnauthorizedAccount) |
| applyPendingConfig / allowAsset / applyTimelockDelay | ✓ | ✓ | ✓ (after eta, before eta + 14 d) |
| setPairFeed / setSequencerFeed (the feed and grace queued through the vault, checked against the factory at queue time, GR1-10 / GV-03) | ✗ (NotVault) | ✓ | ✗ (NotVault) |
| transferOwnership / acceptOwnership / renounceOwnership | ✗ OwnershipFollowsVault (GR1-12 / GR1-30; round 1: ✓ two step, renounce allowed) | ✗ | ✗ OwnershipFollowsVault |

## 4. GainsVaultFactory (who)

| Function | Owner | Registrar | Guardian | Sentinel | Launcher (allowed) | Anyone |
|---|---|---|---|---|---|---|
| create | ✓ if allowed | ✓ if allowed | ✓ if allowed | ✓ if allowed | ✓ | LaunchClosed (✓ with openLaunch) |
| registerPlatformAgent | ✓ (any vault address) | ✓ (existing vaults only) | NotRegistrar | NotRegistrar | NotRegistrar | NotRegistrar |
| unregisterPlatformAgent | ✓ | ✓ unless live (LiveAgent) | ✓ | ✓ | NotRegistrar | NotRegistrar |
| set* (recipient, shares, minSeed, minAgentGas, launcher, openLaunch, guardian, sentinel, registrar, curation, maxDepositCap, sequencerFeed (never zero, GR1-10)), lowerProtocolShare | ✓ | ✗ | ✗ | ✗ | ✗ | ✗ (OwnableUnauthorizedAccount) |
| transferOwnership | ✓ (not to a hot role) | | | | | ✗ |
| renounceOwnership | RolesCollide | | | | | ✗ |

Lens: views only.
