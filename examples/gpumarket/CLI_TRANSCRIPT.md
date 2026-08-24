# gpumarket CLI transcript

Generated 2026-08-24 from a fresh `data/` dir. Providers, silicon,
pricing models and regions are closed worlds; listings and models are the
open world. Prices are an illustrative snapshot in millidollars/GPU-hr.

## schema — two tables, closed worlds visible as enum columns

```console
$ gpumarket schema
{"base":"gpumarket","fingerprint":"15276474960197467840","ok":true,"tables":[{"columns":[{"enum":["lambdaLabs","coreweave","runpod","vastAi","awsEc2","gcp","azure","nebius","crusoe","hotAisle","togetherAi","voltagePark","paperspace"],"name":"provider","nullable":false,"type":"TEXT"},{"enum":["h100Sxm","h100Pcie","h200","b200","gh200","a100Sxm80","a100Pcie40","l40s","l4","a10","rtx4090","rtx5090","mi300x","mi325x"],"name":"gpu","nullable":false,"type":"TEXT"},{"name":"count","nullable":false,"type":"INTEGER"},{"default":"onDemand","enum":["onDemand","spot","reserved1mo","reserved1yr"],"name":"pricing","nullable":false,"type":"TEXT"},{"default":"northAmerica","enum":["northAmerica","europe","asiaPacific","middleEast"],"name":"region","nullable":false,"type":"TEXT"},{"name":"usdHr","nullable":false,"type":"INTEGER"},{"default":1,"name":"available","nullable":false,"type":"INTEGER"},{"name":"observedAt","nullable":false,"type":"INTEGER"}],"name":"listing"},{"columns":[{"name":"name","nullable":false,"type":"TEXT"},{"enum":["metaAi","deepseek","alibaba","mistral","openai","google","moonshot","zhipu"],"name":"maker","nullable":false,"type":"TEXT"},{"name":"paramsB","nullable":false,"type":"INTEGER"},{"name":"activeB","nullable":true,"type":"INTEGER"},{"name":"contextK","nullable":false,"type":"INTEGER"},{"default":16,"name":"quantBits","nullable":false,"type":"INTEGER"},{"default":1,"name":"openWeights","nullable":false,"type":"INTEGER"}],"name":"model"}]}
(exit 0)
```

## seed

```console
$ gpumarket query seed
{"ok":true,"seeded":true}
(exit 0)
```

## cheapest on-demand H100 (whole family, cheapest first)

```console
$ gpumarket query h100 onDemand
{"ok":true,"result":[{"available":1,"count":8,"gpu":"h100Sxm","id":10,"observedAt":1756000000,"pricing":"onDemand","provider":"voltagePark","region":"northAmerica","usdHr":1990},{"available":1,"count":8,"gpu":"h100Sxm","id":3,"observedAt":1756000000,"pricing":"onDemand","provider":"vastAi","region":"northAmerica","usdHr":2210},{"available":1,"count":8,"gpu":"h100Sxm","id":9,"observedAt":1756000000,"pricing":"onDemand","provider":"togetherAi","region":"northAmerica","usdHr":2390},{"available":1,"count":1,"gpu":"h100Pcie","id":16,"observedAt":1756000000,"pricing":"onDemand","provider":"runpod","region":"northAmerica","usdHr":2390},{"available":1,"count":8,"gpu":"h100Sxm","id":1,"observedAt":1756000000,"pricing":"onDemand","provider":"lambdaLabs","region":"northAmerica","usdHr":2490},{"available":1,"count":8,"gpu":"h100Sxm","id":2,"observedAt":1756000000,"pricing":"onDemand","provider":"runpod","region":"northAmerica","usdHr":2790},{"available":1,"count":8,"gpu":"h100Sxm","id":7,"observedAt":1756000000,"pricing":"onDemand","provider":"nebius","region":"europe","usdHr":2950},{"available":1,"count":8,"gpu":"h100Sxm","id":8,"observedAt":1756000000,"pricing":"onDemand","provider":"crusoe","region":"northAmerica","usdHr":3900},{"available":1,"count":8,"gpu":"h100Sxm","id":4,"observedAt":1756000000,"pricing":"onDemand","provider":"coreweave","region":"northAmerica","usdHr":4760},{"available":1,"count":1,"gpu":"h100Pcie","id":17,"observedAt":1756000000,"pricing":"onDemand","provider":"paperspace","region":"northAmerica","usdHr":5950},{"available":1,"count":8,"gpu":"h100Sxm","id":6,"observedAt":1756000000,"pricing":"onDemand","provider":"gcp","region":"europe","usdHr":6350},{"available":1,"count":8,"gpu":"h100Sxm","id":5,"observedAt":1756000000,"pricing":"onDemand","provider":"awsEc2","region":"northAmerica","usdHr":6980}]}
(exit 0)
```

## cheapest H100 SXM spot

```console
$ gpumarket query cheapest h100Sxm spot
{"ok":true,"result":[{"available":1,"count":8,"gpu":"h100Sxm","id":11,"observedAt":1756000000,"pricing":"spot","provider":"vastAi","region":"northAmerica","usdHr":1650},{"available":1,"count":8,"gpu":"h100Sxm","id":12,"observedAt":1756000000,"pricing":"spot","provider":"runpod","region":"northAmerica","usdHr":1790},{"available":1,"count":8,"gpu":"h100Sxm","id":13,"observedAt":1756000000,"pricing":"spot","provider":"awsEc2","region":"northAmerica","usdHr":2860}]}
(exit 0)
```

## unknown SKU is refused with the whole world named (exit 2)

```console
$ gpumarket query cheapest h300 onDemand
{"code":"decode","message":"cli.g: \"h300\" is not one of #[h100Sxm, h100Pcie, h200, b200, gh200, a100Sxm80, a100Pcie40, l40s, l4, a10, rtx4090, rtx5090, mi300x, mi325x]","ok":false}
(exit 2)
```

## AMD silicon — Gpu.vendor match compiles to (gpu IS 'mi300x' OR gpu IS 'mi325x')

```console
$ gpumarket query amd
{"ok":true,"result":[{"available":1,"count":1,"gpu":"mi300x","id":38,"observedAt":1756000000,"pricing":"spot","provider":"vastAi","region":"northAmerica","usdHr":1550},{"available":1,"count":8,"gpu":"mi300x","id":35,"observedAt":1756000000,"pricing":"onDemand","provider":"hotAisle","region":"northAmerica","usdHr":1990},{"available":1,"count":8,"gpu":"mi300x","id":36,"observedAt":1756000000,"pricing":"onDemand","provider":"runpod","region":"northAmerica","usdHr":2490}]}
(exit 0)
```

## who can serve DeepSeek-V3 (671B, native fp8), cheapest first

```console
$ gpumarket query canServe 4
{"ok":true,"result":[[{"activeB":37,"contextK":128,"id":4,"maker":"deepseek","name":"DeepSeek-V3","openWeights":1,"paramsB":671,"quantBits":8},{"available":1,"count":8,"gpu":"mi300x","id":35,"observedAt":1756000000,"pricing":"onDemand","provider":"hotAisle","region":"northAmerica","usdHr":1990}],[{"activeB":37,"contextK":128,"id":4,"maker":"deepseek","name":"DeepSeek-V3","openWeights":1,"paramsB":671,"quantBits":8},{"available":1,"count":8,"gpu":"mi300x","id":36,"observedAt":1756000000,"pricing":"onDemand","provider":"runpod","region":"northAmerica","usdHr":2490}],[{"activeB":37,"contextK":128,"id":4,"maker":"deepseek","name":"DeepSeek-V3","openWeights":1,"paramsB":671,"quantBits":8},{"available":1,"count":8,"gpu":"h200","id":18,"observedAt":1756000000,"pricing":"onDemand","provider":"lambdaLabs","region":"northAmerica","usdHr":3290}],[{"activeB":37,"contextK":128,"id":4,"maker":"deepseek","name":"DeepSeek-V3","openWeights":1,"paramsB":671,"quantBits":8},{"available":1,"count":8,"gpu":"h200","id":19,"observedAt":1756000000,"pricing":"onDemand","provider":"runpod","region":"northAmerica","usdHr":3590}],[{"activeB":37,"contextK":128,"id":4,"maker":"deepseek","name":"DeepSeek-V3","openWeights":1,"paramsB":671,"quantBits":8},{"available":1,"count":8,"gpu":"b200","id":21,"observedAt":1756000000,"pricing":"onDemand","provider":"nebius","region":"europe","usdHr":5500}],[{"activeB":37,"contextK":128,"id":4,"maker":"deepseek","name":"DeepSeek-V3","openWeights":1,"paramsB":671,"quantBits":8},{"available":1,"count":8,"gpu":"h200","id":20,"observedAt":1756000000,"pricing":"onDemand","provider":"coreweave","region":"northAmerica","usdHr":6310}],[{"activeB":37,"contextK":128,"id":4,"maker":"deepseek","name":"DeepSeek-V3","openWeights":1,"paramsB":671,"quantBits":8},{"available":1,"count":8,"gpu":"b200","id":22,"observedAt":1756000000,"pricing":"onDemand","provider":"coreweave","region":"northAmerica","usdHr":8900}]]}
(exit 0)
```

## provider lookup: closed world answers from code, open world from rows

```console
$ gpumarket query providerInfo hotAisle
{"ok":true,"result":{"cheapest_milli":1990,"listings":2,"name":"Hot Aisle","website":"https://hotaisle.xyz"}}
(exit 0)
```

## typed row filter

```console
$ gpumarket rows listing --eq provider=vastAi --eq pricing=spot
{"count":2,"ok":true,"rows":[{"available":1,"count":8,"gpu":"h100Sxm","id":11,"observedAt":1756000000,"pricing":"spot","provider":"vastAi","region":"northAmerica","usdHr":1650},{"available":1,"count":1,"gpu":"mi300x","id":38,"observedAt":1756000000,"pricing":"spot","provider":"vastAi","region":"northAmerica","usdHr":1550}]}
(exit 0)
```

## insert with defaults (pricing, region, available omitted)

```console
$ gpumarket insert listing {"provider":"crusoe","gpu":"h200","count":8,"usdHr":3490,"observedAt":1756000000}
{"ok":true,"row":{"available":1,"count":8,"gpu":"h200","id":39,"observedAt":1756000000,"pricing":"onDemand","provider":"crusoe","region":"northAmerica","usdHr":3490}}
(exit 0)
```

## closed world refuses an unknown provider (exit 2)

```console
$ gpumarket insert listing {"provider":"initech","gpu":"h200","count":8,"usdHr":1000,"observedAt":1756000000}
{"code":"decode","message":"listing.provider: \"initech\" is not in the closed world","ok":false}
(exit 2)
```

## query log — the reified plans

```console
$ gpumarket log 3
{"count":3,"entries":[{"at":1787606053,"detail":"listing","error":null,"id":56,"ok":true,"rows":1,"verb":"insert"},{"at":1787606053,"detail":"listing | pushed: t0.\"provider\" IS ?, residual conjuncts: 0","error":null,"id":55,"ok":true,"rows":2,"verb":"select"},{"at":1787606053,"detail":"model×listing | pushed: (t0.\"id\" IS ? AND t1.\"available\" IS ?), residual conjuncts: 1","error":null,"id":54,"ok":true,"rows":7,"verb":"select"}],"ok":true}
(exit 0)
```

## migrate status

```console
$ gpumarket migrate status
{"applied":[],"fingerprint":"15276474960197467840","notes":["schema already up to date"],"ok":true}
(exit 0)
```

