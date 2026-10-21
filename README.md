# Mugi — Ten Crews, One Survivor

Mugi is a pirate-themed Ethereum game where ten crews compete through trading,
treasure rewards and eliminations. Each crew has its own token and Uniswap V4
pool, with one shared game hook enforcing the rules. Chainlink VRF supplies the
randomness used to eliminate crews until one survivor remains.

Trading funds player treasure and token buybacks. When a crew is eliminated,
its liquidity helps support the surviving crews. The finale prepares the
remaining assets for an explicit owner-authorized migration to Mugi V2.

## How Mugi uses IMD

IMD supports the project's deployment workflow and its recurring buyback
research. Research agents evaluate a confirmed game snapshot and propose how to
allocate the survivor-buyback budget across living crews. A separate signed
review binds the proposal to its request, chain, hook and plan hash.

Mugi's contracts keep custody of the funds. They enforce allocation bounds,
spending limits, timing and price protections; purchased crew tokens are burned.
An equal-allocation fallback remains available when there is no active IMD plan.
A hosted, funded keeper relays eligible actions, and V1's bounded buyback
execution functions can also be called by anyone.

The IMD deployment manifest contains four factories. Subsequent owner-authorized
transactions create and bind the shared hook, ten crew tokens, airdrop, VRF
adapter, IMD verifier, swap router and accounting/liquidity modules. The factories
use ordinary calls without linked game libraries.

## Source and development

This repository contains the standalone Mugi V1 contracts, deployment manifest
and tests. Mainnet deployment and remote IMD source approval are still pending.
The source preserves the game's hook-controlled mint/burn, defeated-token
restrictions and owner pause rules.

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
