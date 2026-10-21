> Historical audit response for an earlier source revision. Current V2/treasury rules and fixes are in [IMD_COMPATIBLE_R2_RESPONSE.md](IMD_COMPATIBLE_R2_RESPONSE.md).

# Response to IMD audit, 21 October 2026

Historical response for source `028d37769edce6e38324182b8909392a9852af16`.
The current compatibility candidate is defined by [ADAPTATION.md](../ADAPTATION.md).
Any retained mint/freeze/pause/bootstrap requirements below describe that older
source and are superseded; current validation is under `validation/compatible/`.

Previous request transaction:
`0xa8f865165061fb43d5fff15c13152830a64718adcb8788c76c7d9233b9d5e7e7`.
Previous source: `56673aef8e55af52eec99c2567d272b7f01b8a65`.
Previous job: `a6715145-76db-498f-9ca9-a11ed38d82a8`.
The requester authorized repairing the reported issues and resubmitting revised
source. That authorization supersedes the prior request's packaging-only source
restriction for this new candidate; it does not change the old paid body.

| Finding | Response |
| --- | --- |
| High: accepted but never fulfilled VRF request locks the season | Fixed seven-day deadline measured from round cutoff, permissionless bounded terminal LP unwinding and deterministic recovery payout. No replacement request, reroll or arbitrary winner. A word stored before the deadline must still be used even if its delivery was deferred. First storage at or after the deadline cannot restart the game. |
| Medium: constructor V2 target discarded; repeatable migration | Persist and enforce a nonzero constructor target, make handoff one-time, and retain backing for existing player claims. Zero explicitly retains a one-time owner-selected V2 receiver. |
| Medium: earned survivor-token claims erased at finalization | Preserve escrow and earned claims for the same thirty-day final claim window as ETH. Exclude token escrow from V2 inventory; burn only expired residual backing after the deadline. |
| Medium: unbounded owner trading pause | Replace with one pause per round, at most one hour and never beyond cutoff. Automatic expiry; early release cannot replenish that round's allowance. Claims and settlement remain available under their lifecycle rules. A bounded pause still needs source-policy admission. |
| Medium: deterministic transfer restrictions | Fully disclose the original economic rules: normal transfers require a live, before-cutoff round and a surviving crew; eliminated balances are frozen receipts. After normal finalization, prelaunch abort or emergency closure, ordinary transfers remain frozen, including the final survivor. Earned token claims use an explicit protocol-transfer exception before expiry; receipt ownership is not freely transferable afterward. These rules need policy admission; they are not claimed to be a conventional unrestricted ERC20. |
| Medium: postlaunch minting | Fully disclose hook-only settlement minting for matched liquidity and elimination-claim escrow. The owner has no arbitrary mint entry point. Initial supply is not a lifetime cap. This required game rule still needs source-policy admission. |
| Medium: descendants and later configuration | Four recorded factory entries, nineteen later application contracts, and explicit owner setup remain fully disclosed. All descendant source is in the review scope. The hook creation bytecode is hash-bound; later modules use ordinary CALL, not upgrade proxies or delegatecall. No descendant is promised its own IMD Explorer launch entry. |
| Low: verifier signer and policy trust | Make the oracle signer, minimum panel size/quorum and maximum age immutable at construction. Owner pin/revoke remains, but cannot replace the signer or weaken evidence checks. Initial signer trust and any external ERC1271 signer governance remain explicit. |
| Info: hook hash lacks reproducible constructor inputs | Publish every argument in `hook-constructor.json` and the deterministic `scripts/check-hook-commitment.py`. Update the four-factory manifest to the newly compiled hook hash. |

The terminal recovery payout splits recovered, unreserved ETH equally across
currently live crews, then proportionally to each crew's eligible wallet plus
virtual balances. Prior earned ETH and team fees are excluded. Empty-crew shares
and rounding dust remain until the thirty-day sweep to the immutable community
treasury. It is a deterministic emergency refund, not another elimination.

The public configuration uses the same address for owner, team and community.
Those roles are excluded from player reward accounting. Emergency closure does
not add an owner withdrawal or a V2 handoff; the published expiration sweep can
still benefit the community address after the claim window.

## Source admission

The revised submission must establish eligibility under current `evm_contracts`
source policy, not only manifest compatibility. Review all four factories and
nineteen descendants. Distinguish hook-controlled game minting from discretionary
owner minting, deterministic lifecycle restrictions from owner freezing, a
bounded pause from indefinite pausing, and explicit setup from upgradeability.
If any required mechanic is prohibited, stop with `needs_input`, cite the policy
and explain the conflict. Do not hide or silently remove game behavior. A free
planning check does not establish final source admission.

No explorer source verification is authorized. The paid deployment covers the
four factories only; application bootstrap, liquidity and VRF funding are
separate operations. No successful launch or deployed address is claimed here.

## Oracle trust

The verifier authenticates the configured IMD signer's attestation, including its
reported panel counts; it does not independently verify each panel member onchain.
The owner can pin or revoke a request but cannot alter the immutable signer or
minimum evidence policy. An ERC1271 signer may have its own mutable governance.
Signer unavailability prevents optional approved allocation plans; deterministic
round settlement, player claims and timeout recovery do not depend on the signer.
