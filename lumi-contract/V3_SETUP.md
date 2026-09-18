# LUMI V4 deployment map

V4 package: `0xbacbba6c003852e0b1b4bbe3219e4cad43617bbceb75583035ebf0de7c1abf35`  
V4 upgrade transaction: `2kjT952BJte7c1P6J6zvxiHJssnLhNLzJFsKimN4y9Tx`

V4 adds `cetus_adapter::close_with_native_rewards`, which atomically claims
the configured native reward and the pool coin-B reward before closing. This
is required because Cetus will not close a position with even a fractional
unclaimed incentive.

## Existing shared revenue vaults

- SUI: `0xd287e57727542b0654a93b3dab7b6b78df5d71a1456220be803d842022f31a00`
- USDC: `0xc6f8ff6178217465e96c7cc751d5e7aa7c1031f358cd39e7efb19aedd31a89ec`
- CETUS: `0x786f54ab80ecd0bc3af89a2630acf55c2b269166130eb4e0c7b6a48db4651d03`

## Additional shared revenue vaults

These vaults are live, empty typed custody for future protocol revenue. They
do not deploy to LP pools until a later guarded revenue-deployment upgrade.

| Asset | Vault | Coin type | Reason |
| --- | --- | --- | --- |
| DEEP | `0xb8b0c4b6569b1d7ef5ae3ee5cd8f22666af026e0307c0dcf8ce9bfb5da1ae117` | `0xdeeb7a4662eec9f2f3def03fb937a663dddaa2e215b8078a284d026b7946c270::deep::DEEP` | Cetus/Bluefin pair asset and incentive |
| USDSUI | `0xaf7470983e1056df16aeb241921a2edb59be34a6ab2d7ffb233ececb46144867` | `0x44f838219cf67b058f3b37907b655f226153c18e33dfcd0da559a844fea9b1c1::usdsui::USDSUI` | Cetus pair asset and trading fees |
| WAL | `0xf8053d438cfdab921f9ef3d40264b1453446d8a4cb7582a9ea7244e9686f9f0a` | `0x356a26eb9e012a68958082340d4c4116e7f55615cf27affcff209cf0ae544f59::wal::WAL` | Cetus/Bluefin pair asset and incentive |
| BLUE | `0x4ddfce7f0a2d3424ec8f9e8ad25a9945acc8382cd18bdeec74842b3d24b066c1` | `0xe1b45a0e641b9955a20aa0ad1c1f4ad86aad8afb07296d4085e349a50e90bdca::blue::BLUE` | Bluefin incentives |
| stSUI | `0xb2ad4a25062eebfc0e97919fb32ed99d69bd12aa64545a85bfcb0ebfa5e669e1` | `0xd1b72982e40348d069bb1ff701e634c117bb5f741f44dff91e472d3b01461e55::stsui::STSUI` | Bluefin incentives |

The opening farm reward inventory was read directly from the current Cetus and
Bluefin pool objects. New reward emissions require a new typed vault before a
farm can route that reward to protocol revenue.
