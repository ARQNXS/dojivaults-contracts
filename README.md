# DojiVaults contracts

DojiVaults are non-custodial USDC vaults. A manager launches a vault with its own risk limits, depositors put USDC
in and receive shares, and the vault trades perpetuals in its own name: on Hyperliquid (from HyperEVM) or on gTrade
(Gains Network, on Arbitrum One). The vault contract is the trading account. USDC leaves it only into its own
positions and orders, every payout comes back to it, and no role can send depositors' USDC anywhere except back to
them.

This repository holds the smart contracts, their tests, the deployment scripts and records, and the internal security
review reports. The off-chain executor and the website are not part of it.

## How the contracts fit together

Each venue has the same four parts:

| Part | Hyperliquid | gTrade | What it does |
|---|---|---|---|
| Factory | `HyperVaultFactory` | `GainsVaultFactory` | Launches a vault and its policy in one transaction as clones of fixed implementations. Keeps the list of markets a vault may trade, the platform roles (guardian, sentinel, agent registrar) and the deposit cap. |
| Vault | `HyperVault` | `GainsVault` | Holds the USDC and the positions. Deposits and withdrawals are requests that settle at the end of each epoch (ERC-7540 style), at a share price that includes the open positions. Enforces the risk limits: anyone can run `checkRisk()`, and a broken limit only lets positions shrink. Withdrawals are never blocked. |
| Policy | `VaultPolicy` | `GainsVaultPolicy` | The vault's risk limits: allowed markets, leverage, order size, daily loss, drawdown, slippage. Every order is checked against it. A tighter limit applies at once; a looser one waits for a timelock, so depositors can leave first. |
| Lens | `HyperVaultLens` | `GainsVaultLens` | Read-only views for apps: previews of a settlement including fees, claimable and pending requests, epoch status. One deployment serves every vault. |

The vaults delegate most of their code to linked libraries so they fit the contract size limit: `VaultLogic` /
`GainsVaultLogic` (deposits, withdrawals, settlement, fees, trading), `VaultGovernance` / `GainsVaultGovernance`
(risk checks, breaches, emergencies, the owner timelock) and `VaultMath` / `GainsVaultMath`. On Hyperliquid,
`hypercore/HyperCore.sol` reads HyperCore through precompiles and sends actions through CoreWriter. On gTrade,
`GainsNav` values open trades through gTrade's own close path at a conservative Chainlink price and `GainsPrice` reads
the Chainlink feeds behind the Arbitrum sequencer uptime feed.

Roles on a vault launched from a factory:

- **Owner** (the launcher's wallet): sensitive changes go through a timelock; can pause, set a deposit cap, resume
  after a drawdown limit and start an emergency. Cannot move depositors' USDC.
- **Manager**: settles epochs and trades within the policy. A manager's own deposits wait one extra epoch.
- **Operator** (optional, granted by the owner): settlements on a schedule and the transfers a settlement needs.
- **Platform agent**: the trading key the factory binds to the vault; it can only place orders that pass the policy.
- **Sentinel** (an online platform key): can only make a vault safer (remove the agent, pause, cancel orders).
- **Guardian** (an offline platform key, also the factory owner): clears breaches, starts and ends emergencies.

## Deployments

The current release (round 2), one factory per chain, from [`deployments/`](deployments):

**HyperEVM (chain id 999), Hyperliquid**: record [`deployments/mainnet.json`](deployments/mainnet.json), block 49,407,893.

| Contract | Address | Role |
|---|---|---|
| `HyperVaultFactory` | [`0x3D16248e795100BeD74649EB0fA79F145F3b83Ad`](https://hyperevmscan.io/address/0x3D16248e795100BeD74649EB0fA79F145F3b83Ad) | factory |
| `HyperVaultLens` | [`0x48aC27e3DcbB569cD633eaa90b4d3410d024BC79`](https://hyperevmscan.io/address/0x48aC27e3DcbB569cD633eaa90b4d3410d024BC79) | lens |
| `HyperVault` | [`0x2d0EbeDbb28ca69AFf110926c70ed1f2B48574FD`](https://hyperevmscan.io/address/0x2d0EbeDbb28ca69AFf110926c70ed1f2B48574FD) | vault implementation (cloned per vault) |
| `VaultPolicy` | [`0x3BBB5942fF4586e72AC6219517a9f5e4fF375fC8`](https://hyperevmscan.io/address/0x3BBB5942fF4586e72AC6219517a9f5e4fF375fC8) | policy implementation (cloned per vault) |
| `VaultLogic` | [`0xEd549FF416f2A93a83d1C712cA7053Cd661dd007`](https://hyperevmscan.io/address/0xEd549FF416f2A93a83d1C712cA7053Cd661dd007) | linked library |
| `VaultGovernance` | [`0x95Fb1d1f1B6BC87A85aF5099b027A279d6D145DE`](https://hyperevmscan.io/address/0x95Fb1d1f1B6BC87A85aF5099b027A279d6D145DE) | linked library |

**Arbitrum One (chain id 42161), gTrade**: record [`deployments/arbitrum.json`](deployments/arbitrum.json), block 517,880,549.

| Contract | Address | Role |
|---|---|---|
| `GainsVaultFactory` | [`0x9bb1DcB64BFfa8c91b86ed2188E14e37e4B0f2f0`](https://arbiscan.io/address/0x9bb1DcB64BFfa8c91b86ed2188E14e37e4B0f2f0) | factory |
| `GainsVaultLens` | [`0xF1c51D24643838cEBf318083351843752809A9B9`](https://arbiscan.io/address/0xF1c51D24643838cEBf318083351843752809A9B9) | lens |
| `GainsVault` | [`0x5b31C85c80d0E1A336905328Ca6C8276BfbEf06E`](https://arbiscan.io/address/0x5b31C85c80d0E1A336905328Ca6C8276BfbEf06E) | vault implementation (cloned per vault) |
| `GainsVaultPolicy` | [`0x7c70C741DBA302ce6ba588AA3bB5EFD2b18ed59f`](https://arbiscan.io/address/0x7c70C741DBA302ce6ba588AA3bB5EFD2b18ed59f) | policy implementation (cloned per vault) |
| `GainsVaultLogic` | [`0xf0748F6A4879f2fA31E6F776F80C56C67FA63D2F`](https://arbiscan.io/address/0xf0748F6A4879f2fA31E6F776F80C56C67FA63D2F) | linked library |
| `GainsVaultGovernance` | [`0xaF18d364f60916d85E2fE8D5eb0A2e9147C15CA6`](https://arbiscan.io/address/0xaF18d364f60916d85E2fE8D5eb0A2e9147C15CA6) | linked library |
| `GainsNav` | [`0x88F2Cea7888469134b5ae1319A3e2ce760b5E5d8`](https://arbiscan.io/address/0x88F2Cea7888469134b5ae1319A3e2ce760b5E5d8) | linked library |

Vaults and their policies are clones of the two implementations, launched by the factory. Each record also lists the
platform roles (guardian, sentinel, agent registrar), the protocol fee recipient and the external contracts the
deployment points at (USDC, and on Arbitrum the gTrade diamond and the sequencer uptime feed). Earlier factories are
closed and not listed here.

## Build and test

Needs [Foundry](https://getfoundry.sh) (the contracts build with solc 0.8.28, `via_ir`, EVM version cancun).

```sh
git clone <this repository> dojivaults-contracts
cd dojivaults-contracts
forge install        # fetches forge-std and OpenZeppelin at the commits pinned in .gitmodules / foundry.lock
forge build
forge test
```

Fork suites need an RPC and skip without it: those on Arbitrum read `ARBITRUM_RPC_URL` (an archive endpoint), those
on HyperEVM are opt-in (`HLR2_FORK=true`). A `via_ir` build of everything is one long compiler job (close to an hour
on a laptop); `forge build --skip test` builds `src/` and `script/` alone much faster.

Layout: `src/` contracts, `test/` tests (`test/audit/` holds the proofs of concept and regression tests from the
reviews), `script/` deployment scripts, `deployments/` deployment records, `audit/` review reports, `verify/` the
release's compiler input and its check.

## Checking the deployed bytecode

[`audit/fix-round/RELEASE-BYTECODE.md`](audit/fix-round/RELEASE-BYTECODE.md) records the runtime and creation hash of
the 13 deployable contracts of the round 2 release, with linked library addresses and immutables zeroed (the values
known only at deploy time). With `via_ir` the bytecode can depend on the whole compiler job, not only on `src/`:
the release was one job over `src/`, `script/` and every test at the time. This repository has a different test set,
so a `forge build` of it is a different job.

[`verify/solc-input.json`](verify/solc-input.json) is that job's standard JSON input, from the release build, with
the test sources left out (they come after `src/` in the job and do not change the 13 contracts; the check below
shows it), except the two `test/gains/spike/` files a script imports. Every other source in it is the file in this
repository (for `script/` and those two test files, up to the license header), the file in the pinned dependency,
or one of forge's generated deploy helpers (`foundry-pp/`). To rebuild the 13
contracts from it and compare them with the record:

```sh
python verify/check.py                     # solc 0.8.28 from Foundry's cache or PATH, or --solc <path>
```

It prints one line per contract and `ALL MATCH`. To compare the code deployed on chain with the same record, add an
RPC endpoint of the chain and the record:

```sh
python verify/check.py --rpc https://rpc.hyperliquid.xyz/evm --record deployments/mainnet.json
python verify/check.py --rpc https://arb1.arbitrum.io/rpc --record deployments/arbitrum.json
```

`check.py` needs Python 3.8 or later and no packages; the compile takes about a minute (only the 13 contracts are
generated).

## Security reviews

The contracts have been through several rounds of internal review. These are reviews by the team, not independent
audits. Every report, finding and status is listed in [audit/README.md](audit/README.md). To report a vulnerability,
see [SECURITY.md](SECURITY.md).

## License

Everything in this repository is under the [Business Source License 1.1](LICENSE), except
`test/gains/spike/IGainsDiamondSpike.sol` (a copy of the Gains interface used by the tests), which is MIT.
`src/gains/IGainsDiamond.sol` carries a BUSL-1.1 header because it is compiled into the deployed contracts; ARQNXS
also makes it available under the MIT License.

- The source is public: anyone may read, copy, modify and audit it, and use it for testing and research.
- Using it in production, commercially or not, needs written permission from ARQNXS.
- Each version opens up 4 years after its first public release, when its license changes to GPL-2.0-or-later. This
  version is the one exported from private commit `2bd7e53ec53b777507c0e251d1f3fc69dd174655`; its Change Date is 2030-10-24. Every new
  contract version gets its own Change Date, 4 years after its own release.

For a license or any questions about it: nigel@arqnxs.com.
