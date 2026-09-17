# LUMI — Liquidity Union Moderated Interface

Curated access to Cetus and Bluefin liquidity farms on Sui. One coin. Fixed supply. **Live on Sui mainnet.**

**Landing:** [lumiliquidityunion.github.io/lumi](https://lumiliquidityunion.github.io/lumi)

## Coin — live

| | |
| --- | --- |
| Name | Liquidity Union |
| Symbol | LUMI |
| Network | Sui mainnet |
| Decimals | 2 |
| Total supply | 100,000,000.00 LUMI |
| Operations wallet | 12,400,000.00 LUMI |
| Shared vault | 87,600,000.00 LUMI |
| Further minting | None. `TreasuryCap` is owned by `0x0`. |
| Icon | [lumi-logo.jpg](https://lumiliquidityunion.github.io/lumi/lumi-logo.jpg) |

### Addresses

| | |
| --- | --- |
| Package | [`0xabb438fbd62e6b2df5954fdf251027c9f939a694c1baa4ffc38cbc3eddabfeb7`](https://suiscan.xyz/mainnet/object/0xabb438fbd62e6b2df5954fdf251027c9f939a694c1baa4ffc38cbc3eddabfeb7) |
| Coin type | [`0xabb438fbd62e6b2df5954fdf251027c9f939a694c1baa4ffc38cbc3eddabfeb7::lumi::LUMI`](https://suiscan.xyz/mainnet/coin/0xabb438fbd62e6b2df5954fdf251027c9f939a694c1baa4ffc38cbc3eddabfeb7::lumi::LUMI) |
| Vault | [`0x5bb897f85645195805f2e48dd21bddbd866048fa030423e6bfcf652a198282c0`](https://suiscan.xyz/mainnet/object/0x5bb897f85645195805f2e48dd21bddbd866048fa030423e6bfcf652a198282c0) |
| Ops wallet | [`0x58189b677894e0fe7ad38e0e516408a3500da57d86fc0436373bc1d9c6334d0a`](https://suiscan.xyz/mainnet/object/0x58189b677894e0fe7ad38e0e516408a3500da57d86fc0436373bc1d9c6334d0a) |
| Publish tx | [`94EyMTBDV4mEywzVUow3qLTt35hESwAWi7ZKnvJpLZki`](https://suiscan.xyz/mainnet/tx/94EyMTBDV4mEywzVUow3qLTt35hESwAWi7ZKnvJpLZki) |

Verified on-chain: 100,000,000.00 total, 12,400,000.00 in ops, 87,600,000.00 in the vault, TreasuryCap at `0x0`, logo URL in coin metadata. Publish cost 0.026092 SUI.

SuiScan source / MetaHub listing badge is still pending. The coin is live without that off-chain badge.

Machine-readable spec: [`docs/coin.json`](docs/coin.json)

Contract source: [`lumi-contract/sources/lumi.move`](lumi-contract/sources/lumi.move)

## Settlement

Stake a listed farm through LUMI with a Sui wallet. Positions stay on Cetus or Bluefin.

Of every profit tick:

- **97.5%** stays with the staker
- **2%** posts into the LUMI/SUI pair
- **0.5%** funds operations

Redeem profits as LUMI from the protocol vault, or take the pool’s coins as they are. Supply does not inflate. LUMI/SUI is protocol-owned liquidity, not an opening stakeable farm.

## Opening registry

Eight CLMMs. Object IDs on Sui mainnet.

| Venue | Pair | Fee | Band | Pool object |
| --- | --- | --- | --- | --- |
| Cetus | USDC / SUI | 0.25% | core | `0xb8d7d9e66a60c239e7a60110efcf8de6c705580ed924d0dde141f4a0e2c90105` |
| Cetus | DEEP / SUI | 0.25% | growth | `0xe01243f37f712ef87e556afb9b1d03d0fae13f96d324ec912daffc339dfdcbd2` |
| Cetus | USDSUI / SUI | 0.20% | core | `0x440e5e3b13b8220c5c338bb5a4291cab5c58064eaf3654c77f3e9aed5147689c` |
| Cetus | USDSUI / USDC | 0.01% | core | `0xa7417fb5f59e23b0a7826d78f025653823c49265be07bbf6dd9e553ba4249a56` |
| Cetus | WAL / SUI | 0.25% | growth | `0x72f5c6eef73d77de271886219a2543e7c29a33de19a6c69c5cf1899f729c3f17` |
| Bluefin | SUI / USDC | 0.175% | core | `0x15dbcac854b1fc68fc9467dbd9ab34270447aabd8cc0e04a5864d95ccb86b74a` |
| Bluefin | DEEP / SUI | 0.175% | growth | `0x7242459a663c4e59434252ceb27c228f6b1f21f2ba506f3b62d71b19a7421cc1` |
| Bluefin | WAL / SUI | 0.175% | growth | `0xe60bc7ade245b9f35b49686dfab0a18e5ca9176d49bef1b90f60d67d06315ff0` |

Full list: [`docs/pools.json`](docs/pools.json)

Delisted: Cetus USDC/SCA (`0x06bd46d0204b7faba458dc2342e08fc5008993d5bef84e0f1d87fa3e1728b319`).
