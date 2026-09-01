import LeanDb
import GpuMarket.Arch

/-! # The closed worlds

Element types, op kinds, languages, target architectures, memory spaces
and licenses are *vocabulary*: TEXT with a CHECK at rest, an inductive in
code. Facts about them are total functions. The SKU vocabulary is not
declared here at all — it is gpumarket's `Gpu`, imported as a Lake
dependency (`Arch.ofGpu` is the one total function that bridges the two
bases' worlds, and adding a SKU to gpumarket refuses to compile this base
until it answers).

`DType` and `MemSpace` also derive JSON instances because they appear
*inside* the opaque `KernelSig` column, where they are JSON strings, not
enum columns — the same value, two encodings (see the base README). -/

namespace Kernels

/-- Element types. `bits` is storage width (tf32 lives in 32 bits). -/
inductive DType where
  | f64 | f32 | tf32 | bf16 | f16 | fp8e4m3 | fp8e5m2 | fp4e2m1
  | int8 | int4 | int32 | uint8 | bool
  deriving Repr, DecidableEq, Ord, LeanDb.ClosedEnum, Lean.ToJson, Lean.FromJson

def DType.bits : DType → Nat
  | .f64 => 64 | .f32 => 32 | .tf32 => 32 | .bf16 => 16 | .f16 => 16
  | .fp8e4m3 => 8 | .fp8e5m2 => 8 | .fp4e2m1 => 4
  | .int8 => 8 | .int4 => 4 | .int32 => 32 | .uint8 => 8 | .bool => 8

def DType.isFloat : DType → Bool
  | .f64 | .f32 | .tf32 | .bf16 | .f16 | .fp8e4m3 | .fp8e5m2 | .fp4e2m1 => true
  | .int8 | .int4 | .int32 | .uint8 | .bool => false

/-- The gpumarket datasheet precision a kernel's compute dtype is rated
    at — the roofline's peak. `none`: no dense-throughput figure exists
    for it (integer scalar types, bool). -/
def DType.precision : DType → Option GpuMarket.Precision
  | .f64 => some .fp64 | .f32 => some .fp32 | .tf32 => some .tf32
  | .bf16 | .f16 => some .bf16
  | .fp8e4m3 | .fp8e5m2 => some .fp8 | .fp4e2m1 => some .fp4
  | .int8 => some .int8
  | .int4 | .int32 | .uint8 | .bool => none

inductive OpKind where
  | gemm | gemv | batchedGemm | attention | flashAttention | pagedAttention
  | softmax | layerNorm | rmsNorm | rope | silu | gelu | reduce | scan
  | embedding | allReduce | allGather | conv2d | topK | sort
  deriving Repr, DecidableEq, Ord, LeanDb.ClosedEnum

inductive Lang where
  | cuda | hip | triton | cutlass | ck | ptx | mlir
  deriving Repr, DecidableEq, Ord, LeanDb.ClosedEnum

/-- Target architectures. Ordered by capability *within a vendor*; the
    order across vendors is meaningless, which is why this must not be
    `SqlOrd` and why `supports` is a total function, not `≤`. -/
inductive Arch where
  | sm80 | sm86 | sm89 | sm90 | sm100 | gfx90a | gfx942 | gfx950
  deriving Repr, DecidableEq, Ord, LeanDb.ClosedEnum

def Arch.vendor : Arch → GpuMarket.Vendor
  | .sm80 | .sm86 | .sm89 | .sm90 | .sm100 => .nvidia
  | .gfx90a | .gfx942 | .gfx950 => .amd

/-- Capability rank within a vendor (the number in the name). -/
def Arch.gen : Arch → Nat
  | .sm80 => 80 | .sm86 => 86 | .sm89 => 89 | .sm90 => 90 | .sm100 => 100
  | .gfx90a => 90 | .gfx942 => 94 | .gfx950 => 95

/-- Does silicon of `target` run a kernel built for `minimum`? Same
    vendor and at least as capable; cross-vendor is always false. Written
    as a conjunction of accessor comparisons: after the planner
    case-splits the `minArch` column each branch is a closed
    value-vs-value test on the captured `target`, folded at plan build.
    (A two-argument `match` on `target` first pushes too, now that the
    tactic splits captured closed-enum parameters — study §3.4.) -/
@[db] def Arch.supports (target minimum : Arch) : Bool :=
  target.vendor == minimum.vendor && minimum.gen ≤ target.gen

/-- The compute capability each gpumarket SKU presents. Total over
    gpumarket's world: a new SKU there is a compile error here. RTX 5090
    is sm120 in the field; it is folded into `sm100` because this base's
    kernels target the datacenter line. -/
def Arch.ofGpu : GpuMarket.Gpu → Arch
  | .h100Sxm | .h100Pcie | .h200 | .gh200 => .sm90
  | .b200 | .rtx5090 => .sm100
  | .a100Sxm80 | .a100Pcie40 => .sm80
  | .a10 => .sm86
  | .l40s | .l4 | .rtx4090 => .sm89
  | .mi300x | .mi325x => .gfx942

inductive MemSpace where
  | global | shared | register | constant
  deriving Repr, DecidableEq, Ord, LeanDb.ClosedEnum, Lean.ToJson, Lean.FromJson

inductive License where
  | mit | apache2 | bsd3 | proprietary
  deriving Repr, DecidableEq, Ord, LeanDb.ClosedEnum

end Kernels
