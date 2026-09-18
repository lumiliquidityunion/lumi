# LUMI DApp test configuration

## Mainnet deployment

| Item | Address |
| --- | --- |
| LUMI original package | `0xabb438fbd62e6b2df5954fdf251027c9f939a694c1baa4ffc38cbc3eddabfeb7` |
| LUMI V5 package | `0x3a6e9dde0fcf456ef27c16d06d3b4ddadabc7cc8832fefbac3b7883d5601ebbd` |
| LUMI coin type | `0xabb438fbd62e6b2df5954fdf251027c9f939a694c1baa4ffc38cbc3eddabfeb7::lumi::LUMI` |
| Router | `0x83d70c4960964f37b2890703a9f293999f6e01d75da002f75d941b38e52ab1cc` |
| USDC revenue vault | `0xc6f8ff6178217465e96c7cc751d5e7aa7c1031f358cd39e7efb19aedd31a89ec` |
| SUI revenue vault | `0xd287e57727542b0654a93b3dab7b6b78df5d71a1456220be803d842022f31a00` |
| CETUS revenue vault | `0x786f54ab80ecd0bc3af89a2630acf55c2b269166130eb4e0c7b6a48db4651d03` |
| LBTC revenue vault | `0x3c82b695f06a69d871f0d859af643c0ccfd17d0c6fa1b7c9a150abe49896be5c` |
| X_SUI revenue vault | `0x709119f295b6d966a4255bcaa9e956ed8dd11c982ee044a6cc49d234dd29491b` |
| LUMI reserve vault | `0x5bb897f85645195805f2e48dd21bddbd866048fa030423e6bfcf652a198282c0` |
| Cetus USDC/SUI pool | `0xb8d7d9e66a60c239e7a60110efcf8de6c705580ed924d0dde141f4a0e2c90105` |
| LUMI/SUI pool | `0x451b42a0c1a3ce4b32cffda328ec22e726d7f4cb1c6f77800bd1defb1a1a2ff2` |

## Registered Cetus farms

| Farm ID | Pair | Pool | Fee | Registration transaction |
| --- | --- | --- | --- | --- |
| 0 | USDC/SUI | `0xb8d7d9e66a60c239e7a60110efcf8de6c705580ed924d0dde141f4a0e2c90105` | 0.25% | `Dddw79QXseTKQWsvojBTCde7hNqrLg6mGLQ4btaeLW3E` |
| 1 | DEEP/SUI | `0xe01243f37f712ef87e556afb9b1d03d0fae13f96d324ec912daffc339dfdcbd2` | 0.25% | `64qqbzroLZMJSqccXXBb3okotCNFRu98LQMSEowCiNJE` |
| 2 | USDSUI/SUI | `0x440e5e3b13b8220c5c338bb5a4291cab5c58064eaf3654c77f3e9aed5147689c` | 0.20% | `Bp73k6RNZAdwm6knrgd8LS2ng3dkHSJ1bxtYUwGQVfTV` |
| 3 | USDSUI/USDC | `0xa7417fb5f59e23b0a7826d78f025653823c49265be07bbf6dd9e553ba4249a56` | 0.01% | `BGqyxUySnS3rww2W4YpxYPKf5ifxpmePpcpDZUeJtCs` |
| 4 | WAL/SUI | `0x72f5c6eef73d77de271886219a2543e7c29a33de19a6c69c5cf1899f729c3f17` | 0.25% | `JBmeafeJbEZzL74ZAsV7vZXqAZy9Fbf4pVnUSrqbURDH` |

The current Cetus adapter supports these five registered Cetus farms. Coin A
and B are read from the live pool type; the dapp must not rely on display order.

The dapp calls `cetus_adapter::open_position` with the router, Cetus global
config, pool, farm ID, settlement route, tick range, USDC coin, SUI coin, and
Sui clock. The user selects one immutable route at open:

- `0`: native rewards. Native reward claims return 97.5%; 2% is retained in
  the matching revenue vault and 0.5% goes to operations.
- `1`: LUMI claim test route. The operations wallet supplies a manually quoted
  gross LUMI amount; the user specifies `min_lumi_out`; 0.5% LUMI goes to
  operations and the full native reward stays in the matching revenue vault.

## Test-only constraint

`claim_lumi_reward_for_test` is operations-wallet executed. It is for the
connected operations wallet's controlled test only. Do not expose it to public
users until an on-chain TWAP/oracle and a price-deviation guard replace the
manual quote.

## Registered MMT farms

Bluefin is excluded from the launch route. No Bluefin pools are registered in
the router. V5 adds the MMT V3 adapter and the following active MMT farms:

| Farm ID | Pair | MMT pool | Pool fee | Active reward inventory | Registration transaction |
| --- | --- | --- | --- | --- |
| 5 | LBTC/SUI | `0x392745193a7e472a8fd354d9fc38f26f023547566a4cda4864ee29a2c21f6fc8` | 0.20% | DEEP | `HCvZ8kJwS5i3N1F8qQJMPCdJwpoQTgpcRA94z9oLqsuy` |
| 6 | SUI/USDC | `0x455cf8d2ac91e7cb883f515874af750ed3cd18195c970b7a2d46235ac2b0c388` | 0.175% | X_SUI | `9pMGjZHUvp3Xsb64dCn6QNy3SyMwEyjzAtTGMvVXEctU` |
| 7 | LBTC/USDC | `0x7665f3a76ea9bb923556906a4d8ba8d98aa59776b7f098300758fe75d161a42c` | 0.20% | DEEP | `9Q3oJNF7kBVQxiw1zYSxkwyQU3FdoA65d8s3v8Aa5Dv6` |

The MMT adapter is native-settlement only in this release. Users receive the
native position assets and rewards; trading fees and claimed rewards use the
same 97.5% user / 2% revenue vault / 0.5% operations split as Cetus. The DApp
passes signed ticks as a positive magnitude plus a `negative` boolean. Claim
each configured reward type before closing; the venue rejects a non-empty
position so a close cannot silently discard accrued incentives.

MMT shared objects required by every DApp PTB are:

- Global config: `0x9889f38f107f5807d34c547828f4a1b4d814450005a4517a58a1ad476458abfc`
- Version: `0x2375a0b1ec12010aaea3b2545acfa2ad34cfbba03ce4b59f4c39e1e25eed1b2a`

## Remaining setup

1. Fund the wallet with DEEP and USDSUI before opening those Cetus test pairs.
2. Query and pass Cetus GlobalConfig and RewarderGlobalVault objects.
3. Test MMT SUI/USDC first at a small size; the connected wallet already has
   both assets.
4. Open a small position, claim its venue rewards through the selected route,
   and close using the applicable settlement path.
