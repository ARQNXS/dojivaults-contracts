# GR2-LIVE-01 fix: the vault keeps its own Gains index set, so NAV and settle are O(open items)

**Internal, AI-assisted review. Not an independent audit.** Proposed core patch for the fix round (design + working
core, not the finished change; see "Left for the fix round"). Nothing in `contracts/src` was changed. Patch against
4ec6feb, applies with `git apply` from the repo root (checked with `git apply --check` on the worktree).

## How Gains assigns indexes (verified in the saved facet sources, TradingStorageUtils / TradingCallbacksUtils)

- Two per-trader counters, `getCounters(trader, 0 = TRADE | 1 = PENDING_ORDER).currentIndex`; an index is
  `currentIndex` at store time and the counter only grows (indexes are never reused).
- **Trade indexes** are assigned by `storeTrade`: when the vault places a limit / stop order (at the request), when
  Gains fills a vault market open (in the callback, *not* at the request), and when Gains executes a resting limit /
  stop (the callback closes the resting trade and stores a **new** trade with a new index, `executeTriggerOpenOrderCallback`).
- **Pending-order indexes** are assigned by `storePendingOrder` at the vault's request (market open / close, partial
  open / close, leverage update). Trigger orders (TP / SL / liquidation / limit execution) are filed under the bot, not
  the vault.
- `getTrades` / `getPendingOrders` walk `0 .. currentIndex` until the last open item: the cost is the lifetime index
  count, which is the finding.

So the vault cannot know a market open's trade index at the request, and Gains creates trade indexes without a vault
call. A cursor over the counters covers both.

## Design (the patch)

`GainsNav` keeps, at an ERC-7201 slot (`cast index-erc7201 dojipad.gains.indexset`, so `VaultStorage` is untouched):

```
struct IndexSet { uint32 tradeCursor; uint32 orderCursor; uint32[] trades; uint32[] orders; }
```

Invariant: every index below a cursor is either in the tracked array (it was open when last seen) or known closed;
indexes at or above the cursor are "unseen".

- **Readers** (`readTrades`, `readPendingOrders`, `tryReadTrades`, and through them `snapshot`, `blockingOrders`,
  `hasPendingOrder`, `redemptionShortfall`, `flatten`, `_cancelResting`): read each tracked index plus every unseen index
  `[cursor, counter)` with one `getTrade` / `getPendingOrder((trader, index))` call each, decoded with the same
  range-checked, append-tolerant decoder as the lists (GR1-08, GV-01 plausibility kept), and keep the open ones. The
  result is the same array the list call returned, so every caller is unchanged. Nothing unseen is ever missed: a
  fill-created or limit-execution trade is valued before any sync (fix test).
- **`sync(maxSteps)`** (vault `syncIndexes(maxSteps)`, permissionless): drops tracked entries that are no longer open
  (swap-pop) and pulls up to `maxSteps` unseen indexes into the set (trades first), advancing the cursors. The vault
  calls `sync(max)` at the start of `settle`, `checkRisk`, `openTrade`, `increaseTrade`, `updateLeverage`, so the unseen
  range stays at "fills and limit executions since the last such call" and the tracked arrays at "open items + those
  closed since the last such call" (≤ MAX_POSITIONS-ish).
- **Fail closed / never block a stop:** an index that cannot be decoded is kept tracked (the strict readers revert
  `DiamondLayoutChanged`, as before); `getCounters` is read with a staticcall, so the full-stop path (`tryReadTrades`)
  returns `ok = false` instead of reverting, and `sync` pulls nothing when the counter is unreadable.
- **Views:** `GainsVault.openItems()` (open trades and pending orders through the index set) and `indexSet()`; the lens
  (`timedOutOrders`, `openPositions`) uses `openItems()` instead of running `GainsNav` in its own context (a lens has no
  index set: it would have walked the whole history through single reads).
- **Interface:** `IGainsDiamond.Counter`, `getCounters(address,uint8)` (selector `0x0212f0d6`) and
  `getPendingOrder((address,uint32))` (`0xc6e729bb`), both on facet `0xaFBD02cf04baAC6726ae017AC446e3Ae5E1190D9` of
  the Arbitrum diamond per the saved facet table. Mocks: `MockGainsDiamond.getCounters` / `getPendingOrder(Id)`,
  `EvilDiamond.getCounters` (keeps its re-entrancy probe in the read path).

Gas: per state-changing NAV path, one `getCounters` per kind plus one `getTrade` / `getPendingOrder` per tracked entry
in `sync`'s prune and again in the read (≈ 2 × open items single reads instead of 1 list read): on the mock, a settle
with one open trade costs 372,330 instead of 355,533 (+16.8k), flat from there.

## Fix test

`FixTest.t.sol` (`LIVE01FixTest`, mock diamond; `syncIndexes` / `indexSet` called with low-level calls so the file
compiles on 4ec6feb):

| Test | Asserts | Unfixed | Fixed |
|---|---|---|---|
| `test_LIVE01_fix_navParityWithTheListReaderOnAMixedState` | 2 filled trades, a resting limit, a pending open, a pending close, plus a closed trade, a cancelled limit and a timed-out order in the history: `venue()` value 25,993,000,000, notional 323,499,999,999, orders 5 / pending 2 / blocking 1, `totalAssets` 103,993,000,000, lens `openPositions` 5 — the 4ec6feb list reader's own numbers | PASS (it is the old reader) | PASS (same numbers) |
| `test_LIVE01_fix_fillCreatedIndexValuedWithoutSync` | a trade Gains stores at the fill is in NAV without a sync | PASS | PASS |
| `test_LIVE01_fix_gasFlatInLifetimeIndexes_churn` | 300 limit place / cancel cycles through the vault: `checkRisk` and `settle` within +30k gas of before; only the open trade is tracked | FAIL: checkRisk 221,524 → 1,089,718, settle 355,533 → 1,231,833 | PASS: settle 372,330 → 372,330 |
| `test_LIVE01_fix_gasFlatInLifetimeIndexes_50k` | both counters at 50,000 (vm.store), the vault synced once in 10 chunks: `checkRisk` / `settle` within +30k gas | FAIL: checkRisk 292,907,564, settle 339,698,746 | PASS: settle 372,330 → 372,330 |

## Existing tests (patched scratch tree, 40 suites)

**395 pass, 9 fail** (404 tests). Failing, by design of the change (they inject malformed diamond output by
`vm.mockCall` on `getTrades` / `getPendingOrders`, which the vault no longer calls, or assert list behaviour of the mock):

| Test | Port to |
|---|---|
| `fixes/R2Regression.t.sol::test_GV01_fieldInsertedBeforePositionSize_revertsLayoutChanged`, `test_GV01_implausibleOpenTrade_revertsLayoutChanged`, `test_GV01_openTradeWithImpossibleSize_revertsLayoutChanged`, `test_GV02_knownNonHoldingTypes_stillDoNotBlock` | mock `getTrade(vault, i)` / `getPendingOrder((vault, i))` for a tracked or unseen index instead of the list |
| `verify-r2/VerifyR2Mock.t.sol::test_R2_GV02_everyRealOrderType_classified` | same, per order index |
| `fixes/R1Regression.t.sol::test_GR1_08_flattenIndicesWorksWhenTheTradeListIsUnreadable`, `integration/IntegrationMock.t.sol::test_GR1_08_unreadableLayout_revertsDiamondLayoutChanged_flattenIndicesCloses`, `r2/LivenessStateMachine.t.sol::test_LIVE_SM_D1_unreadableLayout_flattenIndicesThenSettle` | make `getTrade` / `getCounters` unreadable instead of `getTrades` |
| `gains/GainsBranches.t.sol::test_NavSkipsClosedTradesAndOrders` | its second assertion (closed entries listed by the mock are counted) no longer applies; keep the value assertion |

Fork tests that call `GainsNav.snapshot` from a contract etched at a real trader's address (`verify-r2/VerifyR2Fork.t.sol`)
now read that trader's history through single reads from cursor 0 (correct, but O(history)); they should call
`sync` in chunks first or keep a list-based reader in the test.

## Left for the fix round

1. Port the 9 tests above; add a fork test on the real diamond (counter, `getTrade`, `getPendingOrder` decoding, a
   limit execution creating a new index, the 32M settle at a large history).
2. Remove the now-unused list helpers (`_list`, `_call`) or keep a list reader only for off-chain views.
3. Decide the `sync` bound in `settle` / `checkRisk` / trading (now unbounded: the unseen range is small by
   construction, but a vault that only ever has Gains-created indexes between two syncs is bounded only by
   MAX_POSITIONS of resting orders). A `MAX_UNSEEN` revert with "call syncIndexes" is an option.
4. Migration of an existing vault is impossible (EIP-1167 clones of a fixed implementation): a new implementation and a
   new factory; a new vault starts at counter 0, so no catch-up is needed.
5. Executor: stop calling `getTrades` / `getPendingOrders` for the vault where gas matters (eth_call is fine, but cap
   it); use `openItems()` / `indexSet()`. Keep the counter monitor from ALERT.md for 4ec6feb vaults.
6. Gas measurements on a fork at 20 positions (`LivenessGasFork.t.sol` against the patched vault).
