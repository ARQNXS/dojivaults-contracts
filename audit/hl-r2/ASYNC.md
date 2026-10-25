# hl-r2: asynchrony between HyperEVM and HyperCore (brief section 3.2)

**This is an internal, AI-assisted review. It is not an independent audit and must not be presented as one.**

Sub-reviewer: async / conservation (branch `audit/hl-r2-async`). Code: `contracts/src` at `eed5e85` (unchanged since
the round 4 deploy). Tests: `contracts/test/audit/hl-r2/async/` (this file names them). Nothing deployed, no
transaction sent, `contracts/src` never committed modified (sensitivity edits were reverted, see INVARIANTS.md).

Run:

```bash
cd contracts
forge test --skip "src/gains/**" --skip "test/gains/**" --skip "test/audit/gains/**" --skip "script/**" \
  --match-path "test/audit/hl-r2/async/*.t.sol" --match-test "test_HLR2|test_sim" -vv     # 14 pass
```

## 1. The simulator (CoreSim)

`test/audit/hl-r2/async/CoreSim.sol` replaces the hash-keyed mocks of `test/Base.t.sol` with an explicit model of
HyperCore. Etched code forwards every precompile (0x801, 0x803, 0x806, 0x807, 0x809, 0x80a, 0x80F, 0x810, 0x813) to
`CoreSim.read` by `staticcall` (answers are computed from state), and the CoreWriter at `0x3333...3333` to
`CoreSim.enqueueAction`. `SimDepositWallet` stands in for the CoreDepositWallet.

| HL behaviour (docs / SDK) | Sim model |
|---|---|
| Precompile reads = Core state when the EVM block is built | a queued item with `at = B` is visible from EVM block `B + 1`; `process()` runs at the start of every handler step / test tick |
| CoreWriter actions execute after the EVM tx (orders / vault transfers a few seconds later) | queued with `at = B + actionDelay[id]`; failed actions (insufficient balance, withdrawable, unknown) and injected drops are recorded, never revert on the EVM |
| Actions of an account that does not exist yet are dropped (A-13) | same |
| CoreDepositWallet takes the USDC at once, credits Core spot later | `depositDelay` blocks, or never (`depositLost`, counted as a lost transfer); the first credit pays the 1 USDC activation fee |
| Core -> EVM: sendAsset to the system address debits spot, a system tx delivers on the EVM | debit when the action executes, delivery `evmDelay` blocks later (or never) |
| Agent (API wallet) signs off chain | `agentAct`: spot <-> perp moves (agentSendAsset), opens and closes at mark; accepted only while Core's `dojipad` slot holds that agent (whatever the EVM side believes) |
| Perp account value = cash + unrealised PnL; withdrawable = value - initial margin, capped at cash | same (initial margin = notional / 10) |
| Trading PnL | explicit ghost: `shock` (realised), mark moves on positions (unrealised), realised on reductions |

Self tests: `CoreSimSelfTest` (seed landing and A-13 agent sync, round-trip bridge, orders / PnL / flatten, dropped
action). The sim keeps a perp account value >= 0 in the invariant runs (HL liquidates before; see A06 for the
transient).

## 2. Where the vault's view of Core can be stale, double counted or missing

Each line: the contract's view, what is really on Core / in flight, the guard, and the test.

| # | Situation | View vs truth | Guard in src | Result | Test |
|---|---|---|---|---|---|
| S1 | EVM->Core bridge, deposit wallet credit pending (1+ blocks) | idle down, Core not up: **missing** | 10 block window, `totalAssets = equityAtBridge`, landing on spot (R-02 / R3-01) | sound while the credit lands within 300 blocks | `test_sim_bridgeRoundTrip`, invariant F2 |
| S2 | Core->EVM bridge, debit done, delivery pending | **missing** | same window, landing on EVM balance net of tracked flows | sound within 300 blocks | same |
| S3 | Either transfer later than `MAX_UNLANDED_BLOCKS` (300) | written off as lost; it lands later | none | **HLR2-A02** (mispriced settle, phantom performance fee) | `test_HLR2_A02_*` |
| S4 | A written-off transfer lands inside the NEXT bridge's window (same direction) | latches the next bridge as landed | none | **HLR2-A05** (next window closes at 10 blocks with its own USDC in flight) | `test_HLR2_A05_*` |
| S5 | Agent moves landed spot to perp in the credit's Core block | landing never seen | runs to 60 / 300 blocks (safe direction) | **HLR2-A03** (300 block freeze, loss masking up to the amount) | `test_HLR2_A03_agentHidesLanding...` |
| S6 | Agent consumes withdrawable (opens size) ahead of the vault's class transfer, or holds spot in orders | bridge home fails silently | 300 block cap | **HLR2-A03** (same freeze; R3-05 masking now agent-reachable) | `test_HLR2_A03_agentMakesBridgeHomeFail` |
| S7 | Agent moves perp to spot during a to-Core window while the credit is late | landing faked, window closes at 10 blocks | none (R3-01 residual, documented as trust boundary) | **HLR2-A04** (settle at NAV minus the transfer in flight) | `test_HLR2_A04_*` |
| S8 | Full stop: `addApiWallet(burn)` dropped / failed on Core | EVM `agent = 0`, Core agent live | none, and no way to re-send | **HLR2-A01** | `test_HLR2_A01_*` |
| S9 | Negative perp account value (liquidation shortfall) with spot USDC | one-sum floor nets spot against it: NAV **under** by the shortfall; bridging the spot home removes the netting | L-05 | **HLR2-A06** (Info) | `test_HLR2_A06_*` |
| S10 | Settle in the same block as the vault's own Core actions (orders, flatten, moveUsd) | precompiles show pre-action state | orders / class transfers do not move NAV at fill-at-mark; bridges open a window that blocks settle | no issue found (flatten slippage is a real cost, N2-03) | invariant (managerOrder, flatten, moveUsd in the handler) |
| S11 | `bridgeToEvm` sends class transfer + sendAsset; one of the two fails | both orders: funds stay on Core (spot or perp), counted | window then 300 block cap | liveness only (no NAV error) | `test_sim_droppedActionDoesNotRevert`, invariant (`faults`: drop class / send) |
| S12 | Flatten IOC that does not fill | position stays, NAV correct | none needed (no EVM state recorded, retryable) | no issue | invariant (flatten by each role) |
| S13 | Donations (EVM USDC to the vault, Core spot to the vault) | latch a landing early, replace the missing amount | - | costs the donor the amount, I3-03 holds | analysis |
| S14 | Insider deposit delay (R3-02) vs asynchrony | insiders priced >= 1 h into the next epoch | R3-02 | unaffected: the delay is timestamp based, no Core state involved | invariant (owner / manager / fee recipient deposit) |
| S15 | Deposit cap, lens previews, `emergencyFillBps` between block 60 and 300 of an unlanded transfer | `totalAssets()` reads live (missing) while `bridgePending()` holds settle | R3-08 | views only; `clearBreach` uses `sharePrice()` there (A07, Info) | analysis |
| S15b | A bridge of less than `BRIDGE_LANDING_TOLERANCE` (1 USDC; possible as "the full available amount") | `want = 0`: counted as landed at once, the window closes after 10 blocks with the dust in flight | documented tolerance | NAV short by < 1 USDC for the delivery time; harmless (found by the 2,048-run campaign, then allowed in F2) | analysis |
| S16 | Double count of a transfer on both sides | never observed: EVM->Core debits the EVM first, Core->EVM debits Core first; reads in the bridge block see the pre-action state | L-04 snapshot in the window | none found in 2 x 1M invariant calls (F1 never fired) | invariant F1 |

No path was found where a settle prices at a NAV **above** the true NAV (invariant F1 held in every campaign), apart
from an artefact of the first sim (negative perp value; S9), which is the opposite direction on HL.

## 3. Findings

> **Correction (lead, 2026-10-21).** The fixes below were patched in `fixes/patches/a-series/` (A01, A02, A04, A05, A08). Two of the suggestions here are wrong and were not used:
> - **"spot + rawUsd" as the landing signal (A03 / A04).** On mainnet rawUsd moves by the notional of every fill (`evidence/async/rawusd-2026-10-21.txt`), and CoreSim reported rawUsd as plain cash. The patch uses spot **and** spot + rawUsd + signed entry notional.
> - **Fix (1) of A08** (burn at the checkpoint price, pay at the live price). It overpays in a real loss (46.67 against a fair 40, `fixes/patches/a08/README.md`). The patch holds the settle while the NAV is short by a late transfer instead.

Severity scale as CONTEXT.md. Numbers from the PoCs (the platform vault policy: 5x, daily loss 20%, drawdown 50%, maxNavMove
20%, 2% / 20% fees, 33% protocol share on hosted vaults).

| ID | Sev | Title | PoC |
|---|---|---|---|
| HLR2-A08 | **High** (conditional, low likelihood) | An exit-only settle prices redemptions at min(NAV, checkpoint) with no lower bound: at a short NAV (the emergency unwind's bridge home written off after 300 blocks) every requested share is burned for about 0 and counted as paid in full; with supply 0 the next 10 USDC deposit owns the late arrival | `test_HLR2_A08_exitOnlySettleAtWrittenOffNavBurnsRedeemersForZero` (found by the 2,048 x 500 campaign) |
| HLR2-A01 | **Medium** | A dropped burn approval leaves the agent live on Core through a full stop, and nothing can re-send it | `test_HLR2_A01_droppedRevokeLeavesAgentLiveAndCannotBeRetried` |
| HLR2-A02 | **Medium** (low likelihood) | A transfer that lands after `MAX_UNLANDED_BLOCKS` is written off; normal settles price deposits and redemptions at the deflated NAV, the late arrival is a gift to the new depositors / remaining holders (on a full exit: to the fee holders) and is then charged a performance fee | `test_HLR2_A02_lateLandingPricesDepositAtDeflatedNav`, `test_HLR2_A02_lateLandingUnderpaysRedeemerAndMintsPerformanceFee`, `test_HLR2_A02_fullExitThenLateLandingGoesToFeeHolders` |
| HLR2-A03 | Low | The agent can hide a landing or make a bridge home fail: settle, bridges and `moveUsd` wait 300 blocks per bridge and `checkRisk` masks a loss up to the bridged amount meanwhile | `test_HLR2_A03_agentHidesLandingFreezesSettleAndMasksLoss`, `test_HLR2_A03_agentMakesBridgeHomeFail` |
| HLR2-A04 | Low | The agent can fake an EVM->Core landing (perp -> spot); with a late credit the window closes after 10 blocks and a settle prices without the USDC in transit | `test_HLR2_A04_agentFakesLandingWhileDepositLate` |
| HLR2-A05 | Low | A written-off transfer that lands later latches the next bridge in the same direction | `test_HLR2_A05_lateOldLandingLatchesNextBridge` |
| HLR2-A06 | Info | A negative perp account value is netted against spot USDC in `coreEquity` | `test_HLR2_A06_negativePerpNettedAgainstSpot` |
| HLR2-A07 | Info | `clearBreach` re-bases the daily reference on `sharePrice()`, which reads the live (short) NAV between block 60 and 300 of an unlanded transfer | analysis |

A08 is High but not exploitable at will on a live vault today: it needs the NAV to read short at an exit-only
settle, which in this domain means a Hyperliquid-side delay above 300 EVM blocks on the bridge home of an emergency
unwind (the moment when most of the NAV is in flight). Once that happens, the loss needs no attacker (the keeper's
own exit-only settle burns the redeemers) and the gain goes to an unprivileged depositor. A01 needs a dropped Core
action and a compromised or rogue agent; A02 needs the same HL delay. Live exposure is about 172 USDC (CONTEXT.md).

### HLR2-A08 (High, conditional): exit-only settles burn redeemers at a short NAV

**Location.** `VaultLogic.settle:242-244` (exit-only `priceNav = min(nav, checkpointNav)`, no lower bound),
`:256-269` (`redAssets` from `priceNav`; when `available >= redAssets` everything is burned, the partial fill /
share return of V-01 only applies when liquidity is short), `VaultGovernance.exitEmergency:271-281` (a settle that
burned every requested share counts as "paid in full"), `VaultMath.toShares:188-191` (supply 0: first mint 1:1
whatever the NAV) and `VaultPolicy.nextCheckpoint:234-236` (checkpoint 0 is unbounded, N-12).

**Description.** The exit-only rule protects the holders who stay (redeemers never get more than the checkpoint),
but nothing protects the redeemers from a NAV that reads too LOW. In an emergency (or an overdue epoch) the exit-only
settle has no NAV band. If the NAV is short when it runs, the redemptions are priced at the short NAV; when the idle
USDC covers that (small) amount, all requested shares are burned, nothing is returned, and the epoch is recorded as
fully paid, so the guardian may also end the emergency. The value that was missing reappears later and belongs to
whoever holds shares then; if nobody does, `toShares` mints the next deposit 1:1 and the depositor owns it.

**Numbers (PoC passes).** alice (only depositor, 100,001 on perp) redeems everything; the owner triggers emergency;
the keeper bridges the whole Core balance home and HyperCore is slow to deliver (2,000 blocks); after 300 blocks NAV
reads 0 (true 100,001); the keeper's exit-only settle pays alice **0** and burns all her shares; the guardian exits
the emergency and clears the stop; the transfer lands; carol deposits 10 USDC and after the next settle holds
**100,011** (alice's 100,001). With other holders left (fee shares, other depositors) they split it pro rata
(A02 full-exit variant: the fee recipient and the protocol got 15 k of a 15 k written-off amount).

**Why it is reachable.** The emergency unwind is exactly "flatten, bridge everything home, settle exit-only": it is
the one moment when most of the NAV is in flight. A delay above 300 blocks on that bridge is enough; the keeper
(operator) settles automatically; any listed role can. The invariant found it unprompted: `ConservationPlatformVaultInvariants`
at 2,048 x 500 failed at run 500 (249,982 calls) with an 11-call sequence (redeem all, faults: delivery late,
keeperCycle: bridge everything home, roll, emergency, keeperCycle: exit-only settle at NAV 0, guardian exit + clear,
warp: lands, deposit, keeperCycle: settle) that F3 / F5 flagged at the deposit (a 300 k deposit took the 100 k).
Other ways to a short NAV at an exit settle are outside this domain but feed the same path: an abstraction mode in
which the spot precompile reads 0 (CONTEXT item 3, agent-settable before a stop), a negative perp transient (A06),
a precompile under-read.

**Impact x likelihood.** Impact: up to 100% of the redemptions priced in that settle (in the PoC, 100%), moved to
the remaining holders or to the next depositor (unprivileged). Likelihood: needs an under-read NAV during an
exit-only settle; for the late-landing trigger, an HL delay above 300 blocks on the unwind bridge (low). Rated High
(conditional loss of depositor funds, low likelihood); it would be Critical if a short NAV could be produced at will.

**Fix (describe).** (1) Never price an exit below what the vault can see as owed: in exit-only and redemption-only
settles, burn shares against the checkpoint price and pay at most the live price, i.e.
`redAssetsCp = toAssets(redShares, checkpointNav)`, `paid = min(available, toAssets(redShares, min(nav, cp)))`,
`burned = redShares * paid / redAssetsCp` (rounded down), so a short NAV becomes a partial fill and the unpaid shares
go back to the redeemers (the V-01 machinery already handles it); then `exitEmergency` keeps the emergency open
(`redeemBurned < redeemShares`). (2) No exit-only settle while a written-off transfer is unresolved (A02 fix (a)).
(3) First mint: when `supply == 0` and the NAV is above dust, do not mint 1:1 (mint at `assets * OFF` only if
`nav <= MIN_RISK_NAV`, otherwise refuse or price the leftover NAV into the first mint).

### HLR2-A01 (Medium): dropped revoke, agent stays live, no retry

**Location.** `VaultLogic._revokeAgent` (`src/VaultLogic.sol:623-630`: `if (old == address(0)) return;` then
`addApiWallet(burn)` fire-and-forget, `$.agent = address(0)`), `VaultLogic.syncAgent:601-607` (reverts on agent 0 and
in a full stop), `HyperVault.setAgent:252-255` (reverts in a full stop), `VaultGovernance._stop:234-240`.

**Description.** A full stop (guardian / sentinel / owner `triggerBreach`, `triggerEmergency`, `leaveHosted`, the
factory's `unregisterPlatformAgent`) revokes the agent by overwriting the Core `dojipad` slot with a burn address.
CoreWriter actions are fire and forget (`HyperCore.sol:17-20` says so). The EVM side sets `agent = 0` in the same
call. If HyperCore drops or rejects that approval, the agent stays approved on Core, and:
- `revokeAgent()` again is a no-op (agent is 0, nothing is sent; the PoC asserts no Core item was queued);
- `syncAgent()` reverts `ZeroAddress` (and `ReduceOnlyMode` in a full stop);
- `setAgent` (timelocked) reverts `ReduceOnlyMode` in a full stop; `triggerEmergency` runs `_stop`, also a no-op.
The only exits are: the guardian clears the stop, then the owner's 2 day timelock installs another registered
platform agent (which overwrites the slot), or the Core approval expires (`validUntil`; the platform vault's agent: 2027-01-06).

**Impact x likelihood.** The full stop exists to stop a compromised or misbehaving agent. In the PoC the agent opens
4 BTC long (4x, 400 k notional on a 100 k vault) during the emergency; a 10% move costs 40 k (40% of NAV). An agent
cannot withdraw, but it can lose the account's equity against its own counterparty account (wash trading, illiquid
perps, `vaultTransfer` into a vault it leads; CONTEXT item 1 lists the agent's powers). Loss bound: the Core equity.
Likelihood: needs both a dropped Core action and a hostile agent. Drop causes known: A-13 (account absent); others
unverified (assumption A3): L1 address rate limits (a hostile agent can spend the account's request budget with
cancels / noops right before the stop, if CoreWriter actions count toward it), Core-side validation of the approval.
Note on the rate-limit path: `syncAgent()` is permissionless and sends one CoreWriter action per call (only EVM gas,
`VaultLogic.syncAgent:601-607`), so if CoreWriter actions do count toward the vault address's L1 budget, anyone (not
only the agent) can spend that budget before a stop, and the revoke, flatten and bridge-home actions that follow can
be dropped. Evidence against it (read-only, `evidence/async/ratelimit-2026-10-20.txt`): the x402 Test vault's
agent was approved through CoreWriter (a contract has no other way) and its `userRateLimit` shows
`nRequestsUsed: 0`; the Copy HL Test Vault shows 5 requests for 4 agent fills plus at least two CoreWriter approvals.
So CoreWriter actions most likely do not count toward the address budget, and this drop cause is unlikely. The
remaining drop causes are unknown Core-side rejections; the finding is about the missing retry, which costs nothing
to add. Cheap hardening anyway: a cooldown on `syncAgent`.
Rated Medium (conditional loss bounded by Core equity, with no on-chain retry; likelihood low, see the evidence
below); the off-chain mitigation is that
the platform stops using the key, which does not help against a stolen key.

**Fix (describe).** Make the revoke idempotent and retryable: in a full stop let `revokeAgent()` always send
`addApiWallet(burn, AGENT_NAME)` even when `$.agent == 0` (only owner / guardian / sentinel / factory may call it, as
now), or add a permissionless `syncRevoke()` that re-sends the burn while `hardStop()`. The sentinel then re-sends
until `extraAgents` on the info API shows the burn wallet (the Copy HL Test Vault shows the revoke landed once).

### HLR2-A02 (Medium, low likelihood): late landing written off and mispriced

**Location.** `VaultMath.bridgeUnlanded:139-143` and `bridgePending:146-148` (cap `MAX_UNLANDED_BLOCKS = 300`,
`VaultTypes.sol:30`), `VaultMath.totalAssets:181-184`, `VaultLogic.settle:223-224` (the only guard is
`bridgePending()`), `VaultLogic._accrueFees:345-347` (performance fee on any price above the HWM).

**Description.** After 300 blocks (about 5 minutes of 1 s blocks) an unlanded transfer counts as lost and every
guard lifts. If it is merely late (Core->EVM system tx, or the CoreDepositWallet credit), the NAV reads short by the
amount until it lands. A normal settle then prices at the short NAV as long as it is within `maxNavMoveBps` of the
checkpoint (20% on the platform vault: no ratchet needed for a bridge below 20% of NAV) and below the daily loss limit (20%).

**Numbers (both PoCs pass).**
1. Deposits: 100 k vault, keeper bridges 15 k home, delivery 400 blocks late. At block 301 NAV reads 85,001
   (true 100,001), daily loss 15% (no breach), carol deposits 85 k and the keeper settles. After the landing carol
   holds 92,500 (+7,500, +8.8%), alice 92,501 (-7,500, -7.5%).
2. Redemptions + fee: alice 50 k + bob 50 k, 50 k on Core; 15 k bridged home late; bob redeems all at 85,001: paid
   42,500 for 50,000 fair (-7,500, 15%). After the landing the share price is 1.15 against an HWM of 1.00 and the
   next normal settle mints 1,500 USDC of fees (20% of the 7,500 "gain", 33% of it to the protocol): a performance
   fee charged on bob's money.
3. Larger bridges (> 20% of NAV): a DAILY_LOSS breach fires (permissionless `checkRisk`), redemption-only settles
   pay at min(live, previous checkpoint) once the hourly ratchet reaches the short NAV (20% per hour), deposits are
   carried; at the next UTC day the breach clears and, if it is still unlanded, a normal settle mints at it.
4. Full exit: the only depositor (alice, 100 k, 30 days of fees accrued) redeems everything while 15,001 is
   written off; she is paid 84,860. What remains is the fee shares (fee recipient + protocol treasury, about 165
   USDC of value). When the transfer lands they hold 15,141: the fee recipient 10,144 and the protocol 4,996 of
   alice's money (`test_HLR2_A02_fullExitThenLateLandingGoesToFeeHolders`). If no share at all were left, the next
   depositor would get it (first mint at 1:1, checkpoint 0 is unbounded, N-12).
5. In the invariant (`ConservationPlatformVaultInvariants`, coverage probe 24 x 300) the handler reached 3 such settles
   per 7,200 calls with 45 k of value moved to depositors (`M late deposit gain`); none of it is flagged because the
   rule is documented (R3-08 "after this, whatever is missing counts as lost").

Who gains: whoever deposits between block 301 and the landing (anyone can see it: `lastBridgeBlock`, the EVM balance
and the Core balances are public), and the holders who stay in when someone redeems; the manager and the protocol
through the performance fee after the landing. Who can cause it: nobody in the protocol; it needs a Hyperliquid-side
delay above 300 EVM blocks. Nothing in the docs bounds the Core->EVM or CoreDepositWallet latency; normal latency is
1-2 blocks. Who can predict it: everyone, once block 301 has passed with the transfer missing. Impact bound: bridged
amount x share of the vault priced in that settle. Likelihood: low (an HL incident), but the beneficiary needs no
privilege and the keeper settles automatically.

**Fix (describe).** Do not write a transfer off by the clock alone. Options, most conservative first: (a) keep a
missing transfer "pending" (no normal settle, no fee accrual, no new bridge) until it lands or the guardian writes it
off explicitly (`writeOffBridge()`, guardian only, after a long delay), exit-only settles still allowed at
min(NAV, checkpoint); (b) after the cap, carry the amount in `totalAssets()` (visible + `bridgeAmount`, like
`_check`) for normal settles and use the visible NAV only for exit-only settles, until the guardian writes it off;
(c) at minimum, record `unlandedWrittenOff` and refuse normal settles while it is non-zero, and exclude a later
landing of a written-off amount from the performance fee (raise the HWM by it when it lands).

### HLR2-A03 (Low): agent-made 300 block freezes and loss masking

**Location.** `VaultMath.bridgeArrived:151-159` (to-Core landing = spot only), `VaultMath.bridgeUnlanded:139-143`,
`VaultGovernance._check:171-176` (`min(snapshot, visible + amount)` while pending), `VaultLogic.bridgeToEvm:441-449`
(class transfer and send, checked against the block's precompile state only).

**Description.** Two agent-signable ways to keep `bridgePending()` true for 300 blocks:
- to Core: in the Core block of the credit the agent moves the landed USDC to perp (`agentSendAsset`); the spot
  signal never fires;
- to EVM: in the same Core block, ahead of the vault's actions, the agent opens size (or rests spot orders) so the
  class transfer / send fails.
Meanwhile settle, both bridges, `moveUsd` and fee accrual revert `BridgeInFlight`, and `checkRisk` reads
`min(snapshot, visible + amount)` where visible already holds the amount: a loss up to the bridged amount is masked.

**Numbers.** 150 k vault, keeper bridges 50 k to Core, agent moves it to perp; a 45 k loss (30% > 20% daily limit)
reads 0 for 300 blocks; carol's deposit cannot settle; `moveUsd` reverts; at block 301 the breach fires. Bridge
home of 50 k: the agent opens 9x; nothing comes home; pending 300 blocks.

**Impact x likelihood.** Liveness (5 minutes per keeper bridge, repeatable at every bridge the keeper makes) and a
5 minute masking window up to the bridged amount (R3-05, now reachable by the agent and not only the treasury). The
agent is inside the trust boundary (CONTEXT item 4), and the sentinel alerts on pending > 30 blocks. Low.

**Fix (describe).** For to-Core, also accept "spot + perp cash (rawUsd, excludes PnL) up by the amount" as the
landing (the agent's move keeps the sum); for to-EVM, have the keeper bridge only `min(spot, withdrawable)` with
headroom, and let the sentinel treat agent activity inside a pending window as an ACT. Document the masking bound as
"bridged amount, 300 blocks, reachable by the agent".

### HLR2-A04 (Low): agent-faked landing with a late credit

**Location.** `VaultMath.bridgeArrived:156`.

**Description / numbers.** 120 k vault, keeper bridges 20 k to Core, the credit is 100 blocks late; the agent moves
20 k perp -> spot; `syncBridge` latches; after 10 blocks NAV reads 100,001 (true 120,001, 16.7% low, inside every
limit); carol deposits 100 k and is settled; after the credit she holds 110,000 (+10 k from alice and bob).
Needs the agent and a late credit (> 10 blocks). Already named as an R3-01 residual (trust boundary); this PoC puts
a number on it. Medusa found it on its own (run 1, 3 h 23 min, a 6-call sequence: the agent's perp -> spot move is
queued in the same block as the keeper's `bridgeToCore`, the credit is late, the keeper settles 11 blocks later 809.9
USDC short; replay `MedusaReplay.t.sol`). The variant shows the agent does not even need to see the bridge first:
any perp -> spot move of at least the amount, landing in the window, latches it. Low. **Fix:** as A03, use `spot + rawUsd` (sum unchanged by the agent's move) as the to-Core landing
signal, so neither direction of agent move changes the latch.

### HLR2-A05 (Low): a written-off transfer latches the next bridge

**Location.** `VaultLogic._arm:465-473` (snapshots `evmAtBridge` / `spotAtBridge` without accounting for older
transfers still in transit), `VaultMath.bridgeArrived:151-159`.

**Description / numbers.** 30 k bridged home is late past the cap (written off); the keeper bridges 15 k home with
its own delivery 150 blocks late; the old 30 k arrives 100 blocks into the new window and satisfies
`bal >= evmAtBridge + want`: the new bridge is latched, the window ends with the new 15 k in flight; NAV 15% short;
carol's 50 k deposit settles at it and is worth 55,556 after the landing (+5.6 k). Only reachable after an A02
event. **Fix:** with A02 (a), there is no second bridge while a transfer is missing; otherwise carry the written-off
amount in the landing baseline (`evmAtBridge += writtenOff`).

### HLR2-A06 (Info): negative perp account value netted against spot

**Location.** `VaultMath.coreEquity:119-124` (one-sum floor, L-05).

If the perp account value goes negative before the backstop liquidation (shortfall transient), `coreEquity` nets it
against spot USDC, which on a standard (non unified / non portfolio margin) account is not perp collateral. PoC:
perp -10 k, spot 50,001: NAV 40,001; the spot can still be bridged home in full, after which NAV is 50,001 (+25%
without PnL). Under-read, short lived, no attacker; a `checkRisk` in the transient can fire a false daily loss.
Recorded so the L-05 rationale also covers this direction. Possible change: `max(0, perp) + spot` in standard mode
(keep the one-sum floor for unified / portfolio margin, where it is the right rule).

### HLR2-A07 (Info): `clearBreach` between block 60 and 300 of an unlanded transfer

`VaultGovernance.clearBreach:259-265` sets `dayStartSharePrice = sharePrice()` without a pending check;
`sharePrice()` uses `totalAssets()`, which is the live (short) NAV after block 60. A guardian clear in that window
lowers the day's reference by the transfer: a real loss of up to that amount later the same day reads smaller. Guardian
only. Fix: revert `BridgeInFlight` while `bridgePending()`, as `resume` does.

## 4. Hypotheses the lead asked to check

- (i) Late landing after 300 blocks: confirmed, A02 with numbers. Beneficiary: depositors in the deflated window and
  remaining holders against redeemers; the manager / protocol get a performance fee on the recovered amount.
  Nobody in the protocol can cause the delay; everyone can see it once it happens. Above 20% of NAV the path goes
  through a DAILY_LOSS breach and the hourly ratchet (item 3 of A02).
- (ii) Agent moves landed spot to perp: liveness cost 300 blocks per bridge plus loss masking (A03). Agent moves perp
  to spot to fake a landing early: NAV under-reads by the in-flight amount until it lands, only if the credit is
  later than 10 blocks (A04).
- (iii) Other: A08 (exit-only settles burn redeemers at a short NAV, found by the invariant), A01 (revoke not retryable), A05 (old landing latches the next bridge), A06, A07. `revokeAgent` with a
  dropped approval: A01. Flatten IOC that does not fill: no EVM state, retryable (S12). `bridgeToEvm` partial
  failures: liveness only (S11). Settles in the same block as Core actions: no mispricing found (S10).

## 5. Assumptions and open questions

- A3 (hl-r2): HL behaviour not in the docs is unverified. Specifically unverified here: maximum latency of Core->EVM
  delivery and of CoreDepositWallet credits (A02 assumes it is unbounded); whether CoreWriter actions count toward
  the L1 address rate limit (A01 drop cause; live evidence says most likely not); whether `agentSendAsset` can target the EVM (if yes, the agent can
  bridge home without opening a window: a 1-2 block NAV under-read with no guard; not modelled).
- The sim fills orders at mark (no slippage, no fees) and has no order book: slippage losses are real PnL, outside
  the asynchrony question.
- Unified / portfolio margin accounts (CONTEXT item 3) change what the precompiles report; the landing signals were
  only analysed for the default (standard) mode, which is what the vault is in.
