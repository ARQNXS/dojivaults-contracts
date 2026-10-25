# Gains contracts: specification (round 1 internal review)

Intended behaviour of `contracts/src/gains/*` at `origin/main` 5dd1344, extracted from docs/gains/PLAN.md, AUDIT-DIFF.md,
STAGE0/1/3.md, MAINNET-OWN-CAPITAL.md and the NatSpec. Every property is numbered and testable. "Test" names the test
that checks it in this review (`test/audit/gains/`) or in the existing suites (`test/gains/`). A property without a
test is listed as such in ROUND1.md "checked and sound" or as an open question.

Notation: `$` = VaultStorage; NAV = `idleAssets + GainsNav.value`; idle = USDC balance − pendingDepositAssets −
deferredDepositAssets − claimableRedeemAssets (floored at 0); B(pair) = NAV band of the pair; C = Chainlink price;
"trader" = manager or agent; "insider" = manager, owner or fee recipient (as sender or controller).

## 1. Roles and who may call what

| # | Property |
|---|---|
| R1 | Factory vaults read `guardian()` and `sentinel()` live from the factory; standalone vaults use one fixed guardian that is also the sentinel. The vault owner cannot change either. |
| R2 | `openTrade`, `increaseTrade`, leverage raise (`updateLeverage` up) are callable only by the manager or the agent, and only when not breached, not in emergency and trading not paused. |
| R3 | `updateLeverage` down (adds margin) is callable only by the manager or the agent; refused in a full stop (guardian / emergency) and in a daily-loss or drawdown breach; allowed in a leverage breach and while trading is paused. |
| R4 | `closeTrade` and `reduceTrade`: manager, agent and guardian at any time; owner, operator and sentinel only while breached or in emergency. Nobody else. |
| R5 | `reduceTrade` by the operator outside breach / emergency: only with `leverageDelta == 0` and `collateralDelta ≤ operatorReduceCap(redemptionShortfall())` = shortfall + 2% + 1 USDC (0 without a shortfall). `closeTrade` stays breach / emergency only for the operator. |
| R6 | `setSlTp`: manager and agent at any time; the sentinel only while breached or in emergency, and then only the SL. While breached or in emergency an SL may only tighten (long: higher, short: lower) and may not be removed (0). |
| R7 | `cancelOrder` (resting limit / stop): manager, agent or sentinel, at any time. |
| R8 | `cancelTimedOut`: anyone; the diamond enforces the 200 L2 block timeout and only accepts the trader (the vault). |
| R9 | `flatten`: manager and guardian at any time; owner, operator and sentinel only while breached or in emergency (slippage 0 = policy band). A custom slippage (≠ 0, ≤ maxFlattenSlippageBps ≤ 3%) only by the manager, or the guardian in emergency. Never the agent, a depositor or a stranger. |
| R10 | `settle`: owner, manager, operator, guardian or sentinel only. Normal mode (deposits minted) only for the manager / operator outside a non-leverage breach and outside emergency. Platform roles (owner, guardian, sentinel) settle only redemption-only (loss breach), in emergency, or exit-only once the epoch is overdue. Refused in a guardian full stop outside emergency (`ReduceOnlyMode`). |
| R11 | `checkRisk`, `clearLeverageBreach`, `accrueFees`, `claim(controller)`, `cancelTimedOut`, `execute(data)` (after the delay), `applyPendingConfig`, `allowAsset`, `applyTimelockDelay`: anyone. |
| R12 | `triggerBreach`: owner, guardian or sentinel; revokes the agent. `triggerEmergency`: owner or guardian at any time; anyone when the epoch is overdue with redemptions pending; revokes the agent. |
| R13 | `clearBreach`: the guardian instantly, or the vault itself through a queued call created after the breach; never in emergency. `exitEmergency`: guardian only, not while redemptions are pending, not after a partial-fill settle in this emergency. `resume` (drawdown): owner only, ≥ RESUME_COOLDOWN after the breach, leverage and daily loss within limits. |
| R14 | Pausing deposits / trading: owner, guardian or sentinel. Unpausing: owner or guardian. |
| R15 | `setOperator`: owner. `revokeOperator`: owner, guardian or sentinel. `revokeAgent`: owner, guardian, sentinel or the factory. `setAgent`: only through the timelock (onlySelf), refused in a full stop, only an agent the factory bound to this vault. |
| R16 | `queue`: owner only, for exactly six selectors with exact calldata lengths (setManager, setFeeRecipient, setTimelockDelay, setAgent 36; setFees 68; clearBreach 4; setPairFeed 132). `cancel(id)`: owner or guardian. `execute`: anyone, in [eta, eta + 14 days]. |
| R17 | `setDepositCap`: owner; factory vaults require 0 < cap ≤ factory.maxDepositCap. `lowerFees`: owner, at least one fee lower, none higher. `rescueToken`: owner, never the asset or the vault's own shares. `leaveHosted`: owner, once. `lowerProtocolShare`: factory only, strictly lower. |
| R18 | `renounceOwnership` reverts on the vault and on the factory. Ownership is two step. |
| R19 | Policy: `proposeConfig`, `cancelPendingConfig`, `disallowAsset`, `queueAllowAsset`, `proposeTimelockDelay` owner only. `setPairFeed` only from the policy's vault. |
| R20 | Factory owner only: every setter. Registrar or owner: `registerPlatformAgent` (registrar only for existing vaults). `unregisterPlatformAgent`: registrar, owner, guardian, sentinel; revoking a live agent needs owner / guardian / sentinel. `create`: allowlisted launchers or anyone when openLaunch. |

## 2. Deposits and redemptions

| # | Property |
|---|---|
| D1 | `requestDeposit` pulls exactly `assets` USDC (≥ MIN_DEPOSIT = 10 USDC) and records it; refused while deposits paused, breached or in emergency; refused above a non-zero cap (NAV + pending + deferred + assets). |
| D2 | An insider's deposit belongs to `currentEpoch + 1` and sits in `deferredDepositAssets` until the next settle rolls it into the queue. |
| D3 | One request per controller: a request in another epoch must be claimed (automatically) or settled first (`RequestPending`). |
| D4 | `requestRedeem` escrows the shares in the vault; always allowed (breach, emergency, paused, stale feeds); it reads no price. |
| D5 | `cancelDepositRequest` returns exactly the request's USDC, only while unsettled (or carried); `cancelRedeemRequest` returns exactly the escrowed shares, only in the current epoch. |
| D6 | `claim` delivers exactly `claimableWithCarry`; rounding never pays more than `claimableRedeemAssets`; the sum of claims never exceeds what the epoch paid. |
| D7 | Reserved USDC (pending + deferred deposits + claimable redemptions) is never used for trading, NAV or fees: `idleAssets` excludes it and `openTrade` / `increaseTrade` / `updateLeverage` down are bounded by idle. |

## 3. Settlement

| # | Property |
|---|---|
| S1 | `settle` reverts `OrdersPending` while the diamond holds any pending order for the vault, timed out or not, in every mode. |
| S2 | The venue is valued once per settle; NAV = idle + that value at every step. |
| S3 | Normal settle: NAV within `maxNavMoveBps` of a checkpoint no older than 1 day (`StaleCheckpoint`, `NavMoved`), deposits minted at NAV (floor), redemptions paid in full at NAV (floor) or the call reverts `InsufficientLiquidity`. |
| S4 | Redemption-only settle (daily-loss / drawdown breach): no share minted; redemptions paid at min(NAV, previous checkpoint); the deposit queue is carried and later priced by the settle that ends the carry run. |
| S5 | Exit-only settle (emergency, or overdue): deposits refunded, redemptions priced at min(NAV, checkpoint), in emergency filled pro rata to the USDC on hand; only paid shares burned, the rest returned on claim. |
| S6 | A settle that would price insider deposits runs ≥ INSIDER_MIN_EPOCH_AGE (1 h) into the epoch. |
| S7 | A deposit that would mint 0 shares is refunded (N-11). |
| S8 | After a settle: `checkpointNav = navAfter`, `epochStartedAt = now`, currentEpoch += 1, `pendingRedeemShares = 0`, `pendingDepositAssets = deferredDepositAssets` (or carried), `deferredDepositAssets = 0`. |
| S9 | Flows never move the risk references: deposits and redemptions settle at the share price (R-01). |

## 4. Fees

| # | Property |
|---|---|
| F1 | Management fee accrues linearly on NAV since `lastFeeAccrual`, minted as shares; protocol share = feeShares × protocolShareBps. |
| F2 | Performance fee only in a settle outside any breach and emergency, on (price − HWM) × supply; HWM only moves there. |
| F3 | Fee mints rescale `peakSharePrice` and `dayStartSharePrice` by newPrice / price (no false loss). |
| F4 | A performance fee raise is scheduled and takes effect at the next normal settle (N2-02, R3-06). |
| F5 | Fee rates ≤ 5% / yr management, ≤ 30% performance; protocol share ≤ 50%, never raised on an existing vault. |

## 5. NAV (GainsNav, GainsPrice)

| # | Property |
|---|---|
| N1 | NAV = idle USDC + Σ open trade value + Σ resting limit / stop collateral + Σ (pending open / partial open / leverage-decrease collateral − min gov fee). Pending closes leave the trade valued as open. |
| N2 | An open trade is valued at P = C × (1 − B) for a long and C × (1 + B) for a short, through Gains' close path (spread, skew, two-pass cumulative volume impact, pnl floored at −100%, closing fee without fee tier, pending holding fees at P, + totalRealizedPnl), floored at 0. |
| N3 | A trade whose P is within B of its liquidation price is worth 0 (long P ≤ L(1 + B), short P ≥ L(1 − B)). |
| N4 | NAV is never above what Gains would pay at the oracle price, as long as the oracle is within B of Chainlink (the invariant `navNeverAbovePayout`). |
| N5 | NAV error versus the realizable value is at most 2 × B × vault leverage; the policy enforces maxLeverageBps × 8 × B ≤ maxNavMoveBps × 10,000 for every allowed pair at initialize, config change (both stages), allowlisting and feed rotation. |
| N6 | `GainsPrice.read` reverts `PriceStale(pair)` for a missing, reverting, malformed (< 160 bytes), zero, negative, future-dated, stale (> maxAge) or oversized (not a uint64 1e10) answer, `SequencerDown()` while the sequencer is down, its round not started, or within the grace period, `NoPriceFeed(pair)` without a feed. No raw low-level revert or panic. |
| N7 | Prices are read once per pair per snapshot. |
| N8 | Open notional = Σ positionSizeToken × C (no band) + resting collateral × leverage + pending open collateral × leverage. |
| N9 | The NAV reads only `address(this)`'s trades and orders. |

## 6. Trading

| # | Property |
|---|---|
| T1 | Every new exposure runs `policy.checkOrder`: pair allowed; Gains slippage ≤ maxSlippageBps; market orders' expected price within maxSlippageBps of C on the adverse side; notional ≤ maxOrderNotional; collateral ≥ 5 × min fee (opens); notional ≥ pairMinPositionSizeUsd (opens); (openNotional + notional) / NAV ≤ maxLeverageBps. |
| T2 | `openTrade` and `increaseTrade` are refused at MAX_POSITIONS = 20 (open trades + resting + pending); no exit is ever refused at it. |
| T3 | Collateral of an open / increase / leverage decrease ≤ idle. |
| T4 | The vault approves the diamond for exactly the request's collateral and leaves no allowance after the call. |
| T5 | `openTrade` sends `trade.user = vault`, `collateralIndex = $.collateralIndex`, referrer `address(0)`. |
| T6 | `updateLeverage` down pulls `collateral × lev / newLev − collateral` from idle; raise is checked as a new exposure. |
| T7 | `flatten(pair, slippageBps, expectedPrice, maxTrades)` closes the pair's open trades and cancels its resting orders, at most maxTrades per call, skipping trades with a market order in flight, and returns (sent, remaining). The slippage update and the limit cancel never block the close (try / catch). |

## 7. Exits and liveness

| # | Property |
|---|---|
| X1 | `closeTrade`, `reduceTrade` (every caller), `cancelOrder`, `cancelTimedOut`, `flatten`, `setSlTp`, `requestRedeem`, `cancelRedeemRequest`, `claim` never read GainsNav, GainsPrice, `policy.price` or `policy.navPrice`: they work with every feed stale and the sequencer down. |
| X2 | No exit is refused for MAX_POSITIONS, trading paused, deposits paused or a breach. |
| X3 | Every NAV reader (totalAssets, checkRisk, settle, openTrade, increaseTrade) stays under 10M gas at 20 positions; flatten of 20 trades fits an Arbitrum transaction (32M). |
| X4 | No actor other than the listed roles can keep `settle` blocked for longer than one order's fill or timeout (200 L2 blocks) plus the keeper's cancel. |
| X5 | Exits do not depend on anything the vault's manager controls once the guardian acts (emergency + flatten). |

## 8. Risk, breach, emergency

| # | Property |
|---|---|
| K1 | `checkRisk` (anyone): leverage = notional / equity, daily loss vs dayStartSharePrice, drawdown vs peakSharePrice, all on share price; breaches only escalate (NONE < LEVERAGE < DAILY_LOSS < DRAWDOWN); a full stop is never touched; ratchets the checkpoint at most once per hour by at most maxNavMoveBps. |
| K2 | A risk breach keeps the agent and is reduce-only; leverage clears via clearLeverageBreach (anyone, ≥ 15 min, all limits met), daily loss at the next UTC day, drawdown via resume. |
| K3 | Full stop (triggerBreach) and emergency revoke the agent; `setAgent` refused while hardStop. |
| K4 | No deposit is accepted while breached or in emergency. |

## 9. Governance, policy, timelock

| # | Property |
|---|---|
| G1 | Policy config: tightening (every field at least as strict; maxNavMoveBps higher = tighter) applies at once; loosening waits `timelockDelay` and expires 14 days after eta. |
| G2 | Policy timelock delay: raising instant, lowering timelocked; 1 to 30 days. |
| G3 | Allowlisting a pair waits the policy timelock, then copies the factory's (feed, maxAge, band, decimals) and checks the NAV bound; disallowing is instant and keeps the feed for open trades. |
| G4 | `setPairFeed` accepts only the exact combination the factory curates now, for a pair the policy has listed and the factory still curates, and re-checks the NAV bound; only through the vault's timelock. |
| G5 | The factory owner can never change the price config of an existing vault without that vault's owner (snapshot rule). |
| G6 | A queued `clearBreach` only executes when queued after the breach it clears (N-04). |

## 10. Factory and launch

| # | Property |
|---|---|
| L1 | `create` only by allowed launchers (or anyone with openLaunch), with seed ≥ minSeedUsdc, 0 < depositCap ≤ maxDepositCap, only curated pairs, policy leverage within the NAV bound of every allowed pair. |
| L2 | With an agent: msg.value ≥ minAgentGas forwarded to the agent; the registrar's (or owner's) EIP-191 signature over (chainid, factory, agent, predicted vault, deadline) binds that agent to that vault only; one agent per vault, one vault per agent; expired, wrong-signer, replayed or other-vault signatures fail. Without an agent: msg.value must be 0. |
| L3 | The predicted address is scoped by (creator, salt): nobody else can deploy to it or pre-bind it (except the cold owner via registerPlatformAgent). |
| L4 | Implementations cannot be initialized; clones are initialized once, in the create transaction. |
| L5 | Roles never collide: guardian ≠ sentinel; sentinel and registrar ≠ owner, guardian; checked against the pending owner too. |
| L6 | The seed stays in the vault as idle USDC. |

## 11. External integration

| # | Property |
|---|---|
| E1 | Every diamond call uses Gains units: price / SL / TP 1e10, leverage 1e3, slippage 1e3 percent, collateral index of the asset (3 for USDC). |
| E2 | No ETH path, no receiver hook: Gains pays USDC by `transfer`; the vault has no receive/fallback. |
| E3 | Feeds are read by staticcall; a broken feed surfaces as a named error. |
| E4 | The vault never sets a Gains trading delegate. |
