# Audit working notes

## Pass 1: tooling

- `forge build --sizes`: HyperVault runtime 24,405 B (margin 171 B under EIP-170). Factory 6,262 B, VaultPolicy 7,298 B.
  Every recommended fix must be weighed against 171 B of headroom (see FIXES.md "size budget").
- `forge test`: 88/88 pass (baseline suites).
- Slither 0.11.6 (`python -m slither . --filter-paths "lib|test|script"`): 56 results, 11 detectors. Triage:

| Detector | Location | Verdict | Reason |
|---|---|---|---|
| incorrect-equality | `_accrueFees` supply/assets == 0; Policy eta == 0 | FP | Zero sentinel checks, not balance equality |
| reentrancy-no-eth | `_revokeAgent`, `bridgeToEvm`, `setAgent` | FP | Callee is the CoreWriter system contract (no callback); bridge fns are NR |
| uninitialized-local | `feeShares`, `protocolShares`, `n` | FP | Intentional zero defaults |
| unused-return | `approve` in `_depositToCore`; `markPx1e8` 2nd value | FP / Info | Circle USDC returns true or reverts; szDecimals not needed there. `forceApprove` would be stricter |
| events-maths | `lowerProtocolShare` no vault event | TP (Info, I-01) | Factory emits it, vault does not |
| reentrancy-benign | `_depositToCore`, `bridgeToEvm`, factory `create`, `initialize` | FP | System contracts / trusted USDC; state after calls not exploitable |
| reentrancy-events | multiple | FP | Events after system calls, no reentrancy vector |
| timestamp | epochOverdue, settle, execute, policy etas | FP | Day/second granularity, validator skew irrelevant |
| cyclomatic-complexity | settle / checkRisk | Info | - |
| low-level-calls | `_fundCoreGas`, `execute` | FP | Return checked |
| unindexed-event-address | events | Info | - |
| cache-array-length | `allowedAssets` loop | Info (gas) | view only |

- Aderyn: NOT RUN. `npm i -g @cyfrin/aderyn` reports "Platform Windows_NT x64 is not supported"; WSL is not installed
  on this machine. To run it: `cyfrinup` / `cargo install aderyn` on Linux/macOS, then `aderyn contracts/`.

## Working log (condensed)

- Mainnet vault from broadcast `Deploy.s.sol/999`: factory `0x2da3f59d...d873`, vault `0x542a3f30...df258`.
  Read-only RPC + info API: spot USDC 1.0 (2 USDC seed minus 1 USDC activation fee), HYPE 0.01, no agents
  (`extraAgents` []), `userAbstraction` "default", perp account empty. Precompile outputs decode exactly as the
  library structs; unknown asset index -> precompile reverts (`PrecompileError`).
- HL docs: `agentSendAsset` is agent-signable ("destination must match the source address") and moves tokens between
  dexes / spot <-> perp. `order` with asset 10000+i is spot. These two make NAV deflation by an agent cheap (C-01).
- CoreWriter has action 16 "Set abstraction". Not used by the vault; if the account were switched to a unified mode,
  `accountValue` semantics may change (unverified, Pass 4 A-11).
- First invariant run found a counterexample: a dust depositor in the first epoch is credited part of the 1 USDC
  seed. That is documented behaviour (seed = donation), so first-mint epochs are excluded from that check and the
  behaviour is recorded as I-04.
- via_ir caches `block.number` inside a test function; PoCs use `vm.getBlockNumber()`.
