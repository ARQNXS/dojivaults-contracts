# Gains contracts: threat model (round 1 internal review)

Scope: `contracts/src/gains/*` (GainsVault, GainsVaultLogic, GainsVaultGovernance, GainsVaultMath, GainsNav,
GainsPrice, GainsVaultPolicy, GainsVaultFactory, GainsVaultLens, GainsTypes, IGainsDiamond), `script/DeployGains.s.sol`,
and the executor paths that sign for Gains vaults (`server/src/venues/gains/*` and the Gains branches of keeper,
operator, watcher, monitor, launch, registrar).

## 1. Assets at risk

| # | Asset | Where it sits |
|---|---|---|
| A1 | Idle USDC of share holders | vault balance minus reserves |
| A2 | Reserved USDC: queued deposits, deferred insider deposits, claimable redemptions | vault balance (`pendingDepositAssets`, `deferredDepositAssets`, `claimableRedeemAssets`) |
| A3 | Trade collateral and unrealized PnL | gTrade diamond / gToken vault, owed to `trade.user = vault` |
| A4 | Collateral in flight (pending market orders, resting limit / stop orders, leverage decreases) | diamond |
| A5 | Share value: the price at which deposits mint and redemptions burn | NAV (GainsNav + idle) |
| A6 | Fees: manager fee shares, protocol fee shares, HWM | share supply |
| A7 | Liveness: the ability to redeem and be paid, to exit trades, to settle | vault + diamond |
| A8 | Integrity of roles and config: agent binding, policy, feeds, timelock queue | vault, policy, factory |
| A9 | Gas ETH on the agent and keeper wallets | EOAs |

## 2. Actors, powers, and what each must never achieve

| Actor | Powers (on chain) | Must never |
|---|---|---|
| Depositor | requestDeposit / requestRedeem / cancel / claim for itself | get shares or USDC worth more than its contribution at a fair NAV; block other users' requests, settle or exits; read or move other users' reserves |
| Late depositor (deposits while trades are open) | as depositor | buy shares below fair value at the expense of existing holders beyond the documented NAV error bound |
| Redeemer | as depositor | be paid above its pro-rata share of NAV; be paid out of reserves of others; be blocked from redeeming |
| Manager | trade within policy (open, increase, leverage, SL/TP, close, reduce, cancel, flatten), settle normally | move USDC anywhere but its own vault's trades; trade outside the policy; price its own deposits (insider deferral); keep redemptions blocked; deflate or inflate the settle NAV beyond maxNavMoveBps |
| Owner (vault) | policy config (timelocked loosening), timelocked admin queue, pauses, setOperator, resume, rescue non-asset tokens, leaveHosted, deposit cap | take depositor USDC; change prices of the vault without timelock; remove the platform guardian / sentinel |
| Agent (platform wallet bound by the factory) | same trading powers as the manager, minus settle and flatten | trade another vault; trade outside policy; act after revocation; become a Gains delegate |
| Compromised agent key | as agent | lose more than bounded by policy + daily loss breach latency; steal funds; block exits |
| Operator (treasury, platform keeper by default) | settle, reduceTrade up to the redemption shortfall cap outside breach, close / reduce / flatten in breach or emergency, cancel timed-out orders | add exposure; reduce beyond what redemptions need (+2% + 1 USDC); change config, fees or roles |
| Compromised operator key | as operator | drain value through fees, slippage or repeated reduces beyond the cap |
| Sentinel (hot, platform) | revokeAgent, revokeOperator, pause, triggerBreach, cancelOrder, SL tightening and close / flatten in breach, settle in breach / emergency / overdue | unpause, clear a breach, end an emergency, loosen anything, move funds |
| Guardian (cold, platform) | clearBreach, triggerEmergency, exitEmergency (conditions), cancel queued items, unpause, close / flatten anytime (custom slippage in emergency), settle in emergency / overdue | move funds anywhere but back to the vault; mint shares |
| Registrar (hot, platform) | sign agent bindings for new vaults; register replacement agents for existing vaults; unregister non-live agents | bind an agent to a vault it was not signed for; pre-bind a predicted address; stop a live agent |
| Factory owner (cold) | curation and feeds for future allowlistings, roles, caps, launch allowlist, shares for future vaults, lowerProtocolShare | change an existing vault's feeds or protocol share upward; touch vault funds |
| Stranger | checkRisk, clearLeverageBreach, accrueFees, cancelTimedOut, claim for others, execute queued items, allowAsset / applyPendingConfig after eta, donate USDC, triggerEmergency when overdue | block settle, exits or redemptions; change NAV other than by donation; move anyone's funds |
| MEV searcher / sequencer ordering | order transactions within Arbitrum's FCFS sequencer | profit from a settle at a stale or manipulated NAV beyond the documented bound |
| Gains governance (diamond owner / manager / emergency timelocks) | upgrade facets (14 d / 3 d / 10 h timelocks), pause trading, delist pairs, change fees and parameters | — (trusted, see T2); the vault must stay exit-able and its NAV must fail closed |
| Gains oracle nodes and trigger bots | fill market orders at their median price; trigger TP / SL / limit / liquidation | — (trusted for price within B of Chainlink, see T3) |
| Chainlink (price and sequencer feeds) | publish prices | — (trusted within deviation + heartbeat, see T4) |
| Circle (USDC) | pause, blacklist, upgrade | — (trusted, see T5) |

## 3. Trust assumptions (named)

| # | Assumption |
|---|---|
| T1 | The gTrade diamond is the counterparty of every trade and pays the vault what its close path computes; it never moves collateral to anyone but `trade.user` and never calls back into the vault. |
| T2 | Gains governance does not upgrade a facet maliciously; upgrades sit behind 14 d (owner), 3 d (manager), 10 h (emergency) timelocks. A malicious or broken upgrade can lose all A3 / A4 (accepted, out of scope). |
| T3 | Gains' oracle median is within B(pair) of Chainlink at fills (measured −12 to +15 bps on 19 fills, STAGE0.md C). |
| T4 | Chainlink feeds on Arbitrum report within their deviation threshold and heartbeat; the sequencer uptime feed reflects the sequencer. |
| T5 | USDC (Circle) does not blacklist or pause the vault or the diamond. |
| T6 | The cold roles (factory owner, guardian) are honest and their keys safe; hot roles (sentinel, registrar, keeper / operator, agent) may be compromised. |
| T7 | The vault owner and manager are semi-trusted: they may act against depositors only within the policy and the timelocks, and depositors watch queued loosening. |
| T8 | Arbitrum's sequencer orders transactions first come first served; there is no public mempool, but a sequencer feed shows transactions as they are sequenced. |
| T9 | The executor honours breach modes off chain, but the contract must enforce every bound without it. |
| T10 | MAX_POSITIONS = 20 keeps every NAV reader under the Arbitrum block gas limit (32M) with margin. |

## 4. Attack surface by asset (hypotheses tested in ROUND1.md)

- A5 share price: NAV bias at the adverse band (deposit vs redemption side), near-liquidation cliff, pending-order
  valuation, donation, first depositor and seed, rounding, dust supply, fee mints, checkpoint ratchet, feed outliers
  (overflow, min/max answer), sequencer, feed rotation, oracle lag vs settle timing, cancellable requests as options.
- A3 / A4 trades: policy bypass (limit orders, increases, leverage updates), Gains semantic mismatch (pending order
  fields, liquidation input, fees), approvals, index reuse, Gains-side executions.
- A7 liveness: OrdersPending griefing by every role, timed-out orders, Gains pause / delist, Circle blacklist,
  MAX_POSITIONS, gas at 20 positions, flatten skipping, expectedPrice griefing, settle reverts (NavMoved,
  StaleCheckpoint, InsufficientLiquidity) in every mode.
- A8 roles: access matrix, registrar signature, CREATE2 front-running, clone initialization, timelock queue,
  feed rotation, curation changes between queue and allow.
- A6 fees: protocol share, HWM, management fee on reserved USDC, fee mints during breaches, scheduled raises.
