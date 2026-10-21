# Mugi V1 IMD source admission candidate

This is an unsubmitted follow-up Foundry source candidate for Mugi V1 IMD. Source
admission remains PENDING. Paid job
`6a953f2f-d28d-46cc-91a4-f348efed5c10` reviews the earlier source pin
`028d37769edce6e38324182b8909392a9852af16`; accepting its audit report does not
accept deployment. The preceding job
`a6715145-76db-498f-9ca9-a11ed38d82a8` was blocked without deploying contracts.
See `docs/validation/vrf-stall-repair/RECOVERY.md` for the revised lifecycle and
`docs/IMD_FINDINGS_RESPONSE.md` for the original findings response. The current
follow-up repairs, complete owner-trust disclosures and unresolved platform-policy
conflicts are recorded in `docs/IMD_FOLLOWUP_RESPONSE.md`.

The proposed manifest records four factories. They permit owner-authorized later
deployment of the Mugi hook, ten crew tokens, airdrop, VRF adapter, IMD verifier,
swap router, and ledger/buyback/oracle/liquidity-engine modules. The owner binds
modules before configuration and seeding. They use ordinary CALL; no linked game
libraries are needed. The lifecycle and every descendant must be disclosed to IMD.
Acceptance of that lifecycle and its appearance in IMD Explorer remain unconfirmed.
The source import must preserve the game token's restricted transfer/mint/burn rules.

Build and run local tests with:

```sh
forge build
forge test --match-contract MugiV1IMDDeploymentFactoryTest -vv
forge test --match-contract MugiIMDStateModulesTest -vv
```

The separate fork test requires MUGI_IMD_MAINNET_FORK_RPC in the local environment;
MUGI_IMD_MAINNET_FORK_BLOCK optionally pins a block. It skips without an RPC.
Run it with `forge test --match-contract MugiIMDProjectFactoryForkTest -vv`.
It creates state locally on a fork; a fork result is not a public deployment.

Compiler: Solidity 0.8.26, Cancun, optimizer 200, via IR, bytecode hash none.
The complete public constructor inputs are in `hook-constructor.json`. Rebuild
and check the committed hook creation bytecode plus ABI-encoded arguments:

```sh
python3 scripts/check-hook-commitment.py
```

It checks the compiler settings, runtime/initcode size and `launch.json` commitment.
No signatures, network writes or deployments occur. The script requires Python 3
and Foundry (the submission verifier uses v1.8.3). Changing a constructor input or
Solidity source requires an explicitly reviewed replacement commitment; maintainers
can then regenerate it using `--write-manifest` before preparing a new request.
The zero V2 target explicitly selects a one-time owner-selected future V2 receiver;
a nonzero configured target is immutable and enforced. Team/community addresses
and initial supply are public and unchanged from the prior request. No keys or
private RPC URLs belong here.
Inventory SHA-256 hashes cover every shipped file except inventory.json itself.
Build products are not part of the source inventory. launch.json, if supplied,
contains only validated public constructor values and standardized public notes.
Third-party source licenses are preserved beside their respective dependencies.
