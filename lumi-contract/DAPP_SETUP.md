# LUMI DApp test configuration

## Mainnet deployment

| Item | Address |
| --- | --- |
| LUMI original package | `0xabb438fbd62e6b2df5954fdf251027c9f939a694c1baa4ffc38cbc3eddabfeb7` |
| LUMI V2 package | `0xc3f4cd97d86c36c807bae8e7b766b74de3e9feee504e3360a803082484c6d906` |
| LUMI coin type | `0xabb438fbd62e6b2df5954fdf251027c9f939a694c1baa4ffc38cbc3eddabfeb7::lumi::LUMI` |
| Router | `0x83d70c4960964f37b2890703a9f293999f6e01d75da002f75d941b38e52ab1cc` |
| USDC revenue vault | `0xc6f8ff6178217465e96c7cc751d5e7aa7c1031f358cd39e7efb19aedd31a89ec` |
| SUI revenue vault | `0xd287e57727542b0654a93b3dab7b6b78df5d71a1456220be803d842022f31a00` |
| CETUS revenue vault | `0x786f54ab80ecd0bc3af89a2630acf55c2b269166130eb4e0c7b6a48db4651d03` |
| LUMI reserve vault | `0x5bb897f85645195805f2e48dd21bddbd866048fa030423e6bfcf652a198282c0` |
| Cetus USDC/SUI pool | `0xb8d7d9e66a60c239e7a60110efcf8de6c705580ed924d0dde141f4a0e2c90105` |
| LUMI/SUI pool | `0x451b42a0c1a3ce4b32cffda328ec22e726d7f4cb1c6f77800bd1defb1a1a2ff2` |

## First test farm

Use Cetus USDC/SUI only. It is listed as farm ID `0` once the router listing
transaction is executed. Coin A is USDC and Coin B is SUI.

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

## Required remaining setup

1. Register Cetus USDC/SUI in the router.
2. Query and pass Cetus GlobalConfig and RewarderGlobalVault objects.
3. Open a small USDC/SUI test position using the dapp.
4. Claim CETUS or SUI rewards through the selected route.
5. Close the position and verify principal/revenue-vault accounting.
