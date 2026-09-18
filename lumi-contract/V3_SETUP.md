# LUMI V3 setup plan

## Existing shared revenue vaults

- SUI: `0xd287e57727542b0654a93b3dab7b6b78df5d71a1456220be803d842022f31a00`
- USDC: `0xc6f8ff6178217465e96c7cc751d5e7aa7c1031f358cd39e7efb19aedd31a89ec`
- CETUS: `0x786f54ab80ecd0bc3af89a2630acf55c2b269166130eb4e0c7b6a48db4651d03`

## Create immediately after the V3 upgrade

Call `revenue::create_vault<T>` once for each type below, using the LUMI
`AdminCap`. These start empty and hold revenue only; they do not deploy to LP
pools until a later guarded revenue-deployment upgrade.

| Asset | Coin type | Reason |
| --- | --- | --- |
| DEEP | `0xdeeb7a4662eec9f2f3def03fb937a663dddaa2e215b8078a284d026b7946c270::deep::DEEP` | Cetus/Bluefin pair asset and incentive |
| USDSUI | `0x44f838219cf67b058f3b37907b655f226153c18e33dfcd0da559a844fea9b1c1::usdsui::USDSUI` | Cetus pair asset and trading fees |
| WAL | `0x356a26eb9e012a68958082340d4c4116e7f55615cf27affcff209cf0ae544f59::wal::WAL` | Cetus/Bluefin pair asset and incentive |
| BLUE | `0xe1b45a0e641b9955a20aa0ad1c1f4ad86aad8afb07296d4085e349a50e90bdca::blue::BLUE` | Bluefin incentives |
| stSUI | `0xd1b72982e40348d069bb1ff701e634c117bb5f741f44dff91e472d3b01461e55::stsui::STSUI` | Bluefin incentives |

The opening farm reward inventory was read directly from the current Cetus and
Bluefin pool objects. New reward emissions require a new typed vault before a
farm can route that reward to protocol revenue.
