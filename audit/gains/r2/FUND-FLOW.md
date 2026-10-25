# Round 2, domain FF: fund-flow map of the Gains contracts

**Internal, AI-assisted review. Not an independent audit.**

Scope: `contracts/src/gains/*` at `origin/main` 4ec6feb (the deployed factory [an earlier factory]), plus `script/DeployGains.s.sol`
for how the libraries are linked. Line numbers are those of the files at that commit. Tests:
`contracts/test/audit/gains/r2/FundFlowR2.t.sol` (31 tests, mock diamond, run in the worktree, see the end of this
file). The question this file answers is METHOD.md's: can USDC or share value leave a vault, or move between
depositors, other than (a) as collateral for the vault's own Gains trades, (b) to a redeemer pro rata at a fair price,
(c) as fees within the caps?

**Bottom line.** Every value-moving path is listed below. None takes a caller-supplied recipient except where the
recipient is that caller's own entitlement (the controller of a request, the owner's choice of where a stray non-asset
token goes, the creator's own seed and ETH). The vault approves exactly one spender (the diamond fixed at initialize),
for exactly one request's collateral, bounded by idle USDC, and the allowance is 0 after every path, including revert,
try / catch and short-pull paths. No arbitrary call, no delegatecall to a mutable target. Nothing on the Gains side that a
third party can call pulls or redirects the vault's collateral (live checks below). One informational griefing item
(GR2-FF-01). No Critical, High, Medium or Low finding.

## 1. Table

Legend for "who": Str stranger, Dep depositor, Ctl the request's controller, Mgr manager, Agt agent, Own owner,
Opr operator, Sen sentinel, Grd guardian, Fac factory, Self the vault through `execute`. Roles and states are as in
ACCESS-MATRIX.md (re-verified there cell by cell, 4,752 cells); this table adds where the value goes and its bound.
"L:" = GainsVaultLogic.sol, "G:" = GainsVaultGovernance.sol, "V:" = GainsVault.sol, "M:" = GainsVaultMath.sol,
"F:" = GainsVaultFactory.sol, "N:" = GainsNav.sol, "P:" = GainsVaultPolicy.sol.

### 1.1 USDC in and out of the vault (depositor side)

| # | Path | Code | Who can trigger | From → to (recipient expression) | Bound | Test |
|---|---|---|---|---|---|---|
| U1 | requestDeposit | L:52, transfer L:68 | anyone, for any controller; not while deposits paused, breached or in emergency; cap (factory vaults always) | `msg.sender` → `address(this)` (`safeTransferFrom(msg.sender, …)`) | exactly `assets` ≥ MIN_DEPOSIT (10 USDC); NAV + queued + assets ≤ depositCap | `test_FF_requestDeposit_forAnotherController_onlySenderPays` |
| U2 | cancelDepositRequest | L:106, transfer L:124 | Ctl only (`requests[msg.sender]`), only unsettled or carried | vault → `msg.sender` = the controller | exactly `r.depositAssets`, reserve decremented first | same test (the payer cannot cancel, the controller is refunded) |
| U3 | claim (any controller) | L:141 → `_claimIfSettled` L:151, transfer L:165 | anyone, for a settled request; also run inside U1 / S1 / S2 for that controller | vault → `controller` (the request's owner; the caller chooses only whose request is delivered, never where it goes) | `min(pro-rata assets, claimableRedeemAssets)`; floor rounding (M:224) | `test_FF_claimByStranger_paysOnlyTheController` |
| U4 | settle | L:221 | Mgr / Opr (normal), Own / Grd / Sen (exit-only when overdue or emergency; redemption-only in a loss breach) | no USDC transfer: moves USDC from idle into `claimableRedeemAssets` (reserve) | redemptions at the adverse-edge NAV (min with checkpoint in loss breach / exit-only), deposits at max(NAV, favourable edge); emergency partial fill ≤ idle | `test_FF_settle_movesNoUsdc_feesOnlyToFeeRecipient` (ledger), SPEC D6 / S3-S5 (round 1 invariants) |

### 1.2 Shares

| # | Path | Code | Who | From → to | Bound | Test |
|---|---|---|---|---|---|---|
| S1 | requestRedeem | L:80, allowance L:87, transfer L:95 | `owner_` itself, or a spender with an ERC-20 allowance from `owner_` (spent exactly; ∞ allowance not decremented, M:91) | `owner_` → vault escrow; request recorded under any `controller` (who later receives the payout) | `shares` ≤ balance; the allowance holder has the same power as with `transferFrom` | `test_FF_shares_requestRedeemBySpender_needsAndSpendsAllowance`, `test_FF_shares_escrowCannotBePulled` |
| S2 | cancelRedeemRequest | L:129, transfer L:136 | Ctl only, current epoch only | escrow → `msg.sender` = the controller | exactly `r.redeemShares` | `test_FF_shares_thirdPartyRequestsForAVictim_doNotBlockItsExit` |
| S3 | claim (shares part) | L:160 | as U3 | escrow → `controller` | minted deposit shares (floor) + returned unpaid shares (partial fill, ceil-burned) | U3 tests; round 1 `testFuzz_conversionRoundingFavoursTheVault` |
| S4 | settle burn / mint | L:294, L:295 | as U4 | burn from escrow (`address(this)`); mint to escrow | burn ≤ pendingRedeemShares (floor on partial fill); mint = toShares(depIn) floor | `test_FF_settle_movesNoUsdc_feesOnlyToFeeRecipient` |
| S5 | management fee | L:360, mint L:383 / L:386 | anyone (`accrueFees` L:355), settle, setFees (G:426, Self) | new shares → `IVaultFactory($.factory).protocolFeeRecipient()` (read live; factory owner sets it) and `$.feeRecipient` (owner, timelocked) | ≤ MAX_MANAGEMENT_FEE_BPS 5% / yr of NAV (G:69, G:425); protocol part = feeShares × protocolShareBps ≤ 50%, only lowered | `test_FF_protocolShare_mintsOnlyToFactoryRecipient`, `test_FF_settle_movesNoUsdc_feesOnlyToFeeRecipient` |
| S6 | performance fee | L:370-373 (inside S5) | normal settle only, not in breach / emergency | as S5 | ≤ 30% of (price − HWM) × supply (G:69); a raise waits one settle (N2-02) | round 1 `test_fees_breachSettleChargesNoPerformanceAndKeepsHwm`; F2-F4 invariants |
| S7 | ERC-20 transfer / transferFrom / approve | inherited OZ ERC20Upgradeable | any holder / allowance holder | holder → anyone the holder chooses | holder's own balance / allowance | `test_FF_shares_escrowCannotBePulled` (the vault never approves: escrow cannot be pulled) |

### 1.3 Vault ↔ Gains diamond

The only spender the vault ever approves is `$.diamond`, set once in `initialize` (G:81) and never written again
(grep: the only assignment is G:81). The factory's `diamond` is `immutable` (F:48).

| # | Path | Code | Who / state | USDC flow | Bound | Allowance after | Test |
|---|---|---|---|---|---|---|---|
| D1 | openTrade (market / limit / stop) | L:445; approve L:482 → L:783; call L:484; clear L:485 → L:787 | Mgr / Agt; not breached, not emergency, not trading-paused, not overdue; policy.checkOrder | vault → diamond (Gains `transferFrom(trader)` at the request) | exactly `o.collateral` ≤ idle (L:453), `t.user = address(this)` (L:471), referrer 0 (L:484) | 0 (`_clearApproval`) | `test_FF_openTradeMarket_*`, `test_FF_openTradeLimit_*`, `test_FF_reservedUsdcNeverReachesTheDiamond` |
| D2 | increaseTrade | L:491; approve L:522; call L:523; clear L:524 | as D1, one pending order per trade (L:502) | vault → diamond | exactly `collateralDelta` ≤ idle (L:506); 0 → no approve | 0 | `test_FF_increaseTrade_withCollateral_*`, `test_FF_increaseTrade_leverageOnly_noApproveNoPull` |
| D3 | updateLeverage down | L:536-547 | Mgr / Agt; not full stop, not loss breach, not overdue | vault → diamond | `collateral × lev / newLev − collateral` (Gains' formula) ≤ idle (L:544) | 0 | `test_FF_updateLeverageDown_pullsExactlyTheMarginDelta` |
| D4 | updateLeverage up | L:548-567 | as D1 (new risk) | diamond → vault on fill | collateral freed by Gains | no approve | `test_FF_updateLeverageUp_noPull_fillReturnsToVault` |
| D5 | closeTrade | L:573, call L:575 | Mgr / Agt / Grd; Own / Opr / Sen in breach or emergency | diamond → `trade.user` = vault on fill | Gains' payout | no approve | `test_FF_closeTrade_payoutOnlyToVault` |
| D6 | reduceTrade | L:583, call L:599 | as D5, plus Opr outside a breach up to `operatorReduceCap(shortfall)` | diamond → vault on fill | partial close payout | no approve | `test_FF_reduceTrade_payoutOnlyToVault`; operator cap: round 1 `gov/OperatorBound.t.sol` |
| D7 | setSlTp | L:606, L:613, L:617 | Mgr / Agt; Sen SL-only in breach (tighten only) | none at the call; a later TP / SL fill pays the vault | — | no approve | `test_FF_setSlTp_movesNothing` |
| D8 | cancelOrder | L:623, call L:625 | Mgr / Agt / Sen | diamond → vault (resting collateral) | the order's collateral | no approve | `test_FF_cancelOrder_collateralBackToVault` |
| D9 | cancelTimedOut | L:632, call L:633 | anyone (Gains enforces the timeout and that the trader is `msg.sender` = vault) | diamond → vault | the pending order's collateral | no approve | `test_FF_cancelTimedOut_byStranger_collateralBackToVault` |
| D10 | flatten | L:656; try cancelOpenOrder L:680; try updateMaxClosingSlippageP L:686; closeTradeMarket L:688 | Mgr / Grd; Own / Opr / Sen in breach or emergency; custom slippage Mgr, or Grd in emergency | diamond → vault (cancels now, closes on fill) | slippage ≤ maxFlattenSlippageBps ≤ 3% (P:289-294) | no approve; a refused cancel / slippage update moves nothing | `test_FF_flatten_closesAndCancels_payoutsOnlyToVault`, `test_FF_flatten_cancelRefusedInTryCatch_nothingMoves` |
| D11 | flattenIndices | L:698; try L:712, L:713, L:717 | as flatten | as flatten | as flatten | no approve | `test_FF_flattenIndices_payoutsOnlyToVault` |
| D12 | full stop cancels resting orders | G:232 `_stop` → G:244 `_cancelResting`, try G:250 | triggerBreach (Own / Grd / Sen), triggerEmergency (Own / Grd; anyone when overdue with redemptions) | diamond → vault | the resting collateral | no approve | `test_FF_fullStop_cancelsRestingOrders_collateralBackToVault` |
| D13 | short pull / revert | L:782-788 | — | if the diamond takes less than approved (here 0), the rest stays in the vault; if it reverts, the whole call reverts | — | 0 (cleared whenever non-zero) | `test_FF_diamondPullsLessThanApproved_openTrade_allowanceCleared`, `test_FF_diamondPullsLessThanApproved_increaseAndLeverage_allowanceCleared`, `test_FF_diamondReverts_nothingMovesNoAllowance` |

Diamond calls the vault never makes (grep of `src/gains`, and absent from `IGainsDiamond.sol`, so they cannot even be
encoded): `setTradingDelegate`, `delegatedTradingAction`, `withdrawPositivePnl`, `openTradeNative`,
`updateLeverageNative`, `increasePositionSizeNative`, `updateOpenOrder`, `triggerOrder`. `getTradingDelegate` is
declared but called nowhere in `src/gains`.

### 1.4 Owner, factory, policy

| # | Path | Code | Who | Flow | Bound | Test |
|---|---|---|---|---|---|---|
| O1 | rescueToken | V:363-366 | Own only (`onlyOwner`) | `token.balanceOf(vault)` of `token` → `to` (owner's choice) | never `$.asset`, never the vault's own shares (V:364); fixed selectors `balanceOf` / `transfer` | `test_FF_rescueToken_neverAssetOrShares` |
| O2 | execute (timelock) | G:373, self-call G:383 | anyone after eta, within 14 days; the data was queued by the owner (G:346) | none: only 8 whitelisted `onlySelf` setters with exact calldata lengths (G:351-357): setManager, setFeeRecipient, setTimelockDelay, setAgent, setFees, clearBreach, setPairFeed, setSequencerFeed | setFees mints only the management fee at the old rate (S5); setFeeRecipient changes the future recipient of S5 / S6 (both capped) | `test_FF_execute_queueRefusesEveryValueMovingSelector` (44 selectors refused, incl. padded whitelisted ones), `test_FF_execute_everyQueueableCallMovesNoUsdc` |
| F1 | create: seed | F:251, permit F:281 (try, owner = msg.sender), pull F:291 | allowed launchers, or anyone with openLaunch | `msg.sender` → the new clone `vault` (`cloneDeterministic` of the fixed implementation, salt scoped to msg.sender) | `seedUsdc` ≥ minSeedUsdc, the creator's own money | `test_FF_factoryCreate_seedFromCreatorOnly_ethToBoundAgent` (a third party cannot spend the creator's leftover allowance to the factory) |
| F2 | create: agent gas | F:322-325 | as F1 | `msg.value` (ETH) → `p.agent`, only when `p.agent` is bound to the predicted vault (owner pre-bind, or the registrar / owner signature over chain, factory, agent, predicted vault, deadline, F:260-272); with no agent `msg.value` must be 0 (F:259); empty calldata | the creator's own ETH; the factory keeps none (no receive / fallback) | same test |
| F3 | unregisterPlatformAgent | F:348, `GainsVault(vault).revokeAgent()` F:355 | registrar (not a live agent), Own / Grd / Sen | none | — | round 1 `gov/FactoryMatrix.t.sol` |
| F4 | lowerProtocolShare | F:379 → V:214 → L:431 | factory owner | none (lowers future S5 protocol part) | strictly lower | round 1 `gov/FactoryMatrix.t.sol` |
| P1 | policy external calls | P:152-153, P:165, P:389-390, P:442, P:450; feeds via GainsPrice:108 / :116 (staticcall, 200k gas) | — | none: views of the factory (`factory`, set once, P:150), the vault's `owner()`, curated feeds | — | — |

## 2. Proofs

### P1. No arbitrary call

Every call site in `src/gains` (grep `\.call|staticcall|delegatecall|safeTransfer|transferFrom|forceApprove|\.approve\(`
plus every `IGainsDiamond`, `IVaultFactory`, `IGainsCuration`, `GainsVault(…)`, `GainsVaultPolicy(…)` call) targets one of:

- `$.asset`, `$.diamond`, `$.policy`, `$.factory`: assigned only in `GainsVaultGovernance.initialize` (G:79-83; grep
  finds no other assignment), and `initialize` runs once (`initializer`, implementation `_disableInitializers`).
- feeds: the policy's `_feeds[pair]`, copied from the factory's curation at allow / rotation (P:452, P:392), read by
  `staticcall` only (GainsPrice:108, :116); `sequencerFeed` likewise (P:404).
- `address(this)`: only in `execute`, with data the owner queued and `queue` whitelisted (P5 below).
- factory: `usdc` and `diamond` are `immutable`; the clones it creates itself; `p.agent` with empty calldata and only
  the creator's own `msg.value`; `GainsVault(vault)` only for `isVault[vault]` (F:353, F:380); `IChainlinkFeed(feed).decimals()`
  in the owner-only `setAssetCurated`.
- The one caller-chosen target is `rescueToken`'s `token` (owner only; selectors `balanceOf` and `transfer` only;
  never the asset or the share token). It can move only that token's balance.

### P2. No delegatecall to a mutable or caller-supplied target

- `src/gains` contains no `delegatecall` keyword. Solidity emits DELEGATECALL only for calls to `external` / `public`
  functions of the three linked libraries (GainsVaultLogic, GainsVaultGovernance, GainsNav). GainsVaultMath and
  GainsPrice are internal only (inlined).
- Library addresses are link-time constants in the implementation's runtime code: `forge create` / the script deploys
  and links them (DeployGains.s.sol:105), and `resolveLibraries` (:181-207) cross-checks the links from the artifacts'
  linkReferences. **Live check (block 516,385,882):** the implementation [an earlier vault implementation] contains `PUSH20` of the recorded
  GainsNav [an earlier library] (5 times), GainsVaultLogic [an earlier library] (21) and GainsVaultGovernance [an earlier library] (22); the
  live vault [an earlier vault] is the EIP-1167 clone `363d3d373d3d3d363d73` + [an earlier vault implementation] + `5af43d82803e903d91602b57fd5bf3`, whose
  delegate target is in its code. No proxy admin, no upgrade function, no storage slot holds a code address.
- A non-view library function called directly (CALL instead of DELEGATECALL) reverts (solc's library call guard), and the
  libraries hold no state the vault reads.

### P3. No caller-supplied recipient except the caller's own entitlement

Recipients in the table: `address(this)`; `$.diamond`; `msg.sender` in U2 / S2 (the controller's own request);
`controller` in U3 / S3 (the request's owner; a caller can only trigger delivery to it); `$.feeRecipient` and the
factory's `protocolFeeRecipient` (S5 / S6, capped); `trade.user = address(this)` for every Gains payout (D1 sets it,
L:471; Gains pays the trader, verified on the fork in round 1, `LC_LifecycleFork`, and here on the mock); the new
clone and `p.agent` in F1 / F2 (the creator's own funds); `to` in O1 (owner, non-asset tokens).

### P4. No leftover allowance

- One approve site: `_approve` (L:782-784), called from D1, D2 (collateral > 0) and D3 only, each time with the
  request's collateral after the idle check, and each time followed in the same function by `_clearApproval`
  (L:786-788), which sets the allowance to 0 whenever it is not already 0. If the diamond reverts, the whole
  transaction reverts (no try / catch around D1-D3). The try / catch paths (D10, D11, D12) approve nothing.
- The vault never approves its own shares (no `approve` in `src/gains`; `execute` cannot reach `approve`, P5), so the
  escrow cannot be pulled with `transferFrom` or `requestRedeem(…, owner_ = vault)`.
- The factory and the policy approve nothing.
- Tests: every D-row test ends with `allowance(vault, diamond) == 0` and a ledger over 15 addresses; the short-pull
  tests mock the diamond to take nothing. **Sensitivity:** with `_clearApproval` emptied in a scratch copy, the two
  short-pull tests fail (`vault -> diamond allowance: 10000000000 != 0`, `4000000000 != 0`).
- **Live (block 516,385,882):** `USDC.allowance(vault, diamond) = 0` for [an earlier vault] and [an earlier vault].

### P5. execute() reaches nothing that moves value

`queue` (owner) accepts 8 selectors with exact lengths (36 / 68 / 4 / 132) and reverts `Unauthorized` for anything
else; `execute` runs `address(this).call(data)` only for `keccak256(data)` queued earlier. Within one contract a
selector maps to exactly one function (solc rejects clashes), so a whitelisted selector reaches only its `onlySelf`
setter. None of the 8 transfers USDC or shares; setFees crystallises the management fee at the old rate (S5),
setFeeRecipient / setManager / setAgent change roles (setAgent only to a factory-bound agent on factory vaults).
`test_FF_execute_queueRefusesEveryValueMovingSelector` tries 44 calldatas (every other external function of GainsVault,
the ERC-20 and Ownable functions, and padded whitelisted ones): all refused. `test_FF_execute_everyQueueableCallMovesNoUsdc`
executes all 8: no USDC moves, no holder's shares move.

### P6. The Gains diamond side

Where approved USDC goes (verified Gains source, TradingInteractionsUtils / TradingCommonUtils, facet 0x66B2…D327):
`openTrade`, `increasePositionSize` and the leverage-decrease `updateLeverage` pull the collateral from `_msgSender()`
(the vault) at the request (TradingInteractionsUtils.sol:704, UpdatePositionSizeLifecycles.sol:36,
UpdateLeverageLifecycles.sol:39, all `TradingCommonUtils.transferCollateralFrom(…, trader, amount)`; nothing is pulled
later, so clearing the allowance after the call cannot starve a fill). It sits in the diamond as the trade's (or pending order's) collateral; fills charge Gains'
fees from it; closes, partial closes, TP / SL, cancels and timeouts pay `trade.user`; a loss or liquidation goes to the
gToken vault (market risk, case (a)).

Third-party entry points that touch a vault's trade:

| Entry point | Who may call | Effect on the vault | Evidence |
|---|---|---|---|
| `triggerOrder` / `triggerOrderWithSignatures` | anyone (bots) | executes the vault's own TP / SL / liquidation / resting limit at Gains' oracle; payout to the vault. The trigger fee does not go to the caller: `distributeTriggerReward` splits it among Gains' oracle set (TriggerRewardsUtils.sol:50-63, facet 0xa964…00d1), so a manager running a trigger bot earns nothing from the vault's orders | round 1 `LC_LimitStopFork` (no value to LPs from far-off orders), GR1-25 (blocking SL updates ~20 blocks, accepted) |
| `delegatedTradingAction(trader, data)` | only `delegations[trader]` | the vault never sets a delegate | **live:** `getTradingDelegate(vault) = 0` (both vaults); `eth_call` from 0x…dEaD reverts `DelegateNotApproved()` (0x0cf0b6f5) |
| `registerPotentialReferrer(trader, referrer)` | `onlySelf` (diamond-internal), and the vault passes referrer 0 | none | **live:** `eth_call` from a stranger reverts `WrongAccess()` (0x6c5ffd54); `getTraderActiveReferrer` / `getTraderLastReferrer(vault) = 0` |
| `initiateManualNegativePnlRealization` | Gains GOV / MANAGER roles | realizes the vault's own holding fees / negative PnL (accounting, no transfer out) | facet source `onlyRoles(GOV, MANAGER)`; VERIFY-R2 fork: a stranger gets `WrongAccess()` |
| `cancelOrderAfterTimeout`, `cancelOpenOrder`, `closeTradeMarket`, `decreasePositionSize`, `withdrawPositivePnl`, `update*` | the trader (`_msgSender()`) only | only the vault itself (D5-D11; PNL_WITHDRAWAL is never created) | source; `test_FF_cancelTimedOut_byStranger_*` (the vault exposes the timeout cancel; collateral returns to the vault) |
| Gains governance (facet upgrades, pair delisting, pause) | Gains' timelocked governance | trust assumption T2 (round 1 GR1-08 / GR1-45) | out of scope |

### P7. ERC-20 share surface: one depositor moving another's value or blocking another's exit

- `transferFrom` and `requestRedeem(owner_ ≠ msg.sender)` both require and spend an ERC-20 allowance granted by
  `owner_`. The spender may name itself as controller: the same power `transferFrom` gives. No path moves shares out of
  an account without its own call or allowance (S1, S7; tests above).
- A third party may add to a victim's request (a deposit funded by the third party, or shares it escrows for the
  victim as controller). That is a gift: the victim can cancel and receives it; it never blocks a non-insider's
  redeem or cancel (`test_FF_shares_thirdPartyRequestsForAVictim_doNotBlockItsExit`). It also cannot block a
  victim's claim (claim delivers to the controller and is callable by anyone).
- A request whose controller is the vault itself delivers to the vault (self-transfer); the requester loses the value
  to the holders or to an orphaned escrow balance. Self-harm only, no other depositor loses.
- **GR2-FF-01** (below) is the one case where a third party can make a call by someone else revert.

## 3. Findings

### GR2-FF-01 (Info): a third party can make an insider's requestRedeem revert until the insider cancels a gifted deposit

- **Location:** GainsVaultLogic.sol:64-67 (`insider = _isInsider(msg.sender) || _isInsider(controller)`, the request
  goes to `currentEpoch + 1`), :94 (`requestRedeem` reverts `RequestPending` while `r.epoch > currentEpoch`).
- **Scenario:** a stranger calls `requestDeposit(10 USDC, feeRecipient)` (or the manager / owner as controller). The
  insider's request now sits in the next epoch, so the insider's `requestRedeem` reverts `RequestPending`. The insider
  calls `cancelDepositRequest` (always allowed; GR1-32 resets the epoch), receives the stranger's 10 USDC, and redeems.
  The deferred deposit also arms `insiderInQueue`, i.e. the known GV-05 one-hour wait on the next deposit-pricing settle.
- **Impact × likelihood:** no value moves the wrong way; the griefer pays the insider ≥ MIN_DEPOSIT (10 USDC) per use;
  the insider needs one extra transaction (an automated fee-recipient redemption would see one revert). Impact 0 USDC
  of depositor value × likelihood low → Info. Not reachable for non-insider controllers.
- **PoC:** `FundFlowR2.t.sol::test_GR2_FF_01_strangerDepositForInsiderBlocksItsRedeemUntilCancel` (passes).
- **Optional fix:** refuse `requestDeposit` where `controller ≠ msg.sender` and the controller is an insider, or let an
  insider's `requestRedeem` coexist with a deferred deposit. Not needed for safety.

## 4. Open questions

- The `transferFrom` that Gains performs inside `openTrade` / `increasePositionSize` / `updateLeverage` is in the
  verified facet source and was checked on the fork in round 1 (approvals back to 0, exact pull). The leverage-decrease
  amount uses the same formula as Gains (`collateral × leverage / newLeverage`); a rounding difference on Gains' side
  would revert the request (under-approval) or leave an allowance that `_clearApproval` removes. Not re-run on a fork
  in this pass.
- The five Gains facets that are not on Sourcify (VERIFY-R2 "Not covered") could in principle hold another
  third-party entry point on trader positions; the live `eth_call` checks above cover the two known ones only.

## 5. How the evidence was produced

```bash
# tests (worktree, forge lock held): 2026-10-19, 31 passed, 0 failed (4m18s incl. build)
cd contracts && forge test --match-path "test/audit/gains/r2/FundFlowR2.t.sol"
# live reads (eth_call only, public RPC, block 516385882)
cast call 0xaf88d065e77c8cC2239327C5EDb3A432268e5831 "allowance(address,address)(uint256)" <vault> 0xFF162c694eAA571f685030649814282eA457f169
cast call 0xFF162c694eAA571f685030649814282eA457f169 "getTradingDelegate(address)(address)" <vault>
cast call 0xFF16…f169 "delegatedTradingAction(address,bytes)" <vault> $(cast calldata "closeTradeMarket(uint32,uint64)" 0 1) --from 0x…dEaD   # 0x0cf0b6f5
cast call 0xFF16…f169 "registerPotentialReferrer(address,address)" <vault> 0x…dEaD --from 0x…dEaD                                      # 0x6c5ffd54
cast code <vault>; cast code [an earlier vault implementation]   # clone target and linked library PUSH20s
```
