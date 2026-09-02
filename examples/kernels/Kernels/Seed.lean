import Kernels.Queries

/-! # Seed data

Fourteen kernels, benches on H100 SXM and MI300X, one stored program.
Every value passes through a smart constructor (`seedM` lifts a failed
one into a typed `.decode` error). Numbers are **illustrative** — the
right order of magnitude for the shapes named, not measurements.

Planted for the tests: `gemm-cutlass-sm90-bf16` and `gemm-ck-gfx942-bf16`
each have a later 4096³ sample more than 10% slower than an earlier one
(`regressions`), and the 8192³ resample of the CUTLASS kernel is within
10% (not a regression). -/

namespace Kernels

open LeanDb
open GpuMarket (Gpu)

def seedM (context : String) (r : Except String α) : DbM α :=
  match r with
  | .ok a => pure a
  | .error msg => throw (.decode "seed" context msg)

/-- `"M,K"` → `[var M, var K]`; a numeric token is a literal. -/
private def ty (dt : DType) (shape : String) (layout : Layout := .rowMajor) :
    Except String TensorTy := do
  let dims ← (shape.splitOn ",").mapM fun tok =>
    match tok.toNat? with
    | some n => pure (Dim.lit n)
    | none => Dim.var <$> DimVar.make tok
  return { dtype := dt, shape := dims, layout }

/-- A variable reference inside a constraint. Bypasses `DimVar.make` for
    a literal name; `KernelSig.make` still refuses it unless declared. -/
private def V (s : String) : Dim := .var ⟨s⟩

private def sig (vars : String) (ins outs : List (Except String TensorTy))
    (constraints : List DimConstraint := []) (scalars : List (String × DType) := []) :
    Except String KernelSig := do
  let vars ← (vars.splitOn " ").mapM DimVar.make
  let scalars ← scalars.mapM fun (n, dt) => (·, dt) <$> ScalarName.make n
  KernelSig.make vars (← ins.mapM id) (← outs.mapM id) scalars constraints

/-- A stand-in for sha256 of source we do not have: 64 hex chars derived
    from the name. -/
private def fakeHash (name : String) : String :=
  let h := String.ofList (Nat.toDigits 16 (hash name).toNat)
  let h := "".pushn '0' (16 - min 16 h.length) ++ h
  h ++ h ++ h ++ h

private def kernel! (name : String) (op : OpKind) (lang : Lang) (variant : String)
    (s : Except String KernelSig) (minArch : Arch) (maxArch : Option Arch := none)
    (block : Nat := 256) (smem : Nat := 0) (stages : Nat := 1)
    (deterministic : Bool := true) (accum : DType := .f32) (fuses : List OpKind := [])
    (license : License := .bsd3) : DbM (Stored Kernel) := do
  let k ← seedM name do
    Kernel.make (← KernelName.make name) op lang (← Variant.make variant) (← s)
      minArch maxArch (← LaunchConfig.make block smem stages) { deterministic, accum }
      (EnumSet.ofList fuses) (← SourceHash.make (fakeHash name)) license
  insert Kernel k

private def bench! (k : Stored Kernel) (sku : Gpu) (binding : String) (prec : DType)
    (us tflopsMilli bw occ : Nat) (driver toolchain host : String) (at' : Nat) : DbM Unit := do
  let m ← seedM s!"bench {k.val.name.raw}" do
    return { kernel := k.ref, sku, binding := ← DimBinding.decode binding, precision := prec
             latency := ← Micros.make us, tflops := ⟨tflopsMilli⟩, bwGBs := bw
             occupancy := ← Permille.make occ
             driver := ← DriverVersion.make driver, toolchain := ← ToolchainVersion.make toolchain
             host := ← HostId.make host, measuredAt := ⟨at'⟩ : Bench }
  discard <| insert Bench m

/-- The bindings the benches are taken at. -/
def g1 : String := "M=4096,N=4096,K=4096"
def g2 : String := "M=8192,N=8192,K=8192"
def g3 : String := "M=1024,N=1024,K=1024"
def attn : String := "B=8,D=128,H=32,S=4096"
def norm : String := "H=4096,S=4096"

def seed : DbM Unit := do
  -- GEMM: ∀ M N K, bf16[M,K] → bf16[K,N] → C[M,N], K % 64 = 0
  let gemmSig (outDt : DType) (kDiv : Nat) := sig "M N K"
    [ty .bf16 "M,K", ty .bf16 "K,N" .colMajor] [ty outDt "M,N"]
    [.divides kDiv (V "K"), .divides 8 (V "N")]
    [("alpha", .f32), ("beta", .f32)]
  let cutlassBf16 ← kernel! "gemm-cutlass-sm90-bf16" .gemm .cutlass "wgmma-128x256x64"
    (gemmSig .f32 64) .sm90 (block := 384) (smem := 196608) (stages := 4)
  let cutlassBf16Out ← kernel! "gemm-cutlass-sm90-bf16-bf16out" .gemm .cutlass "wgmma-128x256x64-castout"
    (gemmSig .bf16 64) .sm90 (block := 384) (smem := 196608) (stages := 4)
  let ckBf16 ← kernel! "gemm-ck-gfx942-bf16" .gemm .ck "xdl-256x256x64"
    (gemmSig .f32 64) .gfx942 (block := 256) (smem := 65536) (stages := 2) (license := .mit)
  let ckSilu ← kernel! "gemm-ck-gfx942-bf16-silu" .gemm .ck "xdl-256x256x64-silu-epilogue"
    (gemmSig .bf16 64) .gfx942 (block := 256) (smem := 65536) (stages := 2)
    (fuses := [.silu]) (license := .mit)
  let tritonBf16 ← kernel! "gemm-triton-sm80-bf16" .gemm .triton "autotuned-128x128x32"
    (gemmSig .bf16 32) .sm80 (block := 128) (smem := 49152) (stages := 3) (license := .mit)
  discard <| kernel! "gemm-cutlass-sm80-f16" .gemm .cutlass "mma-128x128x32"
    (sig "M N K" [ty .f16 "M,K", ty .f16 "K,N" .colMajor] [ty .f16 "M,N"] [.divides 32 (V "K")])
    .sm80 (maxArch := some .sm89) (block := 256) (smem := 49152) (stages := 3)
  let cutlassFp8 ← kernel! "gemm-cutlass-sm90-fp8" .gemm .cutlass "wgmma-128x256x128-e4m3"
    (sig "M N K" [ty .fp8e4m3 "M,K", ty .fp8e4m3 "K,N" .colMajor] [ty .bf16 "M,N"]
      [.divides 128 (V "K"), .divides 16 (V "N")] [("scaleA", .f32), ("scaleB", .f32)])
    .sm90 (block := 384) (smem := 232448) (stages := 4)
  -- flash attention: ∀ B H S D, q k v : bf16[B,H,S,D] → bf16[B,H,S,D], D % 8 = 0, D ≤ 256
  let attnSig := sig "B H S D"
    [ty .bf16 "B,H,S,D", ty .bf16 "B,H,S,D", ty .bf16 "B,H,S,D"] [ty .bf16 "B,H,S,D"]
    [.divides 8 (V "D"), .le (V "D") (.lit 256)] [("causal", .bool), ("scale", .f32)]
  let flashSm90 ← kernel! "flash-attn-sm90-bf16" .flashAttention .cuda "flash-v3-causal"
    attnSig .sm90 (block := 384) (smem := 196608) (stages := 2) (deterministic := false)
  let flashCk ← kernel! "flash-attn-ck-gfx942-bf16" .flashAttention .ck "fmha-fwd-causal"
    attnSig .gfx942 (block := 256) (smem := 65536) (deterministic := false) (license := .mit)
  -- normalization / elementwise: ∀ S H
  let rmsSig := sig "S H" [ty .bf16 "S,H", ty .bf16 "H"] [ty .bf16 "S,H"]
    [.divides 8 (V "H")] [("eps", .f32)]
  let rmsTriton ← kernel! "rmsnorm-triton-sm80-bf16" .rmsNorm .triton "one-pass"
    rmsSig .sm80 (block := 1024) (license := .mit)
  let rmsHip ← kernel! "rmsnorm-hip-gfx942-bf16" .rmsNorm .hip "one-pass-wave64"
    rmsSig .gfx942 (block := 256) (license := .mit)
  let rope ← kernel! "rope-cuda-sm80-bf16" .rope .cuda "interleaved"
    -- the cos/sin cache is f32[S, H/2]: an affine `Dim`, spelled directly
    (sig "S H" [ty .bf16 "S,H", pure { dtype := .f32, shape := [V "S", .div (V "H") 2] }]
      [ty .bf16 "S,H"] [.divides 2 (V "H")])
    .sm80 (block := 256)
  let softmax ← kernel! "softmax-cuda-sm80-f32" .softmax .cuda "warp-per-row"
    (sig "M N" [ty .f32 "M,N"] [ty .f32 "M,N"]) .sm80 (block := 128)
  let gemv ← kernel! "gemv-cuda-sm80-bf16" .gemv .cuda "split-k-8"
    (sig "M K" [ty .bf16 "M,K", ty .bf16 "K"] [ty .f32 "M"] [.divides 8 (V "K")])
    .sm80 (block := 256) (deterministic := false)

  -- H100 SXM (sm90). Drivers/toolchains illustrative.
  let h := "h100-node-01"
  bench! cutlassBf16 .h100Sxm g1 .bf16 172 799000 585 500 "550.90" "cuda-12.6" h 1756000000
  bench! cutlassBf16 .h100Sxm g1 .bf16 198 694000 508 500 "560.35" "cuda-12.8" h 1756500000  -- planted regression
  bench! cutlassBf16 .h100Sxm g2 .bf16 1290 852000 625 500 "550.90" "cuda-12.6" h 1756000000
  bench! cutlassBf16 .h100Sxm g2 .bf16 1310 839000 615 500 "560.35" "cuda-12.8" h 1756500000  -- within 10%
  bench! cutlassBf16Out .h100Sxm g1 .bf16 168 818000 399 500 "550.90" "cuda-12.6" h 1756000000
  bench! cutlassBf16Out .h100Sxm g3 .bf16 5 429000 1258 250 "550.90" "cuda-12.6" h 1756000000
  bench! tritonBf16 .h100Sxm g1 .bf16 236 582000 426 333 "550.90" "cuda-12.6" h 1756000000
  bench! cutlassFp8 .h100Sxm g2 .fp8e4m3 808 1361000 249 500 "550.90" "cuda-12.6" h 1756000000
  bench! flashSm90 .h100Sxm attn .bf16 3400 647000 1183 500 "550.90" "cuda-12.6" h 1756000000
  bench! rmsTriton .h100Sxm norm .bf16 31 1600 2165 800 "550.90" "cuda-12.6" h 1756000000
  bench! rope .h100Sxm norm .bf16 28 1200 2400 800 "550.90" "cuda-12.6" h 1756000000
  bench! softmax .h100Sxm "M=4096,N=4096" .f32 66 1000 2034 750 "550.90" "cuda-12.6" h 1756000000
  bench! gemv .h100Sxm "K=4096,M=4096" .bf16 14 2400 2400 600 "550.90" "cuda-12.6" h 1756000000
  -- MI300X (gfx942)
  let a := "mi300x-node-01"
  bench! ckBf16 .mi300x g1 .bf16 150 916000 671 500 "6.2.0" "rocm-6.2" a 1756000000
  bench! ckBf16 .mi300x g1 .bf16 171 804000 589 500 "6.3.0" "rocm-6.3" a 1756500000   -- planted regression
  bench! ckBf16 .mi300x g2 .bf16 1120 981000 720 500 "6.2.0" "rocm-6.2" a 1756000000
  bench! ckSilu .mi300x g1 .bf16 156 881000 430 500 "6.2.0" "rocm-6.2" a 1756000000
  bench! flashCk .mi300x attn .bf16 4100 536000 981 500 "6.2.0" "rocm-6.2" a 1756000000
  bench! rmsHip .mi300x norm .bf16 24 2100 2796 850 "6.2.0" "rocm-6.2" a 1756000000

  -- one stored program: GEMM (bf16 out) → RMSNorm, a chain with one
  -- program input (the norm weight) beside the upstream edge
  let prog ← insert Program
    { name := ← seedM "program" (ProgramName.make "gemm-rmsnorm-4096"), sku := .h100Sxm
      binding := ← seedM "binding" (DimBinding.decode g1) }
  let n0 ← insert ProgramNode { program := prog.ref, position := 0, kernel := cutlassBf16Out.ref }
  let n1 ← insert ProgramNode { program := prog.ref, position := 1, kernel := rmsTriton.ref }
  discard <| insert ProgramEdge
    { program := prog.ref, toNode := n1.ref, toInput := 0, fromNode := n0.ref, fromOutput := 0 }

end Kernels
