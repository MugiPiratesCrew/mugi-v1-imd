# Follow-up source validation

All 131 tests passed across 15 suites, with zero failed or skipped tests. Both mainnet fork suites used Ethereum block 26243437, hash `0x4fd384a91faad357baf09e355102940d13e6e720646d064d1e834da5ccbaa29f`. These executions changed local fork state only.

The complete run validates constructor-only full crew tokens and terminal virtual-to-wallet supply conservation. The terminal regression assertions failed in both normal and emergency modes before the ledger fix. Targeted validation passed 27 factory tests and 14 ledger tests, including 256 randomized eager/lazy synchronization cases. The full run passed after all production changes, independently of those targeted results.

```sh
ETHEREUM_MAINNET_RPC_URL=https://ethereum-rpc.publicnode.com MUGI_V4_FORK_BLOCK=26243437 MUGI_IMD_MAINNET_FORK_RPC=https://ethereum-rpc.publicnode.com MUGI_IMD_MAINNET_FORK_BLOCK=26243437 forge test --json
python3 scripts/check-hook-commitment.py
```

Compiler settings remain Solidity 0.8.26, Cancun, optimizer 200, via IR and bytecode hash none. All 23 production artifacts fit Ethereum bytecode limits with no unresolved library links. The hook runtime remains 24483 bytes; its constructor-complete initcode hash remains `0x08f972c762e16058099e4d4b614fe24f360fd1780af043308c475cab65d39b3d`. The full-token ABI contains no `initialize` function. Crew creation code changed, so future CREATE2 predictions must be recomputed.

`validation-summary.json` records production source hashes, bytecode sizes, test counts and the pinned fork block. `full-suite.raw.json` preserves the complete successful run. `terminal-claim-baseline.log` preserves the failing pre-fix cases; `ledger-targeted-summary.json` records the focused follow-up run.

This candidate has not been submitted to IMD. No additional payment, public deployment, explorer verification or platform admission is claimed. The current paid job reviews the prior commit. Admission-policy conflicts and owner-setup/V2 custody assumptions remain documented in `../../IMD_FOLLOWUP_RESPONSE.md`.
