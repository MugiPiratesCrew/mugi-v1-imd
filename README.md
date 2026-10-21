# Mugi V1 IMD source admission candidate

This is a sanitized local Foundry source bundle. IMD source admission is PENDING.
Creating this directory does not publish a repository, submit an IMD job, pay any
fee, deploy a contract, verify source in an explorer, or prove hackathon eligibility.

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
Recheck the hook initcode hash from these exact compiled sources against any
prepared launch.json before submission. No keys or private RPC URLs belong here.
Inventory SHA-256 hashes cover every shipped file except inventory.json itself.
Build products are not part of the source inventory. launch.json, if supplied,
contains only validated public constructor values and standardized public notes.
Third-party source licenses are preserved beside their respective dependencies.
