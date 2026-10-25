# Gains round 1, section 3.5: external integrations

Internal review (sub-reviewer), not an independent audit. Source: contracts/src/gains/* at audit/gains-r1 (9f39013).
Tests: `contracts/test/audit/gains/integration/IntegrationMock.t.sol` (11, mock diamond) and
`IntegrationFork.t.sol` (6, Arbitrum One fork at block 515,219,884, real gTrade v10 diamond, LifecycleForkBase oracle
emulation). All 17 pass.

```
FOUNDRY_OUT=out-integ FOUNDRY_CACHE_PATH=cache-integ forge test --match-path 'test/audit/gains/integration/*'
# fork suite needs ARBITRUM_RPC_URL (skips without it)
```

| Id | Title | Verdict | Severity (proposed) | Test |
|---|---|---|---|---|
| INT-01 | A Gains facet upgrade that adds a field to `Trade` (or anything nested in `PendingOrder`) breaks the vault's fixed decoder: NAV, every settle mode, capped deposits, openTrade, checkRisk and flatten revert; the vault cannot adapt (diamond and ABI baked in, not upgradeable); recovery only by closing trades one index at a time down to <= 1 | CONFIRMED (mock PoC + live word counts) | Medium | IntegrationMockTest.test_INT01_tradeLayoutChange_freezesNavSettleAndFlatten, test_INT01_pendingOrderLayoutChange_blocksNavFlattenAndOperatorReduce; IntegrationForkTest.test_INT_fork_returnLayoutsMatchIGainsDiamond |
| INT-02 | A feed that halts exceptionally (invalid opcode, or a state write under the staticcall) burns 63/64 of the gas of the NAV read: NAV readers run out of gas instead of reverting `PriceStale` | CONFIRMED | Info (trust T4, curated Chainlink proxies revert normally) | IntegrationMockTest.test_INT_feedsAreStaticcalled (977M gas used for one read) |

No finding in the known lists (NAV-01..11, LC-01..07, GOV-01..08, ADVERSETRUNC, D-*) was rediscovered. LC-06 (Gains
pause / close-only / USDC blacklist) is the closest neighbour of INT-01: there Gains changes *state*, here it changes
the *ABI*.

## INT-01 (Medium): Trade / PendingOrder ABI change on a facet upgrade

**Location.** IGainsDiamond.sol:12-28 (Trade, 15 ABI words), :53-61 (PendingOrder, 21 words, Trade nested first);
decoders at GainsNav.sol:43-44 (snapshot), GainsVaultMath.sol:134 (ordersPending, settle), :151
(redemptionShortfall, operator reduce), GainsVaultLogic.sol:662-663 (flatten), GainsVaultLens.sol:205/228. The diamond
address is set once (GainsVaultGovernance.sol:78) and vaults are non-upgradeable clones; the factory's diamond is
immutable.

**Description.** Gains packs `Trade` in storage with a trailing placeholder and grows the struct by carving new fields
out of it. Storage stays compatible, the ABI does not: every field is one word. v10's layout ends
`sl, isCounterTrade (8), positionSizeToken (160), __placeholder (24)`; 8 + 160 + 24 = 192 bits, the width of the single
`uint192 __placeholder` that ended the v8/v9 Trade (gTrade public source; not re-verified on chain here, only the
v10 word counts are). So the v9 → v10 upgrade already grew the Trade ABI from 13 to 15 words. The PoC repeats that
step once more: the 24-bit placeholder becomes `uint16 newField, uint8 __placeholder` (16 words).

What the old 15-word decoder then does (Solidity ABI v2 decoding validates every value):
- `Trade[]` with n >= 2: element i is read 15 words in; element 1's `index` lands on element 1's `user` word (an
  address), out of uint32 range → revert. n = 1: the first 15 words decode, the new field is read as `__placeholder`
  (silently accepted while it fits 24 bits; the vault cannot detect the upgrade). n = 0: fine.
- `PendingOrder[]` with n >= 1: every field after the nested Trade shifts by one word (`index` reads the order's
  `user`) → revert. n = 0: fine.
- Single structs (`getTrade`, `getTradeInfo`, ...): a field appended at the end is ignored.

Effects with >= 2 open trades (test 1): `totalAssets`, `checkRisk`, `accrueFees`, `settle` by the manager (normal),
the guardian's exit-only emergency settle, `openTrade`, `requestDeposit` whenever `depositCap != 0` (every factory
vault: create requires 0 < cap), and the guardian's `flatten` all revert. Still working: `requestRedeem`, `claim`,
`triggerEmergency`, `closeTrade` / `reduceTrade` by trader or guardian (no list decode), `cancelOrder`,
`cancelTimedOut`, `setSlTp` (single `getTrade`). With >= 1 pending order (test 2) `totalAssets`, `flatten` and the
operator's shortfall `reduceTrade` revert; settle is `OrdersPending` in that state anyway. Recovery shown in test 1:
the guardian closes trade `a` by index, the one remaining trade decodes silently, the exit-only settle runs again.

Off chain the same upgrade changes the topic0 of every diamond event that carries a Trade (MarketExecuted,
LimitExecuted, TradeStored, PendingOrderStored): server/src/venues/gains/fills.ts:41 keys events by
`toEventSelector`, so the executor silently stops seeing fills rather than failing, and its own `getTrades` /
`getPendingOrders` reads (chain.ts:192/197, abi.ts:81/83) mis-decode the same way.

**Impact.** No loss by itself; a fleet-wide liveness failure. Every Gains vault (all share one implementation and one
IGainsDiamond) loses settle in every mode, deposits, new trades, risk checks and the batch exit at the same moment.
Redemptions are requested but not paid until the manager or the cold guardian closes trades individually (indexes from
`getTrade(vault, i)` / events) down to at most one, each a market close at that moment's price (crystallises PnL at a
time the vault did not choose). With 20 positions: up to 19 close transactions (~1.4M gas each) by a cold Safe guardian
if the manager is absent. Holders cannot migrate out by themselves (redeeming needs settle). The silent n = 1 case
means a value inserted before the old last word would be misread as an existing field without any revert (not shown:
Gains has so far only split the trailing placeholder).

**Likelihood.** Needs Gains governance to ship a facet upgrade that changes one of these struct ABIs (behind Gains'
own timelock, publicly visible). It has happened at least once (v9 → v10, inferred above); each major Gains version
has changed the Trade or TradeInfo layout. Proposed: impact 3/5 (temporary lock of every vault's redemptions with a
role-operated exit path; no direct loss) x likelihood 2/5 (external, announced, has precedent) → Medium. Not High:
an exit path exists and it is not exploitable by any attacker.

**Fix.** (1) Read `getTrades` / `getPendingOrders` through a low-level staticcall and check
`ret.length == 64 + n x stride`; on mismatch revert a named `DiamondLayoutChanged()` (also catches the silent n = 1
case). (2) Put the list decoding behind a small reader contract whose address the factory curates and each vault adopts
through its owner timelock (the setPairFeed pattern), so a Gains ABI change is absorbed by deploying a new reader.
(3) Give the guardian an index-based batch exit (`flattenIndices(uint32[])`) that decodes nothing. (4) Watch Gains'
timelock for diamondCut proposals that touch the selectors in IntegrationForkTest._selectors() and pin the expected
word counts in a monitor (the fork test asserts them today).

## INT-02 (Info): feed exceptional halt burns the read's gas

GainsPrice.sol:325. `staticcall` forwards 63/64 of the remaining gas. A feed that reverts with `revert(...)` returns
the rest; one that hits an invalid opcode or writes state (a static-context violation) consumes everything forwarded.
test_INT_feedsAreStaticcalled: an etched feed that increments a counter makes `totalAssets()` revert `PriceStale(ETH)`
as designed, but the call used 977M gas of the test's budget. Under a real gas limit the outer NAV read then runs out of
gas with ~1/64 left instead of returning the named error (SPEC N6 assumes a named error). Feeds are curated Chainlink
proxies (trust T4) that revert normally; exits never read feeds. Fix (optional): `feed.staticcall{gas: 100_000}`.

## Checked and sound

| Item | Evidence |
|---|---|
| Every IGainsDiamond selector (10 requests, 24 reads) has a facet on the live diamond | test_INT_fork_everySelectorHasAFacet (DiamondLoupe.facetAddress) |
| Exact ABI word counts on live data: Trade 15, PendingOrder 21, TradeInfo 9, Collateral 5, GroupLiquidationParams 5, TradeHoldingFees 4, realized pnl 3, PairFlags 4, GlobalTradeFeeParams 7; decoded fields sane (user = vault, index 3, leverage) | test_INT_fork_returnLayoutsMatchIGainsDiamond |
| Units: price / SL / TP 1e10 (stored as sent), leverage 1e3, slippage 1e3 percent (open 1,000 = 1%; flatten 250 bps → maxSlippageP 2,500), collateral index 3 = USDC with precisionDelta 1e12 (checked at initialize, GainsVaultGovernance.sol:70-72) | test_INT_fork_openTradeEncodingAndExactApproval, test_INT_fork_slTpAndFlattenSlippageUnits |
| trade.user = vault, collateralIndex = $.collateralIndex, referrer address(0) (no active referrer recorded), never a trading delegate | test_INT_fork_openTradeEncodingAndExactApproval |
| Approvals exact and cleared: market open, limit open (refund to the wei on cancel), increase with collateral, leverage decrease with odd wei (vault's delta = live UpdateLeverage's `c x lev / newLev - c`; collateral after fill = c + delta exactly) | test_INT_fork_limitOrderExactPullAndRefund, test_INT_fork_leverageDecreaseAndIncreaseExactPull, testFuzz_INT_leverageDecreaseDeltaExact (512 runs) |
| Diamond pulling less than approved (nothing) leaves allowance 0 (`_clearApproval`); a reverting request reverts the whole tx, approval included; flatten's try/catch wraps only cancelOpenOrder / updateMaxClosingSlippageP, which carry no approval | test_INT_approvalClearedWhenDiamondPullsLess; GainsVaultLogic.sol:673-679 |
| Return values: request functions are declared without returns (extra returndata ignored); every read's declared return matches the live word count | fork layout test |
| Reentrancy, reads: IGainsDiamond reads, policy views, factory views and feeds are all STATICCALL; a diamond whose reads try a state-changing reentry cannot (settle + checkRisk ran with every read probing) | test_INT_diamondReadsCannotReenter, test_INT_feedsAreStaticcalled. settle makes no state-changing external call at all (GainsVaultLogic.sol:212-337) |
| Reentrancy, requests: from a CALL into the diamond (approval outstanding) only permissionless entries are reachable (settle, openTrade Unauthorized; cancelTimedOut harmless); a hostile diamond could keep the collateral anyway (trust T2), so no extra exposure | test_INT_diamondRequestReentryReachesOnlyPermissionless |
| Reentrancy, token hooks (USDC has none; ERC-777 style mock): from requestDeposit's transferFrom the guarded requestDeposit is refused (Reentrancy) and the unguarded cancelDepositRequest leaves exact books; from claim's payout a second claim / cancelRedeemRequest / cancelDepositRequest pay nothing (CEI: request and reserve zeroed before the transfer, GainsVaultLogic.sol:152-159, 114-118) | test_INT_hookTokenReentryFromDeposit, test_INT_hookTokenReentryFromClaim |
| Unguarded entries reviewed: claim, cancelDepositRequest, cancelRedeemRequest (CEI, internal share moves); trading entries (role-gated, one external request each, no state after the call except the approval clear); checkRisk / accrueFees (static reads only); execute (self-call to six whitelisted onlySelf selectors) | by reading + tests above |
| No native ETH: vault, implementation, policy, factory and lens have no receive / fallback; create requires msg.value = 0 without an agent and forwards the whole msg.value (not only minAgentGas) to the agent, so the factory keeps nothing | test_INT_noNativeEthPaths, test_INT_factoryForwardsAllEthToAgent; GainsVaultFactory.sol:255, :314-317 |
| create sends the agent ETH before `isVault` / `_vaults` bookkeeping (GainsVaultFactory.sol:314-321); the agent is a registrar-signed wallet and nothing reachable from it reads those fields to its advantage | by reading |
| No receiver hooks: Gains pays USDC by transfer; the vault implements no ERC-721/1155/777 receiver | by reading |
| Executor event ABI (server/src/venues/gains/diamondAbi.ts, abi.ts) matches the v10 Trade / PendingOrder / TradeInfo layouts used on chain | by reading; see INT-01 for the upgrade case |
