# Compatible V1 validation — 2026-10-21

The final compatible source passed **144 tests across 18 suites, with zero failures and zero skips**. The separate actual-V2 integration passed one additional test. These are local results; source admission and public deployment remain pending.

## Reproduce the V1 suite

```sh
MUGI_IMD_MAINNET_FORK_RPC=https://ethereum-rpc.publicnode.com \
MUGI_IMD_MAINNET_FORK_BLOCK=26244024 \
ETHEREUM_MAINNET_RPC_URL=https://ethereum-rpc.publicnode.com \
MUGI_V4_FORK_BLOCK=26244024 forge test --json
python3 scripts/check-compatible-artifacts.py
```

The exact fork block hash and timestamp are in `fork-block.json`. The local toolchain is Foundry 1.5.1-stable and Solidity 0.8.26, Cancun, optimizer 200, via IR, bytecode hash none. Remote IMD uses its own environment; these results do not imply an identical worker environment.

`full-suite.json` contains the parsed test output; `full-suite.raw.log` preserves the original stdout, including a harmless missing on-disk fork-cache warning. `test-results.json` lists every test and its result. The real mainnet IMD factory/registry and V4 PoolManager were exercised on the local fork. Factory deployment, complete child creation, ten-pool seeding, launch, full season, terminal claims, timeout recovery, cutoff snapshots, token transfers, ETH/token solvency, handoff and receiver-failure rollback are covered.

## Artifact validation

`artifact-review.json` checks 15 compiled contract types, including all four factories and all 19 descendant instances. All 75 compiled source identities match current files. Every deployed constructor is nonpayable and static with at most 16 words. Runtime and initcode limits pass; the largest factory initcode including owner is 45,836 bytes, and the hook runtime is 22,663 bytes. The validator checks removal of later crew minting, ERC20 freezes, owner pause and application initialization APIs. This is a targeted source/artifact check, not remote admission or a complete security audit.

## Actual V2 handoff

`v2-integration-result.json`, `v2-integration.log` and `MugiIMDCompatibleV1ToV2.t.sol.txt` record a separate isolated test using the existing fixed-supply V2 contracts. `v2-source-identities.json` records the 28 copied source hashes; all were checked unchanged after the run. The full reproducible harness and V2 source remain in the originating workspace under `v2/docs/validation/2026-10-21-imd-compatible-v1-handoff/`; V2 production code is outside this V1 submission.

The test completed nine eliminations and the ordinary finale, handed V1 assets to V2 before V2 token configuration, then configured, seeded, launched and bought through the actual V2 hook. V1 retained all reserved player ETH and token backing. Alice and Bob successfully claimed V1 rewards after V2 trading; repeat claims returned zero and repeat handoff was rejected. This fixture uses a real local PoolManager with mocked VRF and a `deployCodeTo` hook fixture. It proves contract integration, not live oracle delivery or production launch.

V2 remains an independently deployed future system. Handoff transfers only available protocol assets and retains V1 obligations for its 30-day claim period. It does not grant automatic wallet-level V2 allocation or a 1:1 token swap. Emergency closure does not permit migration.

## Remaining deployment work

IMD must explicitly accept the disclosed four-factory/19-descendant graph, reserve presentation and official-pool gates. After factories exist, five owner creation transactions, actual service configuration, exact graph/salt planning, funding and launch operations remain. No public child deployment, source verification or acceptance is asserted here.
