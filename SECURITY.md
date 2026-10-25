# Security policy

## Reporting a vulnerability

Write to **nigel@arqnxs.com** with "Security" in the subject. Include:

- the contract and function involved, and the deployment (chain and address) if it concerns a live contract;
- what an attacker can do and what it costs them;
- a reproduction, ideally a Foundry test against this repository.

Please do not open a public issue or pull request for a vulnerability, and do not test against vaults that hold
other people's deposits. Use a local fork instead.

## Scope

The smart contracts in this repository: everything under `src/`, for both venues (Hyperliquid on HyperEVM and
gTrade on Arbitrum One), and the deployed contracts of the current release, together with every vault and policy
their factories launch:

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

Before reporting against a deployed contract, you can check that its code is the code in this repository: see
"Checking the deployed bytecode" in [README.md](README.md#checking-the-deployed-bytecode).

## Out of scope

- The off-chain executor (the service that runs the platform keys, keepers and monitors) and its infrastructure.
- The website and its API.
- Third-party systems the contracts integrate with: Hyperliquid and HyperCore, gTrade, Chainlink, the Arbitrum
  sequencer, USDC.
- Findings that are already listed in [audit/README.md](audit/README.md) as accepted risks or scheduled for the next
  contract version.

## What to expect

We acknowledge a report within 3 business days and tell you what we will do about it. We keep you informed until it
is resolved.

There is no bug bounty at the moment.
