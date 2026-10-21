> Historical audit response for an earlier source revision. Current V2/treasury rules and fixes are in [IMD_COMPATIBLE_R2_RESPONSE.md](IMD_COMPATIBLE_R2_RESPONSE.md).

# Follow-up IMD audit response, 21 October 2026

> Historical response for candidate94d7836. The authorized compatibility redesign
> supersedes the retained mint/freeze/pause/bootstrap choices below. See
> [ADAPTATION.md](../ADAPTATION.md) and current validation for this source.

The second paid submission is transaction
`0xf9e0ac8ab84e1f9309dd66ba60498854dda03417d580bb07a12106a1bb69f91d`,
job `6a953f2f-d28d-46cc-91a4-f348efed5c10`, reviewing source
`028d37769edce6e38324182b8909392a9852af16`. Its audit report was accepted
at 20:32:52 UTC. That accepts the report, not deployment of the project.
The auditor reported no critical or high code defects, seven medium findings,
one low finding and one informational coverage entry.

This checkout contains an unsubmitted follow-up candidate. No additional fee or
public deployment is authorized by this document. Source admission remains
unresolved. Validation of this candidate is recorded in `validation/followup/VALIDATION.md`: all
131 tests passed, zero failed or skipped, including both mainnet fork suites at
block 26243437. The previous validation report belongs to the previous pin.

These changes apply only to the isolated IMD full-token source bundle. The wider
workspace's original crew factory still uses clones and an initializer; its base
token must not be replaced with this constructor-only version. New token creation
code also changes deterministic token addresses, so any future deployment must
recompute predictions from this candidate instead of reusing earlier addresses.

## Repairs and remaining findings

| Finding | Follow-up disposition |
| --- | --- |
| Terminal claims reduce the public eligible-supply total | Repair the terminal virtual-to-wallet accounting without changing fixed ETH claim snapshots, terminal transfer restrictions, or migration accounting. Validate normal and emergency finalization, partial and batch claims, expiry and eager/lazy account synchronization. |
| Dead external initializer on the full crew-token route | Remove `Initializable`, the external `initialize` entry point and the unused clone route from this IMD-only source tree. Configure tokens directly through constructors. Preserve hook-only mint/burn and transfer callbacks. |
| Owner-selected randomness, verifier and accounting modules | Explicit trust disclosure below. The reviewed deployment factories construct the expected implementations, but the current hook does not enforce their provenance. No claim of on-chain canonical-module enforcement is made. |
| Zero V2 destination permits discretionary owner custody | Preserve the previously selected manual future-V2 mode and disclose the complete scope below. A real reviewed V2 destination has not been provided; no placeholder receiver is introduced. |
| Postlaunch mint, lifecycle freezes and bounded pause | Required game mechanics remain. The adaptation policy prohibits these capabilities. Disclosure does not create an exception. |
| Staged factory deployment and later application configuration | Remains explicit: four recorded factories and nineteen application descendants with owner setup. Removing the token initializer does not make this bootstrap constructor-only. |

## Authority established during owner setup

The hook's `configure` accepts code-bearing randomness-provider and verifier
addresses. `bindAccounting` checks each module's reported hook binding, not its
runtime provenance or deployment in the published factory registries. An owner
can therefore supply a replacement provider that chooses elimination words,
a verifier that accepts arbitrary plans, or replacement accounting/engine
implementations. The published hook creation-code commitment does not commit
these subsequently supplied addresses or their behavior.

The published factories deploy the reviewed VRF adapter, verifier and modules,
but users must inspect the actual owner setup transactions and dependency code
before relying on those implementations. The adapter's coordinator and service
configuration also need inspection; selecting canonical adapter bytecode alone
does not prove a genuine Chainlink coordinator was selected. Setup is a trust
boundary, even though binding/configuration is one-time and the reviewed runtime
has no upgrade or delegatecall path. The initial verifier signer and airdrop
attestor retain their separately disclosed trust assumptions.

An enforced canonical-setup redesign would bind the hook to its deployment
factory, make the factory wire its own created dependencies and canonical module
registries, and commit external coordinator parameters. That would change the
deployment manifest, setup flow, bytecode commitment and tests. It is not present
in this candidate and is not claimed as an implemented mitigation.

## Ordinary finale and the future V2 destination

The published constructor input sets the V2 target to zero. After ordinary
finalization the owner can choose any code-bearing receiver once. The handoff
includes all ETH other than team fees and reserved player ETH, plus the final
survivor's token inventory other than earned-token escrow. This includes the
survivor's withdrawn LP principal, treasure and unused budgets. A receiver can
implement the expected interface and then forward the funds to the owner.

One-shot migration and retained claim reserves prevent repeated handoffs or
spending existing player liabilities; they do not constrain the chosen receiver.
Survivor holders have no promised on-chain redemption right over migrated value.
Owner, team and community addresses are currently identical, so routing the
handoff to the community address would not eliminate this custody discretion.
A meaningful fixed-target mitigation requires a real reviewed destination and
its intended redemption rules. Emergency closure follows its deterministic
player-refund path and does not perform this V2 handoff.

## Admission decision still required

Official references checked during this review:

- https://api.imd.fun/reads/skill/adapt-contract-project
- https://api.imd.fun/reads/skill/evm-contracts-launch
- https://api.imd.fun/reads/skill/build-contract-project
- https://api.imd.fun/launch/policies

The adaptation reference forbids postlaunch minting, pausing and holder freezes.
The contracts-only reference requires constructor configuration without later
initialization. The builder reference permits owner-set external service
parameters in some cases, but does not explicitly admit this entire staged
nineteen-contract bootstrap. No documented policy-27 exception or alternative
contracts-only recipe admitting all required mechanics was found.

The unresolved decision is whether policy 27 expressly admits these deterministic
game mechanics and this factory/bootstrap architecture. An authoritative positive
decision must identify the applicable policy or supported recipe. Omitting an
adaptation step, renaming a capability, or exposing only the four factories is
not evidence of permission. Do not pay again for the same unresolved conflicts.

No explorer source verification is authorized. No source admission, successful
launch, deployed address, or V2 guarantee is claimed.
