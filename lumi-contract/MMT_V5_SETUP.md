# LUMI V5 MMT adapter integration

V5 is deployed to Sui mainnet. It adds `lumi::mmt_adapter`, the two additional
revenue vaults, and all three MMT pools are registered in the LUMI router.

- V5 package: `0x3a6e9dde0fcf456ef27c16d06d3b4ddadabc7cc8832fefbac3b7883d5601ebbd`
- Upgrade transaction: `9xWv5RW5aSbu4Q7PuXUq7ZsFv7YANye5hGdDfsBjYX24`
- LBTC vault: `0x3c82b695f06a69d871f0d859af643c0ccfd17d0c6fa1b7c9a150abe49896be5c`
- X_SUI vault: `0x709119f295b6d966a4255bcaa9e956ed8dd11c982ee044a6cc49d234dd29491b`

## Objects passed to MMT calls

- MMT V3 published package: `0xcf60a40f45d46fc1e828871a647c1e25a0915dec860d2662eb10fdb382c3c1d1`
- MMT V3 runtime address: `0x70285592c97965e811e0c6f98dccc3a9c2b4ad854b3594faab9597ada267b860`
- Global config: `0x9889f38f107f5807d34c547828f4a1b4d814450005a4517a58a1ad476458abfc`
- Version: `0x2375a0b1ec12010aaea3b2545acfa2ad34cfbba03ce4b59f4c39e1e25eed1b2a`
- Sui clock: `0x6`

## Initial test order

1. Open a small route-0 position through `mmt_adapter::open_position_native`
   on registered farm 6 (SUI/USDC).
2. Claim its active `X_SUI` reward with `claim_native_reward`, then close with
   `close_native` using user-provided minimum output protection.
3. After this succeeds, test farm 5 (LBTC/SUI) and farm 7 (LBTC/USDC).

The adapter accepts route `0` only. A LUMI conversion has no on-chain price
guard yet, so it is intentionally not offered for MMT positions.
