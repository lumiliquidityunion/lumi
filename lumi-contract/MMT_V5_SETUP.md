# LUMI V5 MMT adapter integration

This source-only preparation adds `lumi::mmt_adapter`. It has not been deployed
to Sui mainnet yet, and none of the MMT pools are registered in the LUMI router.

## Objects passed to MMT calls

- MMT V3 published package: `0xcf60a40f45d46fc1e828871a647c1e25a0915dec860d2662eb10fdb382c3c1d1`
- MMT V3 runtime address: `0x70285592c97965e811e0c6f98dccc3a9c2b4ad854b3594faab9597ada267b860`
- Global config: `0x9889f38f107f5807d34c547828f4a1b4d814450005a4517a58a1ad476458abfc`
- Version: `0x2375a0b1ec12010aaea3b2545acfa2ad34cfbba03ce4b59f4c39e1e25eed1b2a`
- Sui clock: `0x6`

## Initial test order

1. Upgrade the LUMI package to V5.
2. Create shared `RevenueVault<LBTC>` and `RevenueVault<X_SUI>` objects.
3. List only MMT SUI/USDC, as the connected wallet already has both assets.
4. Open a small route-0 position through `mmt_adapter::open_position_native`.
5. Claim its active `X_SUI` reward with `claim_native_reward`, then close with
   `close_native` using user-provided minimum output protection.
6. Only after this succeeds, list and test the two LBTC pools.

The adapter accepts route `0` only. A LUMI conversion has no on-chain price
guard yet, so it is intentionally not offered for MMT positions.
