# Round 2 release: bytecode of every deployable contract (WP5 step 5, compiler guard)

Internal, AI-assisted verification. It is not an independent audit and must not be presented as one.

**Build.**
- forge 1.8.4, solc 0.8.28+commit.7893614a, via_ir, optimizer 200 runs, evm cancun (`contracts/foundry.toml`, keccak of
  the LF-normalised file starts `82313ffea4e1b938`).
- One compiler job for the whole tree: 308 files (`src`, Gains, scripts and every test, with the WP5 Medusa harness and
  stolen-agent campaigns), as the README builds it: `forge build --force --sizes`. **The record holds for this exact
  tree only:** with via_ir the output can depend on the other files in the job (GainsNav moved 16 bytes in guard 3 with
  no source change, and is back to its guard 2 hash here). Deploy from the RELEASE commit with a clean tree.
- Head 24b8efe (compiler guard 4, the final source). `contracts/src` changes since 3d75366: the comment on
  `DEFAULT_AGENT_TURNOVER_BPS` in `VaultPolicy.sol` (668b621, WP5-HL-01), and two changes to `VaultLogic.sol`:
  `revokeAgent` sends no CoreWriter action (00bc8d5, WP5-D14) and the agent's turnover budget reads the visible NAV
  only (24b8efe, HL-INV-01). `foundry.toml` and both deploy scripts are unchanged. Keccak of the 21 tracked `src`
  files, LF-normalised, sorted by path and concatenated, starts `9ff388959e98aa64` (`0d8618ee59feafac` at 3820d75,
  `355637226ad8c42e` at 3d75366).
- Log: `wp5-logs/guard4.build.txt` (earlier guards: `guard.build.txt`, `guard2.build.txt`, `guard3.build.txt`). Solc
  took 2,914 s, and the compiler run was successful. The exit code is 1 only because of the EIP-170 messages for 11
  test harnesses (`*Handler`, `*Medusa*`); every contract below is under the limit.

**How to check.**
- A local build against this table, from `contracts/` after `forge build --force`:
  `python ../docs/fix-round/bytecode-check.py` must print `ALL MATCH`.
- The deployed code against this table, after the deploy: `--chain hyperevm|arbitrum --rpc <url> --record
  deployments/<file>.json` must also print `ALL MATCH` (DEPLOY-R2.md 3.2, 3.3).

**What the hashes are.** keccak256 of the bytecode with every value known only at deploy time set to zero bytes:
linked library addresses, the factories' immutables (their constructor values) and each library's own deploy
address. The artifact holds zeros there, so an artifact and the deployed code compare equal. The creation hash covers
the constructor code as compiled, before constructor arguments.

<!-- table -->
| Contract | Chain | Runtime keccak256 (links zeroed) | Runtime bytes | Creation keccak256 (links zeroed) | Links |
|---|---|---|---|---|---|
| VaultLogic | hyperevm | `0x7c140f96615bfbffdad3c3ee12d56d654eb298e830e5325c8ede2cac7b07d3f8` | 22,278 | `0x98d8e48f22a3c170d04f092b67432a4fd55f48deef60f409add064415ff66f3c` | none |
| VaultGovernance | hyperevm | `0xeab46c989c058933fdf9159fd76207c6acc55b14a679bf82e059b79f2ea03b17` | 13,840 | `0x8c08dc8f7bae83a45e203f3c80e2b3917d02fea7b6444e4d8cb27096907fd589` | VaultLogic |
| HyperVault | hyperevm | `0xe81d99e0022237eeb2e1a9c77ad0fa747b1b5d05618d173f85fe8a409dadc190` | 19,821 | `0xd27a3bff480d4caf3e4b8e4121a8ce9a925add91bfefabeb79f727ca00e33389` | VaultGovernance, VaultLogic |
| VaultPolicy | hyperevm | `0xc92aad59af7ea3cc2e68c9f561176857122cbead891014fe0fcc2f0eadc7c2f5` | 12,218 | `0xe605e20cd675b344215c089a5cbf9ad94747d5ae51bd2ec9f1339c034b15cdba` | none |
| HyperVaultLens | hyperevm | `0xcffe95fc06edea68237e15f09e5531ffe7f4eb4041dafe6a4e2849c8d753f5da` | 10,090 | `0xd0210c20c5c528733b2238de60f6634b107cc5f2008af9ed9aa81349a31e0e3c` | none |
| HyperVaultFactory | hyperevm | `0xdc96ccd72704731acf42639832a69bc760b46d1012da0f24e6766fe9f0e9327b` | 10,955 | `0x2460fa41ed84691d7145718567448d822aa0753aeef3b85f6995596fa8a36a09` | none |
| GainsNav | arbitrum | `0x0b422b6dffd9fd77b1cba549ff9e650ea2382b3ea41d03d3d7f92e021e0b405b` | 20,286 | `0xcbc36e097d34aa1a485b0701bdc5e4ec18ff13ca5ed9b79fa62480947481dabb` | none |
| GainsVaultLogic | arbitrum | `0x863fd7e5fafbaec61aa585426452e8817654a6a7fc873271ad76d3b201978a84` | 21,855 | `0xa60e2bf525d2117e09bfcbcca76c99d0c4b2a070a93f4c5e8e6456f0f491d3c2` | GainsNav |
| GainsVaultGovernance | arbitrum | `0x268820cc9d580aeec2a59ecbf56aae6ed61be221c8accb22f57664204f81e27c` | 16,907 | `0x35066f680abc89618d2dcfd17b1f8b4b2f52d4cc9d2fac88cf2d11f51bc37dd3` | GainsNav, GainsVaultLogic |
| GainsVault | arbitrum | `0x5dcc5a9cb35ecb4da9c6438440e01cf85d5b25e54dfd56a7eedb7c359561f958` | 22,422 | `0xb330f4e4cf0f017614527b24ae38aced71dfc4485f4b074bfabe6f60b118ed41` | GainsNav, GainsVaultGovernance, GainsVaultLogic |
| GainsVaultPolicy | arbitrum | `0xd7c1e93712fc0658f4bf40621f28dbb1f3071e74f675817a6f2e38abd66c52ed` | 13,084 | `0x2631e9509991c7f2f9b46dc95db5ec1c96b549aeb921012815caa53b78c9669b` | none |
| GainsVaultLens | arbitrum | `0xcad684ad36f0c4352877835c78d30af37a76eb06a3cd4b8b00622edb83e9bd2a` | 10,450 | `0xdfd7387ecc17bfeecea1c114d68db11b954dc238ebf6e8d4d5e9084a9bad3885` | none |
| GainsVaultFactory | arbitrum | `0xfb25836141da5d25269acecdc257e080c41bd6f90ba04f2c375a78afc624f077` | 13,523 | `0x009fda77c4c6703137fb409a8c9892d40d63e95269569c45cf99910a8292ccb6` | none |
<!-- /table -->
