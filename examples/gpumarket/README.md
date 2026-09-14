# GPU market

A larger market example with hardware facts and model-serving estimates.
Use [gpus](../gpus/README.md) for the smaller introduction. This package also
provides the GPU vocabulary used by [kernels](../kernels/README.md).
Requires the root project's Lean toolchain and the local LeanDB checkout.

From the repository root:

```bash
cd examples/gpumarket
lake build gpumarket
demo_dir=$(mktemp -d)
export LEANDB_DB="$demo_dir/gpumarket.sqlite"
gpumarket=./.lake/build/bin/gpumarket
$gpumarket seed
$gpumarket query h100 onDemand
$gpumarket query under 2500 onDemand
```

`h100` returns available H100-family listings in price order. `under 2500`
finds available on-demand listings at or below $2.50 per GPU-hour; prices are
illustrative and stored in millidollars. See
[GpuMarket/Queries.lean](GpuMarket/Queries.lean).

An unknown pricing model is rejected:

```bash
$gpumarket query h100 unknownPricing
```

This exits with code 2 and a JSON `decode` error.

For the model-serving extension, inspect [GpuMarket/Models.lean](GpuMarket/Models.lean).
Run `lake build gpumarket_tests && .lake/build/bin/gpumarket_tests` for the tests.
Common commands are in the [CLI reference](../../README.md#the-cli-every-base-gets).
