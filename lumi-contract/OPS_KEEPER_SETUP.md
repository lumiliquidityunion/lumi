# Operations Rebalance Keeper

This is an **operations-wallet testing tool**, not a public-user feature.

The keeper may only sign with the LUMI operations wallet and may only submit
transactions for LUMI receipts owned by that wallet. It has no authority to
transfer a user's position or to redeem LUMI from the reserve.

## Atomic Cetus flow

For a pool with three reward slots, the keeper builds one PTB that:

1. Calls `claim_native_reward` once for each reward type.
2. Calls `cetus_adapter::rebalance`.

The new `rebalance` call removes the old Cetus liquidity, applies the normal
native fee split to accrued trading fees, creates the new range, and returns
unused top-up coins and user fee proceeds to the operations wallet.

For DEEP/SUI the reward calls are, in this order:

1. `DEEP`
2. `SUI`
3. `CETUS`

This order is required because Cetus refuses to close an LP while any reward
slot remains unclaimed.

## Successor receipts

Cetus range changes require closing the old venue NFT. Sui does not permit a
contract to reuse its deleted wrapper UID, so a rebalance creates a successor
`CetusPosition` receipt. `PositionRebalanced` emits the old and new receipt
IDs. The dapp and keeper must replace their tracked receipt ID with
`new_receipt_id` after a successful transaction.

## Keeper guardrails

The keeper should only rebalance after all of these are true:

- The current pool tick is outside the current range, or has crossed the
  configured near-edge threshold.
- The new ticks are aligned to the pool tick spacing and have a valid lower /
  upper ordering.
- The transaction has explicit `min_amount_a` and `min_amount_b` values.
- The receipt is owned by the operations wallet.
- The transaction is dry-run successfully immediately before submission.

Do not enable this keeper for public user-owned receipts. Public automation
needs a separate opt-in custody and policy design.
