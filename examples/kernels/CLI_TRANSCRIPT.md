# kernels CLI transcript

Generated 2026-09-01 from a fresh `data/` dir, on LEP-0003 stage B (B1–B3).
Dtypes, ops, languages, architectures and licenses are closed worlds; the
SKU world is gpumarket's `Gpu`. `sig` and `launch` are JSON TEXT columns
with a declared shape (`ColCodec.json`) that the fingerprint covers;
`inDtype0`/`outDtype0`/`rank0` are derived from `sig` (recomputed on
write, checked on read); `binding` and `fuses` are canonical TEXT. Bench
numbers are illustrative.

## schema — five tables; sig/launch are TEXT with a declared shape (LEP-0003 B2), the derived search columns are enum/INTEGER beside them

```console
$ kernels schema
{"base":"kernels","fingerprint":"535084016606190269","ok":true,"tables":[{"columns":[{"name":"name","nullable":false,"type":"TEXT"},{"enum":["gemm","gemv","batchedGemm","attention","flashAttention","pagedAttention","softmax","layerNorm","rmsNorm","rope","silu","gelu","reduce","scan","embedding","allReduce","allGather","conv2d","topK","sort"],"name":"op","nullable":false,"type":"TEXT"},{"enum":["cuda","hip","triton","cutlass","ck","ptx","mlir"],"name":"lang","nullable":false,"type":"TEXT"},{"name":"variant","nullable":false,"type":"TEXT"},{"name":"sig","nullable":false,"shape":"KernelSig{vars:[String],ins:[TensorTy{dtype:<f64|f32|tf32|bf16|f16|fp8e4m3|fp8e5m2|fp4e2m1|int8|int4|int32|uint8|bool>,shape:[Dim(lit{n:Nat}|var{v:String}|mul{k:Nat,d:Dim}|add{a:Dim,b:Dim}|div{d:Dim,k:Nat})],layout:Layout(rowMajor|colMajor|strided{strides:[Dim(lit{n:Nat}|var{v:String}|mul{k:Nat,d:Dim}|add{a:Dim,b:Dim}|div{d:Dim,k:Nat})]}|tiled{tile:[Nat],inner:Layout})=,mem:<global|shared|register|constant>=,align:Nat=}],outs:[TensorTy{dtype:<f64|f32|tf32|bf16|f16|fp8e4m3|fp8e5m2|fp4e2m1|int8|int4|int32|uint8|bool>,shape:[Dim(lit{n:Nat}|var{v:String}|mul{k:Nat,d:Dim}|add{a:Dim,b:Dim}|div{d:Dim,k:Nat})],layout:Layout(rowMajor|colMajor|strided{strides:[Dim(lit{n:Nat}|var{v:String}|mul{k:Nat,d:Dim}|add{a:Dim,b:Dim}|div{d:Dim,k:Nat})]}|tiled{tile:[Nat],inner:Layout})=,mem:<global|shared|register|constant>=,align:Nat=}],scalars:[(String,<f64|f32|tf32|bf16|f16|fp8e4m3|fp8e5m2|fp4e2m1|int8|int4|int32|uint8|bool>)],constraints:[DimConstraint(divides{k:Nat,d:Dim(lit{n:Nat}|var{v:String}|mul{k:Nat,d:Dim}|add{a:Dim,b:Dim}|div{d:Dim,k:Nat})}|le{a:Dim(lit{n:Nat}|var{v:String}|mul{k:Nat,d:Dim}|add{a:Dim,b:Dim}|div{d:Dim,k:Nat}),b:Dim(lit{n:Nat}|var{v:String}|mul{k:Nat,d:Dim}|add{a:Dim,b:Dim}|div{d:Dim,k:Nat})}|eq{a:Dim(lit{n:Nat}|var{v:String}|mul{k:Nat,d:Dim}|add{a:Dim,b:Dim}|div{d:Dim,k:Nat}),b:Dim(lit{n:Nat}|var{v:String}|mul{k:Nat,d:Dim}|add{a:Dim,b:Dim}|div{d:Dim,k:Nat})})]}","type":"TEXT"},{"enum":["sm80","sm86","sm89","sm90","sm100","gfx90a","gfx942","gfx950"],"name":"minArch","nullable":false,"type":"TEXT"},{"enum":["sm80","sm86","sm89","sm90","sm100","gfx90a","gfx942","gfx950"],"name":"maxArch","nullable":true,"type":"TEXT"},{"name":"launch","nullable":false,"shape":"LaunchConfig{block:Nat,smemBytes:Nat,stages:Nat=}","type":"TEXT"},{"name":"deterministic","nullable":false,"type":"INTEGER"},{"enum":["f64","f32","tf32","bf16","f16","fp8e4m3","fp8e5m2","fp4e2m1","int8","int4","int32","uint8","bool"],"name":"accum","nullable":false,"type":"TEXT"},{"name":"fuses","nullable":false,"type":"TEXT"},{"name":"source","nullable":false,"type":"TEXT"},{"enum":["mit","apache2","bsd3","proprietary"],"name":"license","nullable":false,"type":"TEXT"},{"enum":["f64","f32","tf32","bf16","f16","fp8e4m3","fp8e5m2","fp4e2m1","int8","int4","int32","uint8","bool"],"name":"inDtype0","nullable":false,"type":"TEXT"},{"enum":["f64","f32","tf32","bf16","f16","fp8e4m3","fp8e5m2","fp4e2m1","int8","int4","int32","uint8","bool"],"name":"outDtype0","nullable":false,"type":"TEXT"},{"name":"rank0","nullable":false,"type":"INTEGER"}],"name":"kernel"},{"columns":[{"name":"kernel","nullable":false,"references":"kernel","type":"INTEGER"},{"enum":["h100Sxm","h100Pcie","h200","b200","gh200","a100Sxm80","a100Pcie40","l40s","l4","a10","rtx4090","rtx5090","mi300x","mi325x"],"name":"sku","nullable":false,"type":"TEXT"},{"name":"binding","nullable":false,"type":"TEXT"},{"enum":["f64","f32","tf32","bf16","f16","fp8e4m3","fp8e5m2","fp4e2m1","int8","int4","int32","uint8","bool"],"name":"precision","nullable":false,"type":"TEXT"},{"name":"latency","nullable":false,"type":"INTEGER"},{"name":"tflops","nullable":false,"type":"INTEGER"},{"name":"bwGBs","nullable":false,"type":"INTEGER"},{"name":"occupancy","nullable":false,"type":"INTEGER"},{"default":10,"name":"warmup","nullable":false,"type":"INTEGER"},{"default":100,"name":"iters","nullable":false,"type":"INTEGER"},{"name":"driver","nullable":false,"type":"TEXT"},{"name":"toolchain","nullable":false,"type":"TEXT"},{"name":"host","nullable":false,"type":"TEXT"},{"name":"measuredAt","nullable":false,"type":"INTEGER"}],"name":"bench"},{"columns":[{"name":"name","nullable":false,"type":"TEXT"},{"enum":["h100Sxm","h100Pcie","h200","b200","gh200","a100Sxm80","a100Pcie40","l40s","l4","a10","rtx4090","rtx5090","mi300x","mi325x"],"name":"sku","nullable":false,"type":"TEXT"},{"name":"binding","nullable":false,"type":"TEXT"}],"name":"program"},{"columns":[{"name":"program","nullable":false,"references":"program","type":"INTEGER"},{"name":"position","nullable":false,"type":"INTEGER"},{"name":"kernel","nullable":false,"references":"kernel","type":"INTEGER"}],"name":"program_node"},{"columns":[{"name":"program","nullable":false,"references":"program","type":"INTEGER"},{"name":"toNode","nullable":false,"references":"program_node","type":"INTEGER"},{"name":"toInput","nullable":false,"type":"INTEGER"},{"name":"fromNode","nullable":false,"references":"program_node","type":"INTEGER"},{"name":"fromOutput","nullable":false,"type":"INTEGER"}],"name":"program_edge"}]}
(exit 0)
```

## seed

```console
$ kernels query seed
{"ok":true,"seeded":true}
(exit 0)
```

## a signature, pretty-printed from the opaque column

```console
$ kernels query kernelInfo gemm-cutlass-sm90-fp8
{"ok":true,"result":{"fuses":"","id":7,"inDtype0":"fp8e4m3","launch":{"block":384,"smemBytes":232448,"stages":4},"name":"gemm-cutlass-sm90-fp8","op":"gemm","outDtype0":"bf16","rank0":2,"sig":"∀ M N K, (fp8e4m3[M,K], fp8e4m3[K,N]:colMajor) → (bf16[M,N]) where K % 128 = 0, N % 16 = 0"}}
(exit 0)
```

## candidates — op, search column, Arch.supports (case split, guards folded), maxArch all push (see log below)

```console
$ kernels query candidates gemm sm90 bf16
{"ok":true,"result":[{"accum":"f32","deterministic":1,"fuses":"","id":1,"inDtype0":"bf16","lang":"cutlass","launch":"{\"block\":384,\"smemBytes\":196608,\"stages\":4}","license":"bsd3","maxArch":null,"minArch":"sm90","name":"gemm-cutlass-sm90-bf16","op":"gemm","outDtype0":"f32","rank0":2,"sig":"{\"constraints\":[{\"divides\":{\"d\":{\"var\":{\"v\":\"K\"}},\"k\":64}},{\"divides\":{\"d\":{\"var\":{\"v\":\"N\"}},\"k\":8}}],\"ins\":[{\"align\":16,\"dtype\":\"bf16\",\"layout\":\"rowMajor\",\"mem\":\"global\",\"shape\":[{\"var\":{\"v\":\"M\"}},{\"var\":{\"v\":\"K\"}}]},{\"align\":16,\"dtype\":\"bf16\",\"layout\":\"colMajor\",\"mem\":\"global\",\"shape\":[{\"var\":{\"v\":\"K\"}},{\"var\":{\"v\":\"N\"}}]}],\"outs\":[{\"align\":16,\"dtype\":\"f32\",\"layout\":\"rowMajor\",\"mem\":\"global\",\"shape\":[{\"var\":{\"v\":\"M\"}},{\"var\":{\"v\":\"N\"}}]}],\"scalars\":[[\"alpha\",\"f32\"],[\"beta\",\"f32\"]],\"vars\":[\"M\",\"N\",\"K\"]}","source":"5957d0a3930a31945957d0a3930a31945957d0a3930a31945957d0a3930a3194","variant":"wgmma-128x256x64"},{"accum":"f32","deterministic":1,"fuses":"","id":2,"inDtype0":"bf16","lang":"cutlass","launch":"{\"block\":384,\"smemBytes\":196608,\"stages\":4}","license":"bsd3","maxArch":null,"minArch":"sm90","name":"gemm-cutlass-sm90-bf16-bf16out","op":"gemm","outDtype0":"bf16","rank0":2,"sig":"{\"constraints\":[{\"divides\":{\"d\":{\"var\":{\"v\":\"K\"}},\"k\":64}},{\"divides\":{\"d\":{\"var\":{\"v\":\"N\"}},\"k\":8}}],\"ins\":[{\"align\":16,\"dtype\":\"bf16\",\"layout\":\"rowMajor\",\"mem\":\"global\",\"shape\":[{\"var\":{\"v\":\"M\"}},{\"var\":{\"v\":\"K\"}}]},{\"align\":16,\"dtype\":\"bf16\",\"layout\":\"colMajor\",\"mem\":\"global\",\"shape\":[{\"var\":{\"v\":\"K\"}},{\"var\":{\"v\":\"N\"}}]}],\"outs\":[{\"align\":16,\"dtype\":\"bf16\",\"layout\":\"rowMajor\",\"mem\":\"global\",\"shape\":[{\"var\":{\"v\":\"M\"}},{\"var\":{\"v\":\"N\"}}]}],\"scalars\":[[\"alpha\",\"f32\"],[\"beta\",\"f32\"]],\"vars\":[\"M\",\"N\",\"K\"]}","source":"3cd07b2c1949ab7d3cd07b2c1949ab7d3cd07b2c1949ab7d3cd07b2c1949ab7d","variant":"wgmma-128x256x64-castout"},{"accum":"f32","deterministic":1,"fuses":"","id":5,"inDtype0":"bf16","lang":"triton","launch":"{\"block\":128,\"smemBytes\":49152,\"stages\":3}","license":"mit","maxArch":null,"minArch":"sm80","name":"gemm-triton-sm80-bf16","op":"gemm","outDtype0":"bf16","rank0":2,"sig":"{\"constraints\":[{\"divides\":{\"d\":{\"var\":{\"v\":\"K\"}},\"k\":32}},{\"divides\":{\"d\":{\"var\":{\"v\":\"N\"}},\"k\":8}}],\"ins\":[{\"align\":16,\"dtype\":\"bf16\",\"layout\":\"rowMajor\",\"mem\":\"global\",\"shape\":[{\"var\":{\"v\":\"M\"}},{\"var\":{\"v\":\"K\"}}]},{\"align\":16,\"dtype\":\"bf16\",\"layout\":\"colMajor\",\"mem\":\"global\",\"shape\":[{\"var\":{\"v\":\"K\"}},{\"var\":{\"v\":\"N\"}}]}],\"outs\":[{\"align\":16,\"dtype\":\"bf16\",\"layout\":\"rowMajor\",\"mem\":\"global\",\"shape\":[{\"var\":{\"v\":\"M\"}},{\"var\":{\"v\":\"N\"}}]}],\"scalars\":[[\"alpha\",\"f32\"],[\"beta\",\"f32\"]],\"vars\":[\"M\",\"N\",\"K\"]}","source":"3a04d4752187e2e53a04d4752187e2e53a04d4752187e2e53a04d4752187e2e5","variant":"autotuned-128x128x32"}]}
(exit 0)
```

## cross-vendor is never supported: the sm80 Triton GEMM does not appear on gfx942

```console
$ kernels query candidates gemm gfx942 bf16
{"ok":true,"result":[{"accum":"f32","deterministic":1,"fuses":"","id":3,"inDtype0":"bf16","lang":"ck","launch":"{\"block\":256,\"smemBytes\":65536,\"stages\":2}","license":"mit","maxArch":null,"minArch":"gfx942","name":"gemm-ck-gfx942-bf16","op":"gemm","outDtype0":"f32","rank0":2,"sig":"{\"constraints\":[{\"divides\":{\"d\":{\"var\":{\"v\":\"K\"}},\"k\":64}},{\"divides\":{\"d\":{\"var\":{\"v\":\"N\"}},\"k\":8}}],\"ins\":[{\"align\":16,\"dtype\":\"bf16\",\"layout\":\"rowMajor\",\"mem\":\"global\",\"shape\":[{\"var\":{\"v\":\"M\"}},{\"var\":{\"v\":\"K\"}}]},{\"align\":16,\"dtype\":\"bf16\",\"layout\":\"colMajor\",\"mem\":\"global\",\"shape\":[{\"var\":{\"v\":\"K\"}},{\"var\":{\"v\":\"N\"}}]}],\"outs\":[{\"align\":16,\"dtype\":\"f32\",\"layout\":\"rowMajor\",\"mem\":\"global\",\"shape\":[{\"var\":{\"v\":\"M\"}},{\"var\":{\"v\":\"N\"}}]}],\"scalars\":[[\"alpha\",\"f32\"],[\"beta\",\"f32\"]],\"vars\":[\"M\",\"N\",\"K\"]}","source":"a3825dccc608fda2a3825dccc608fda2a3825dccc608fda2a3825dccc608fda2","variant":"xdl-256x256x64"},{"accum":"f32","deterministic":1,"fuses":"silu","id":4,"inDtype0":"bf16","lang":"ck","launch":"{\"block\":256,\"smemBytes\":65536,\"stages\":2}","license":"mit","maxArch":null,"minArch":"gfx942","name":"gemm-ck-gfx942-bf16-silu","op":"gemm","outDtype0":"bf16","rank0":2,"sig":"{\"constraints\":[{\"divides\":{\"d\":{\"var\":{\"v\":\"K\"}},\"k\":64}},{\"divides\":{\"d\":{\"var\":{\"v\":\"N\"}},\"k\":8}}],\"ins\":[{\"align\":16,\"dtype\":\"bf16\",\"layout\":\"rowMajor\",\"mem\":\"global\",\"shape\":[{\"var\":{\"v\":\"M\"}},{\"var\":{\"v\":\"K\"}}]},{\"align\":16,\"dtype\":\"bf16\",\"layout\":\"colMajor\",\"mem\":\"global\",\"shape\":[{\"var\":{\"v\":\"K\"}},{\"var\":{\"v\":\"N\"}}]}],\"outs\":[{\"align\":16,\"dtype\":\"bf16\",\"layout\":\"rowMajor\",\"mem\":\"global\",\"shape\":[{\"var\":{\"v\":\"M\"}},{\"var\":{\"v\":\"N\"}}]}],\"scalars\":[[\"alpha\",\"f32\"],[\"beta\",\"f32\"]],\"vars\":[\"M\",\"N\",\"K\"]}","source":"04e2c5e67fa5abe204e2c5e67fa5abe204e2c5e67fa5abe204e2c5e67fa5abe2","variant":"xdl-256x256x64-silu-epilogue"}]}
(exit 0)
```

## fastest GEMM on H100 at 4096³ — join, SKU and canonical binding TEXT push; sort is client-side

```console
$ kernels query fastest gemm h100Sxm M=4096,N=4096,K=4096
{"ok":true,"result":[{"accum":"f32","deterministic":1,"fuses":"","id":2,"inDtype0":"bf16","lang":"cutlass","launch":"{\"block\":384,\"smemBytes\":196608,\"stages\":4}","license":"bsd3","maxArch":null,"minArch":"sm90","name":"gemm-cutlass-sm90-bf16-bf16out","op":"gemm","outDtype0":"bf16","rank0":2,"sig":"{\"constraints\":[{\"divides\":{\"d\":{\"var\":{\"v\":\"K\"}},\"k\":64}},{\"divides\":{\"d\":{\"var\":{\"v\":\"N\"}},\"k\":8}}],\"ins\":[{\"align\":16,\"dtype\":\"bf16\",\"layout\":\"rowMajor\",\"mem\":\"global\",\"shape\":[{\"var\":{\"v\":\"M\"}},{\"var\":{\"v\":\"K\"}}]},{\"align\":16,\"dtype\":\"bf16\",\"layout\":\"colMajor\",\"mem\":\"global\",\"shape\":[{\"var\":{\"v\":\"K\"}},{\"var\":{\"v\":\"N\"}}]}],\"outs\":[{\"align\":16,\"dtype\":\"bf16\",\"layout\":\"rowMajor\",\"mem\":\"global\",\"shape\":[{\"var\":{\"v\":\"M\"}},{\"var\":{\"v\":\"N\"}}]}],\"scalars\":[[\"alpha\",\"f32\"],[\"beta\",\"f32\"]],\"vars\":[\"M\",\"N\",\"K\"]}","source":"3cd07b2c1949ab7d3cd07b2c1949ab7d3cd07b2c1949ab7d3cd07b2c1949ab7d","variant":"wgmma-128x256x64-castout"},{"binding":"K=4096,M=4096,N=4096","bwGBs":399,"driver":"550.90","host":"h100-node-01","id":5,"iters":100,"kernel":2,"latency":168,"measuredAt":1756000000,"occupancy":500,"precision":"bf16","sku":"h100Sxm","tflops":818000,"toolchain":"cuda-12.6","warmup":10}]}
(exit 0)
```

## binding order does not matter: the encoding is canonical

```console
$ kernels query fastest gemm h100Sxm K=4096,N=4096,M=4096
{"ok":true,"result":[{"accum":"f32","deterministic":1,"fuses":"","id":2,"inDtype0":"bf16","lang":"cutlass","launch":"{\"block\":384,\"smemBytes\":196608,\"stages\":4}","license":"bsd3","maxArch":null,"minArch":"sm90","name":"gemm-cutlass-sm90-bf16-bf16out","op":"gemm","outDtype0":"bf16","rank0":2,"sig":"{\"constraints\":[{\"divides\":{\"d\":{\"var\":{\"v\":\"K\"}},\"k\":64}},{\"divides\":{\"d\":{\"var\":{\"v\":\"N\"}},\"k\":8}}],\"ins\":[{\"align\":16,\"dtype\":\"bf16\",\"layout\":\"rowMajor\",\"mem\":\"global\",\"shape\":[{\"var\":{\"v\":\"M\"}},{\"var\":{\"v\":\"K\"}}]},{\"align\":16,\"dtype\":\"bf16\",\"layout\":\"colMajor\",\"mem\":\"global\",\"shape\":[{\"var\":{\"v\":\"K\"}},{\"var\":{\"v\":\"N\"}}]}],\"outs\":[{\"align\":16,\"dtype\":\"bf16\",\"layout\":\"rowMajor\",\"mem\":\"global\",\"shape\":[{\"var\":{\"v\":\"M\"}},{\"var\":{\"v\":\"N\"}}]}],\"scalars\":[[\"alpha\",\"f32\"],[\"beta\",\"f32\"]],\"vars\":[\"M\",\"N\",\"K\"]}","source":"3cd07b2c1949ab7d3cd07b2c1949ab7d3cd07b2c1949ab7d3cd07b2c1949ab7d","variant":"wgmma-128x256x64-castout"},{"binding":"K=4096,M=4096,N=4096","bwGBs":399,"driver":"550.90","host":"h100-node-01","id":5,"iters":100,"kernel":2,"latency":168,"measuredAt":1756000000,"occupancy":500,"precision":"bf16","sku":"h100Sxm","tflops":818000,"toolchain":"cuda-12.6","warmup":10}]}
(exit 0)
```

## unknown SKU is refused with gpumarket's whole world named (exit 2)

```console
$ kernels query fastest gemm h300 M=4096,N=4096,K=4096
{"code":"decode","message":"cli.sku: \"h300\" is not one of #[h100Sxm, h100Pcie, h200, b200, gh200, a100Sxm80, a100Pcie40, l40s, l4, a10, rtx4090, rtx5090, mi300x, mi325x]","ok":false}
(exit 2)
```

## a malformed binding is refused before any SQL runs (exit 2)

```console
$ kernels query fastest gemm h100Sxm M=4096,N=abc
{"code":"decode","message":"cli.b: binding \"N=abc\": expected VAR=nat","ok":false}
(exit 2)
```

## composable — inDtype0 narrows in SQL, unification over sig runs in Lean (only the f32 softmax eats an f32 GEMM)

```console
$ kernels query composable gemm-cutlass-sm90-bf16
{"ok":true,"result":[{"accum":"f32","deterministic":1,"fuses":"","id":13,"inDtype0":"f32","lang":"cuda","launch":"{\"block\":128,\"smemBytes\":0,\"stages\":1}","license":"bsd3","maxArch":null,"minArch":"sm80","name":"softmax-cuda-sm80-f32","op":"softmax","outDtype0":"f32","rank0":2,"sig":"{\"constraints\":[],\"ins\":[{\"align\":16,\"dtype\":\"f32\",\"layout\":\"rowMajor\",\"mem\":\"global\",\"shape\":[{\"var\":{\"v\":\"M\"}},{\"var\":{\"v\":\"N\"}}]}],\"outs\":[{\"align\":16,\"dtype\":\"f32\",\"layout\":\"rowMajor\",\"mem\":\"global\",\"shape\":[{\"var\":{\"v\":\"M\"}},{\"var\":{\"v\":\"N\"}}]}],\"scalars\":[],\"vars\":[\"M\",\"N\"]}","source":"bd13402ebeaca2ecbd13402ebeaca2ecbd13402ebeaca2ecbd13402ebeaca2ec","variant":"warp-per-row"}]}
(exit 0)
```

## synthesize gemm→rmsNorm on H100: the bf16-out GEMM is chosen because the f32 one does not typecheck against the norm

```console
$ kernels query synthesize gemm,rmsNorm h100Sxm M=4096,N=4096,K=4096
{"ok":true,"result":{"estimate_us":199,"inputs":["bf16[4096,4096]","bf16[4096,4096]:colMajor","bf16[4096]"],"launches":[{"binding":"K=4096,M=4096,N=4096","ins":["bf16[4096,4096]","bf16[4096,4096]:colMajor"],"kernel":"gemm-cutlass-sm90-bf16-bf16out","kernel_id":2,"outs":["bf16[4096,4096]"],"position":0},{"binding":"H=4096,S=4096","ins":["bf16[4096,4096]","bf16[4096]"],"kernel":"rmsnorm-triton-sm80-bf16","kernel_id":10,"outs":["bf16[4096,4096]"],"position":1}],"outputs":["bf16[4096,4096]"],"skeleton":"// host skeleton for H100 SXM5 — launch order and edge types only, not compilable\ninput  in0 : bf16[4096,4096]\ninput  in1 : bf16[4096,4096]:colMajor\ninput  in2 : bf16[4096]\nalloc  buf0 : bf16[4096,4096]\nlaunch gemm-cutlass-sm90-bf16-bf16out [K=4096,M=4096,N=4096]  (in0, in1) -> (buf0)\nalloc  buf1 : bf16[4096,4096]\nlaunch rmsnorm-triton-sm80-bf16 [H=4096,S=4096]  (buf0, in2) -> (buf1)\noutput buf1 : bf16[4096,4096]","sku":"h100Sxm"}}
(exit 0)
```

## synthesize gemm→softmax on MI300X: no f32 softmax targets gfx942, so no program

```console
$ kernels query synthesize gemm,softmax mi300x M=4096,N=4096,K=4096
{"ok":true,"result":{"found":false}}
(exit 0)
```

## the stored program re-typed through Prog.ofRows

```console
$ kernels query program gemm-rmsnorm-4096
{"ok":true,"result":{"prog":{"estimate_us":199,"inputs":["bf16[4096,4096]","bf16[4096,4096]:colMajor","bf16[4096]"],"launches":[{"binding":"K=4096,M=4096,N=4096","ins":["bf16[4096,4096]","bf16[4096,4096]:colMajor"],"kernel":"gemm-cutlass-sm90-bf16-bf16out","kernel_id":2,"outs":["bf16[4096,4096]"],"position":0},{"binding":"H=4096,S=4096","ins":["bf16[4096,4096]","bf16[4096]"],"kernel":"rmsnorm-triton-sm80-bf16","kernel_id":10,"outs":["bf16[4096,4096]"],"position":1}],"outputs":["bf16[4096,4096]"],"skeleton":"// host skeleton for H100 SXM5 — launch order and edge types only, not compilable\ninput  in0 : bf16[4096,4096]\ninput  in1 : bf16[4096,4096]:colMajor\ninput  in2 : bf16[4096]\nalloc  buf0 : bf16[4096,4096]\nlaunch gemm-cutlass-sm90-bf16-bf16out [K=4096,M=4096,N=4096]  (in0, in1) -> (buf0)\nalloc  buf1 : bf16[4096,4096]\nlaunch rmsnorm-triton-sm80-bf16 [H=4096,S=4096]  (buf0, in2) -> (buf1)\noutput buf1 : bf16[4096,4096]","sku":"h100Sxm"},"program":"gemm-rmsnorm-4096","typed":true}}
(exit 0)
```

## regressions — self-join; the 10% arithmetic is the one residual conjunct

```console
$ kernels query regressions h100Sxm
{"ok":true,"result":[[{"binding":"K=4096,M=4096,N=4096","bwGBs":585,"driver":"550.90","host":"h100-node-01","id":1,"iters":100,"kernel":1,"latency":172,"measuredAt":1756000000,"occupancy":500,"precision":"bf16","sku":"h100Sxm","tflops":799000,"toolchain":"cuda-12.6","warmup":10},{"binding":"K=4096,M=4096,N=4096","bwGBs":508,"driver":"560.35","host":"h100-node-01","id":2,"iters":100,"kernel":1,"latency":198,"measuredAt":1756500000,"occupancy":500,"precision":"bf16","sku":"h100Sxm","tflops":694000,"toolchain":"cuda-12.8","warmup":10}]]}
(exit 0)
```

## roofline on MI300X from gpumarket's Gpu.spec / Gpu.tflops

```console
$ kernels query roofline mi300x
{"ok":true,"result":{"marketing":"Instinct MI300X","peak_bw_gbs":5300,"rows":[{"binding":"H=4096,S=4096","bound":"memory","bw_gbs":2796,"bw_permille":527,"compute_permille":1,"intensity_milliflop_per_byte":751,"kernel":"rmsnorm-hip-gfx942-bf16","latency_us":24,"peak_tflops":1307,"precision":"bf16","ridge_milliflop_per_byte":246603,"tflops_milli":2100},{"binding":"K=4096,M=4096,N=4096","bound":"compute","bw_gbs":671,"bw_permille":126,"compute_permille":700,"intensity_milliflop_per_byte":1365126,"kernel":"gemm-ck-gfx942-bf16","latency_us":150,"peak_tflops":1307,"precision":"bf16","ridge_milliflop_per_byte":246603,"tflops_milli":916000},{"binding":"K=4096,M=4096,N=4096","bound":"compute","bw_gbs":430,"bw_permille":81,"compute_permille":674,"intensity_milliflop_per_byte":2048837,"kernel":"gemm-ck-gfx942-bf16-silu","latency_us":156,"peak_tflops":1307,"precision":"bf16","ridge_milliflop_per_byte":246603,"tflops_milli":881000},{"binding":"K=4096,M=4096,N=4096","bound":"compute","bw_gbs":589,"bw_permille":111,"compute_permille":615,"intensity_milliflop_per_byte":1365025,"kernel":"gemm-ck-gfx942-bf16","latency_us":171,"peak_tflops":1307,"precision":"bf16","ridge_milliflop_per_byte":246603,"tflops_milli":804000},{"binding":"K=8192,M=8192,N=8192","bound":"compute","bw_gbs":720,"bw_permille":135,"compute_permille":750,"intensity_milliflop_per_byte":1362500,"kernel":"gemm-ck-gfx942-bf16","latency_us":1120,"peak_tflops":1307,"precision":"bf16","ridge_milliflop_per_byte":246603,"tflops_milli":981000},{"binding":"B=8,D=128,H=32,S=4096","bound":"compute","bw_gbs":981,"bw_permille":185,"compute_permille":410,"intensity_milliflop_per_byte":546381,"kernel":"flash-attn-ck-gfx942-bf16","latency_us":4100,"peak_tflops":1307,"precision":"bf16","ridge_milliflop_per_byte":246603,"tflops_milli":536000}],"sku":"mi300x"}}
(exit 0)
```

## typed row filter on a search column

```console
$ kernels rows kernel --eq inDtype0=fp8e4m3
{"count":1,"ok":true,"rows":[{"accum":"f32","deterministic":1,"fuses":"","id":7,"inDtype0":"fp8e4m3","lang":"cutlass","launch":"{\"block\":384,\"smemBytes\":232448,\"stages\":4}","license":"bsd3","maxArch":null,"minArch":"sm90","name":"gemm-cutlass-sm90-fp8","op":"gemm","outDtype0":"bf16","rank0":2,"sig":"{\"constraints\":[{\"divides\":{\"d\":{\"var\":{\"v\":\"K\"}},\"k\":128}},{\"divides\":{\"d\":{\"var\":{\"v\":\"N\"}},\"k\":16}}],\"ins\":[{\"align\":16,\"dtype\":\"fp8e4m3\",\"layout\":\"rowMajor\",\"mem\":\"global\",\"shape\":[{\"var\":{\"v\":\"M\"}},{\"var\":{\"v\":\"K\"}}]},{\"align\":16,\"dtype\":\"fp8e4m3\",\"layout\":\"colMajor\",\"mem\":\"global\",\"shape\":[{\"var\":{\"v\":\"K\"}},{\"var\":{\"v\":\"N\"}}]}],\"outs\":[{\"align\":16,\"dtype\":\"bf16\",\"layout\":\"rowMajor\",\"mem\":\"global\",\"shape\":[{\"var\":{\"v\":\"M\"}},{\"var\":{\"v\":\"N\"}}]}],\"scalars\":[[\"scaleA\",\"f32\"],[\"scaleB\",\"f32\"]],\"vars\":[\"M\",\"N\",\"K\"]}","source":"7df9ea9e8f24b3bd7df9ea9e8f24b3bd7df9ea9e8f24b3bd7df9ea9e8f24b3bd","variant":"wgmma-128x256x128-e4m3"}]}
(exit 0)
```

## rows --eq on the canonical binding TEXT — split at the first '=', so the value may contain '='

```console
$ kernels rows bench --eq binding=K=4096,M=4096,N=4096
{"count":7,"ok":true,"rows":[{"binding":"K=4096,M=4096,N=4096","bwGBs":585,"driver":"550.90","host":"h100-node-01","id":1,"iters":100,"kernel":1,"latency":172,"measuredAt":1756000000,"occupancy":500,"precision":"bf16","sku":"h100Sxm","tflops":799000,"toolchain":"cuda-12.6","warmup":10},{"binding":"K=4096,M=4096,N=4096","bwGBs":508,"driver":"560.35","host":"h100-node-01","id":2,"iters":100,"kernel":1,"latency":198,"measuredAt":1756500000,"occupancy":500,"precision":"bf16","sku":"h100Sxm","tflops":694000,"toolchain":"cuda-12.8","warmup":10},{"binding":"K=4096,M=4096,N=4096","bwGBs":399,"driver":"550.90","host":"h100-node-01","id":5,"iters":100,"kernel":2,"latency":168,"measuredAt":1756000000,"occupancy":500,"precision":"bf16","sku":"h100Sxm","tflops":818000,"toolchain":"cuda-12.6","warmup":10},{"binding":"K=4096,M=4096,N=4096","bwGBs":426,"driver":"550.90","host":"h100-node-01","id":7,"iters":100,"kernel":5,"latency":236,"measuredAt":1756000000,"occupancy":333,"precision":"bf16","sku":"h100Sxm","tflops":582000,"toolchain":"cuda-12.6","warmup":10},{"binding":"K=4096,M=4096,N=4096","bwGBs":671,"driver":"6.2.0","host":"mi300x-node-01","id":14,"iters":100,"kernel":3,"latency":150,"measuredAt":1756000000,"occupancy":500,"precision":"bf16","sku":"mi300x","tflops":916000,"toolchain":"rocm-6.2","warmup":10},{"binding":"K=4096,M=4096,N=4096","bwGBs":589,"driver":"6.3.0","host":"mi300x-node-01","id":15,"iters":100,"kernel":3,"latency":171,"measuredAt":1756500000,"occupancy":500,"precision":"bf16","sku":"mi300x","tflops":804000,"toolchain":"rocm-6.3","warmup":10},{"binding":"K=4096,M=4096,N=4096","bwGBs":430,"driver":"6.2.0","host":"mi300x-node-01","id":17,"iters":100,"kernel":4,"latency":156,"measuredAt":1756000000,"occupancy":500,"precision":"bf16","sku":"mi300x","tflops":881000,"toolchain":"rocm-6.2","warmup":10}]}
(exit 0)
```

## …and --eq goes through the column's codec like every other boundary, so the user-order spelling is canonicalized and matches the same rows

```console
$ kernels rows bench --eq binding=M=4096,N=4096,K=4096
{"count":7,"ok":true,"rows":[{"binding":"K=4096,M=4096,N=4096","bwGBs":585,"driver":"550.90","host":"h100-node-01","id":1,"iters":100,"kernel":1,"latency":172,"measuredAt":1756000000,"occupancy":500,"precision":"bf16","sku":"h100Sxm","tflops":799000,"toolchain":"cuda-12.6","warmup":10},{"binding":"K=4096,M=4096,N=4096","bwGBs":508,"driver":"560.35","host":"h100-node-01","id":2,"iters":100,"kernel":1,"latency":198,"measuredAt":1756500000,"occupancy":500,"precision":"bf16","sku":"h100Sxm","tflops":694000,"toolchain":"cuda-12.8","warmup":10},{"binding":"K=4096,M=4096,N=4096","bwGBs":399,"driver":"550.90","host":"h100-node-01","id":5,"iters":100,"kernel":2,"latency":168,"measuredAt":1756000000,"occupancy":500,"precision":"bf16","sku":"h100Sxm","tflops":818000,"toolchain":"cuda-12.6","warmup":10},{"binding":"K=4096,M=4096,N=4096","bwGBs":426,"driver":"550.90","host":"h100-node-01","id":7,"iters":100,"kernel":5,"latency":236,"measuredAt":1756000000,"occupancy":333,"precision":"bf16","sku":"h100Sxm","tflops":582000,"toolchain":"cuda-12.6","warmup":10},{"binding":"K=4096,M=4096,N=4096","bwGBs":671,"driver":"6.2.0","host":"mi300x-node-01","id":14,"iters":100,"kernel":3,"latency":150,"measuredAt":1756000000,"occupancy":500,"precision":"bf16","sku":"mi300x","tflops":916000,"toolchain":"rocm-6.2","warmup":10},{"binding":"K=4096,M=4096,N=4096","bwGBs":589,"driver":"6.3.0","host":"mi300x-node-01","id":15,"iters":100,"kernel":3,"latency":171,"measuredAt":1756500000,"occupancy":500,"precision":"bf16","sku":"mi300x","tflops":804000,"toolchain":"rocm-6.3","warmup":10},{"binding":"K=4096,M=4096,N=4096","bwGBs":430,"driver":"6.2.0","host":"mi300x-node-01","id":17,"iters":100,"kernel":4,"latency":156,"measuredAt":1756000000,"occupancy":500,"precision":"bf16","sku":"mi300x","tflops":881000,"toolchain":"rocm-6.2","warmup":10}]}
(exit 0)
```

## closed world refuses an unknown dtype (exit 2)

```console
$ kernels rows kernel --eq inDtype0=fp6
{"code":"decode","message":"kernel.inDtype0: \"fp6\" is not in the closed world #[f64, f32, tf32, bf16, f16, fp8e4m3, fp8e5m2, fp4e2m1, int8, int4, int32, uint8, bool]","ok":false}
(exit 2)
```

## a malformed signature (K used, not declared) is refused at insert through KernelSig.make (exit 2)

```console
$ kernels insert kernel '{"name":"bad-sig","op":"gemm","lang":"cuda","variant":"x","sig":"{\"vars\":[\"M\"],\"ins\":[{\"align\":16,\"dtype\":\"bf16\",\"layout\":\"rowMajor\",\"mem\":\"global\",\"shape\":[{\"var\":{\"v\":\"M\"}},{\"var\":{\"v\":\"K\"}}]}],\"outs\":[{\"align\":16,\"dtype\":\"bf16\",\"layout\":\"rowMajor\",\"mem\":\"global\",\"shape\":[{\"var\":{\"v\":\"M\"}}]}],\"scalars\":[],\"constraints\":[]}","minArch":"sm90","maxArch":null,"launch":"{\"block\":256,\"smemBytes\":0,\"stages\":1}","deterministic":true,"accum":"f32","fuses":"","source":"0000000000000000000000000000000000000000000000000000000000000000","license":"mit","inDtype0":"bf16","outDtype0":"bf16","rank0":2}'
{"code":"decode","message":"kernel.sig: shape variable K is used but not declared in vars","ok":false}
(exit 2)
```

## search columns that contradict sig are ignored by the CLI insert — they are derived, recomputed from sig (LEP-0003 B3 closes study §3.2)

```console
$ kernels insert kernel '{"name":"lying-columns","op":"gemm","lang":"cuda","variant":"x","sig":"{\"vars\":[\"M\"],\"ins\":[{\"align\":16,\"dtype\":\"bf16\",\"layout\":\"rowMajor\",\"mem\":\"global\",\"shape\":[{\"var\":{\"v\":\"M\"}}]}],\"outs\":[{\"align\":16,\"dtype\":\"bf16\",\"layout\":\"rowMajor\",\"mem\":\"global\",\"shape\":[{\"var\":{\"v\":\"M\"}}]}],\"scalars\":[],\"constraints\":[]}","minArch":"sm90","maxArch":null,"launch":"{\"block\":256,\"smemBytes\":0,\"stages\":1}","deterministic":true,"accum":"f32","fuses":"","source":"0000000000000000000000000000000000000000000000000000000000000000","license":"mit","inDtype0":"f64","outDtype0":"f64","rank0":7}'
{"ok":true,"row":{"accum":"f32","deterministic":1,"fuses":"","id":15,"inDtype0":"bf16","lang":"cuda","launch":"{\"block\":256,\"smemBytes\":0,\"stages\":1}","license":"mit","maxArch":null,"minArch":"sm90","name":"lying-columns","op":"gemm","outDtype0":"bf16","rank0":1,"sig":"{\"constraints\":[],\"ins\":[{\"align\":16,\"dtype\":\"bf16\",\"layout\":\"rowMajor\",\"mem\":\"global\",\"shape\":[{\"var\":{\"v\":\"M\"}}]}],\"outs\":[{\"align\":16,\"dtype\":\"bf16\",\"layout\":\"rowMajor\",\"mem\":\"global\",\"shape\":[{\"var\":{\"v\":\"M\"}}]}],\"scalars\":[],\"vars\":[\"M\"]}","source":"0000000000000000000000000000000000000000000000000000000000000000","variant":"x"}}
(exit 0)
```

## …and kernelInfo shows the recomputed values; the Lean-side check is gone

```console
$ kernels query kernelInfo lying-columns
{"ok":true,"result":{"fuses":"","id":15,"inDtype0":"bf16","launch":{"block":256,"smemBytes":0,"stages":1},"name":"lying-columns","op":"gemm","outDtype0":"bf16","rank0":1,"sig":"∀ M, (bf16[M]) → (bf16[M])"}}
(exit 0)
```

## a raw-SQL write to a derived column is caught on the next read, by name (exit 2) — then put back

```console
$ sqlite3 data/kernels.sqlite "UPDATE kernel SET \"inDtype0\"='f64' WHERE name='lying-columns'"
(exit 0)
$ kernels rows kernel --eq name=lying-columns
{"code":"decode","message":"kernel.inDtype0: derived column disagrees with its source","ok":false}
(exit 2)
$ sqlite3 data/kernels.sqlite "UPDATE kernel SET \"inDtype0\"='bf16' WHERE name='lying-columns'"
(exit 0)
```

## query log — the reified plans of regressions, fastest, candidates (newest first; candidates is the Arch.supports case split with its guards folded)

```console
$ kernels log 3
{"count":3,"entries":[{"at":1788324877,"detail":"kernel | pushed: t0.\"name\" IS ?, residual conjuncts: 0","error":null,"id":60,"ok":true,"rows":1,"verb":"select"},{"at":1788324876,"detail":"kernel","error":null,"id":59,"ok":true,"rows":1,"verb":"insert"},{"at":1788324876,"detail":"bench×kernel | pushed: (t0.\"kernel\" IS t1.\"id\" AND t0.\"sku\" IS ?), residual conjuncts: 0","error":null,"id":58,"ok":true,"rows":6,"verb":"select"}],"ok":true}
(exit 0)
```

## migrate status

```console
$ kernels migrate status
{"applied":[],"fingerprint":"535084016606190269","notes":["schema already up to date"],"ok":true}
(exit 0)
```

## version

```console
$ kernels version
{"code_fingerprint":"535084016606190269","in_sync":true,"instance_fingerprint":"535084016606190269","ok":true,"schema_version":1}
(exit 0)
```
