# LUMI V6 TWAP observation oracle

V6 is deployed and adds `lumi::price_oracle` for the existing LUMI/SUI pool:

`0x451b42a0c1a3ce4b32cffda328ec22e726d7f4cb1c6f77800bd1defb1a1a2ff2`

- V6 package: `0x11b7a66ba2dd491d63f5eb39872fe98c161555089247469bc8810075e80a2c99`
- V6 upgrade transaction: `GqN6TwPFYzBKtXx1nYZKxLZU1he7gBBEuB3J9LxioBRJ`
- Shared oracle: `0x054a753ddf24a05e15a8ba80b33bd8b0d3b5f604a5e9d57f210f1681a301784e`
- Oracle creation transaction: `AAuK36q3Y6SB4RfiUEe8DoswVVTmqTWCccDjfvU3hHR9`
- First observation transaction: `CtmGPQgBsJM6Af5x9stri9V2Y4JXnXKTphLR8VEsbt2v`

V7 recovery upgrade: `0x89a9123a40e056bba87ffd91bd2d04eade5b217da69fc0e49e68c64ca34bb904`  
V7 transaction: `3ZrNKXm8PjHUQxUdUEwo6RoDHHeheENgQLZZeEBTupEn`

V7 ignores observation gaps that precede the requested window while still
requiring continuous coverage at the beginning of, throughout, and at the end
of the five-minute window.

## What it does

- `create` creates one shared `PriceOracle` object.
- `record_lumi_sui` permissionlessly records the pool's on-chain square-root
  price. The caller never supplies a price.
- Samples are no more frequent than one per minute.
- `twap_sqrt_price` enforces a minimum five-minute window, requires that full
  window to be covered without a gap over two minutes, and rejects stale or
  insufficient histories.

## Activation sequence

1. Upgrade to V6 and create the shared oracle object.
2. Call `record_lumi_sui` approximately once a minute for more than five minutes.
3. Verify the oracle returns a valid five-minute TWAP by passing `300` seconds.
4. Only then add the separate conversion adapter, which must require this TWAP
   plus a user-provided `min_lumi_out` before it swaps or pays LUMI.

V6 records a trustworthy on-chain reference. It does not itself execute any
conversion or make the LUMI payout options public.
