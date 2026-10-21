# Response to the compatible V1 audit

This revision responds to audit report `573ea9d5650bafcdc892589b64157aecbe9239f7efb89fa37b3d9bed699654f2` from IMD job `0c8421fb-4f6d-4650-8c90-d9fd7d7a79c5`, which reviewed source `9901dc71030df5818e4b307df1c5c43506346c12`. Acceptance of that report was not source admission. No public deployment is claimed here.

| Finding | Change |
| --- | --- |
| Blocking medium: zero receiver allows an owner-selected finale sink | Hook construction now rejects zero V2 destinations. Migration accepts exactly the immutable constructor pin and is permissionless. The actual reviewed receiver must be chosen before the child graph is created. The sample V2 field is explicitly unresolved, and is not used by any of the four factory constructors. |
| Blocking medium: owner inactivity can strand normal-finale capital | Normal finale records a 30-day migration deadline. Before it, anyone can execute the fixed handoff. At/after it, anyone can call `fallbackFinaleToCommunity`, which permanently consumes migration and sends only unreserved protocol ETH and survivor inventory to the fixed community. Player and team liabilities remain reserved. The deadline survives the separate expired-claim sweep. |
| Blocking medium: planned community equals owner/team | The user authorized creation of a separate community wallet, `0x973d5993Be7021882f72da0babCF884e77F76bBb`. Hook construction rejects community==owner/team, and ownership cannot transfer to the community address. The same operator controls the separate wallet; address separation is not independent governance. No private key is part of this bundle. |
| Low: PoolManager custody/contract-wallet participation | ADAPTATION.md explicitly describes wallet snapshots: third-party V4 LP custody is excluded and arbitrary contracts must be able to call their own claims. No new beneficiary accounting is invented. |
| Low: factory gas measurement omits deposit/intrinsic gas | Creation regressions explicitly require measured gas to cover the full 200-gas-per-runtime-byte deposit and add intrinsic, calldata, initcode and wrapper allowances. Actual local RPC receipt evidence is recorded separately; local receipts are not public deployment evidence. |

The ten-crew game, daily cutoffs, nine VRF eliminations, 75% conversions, treasure rewards, fee rules, LP redistribution, bounded buybacks, constructor-only finite reserve, ordinary ERC20 transfers and 30-day claim window remain. The intentional terminal changes remove late receiver selection and add a deadline with deterministic recovery. V2 remains a separate reviewed deployment; this request deploys only four owner-bound factories and discloses all nineteen later descendants.

No explorer source verification is requested. The latest test and artifact evidence is under `docs/validation/compatible`.
