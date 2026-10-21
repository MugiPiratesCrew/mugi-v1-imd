# V1 compatibility adaptation and V2 handoff

This candidate supersedes the rejected mint/freeze/pause/bootstrap mechanics of
commit `028d37769edce6e38324182b8909392a9852af16` and the limited follow-up
`94d78364e3efcf5fa5c7ccf8f3727f2abf6b1085`. The owner explicitly requested the
IMD-compatible fixes while retaining the core V1 game and future V2 handoff.
Platform admission is pending. This document does not claim a public deployment.

## Preserved game rules

Ten crews, the 95/5 initial circulating allocation, fixed daily cutoffs, one VRF
outcome per round, nine eliminations, 75% loser conversion across survivors,
pro-rata treasure rewards, LP redistribution, bounded buybacks, team fees,
permissionless timeout recovery and the 30-day final claim window remain.
The game modules use ordinary CALL. There is no proxy or delegatecall route.

## Removed capabilities and their replacements

| IMD adaptation rule | Source change | Observable consequence |
| --- | --- | --- |
| No post-launch token minting | Every crew token mints its entire finite reserve once in its constructor. The hook releases separately tracked reserve for the existing conversions and LP reinforcements. No external mint selector exists. | ERC20 totalSupply includes the unused reserve. It is not circulating supply. Eligibility excludes all protocol custodians. Untouched reserve is burned when that crew exits or the game closes. |
| No holder freezes or confiscation | ERC20 transfers have no hook callback; only the token holder can burn its own balance. | Transfers remain possible at cutoff, after elimination and after finale. Dead crew tokens confer no new game rights. Official game pools still enforce the published round/alive rules. |
| Preserve cutoff ownership without freezing | Tokens record balance/supply history; the ledger reads strictly before each original scheduled cutoff. | A transfer or burn exactly at cutoff or after a known result cannot move or duplicate that round's entitlement. Token materialization waits during resolution; ETH claims remain available under their existing rules. |
| No owner pause | The pause state, selector and checks are removed. | The owner cannot halt live gameplay. Fixed cutoffs and deterministic VRF timeout recovery remain. |
| Constructor configuration without later initialization | Tokens, hook, ledger and dependencies receive final bindings in their constructors. Fixed CREATE child addresses break circular dependencies; the hook uses a mined CREATE2 address. Crew names/symbols are derived internally from crew ID, so deployed child constructors also use only static arguments. | No initialize/configure/bindAccounting/setExcluded selector is present in the new hook/token/ledger route. Later transactions create complete applications; the initial four factories alone do not mean the game is live. |
| Empty-chain constructor simulation | Constructors use only supplied values, hashes and pure address derivation. Live dependency checks run before seeding/use. | Factories and children can be constructed before dependent code exists. Missing/mismatched dependencies prevent economic activation. |

The reserve proof is in `src/game/MugiReserveMath.sol`: with initial allocation
I and M=int128.max, 10I+100M covers the bounded nine-round origin supply and
conversion rounding. Claims consume existing backing; they do not release a
second reserve allocation. Unused reserve can never be withdrawn or migrated.

## V1 to V2 remains possible

V2 is a separate implementation and admission/deployment task. V1 may be launched
with a zero future target. After ordinary V1 finale, the owner selects a deployed
receiver once using `migrateToV2`. If a nonzero target was constructor-pinned,
only that target is accepted. The receiver implements
`receiveV1Finale(uint8,address,uint256)` and is funded atomically with available
finale ETH and survivor inventory.

Before this handoff, finale removes the last V4 position, freezes final accounting
at its original cutoff and burns unused survivor reserve. Migration subtracts
reserved player ETH and team ETH, and subtracts earned-token escrow from survivor
inventory. Player token/ETH claims remain in V1 through their published window.
A rejecting receiver rolls back the migration flag and both asset transfers.
Emergency closure retains its player refund path and does not migrate to V2.

This is protocol-fund continuity, not an automatic 1:1 holder-token conversion.
V2 chooses and funds its own token supply. The current actual V2 receiver allows
V1 funds to arrive before its token is configured; activation is separate.

## Explicit remaining trust and admission limits

- A zero V2 target retains owner discretion over the final receiver. One-shot
  migration protects reserved claims, but does not constrain that receiver's
  later use of protocol funds or promise holder redemption.
- Constructor inputs still select the external VRF coordinator/subscription,
  airdrop attestor and IMD verifier signer. No mock service is a launch parameter.
  Hook dependencies are fixed at construction; factory provenance and external
  service settings must be checked against the published deployment graph.
- Four manifest contracts create nineteen disclosed application descendants in
  later transactions. IMD must admit that application-creation flow and the
  official pool/claim timing rules. Do not infer admission from compilation or
  an accepted audit report.
- V2's present constructor/configuration path has not been adapted or admitted
  by this V1 change. The narrow handoff interface is preserved and tested.
- There is no explorer source verification and no direct-deployment fallback.

See `docs/IMD_CONSTRUCTOR_DEPLOYMENT.md` for creation order and deterministic
bindings, and `docs/validation/compatible/VALIDATION.md` for current test evidence.
Earlier audit/validation documents describe their historical source pins only.

## Official rules checked

- [Contract adaptation](https://api.imd.fun/reads/skill/adapt-contract-project)
- [Contracts-only launch](https://api.imd.fun/reads/skill/evm-contracts-launch)

The no-initialization rule is addressed by constructor-complete children, not by
hiding descendants. Admission still needs IMD review of the disclosed graph.
