# LUMI V6 TWAP observation oracle

V6 is source-ready but not deployed. It adds `lumi::price_oracle` for the
existing LUMI/SUI pool:

`0x451b42a0c1a3ce4b32cffda328ec22e726d7f4cb1c6f77800bd1defb1a1a2ff2`

## What it does

- `create` creates one shared `PriceOracle` object.
- `record_lumi_sui` permissionlessly records the pool's on-chain square-root
  price. The caller never supplies a price.
- Samples are no more frequent than one per minute.
- `twap_sqrt_price` requires an entire requested window to be covered without
  a gap over two minutes, and rejects stale or insufficient histories.

## Activation sequence

1. Upgrade to V6 and create the shared oracle object.
2. Call `record_lumi_sui` approximately once a minute for more than 30 minutes.
3. Verify the oracle returns a valid 30-minute TWAP.
4. Only then add the separate conversion adapter, which must require this TWAP
   plus a user-provided `min_lumi_out` before it swaps or pays LUMI.

V6 records a trustworthy on-chain reference. It does not itself execute any
conversion or make the LUMI payout options public.
