# hl-r2 COREWRITER-ENCODING: actions and precompile reads, byte for byte

Internal, AI-assisted review (sub-reviewer "flow"), 2026-10-19. Not an independent audit. Tests:
`contracts/test/audit/hl-r2/flow/HlR2Encoding.t.sol` (13 tests incl. one 512-run fuzz, all pass). Expected bytes are
built word by word (`bytes32` per field), never with `abi.encode`, so the test does not share the code under test.
Where a live mainnet `RawAction` log exists, the vault clone is placed at the live vault's address and must reproduce
the live bytes exactly. Live logs and ledgers: `evidence/flow/corewriter-live-actions.txt`, `core-ledgers.txt`.

## 1. Sources (fetched 2026-10-19)

- HL docs, "Interacting with HyperCore":
  https://hyperliquid.gitbook.io/hyperliquid-docs/for-developers/hyperevm/interacting-with-hypercore (fetched as `.md`)
  - attached `L1Read.sol`: an attachment on that page
  - attached `CoreWriter.sol`: an attachment on that page
- HL docs, "HyperCore <> HyperEVM transfers":
  https://hyperliquid.gitbook.io/hyperliquid-docs/for-developers/hyperevm/hypercore-less-than-greater-than-hyperevm-transfers
- HL docs, "Interaction timings": https://hyperliquid.gitbook.io/hyperliquid-docs/for-developers/hyperevm/interaction-timings
- HL docs, "Exchange endpoint" (approveAgent): https://hyperliquid.gitbook.io/hyperliquid-docs/for-developers/api/exchange-endpoint
- HL docs, "Nonces and API wallets": https://hyperliquid.gitbook.io/hyperliquid-docs/for-developers/api/nonces-and-api-wallets
- HL docs, "USDC" (two pages): https://hyperliquid.gitbook.io/hyperliquid-docs/hypercore/usdc and
  https://hyperliquid.gitbook.io/hyperliquid-docs/for-developers/api/usdc ("See https://github.com/circlefin/hyperevm-circle-contracts for Circle's published contracts and flows")
- Circle, `circlefin/hyperevm-circle-contracts` @ ffcc978810fa88884c150ad2d6418aa02c576670 (2026-06-18),
  `src/CoreDepositWallet.sol`; Circle "HyperCore contract addresses": https://developers.circle.com/cctp/references/hypercore-contract-addresses
  (lists CoreDepositWallet mainnet 0x6B9E773128f453f5c2C60935Ee2DE2CBc5390A24).

Quotes used below (verbatim):

- Encoding: "Byte 1: Encoding version … Currently, only version `1` is supported" / "Bytes 2-4: Action ID … decoded as
  a big-endian unsigned integer" / "Remaining bytes … It is always the raw ABI encoding of a sequence of Solidity types".
- Action 1: "(asset, isBuy, limitPx, sz, reduceOnly, encodedTif, cloid) | (uint32, bool, uint64, uint64, bool, uint8,
  uint128) | Tif encoding: `1` for `Alo` , `2` for `Gtc` , `3` for `Ioc` . Cloid encoding: 0 means no cloid, otherwise
  uses the number as the cloid. limitPx and sz should be sent as 10^8 \* the human readable value".
- Action 7: "USD class transfer | (ntl, toPerp) | (uint64, bool)" (no unit stated).
- Action 9: "Add API wallet | (API wallet address, API wallet name) | (address, string) | If the API wallet name is
  empty then this becomes the main API wallet / agent".
- Action 10: "Cancel order by oid | (asset, oid) | (uint32, uint64)".
- Action 13: "Send asset | (destination, subAccount, source\_dex, destination\_dex, token, wei) | (address, address,
  uint32, uint32, uint64, uint64) | If subAccount is not the zero address, then transfer from subAccount. Specify
  uint32::MAX for the source\_dex or destination\_dex for spot."
- Delay: "order actions and vault transfers sent from CoreWriter are delayed onchain for a few seconds".
- Prices: "divide the returned price by `10^(6 - szDecimals)` for perps".
- Invalid input: "Precompiles called on invalid inputs such as invalid assets or vault address will return an error
  and consume all gas passed into the precompile call frame."
- Transfers: "Every token has a system address on the Core, which is the address with first byte `0x20` and the
  remaining bytes all zeros, except for the token index encoded in big-endian format." / "Transferring tokens from
  HyperCore to HyperEVM can be done using a sendAsset action (or via the frontend) with the corresponding system
  address as the destination. The tokens are credited by a system transaction that calls `transfer(recipient, amount)`
  on the linked contract as the system address, where recipient is the sender of the sendAsset action."
- Timings: "Note that the account performing the CoreWriter action must exist on HyperCore before the EVM block is
  built. An EVM -> Core transfer to initialize the account in the same block will still result in the CoreWriter
  action being rejected." (A-13 confirmed by the docs.)
- approveAgent: "An account can have 1 unnamed approved wallet and up to 3 named ones. … A custom expiration can be
  set by appending `valid_until {timestamp}` after the name. The expiration can be at most 180 days in the future".
- Pruning: "This also happens to an existing named API Wallet when an ApproveAgent action is sent with a matching name."

## 2. Actions the vault emits

Header: `HyperCore._send` packs `abi.encodePacked(uint8(1), uint24 actionId, payload)` = `01` + 3-byte big-endian id
(HyperCore.sol:150-152). Test `test_HLR2_ENC_headerIsVersion1PlusThreeByteBigEndianId`.

| Id | Library encoder | Doc layout | Match | Units | Tests |
|---|---|---|---|---|---|
| 1 | `limitOrder(uint32 asset, bool isBuy, uint64 limitPx, uint64 sz, bool reduceOnly, uint8 tif, uint128 cloid)` HyperCore.sol:156-160 | same order and types | **exact** (7 words, 228 bytes) | limitPx, sz 1e8; `markPx1e8 = raw × 10^(2+szDecimals)` (raw has 6−szDecimals decimals, so ×10^(8−(6−szDec))); flatten size `|szi| × 10^(8−szDecimals)` (szi is in szDecimals units, verified live, section 4) | `test_HLR2_ENC01_limitOrder_everyTif_reduceOnly_cloid` (TIF 1, 2, 3 × reduceOnly × cloid 0 / set, plus a pinned literal), `test_HLR2_ENC01_flattenIsReduceOnlyIocNoCloid`, `test_HLR2_PC_livePositionDecodesSignedAndFlattenSizes` |
| 7 | `usdClassTransfer(uint64 ntl, bool toPerp)` :171-173 | same | **exact** | **ntl is 1e6 USD**: the docs do not say; mainnet proves it. The platform vault `moveUsd` bytes `…02560b14…01` = 39,193,364 -> Core ledger `accountClassTransfer "39.193364" toPerp true`; also 1,000,000 -> "1.0", 131,768,009 -> "131.768009"; Copy vault 19,535,906 -> "19.535906" toPerp false | `test_HLR2_ENC07_moveUsdReproducesLivePlatformVaultBytes` (three live byte strings) |
| 9 | `addApiWallet(address wallet, string name)` :182-184 | same | **exact** (address, offset 0x40, length 7, "dojipad") | name always "dojipad", never empty (the empty name would take the main agent slot) | `test_HLR2_ENC09_syncAgentReproducesLivePlatformVaultBytes` (live tx 0x76a24eac…), `test_HLR2_ENC09_revokeBurnReproducesLiveCopyVaultRevoke` (live tx 0x1e41dd01…, burn 0xed675beb…d7a7 = low 20 bytes of keccak256(vault, 47945036), as listed by HL `extraAgents`) |
| 10 | `cancelByOid(uint32 asset, uint64 oid)` :162-164 | same | **exact** | — | `test_HLR2_ENC10_cancelByOid` |
| 13 | `sendAsset(destination, address(0), sourceDex, destinationDex, token, amountWei)` :175-180 | (address, address, uint32, uint32, uint64, uint64) | **exact**; subAccount = `address(0)` hard-coded; spot = `type(uint32).max` both sides; token 0 | **wei = amount × 100** (USDC has 8 wei decimals on Core): Copy vault `bridgeToEvm(19535906)` -> wei 0x74716d48 = 1,953,590,600 -> ledger `send … "19.535906"` | `test_HLR2_ENC13_bridgeToEvmReproducesLiveCopyVaultBytes` (live tx 0xf7f5a012…, both actions), `testFuzz_HLR2_ENC13_sendAssetFieldsForAnyAmount` (512 runs, any spot / perp split) |

`test_HLR2_ENC_onlyIds_1_7_9_10_13_andNoForeignAddress` runs every emitting entry point once (placeOrder, cancelOrder,
flatten, moveUsd, bridgeToEvm spot-only and spot+perp, syncAgent, bridgeToCore, triggerBreach) and asserts that only
ids 1, 7, 9, 10, 13 appear, that every 13 goes to `0x2000…0000` with subAccount 0 and token 0, and that every 9 names
the stored agent or the burn.

Encoder defined but never called: `cancelByCloid` (id 11). Constants defined but unused by the vault: `ACTION_SPOT_SEND`
(6), `PRECOMPILE_ORACLE_PX`, `PRECOMPILE_L1_BLOCK` (`l1BlockNumber()` unused).

## 3. Core -> EVM path for USDC (A-07), the system address and the CoreDepositWallet

- **Documented.** USDC is token index 0, so its system address is `0x2000000000000000000000000000000000000000`
  (docs rule above). Core -> EVM is "a sendAsset action … with the corresponding system address as the destination",
  credited to "the sender of the sendAsset action" by a system transaction calling `transfer(recipient, amount)` on
  the linked contract. For USDC the linked contract is Circle's CoreDepositWallet: its `transfer(address to, uint256
  amount)` requires `msg.sender == tokenSystemAddress` and does `token.transfer(to, amount)` (CoreDepositWallet.sol
  `transfer`). Live: `CDW.tokenSystemAddress() = 0x2000…0000`, `CDW.token() = 0xb88339CB…630f`.
- `spotSend` (action 6) is the older "send spot token" action; the docs name `sendAsset` for Core -> EVM, and
  `sendAsset` is what the vault uses. The vault never emits action 6.
- **Verified on mainnet** (previously A-07 "Unverified"): see FUND-FLOW.md section 0 item 4. Observed at 19.5 USDC only.
- **EVM -> Core.** Circle USDC cannot be sent straight to the system address (the vault uses `CDW.deposit(amount,
  type(uint32).max)`): `_deposit` -> `token.transferFrom(msg.sender, address(this), amount)` then, with forwarding not
  enabled for the spot dex, `emit Transfer(msg.sender, tokenSystemAddress, amount)`, which HyperCore credits to
  `msg.sender`'s spot. Live config at block 48988180: `paused() = false`, `isDexForwardingDisabled() = false`,
  `enabledDestinationDexes(uint32.max) = false` (spot never forwards; `enableDex` refuses the spot id),
  `newCoreAccountFee() = 0` (the 1 USDC activation fee is charged by HyperCore itself, ledger `accountActivationGas`).
  Fork test `test_HLR2_FLOW_fork_realCoreDepositWalletPullsExactlyTheApprovedAmount` runs the live CDW code: exact
  pull, allowance 0, the `Transfer(vault, 0x2000…0000, amount)` log is emitted by the CDW.
- **HLR2-F06 (Design).** The CDW's `transfer` is `whenNotPaused` and Circle's USDC enforces its blacklist. If Circle
  pauses the CDW, or blacklists a vault, the system transaction of a Core -> EVM bridge reverts; the HL docs list no
  refund ("There are no guarantees about what the `transfer` call does on the EVM"). The vault's bridge then stays
  unlanded; after `MAX_UNLANDED_BLOCKS` (300) the missing amount counts as lost in NAV (VaultMath.sol:138-148) and
  the drop can trigger a drawdown breach and redemption-only settles at the lower price. Scenario: the platform vault NAV 170.76,
  bridge 100 during a pause -> NAV 70.76 after 300 blocks, drawdown 58.6% > 50% limit -> breach. Issuer risk of this
  kind was accepted for USDC in earlier rounds; recorded so the runbook says "never bridge to EVM while the CDW is
  paused" (`CDW.paused()` is a cheap pre-check the keeper can make).

## 4. Precompile reads: ABI vs L1Read.sol and live decoding

Live read-only `eth_call`s at block 48988925 (the platform vault) and 48989561 (an active trader for a non-zero position); raw
hex in `evidence/flow/precompiles-platform-vault.txt` and `precompiles-trader-position.txt`.

| Addr | Library input / output | L1Read.sol | Match | Live input -> output (the platform vault unless noted) | Decoded |
|---|---|---|---|---|---|
| 0x801 | `abi.encode(address user, uint64 token)` -> `SpotBalance(uint64 total, uint64 hold, uint64 entryNtl)` | `spotBalance(address user, uint64 token)` same struct | exact | `…dffb990c…cf4f` ‖ `0…0` -> 96 zero bytes; token 150 (HYPE) -> `…0f4240`, `0`, `…0515b260` | USDC total 0; HYPE total 1,000,000 (0.01 HYPE at 8 decimals) |
| 0x803 | `abi.encode(user)` -> `uint64` | `withdrawable(address)` -> `struct Withdrawable { uint64 }` (single static field: same ABI) | exact | -> `…0a2d8bf2` | 170,757,106 = 170.757106 USD |
| 0x806 | `abi.encode(uint32 perp)` -> `uint64` | `markPx(uint32)` | exact | BTC (0) -> `…0c8294`; SOL (5) -> `…0ff2d0` | 819,860 / 10^(6−5) = 81,986.0; 1,045,200 / 10^4 = 104.52 |
| 0x80a | `abi.encode(uint32 perp)` -> `PerpAssetInfo(string coin, uint32 marginTableId, uint8 szDecimals, uint8 maxLeverage, bool onlyIsolated)` | same field order | exact | BTC -> (offset 0x20, tuple: string offset 0xa0, 0x38, 5, 0x28, 0, "BTC") | ("BTC", 56, 5, 40, false) |
| 0x80F | `abi.encode(uint32 dex = 0, address user)` -> `AccountMarginSummary(int64 accountValue, uint64 marginUsed, uint64 ntlPos, int64 rawUsd)` | `accountMarginSummary(uint32 perp_dex_index, address user)`, same struct (int64 / uint64 / uint64 / int64) | exact | `0…0` ‖ `…dffb…cf4f` -> (`…0a2d8bf2`, 0, 0, `…0a2d8bf2`) | AV 170.757106, ntlPos 0 |
| 0x810 | `abi.encode(user)` -> `bool` | `coreUserExists(address)` -> `struct CoreUserExists { bool }` (same ABI) | exact | -> `…01` | true |
| 0x813 | `abi.encode(address user, uint32 perp)` -> `Position(int64 szi, uint64 entryNtl, int64 isolatedRawUsd, uint32 leverage, bool isIsolated)` | `position2(address user, uint32 perp)` at 0x813 (0x800 is the uint16 variant) | exact | The platform vault BTC -> (0, 0, 0, 5, false); trader 0xf5d81a13… BTC -> `ffff…fff8f09a`, `…5852b67ed9`, 0, 3, false | szi −462,694 = −4.62694 BTC (info API −4.62608 / −4.68911 in the seconds around; ETH 58.9719 and SOL 99.70 matched exactly) |
| 0x809 | `""` -> `uint64` (unused by the vault) | `l1BlockNumber()` with `abi.encode()` | exact | `0x` -> `…46ed0060` | 1,190,986,848 |

`test_HLR2_PC_livePlatformVaultOutputsDecode` loads these exact live outputs into the hash-keyed mock: it only passes if the
vault's inputs are byte-identical to the live inputs above, and it reproduces `coreEquity() = totalAssets() =
170,757,106` (the live NAV in CONTEXT.md), leverage 0, and a full `bridgeToEvm` of 170.757106.
`test_HLR2_PC_livePositionDecodesSignedAndFlattenSizes` decodes the trader's live BTC short (signed int64 sign
extension correct) and checks the flatten order: buy, reduce only, IOC, size 462,694,000 (1e8), price 828,050 × 10^7.

No struct field order or signedness mismatch was found. The one documentation gap: action 7's `ntl` unit is not
stated by HL; it is 1e6, proven by the mainnet ledger (section 2).

## 5. Things checked and found sound

- `subAccount` is always `address(0)`; `sendAsset` can only debit the vault itself.
- `sendAsset` amount: `SafeCast.toUint64(amount × 100)` reverts above 184,467,440,737 USDC per call (HLO-12).
- Spot assets (≥ 10000) are refused by `placeOrder` (VaultLogic.sol:541) and `flatten` (:573); the policy refuses
  allowlisting them (VaultPolicy.sol:292, 344).
- `markPx1e8` and `PxMath`: integer-valued 5-significant-figure rounding of the raw precompile price stays a valid HL
  tick (raw already has 6−szDecimals decimals); buys round down, sells up (existing `testFuzz_BoundedPxWithinBand`).
- Same-name replacement: every approval and the revoke use "dojipad", so a revoke replaces the live agent in the
  named slot (docs pruning quote; live: Copy vault's slot now holds the burn).
- Burn derivation reproduced from live data (section 2, id 9).

## 6. Findings (encoding / HyperCore semantics)

### HLR2-F01 (Low, operational): CoreWriter agent approvals expire after 90 days

**Location.** VaultLogic.sol:588 (`setAgent`), :605 (`syncAgent`), HyperCore.sol:182-184; AGENT_NAME VaultTypes.sol
("dojipad"); executor `server/src/agentSync.ts:39-42`, `server/src/monitor.ts:238`.

**Description.** Action 9 has no expiry field. The HL `approveAgent` API takes "valid_until {timestamp}" after the
name (≤ 180 days); the CoreWriter path cannot pass one, and HyperCore applies a default. Live `extraAgents`:
The platform vault agent `validUntil 1799292344459` vs its approval tx (block 48047401, timestamp 1791516344): exactly
7,776,000 s = **90 days**; the Copy vault burn: approval 1791415657, validUntil 1799191657389: 90 days; x402 Test agent
validUntil 1799114104385 (2027-01-05). The the platform vault agent expires **2027-01-07 03:25 UTC**. After that the platform
executor can no longer sign for the vault (orders, closes, reduce-only management). The contract's only renewal is
`syncAgent()` (anyone, re-sends the identical approval, refuses in a hard stop). The executor syncs on a bind and when
the monitor sees the agent missing from `extraAgents` (`AGENT_NOT_ON_HL`); it never reads `validUntil`. If HL keeps
listing an expired agent (unknown, assumption A1 in FUND-FLOW.md), the expiry goes unnoticed.

**Impact × likelihood.** Expiry is certain at day 90 for every vault (likelihood 1 without a renewal routine). Impact:
positions the agent opened are no longer managed by the executor (no stop-loss / take-profit / reduce-only actions
from the executor) until someone calls `syncAgent`; the on-chain breakers, `flatten` (manager, guardian; operator /
sentinel in breach) and exits still work, so loss is bounded by the policy limits (the platform vault: 20% daily, 50% drawdown).
Today the platform vault has no positions (impact 0). Low.

**PoC.** `test_HLR2_F01_agentApprovalHasNoExpiryFieldAndOnlySyncAgentRenews` (passes): the approval body is exactly
(address, "dojipad"), no `valid_until`; a stranger's `syncAgent` 91 days later re-sends identical bytes; it reverts
after a full stop. Live evidence: `evidence/flow/extra-agents.txt`.

**Fix (no src change needed).** Keeper calls `syncAgent()` for every served vault at least every ~60 days (and alerts
on `validUntil - now < 14 days`); the monitor treats `validUntil < now + margin` as `AGENT_NOT_ON_HL`. A future
contract could try the name `"dojipad valid_until <ts>"` in action 9, but whether CoreWriter parses that suffix is
unverified (it would need a testnet broadcast), so the keeper routine is the recommended fix. Note that a renewal by
`syncAgent` is permissionless and cheap (~47k gas), so there is no reason to let any agent run close to expiry.

### HLR2-F02 (Low): bridgeToEvm counts held spot USDC

**Location.** VaultLogic.sol:441-449.

**Description.** `spotUsd = spotBalance.total / 100` includes `hold` (USDC reserved by resting spot orders). If spot
holds exist, `bridgeToEvm` accepts an amount larger than the free balance; the `sendAsset` (and possibly the class
transfer) fails on HyperCore (fire and forget), the window opens anyway, nothing lands, and `bridgePending()` keeps
`settle`, `accrueFees`, `moveUsd`, both bridges, `clearLeverageBreach` and `resume` blocked until
`MAX_UNLANDED_BLOCKS` = 300 blocks. The contract never places spot orders; the platform agent can (accepted D-1).

**Impact × likelihood.** Delay only: ≤ 300 blocks (about 5 minutes at 1 block/s) per failed attempt, no value moved,
NAV correct throughout (in flight it reads the snapshot; after it, live). Requires an agent spot order with a hold
(rare; would itself be a FOREIGN_SPOT monitor alert). In emergency it slows the guardian's unwind by the same 300
blocks per attempt until the spot order is cancelled (`cancelOrder` takes spot asset ids). Low.

**PoC.** `test_HLR2_F02_bridgeToEvmCountsHeldSpotAndBlocksSettleForTheUnlandedWindow` (passes): spot total 200,
hold 150, `bridgeToEvm(200)` is accepted with wei 200e8, `settle` reverts `BridgeInFlight` at +300 blocks, clears at
+301.

**Fix.** Use `total - hold` for `spotUsd` in `bridgeToEvm` (VaultLogic.sol:441). (`coreEquity` should keep `total`:
held USDC is still the vault's.)

### HLR2-F05 (Info): placeOrder forwards an undefined TIF

`placeOrder` passes the manager's `uint8 tif` through unchecked (VaultLogic.sol:546). HL defines 1, 2, 3. Any other
value yields an action HyperCore rejects (no fund effect, manager only, the event `OrderSent` still fires, which can
mislead an indexer). PoC `test_HLR2_F05_placeOrderForwardsUndefinedTif`. Fix: `if (tif == 0 || tif > 3) revert`.

### HLR2-F06 (Design): Circle pause / blacklist strands a Core -> EVM bridge

See section 3.
