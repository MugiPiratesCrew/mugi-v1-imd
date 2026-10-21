# Stalled VRF recovery and final claims

The original submitted source accepted one VRF request and had no terminal exit
when that request never produced a word. Its audit proof fails on the original
source; `original-proof.log` records that reproduction. The repair deliberately
does not make the proof's proposed second request succeed. It adds a terminal
recovery path and tests that the coordinator still receives exactly one request.

## Fixed deadline, no reroll

Each round commits to a deadline seven days after its fixed cutoff, even when
the coordinator rejects requests or nobody submits one. Requests made at or
after that deadline revert; requesting late cannot extend it. The adapter
records the first on-chain fulfillment time.
A word stored strictly before the deadline must be delivered and settled,
including when its original hook callback failed and permissionless delivery
is retried after the deadline. Such a stored word prevents emergency recovery.

A word first stored at or after the deadline cannot choose a defeated crew or
resume the season. Once the deadline passes without an on-time stored word,
any account can call `recoverStalledRandomness(maxPools)`, including from Live
when no request was accepted (before the normal final round), with `maxPools` from
1 to 10. Each call removes at most that many still-live positions. A cursor
preserves completed batches; a reverting batch can be retried without repeating
completed withdrawals. No second request, replacement oracle, block-hash
randomness, owner-selected loser, or live-season owner cashout is introduced.
Oracle withholding remains an availability assumption; the deterministic
fallback prevents indefinite custody, rather than pretending to replace VRF.

## Emergency ETH allocation

After every remaining position has been removed and hook fee claims redeemed:

```
R = native ETH held by hook - outstanding team ETH - previously reserved player ETH
n = number of still-live crews
s = floor(R / n)
E_i = frozen eligible wallet units + virtual units for crew i (both scaled)
e_ai = account a's eligible wallet units + virtual units for crew i
new entitlement(a) = sum over live crews with E_i > 0 of floor(s * e_ai / E_i)
```

`R` includes recovered LP principal, treasures, unspent own-buyback and round
buyback funds, deferred liquidity, and protocol ETH dust. Existing earned ETH
is retained separately and is never redistributed. Team LP fees are booked
and excluded. This is an emergency-only distribution of current economic
ownership, not a refund of historical purchase prices or the original seed.
Protocol custody, team/community treasuries, airdrop inventory, and other
excluded accounts do not receive holder shares.

Zero-eligible-supply crew shares and division dust remain unallocated. Individual
rounding residuals remain reserved. Both join unclaimed player ETH for the
immutable community treasury after the 30-day terminal claim window. The
treasury is not called while removing positions or completing recovery, so its
fallback cannot block LP recovery or the player claim window. There is no V2
migration from emergency closure.

## Preserved final token claims

Normal finalization and emergency closure preserve previously earned virtual
token claims and their physical escrow. Players can materialize them throughout
the terminal 30-day claim window. A normal V2 handoff excludes escrow backing
from transferred inventory, so handing off protocol assets cannot take player
claims. Expiry permanently clears accounting and burns the remaining escrow;
lazy account synchronization cannot resurrect expired ETH or token rights.

A nonzero constructor V2 target is now enforced. A zero target explicitly keeps
the original manual selection, made only once by the owner after ordinary
finalization. Migration is one-shot in both modes.

## Bounded owner pause

An owner can pause trading at most once in each elimination round, for at most
one hour and never beyond that round's cutoff. Early unpause does not restore
the allowance. The `paused()` getter reports effective expiry without another
owner transaction. Transfers, claims, elimination, settlement, finalization,
and stalled-request recovery are not blocked by this pause.

The original immutable lifecycle transfer restrictions remain: cutoff and
settlement freeze transfers, eliminated crews stay frozen, and terminal V1
tokens remain frozen receipts. Survivor supply may still be minted by the
settlement rules. Staged factory deployment and these game-specific mechanics
still require explicit platform admission; they are not standard unrestricted
ERC20 launch behavior.
