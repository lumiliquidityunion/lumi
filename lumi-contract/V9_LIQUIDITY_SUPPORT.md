# V9 — LUMI/SUI liquidity support

`lumi::liquidity_support` adds a protocol-owned Cetus LUMI/SUI liquidity
position. It is intentionally separate from user farm receipts.

## What it does

- Withdraws a nominated SUI allocation from the typed SUI revenue vault.
- Reads the five-minute LUMI/SUI TWAP and checks live Cetus spot is within 2%.
- Draws a capped, matching LUMI amount from the fixed reserve.
- Opens or tops up a Cetus LUMI/SUI position atomically.
- Returns every unused SUI to the SUI revenue vault and unused LUMI to the
  LUMI reserve within that same transaction.
- Requires operator-supplied minimum deployed LUMI and SUI amounts, so the
  allocation reverts rather than accepting an unexpectedly small fill.

## What it does not do

- It does not guarantee a LUMI price or undo the price effect of a sale.
- It does not pay a user's farm principal, promise a dollar value, or make the
  protocol treasury responsible for LP impermanent loss.
- It does not swap a full farm exit into LUMI. That requires an actual
  price-guarded swap route for every underlying asset.

## Entry points

- `create_lumi_sui_support` creates a shared protocol-owned Cetus position.
- `add_lumi_sui_support` adds a later SUI revenue allocation to that position.

Both calls require `AdminCap` because they allocate protocol revenue. The
price check, exact reserve draw cap, and user-independent return path are
enforced on chain.

## Test order

1. Record a continuous LUMI/SUI oracle window for at least five minutes with
   no gap above 120 seconds.
2. Dry-run `create_lumi_sui_support` with a very small SUI revenue allocation.
3. Verify the `LiquiditySupported` event and the post-transaction balances of
   the SUI revenue vault and LUMI reserve.
4. Only then execute the same call on mainnet and retain the returned shared
   `LumiSuiLiquidityPosition` object ID for later top-ups.

The allocation must use live minimum amounts calculated by the app immediately
before signing; hard-coded production minimums are unsafe.


