import Kernels.Sig
import GpuMarket.Enums

/-! # The open world

Four tables plus one child table. `Kernel` carries the study's nested
values three different ways, deliberately, so the base can report on each:

- `sig : KernelSig` — one JSON TEXT column with a declared shape
  (`ColCodec.json`, LEP-0003 B2); SQL can test it only for equality.
- `launch : LaunchConfig` — three scalars, *also* stored as one JSON
  column (the inline-flatten candidate, kept nested to show what that
  costs: `smemBytes ≤ 100000` is residual).
- `deterministic`/`accum` — `NumericProps` inline-flattened by hand into
  sibling columns; both push.
- `fuses : EnumSet OpKind` — a set of a closed world as an INTEGER
  bitmask (LEP-0003 A): membership pushes as a bit test, the DDL CHECK
  bounds the mask, row JSON shows the names.

The search columns `inDtype0`/`outDtype0`/`rank0` are **derived** (LEP-0003
B3): their defaults are `derived <fact of sig>`, so `Entity.encode`
recomputes them from `sig` on every write (a supplied value is ignored),
`Entity.decode` checks the stored value against `sig` on every read and
fails with `decode` naming the column if they disagree, and JSON input may
omit them. The invariant that they agree with `sig` is the engine's,
on both sides of the boundary — not `Kernel.make`'s. -/

namespace Kernels

open LeanDb

/-- Launch shape: threads per block, dynamic shared memory in bytes,
    pipeline stages. Small and fixed — the study's inline-flatten
    candidate — stored here as one JSON column on purpose. -/
structure LaunchConfig where
  block     : Nat
  smemBytes : Nat
  stages    : Nat := 1
  deriving Repr, DecidableEq, LeanDb.DbJson

def LaunchConfig.make (block smemBytes : Nat) (stages : Nat := 1) : Except String LaunchConfig := do
  if block == 0 || block > 1024 || block % 32 != 0 then
    throw s!"block must be a positive multiple of 32 up to 1024, got {block}"
  if smemBytes > 232448 then throw s!"dynamic shared memory above 227 KiB ({smemBytes}) fits no supported arch"
  if stages == 0 then throw "stages must be positive"
  return { block, smemBytes, stages }

/-- Validated through `make` at the column boundary; JSON may omit
    `stages` (its default is 1). -/
instance : ColCodec LaunchConfig :=
  ColCodec.json LaunchConfig fun c => LaunchConfig.make c.block c.smemBytes c.stages

structure Kernel where
  name          : KernelName
  op            : OpKind
  lang          : Lang
  variant       : Variant
  sig           : KernelSig
  minArch       : Arch
  maxArch       : Option Arch
  launch        : LaunchConfig
  /-- `NumericProps`, flattened: bitwise-reproducible across runs? -/
  deterministic : Bool
  /-- `NumericProps`, flattened: accumulation dtype. -/
  accum         : DType
  fuses         : EnumSet OpKind
  source        : SourceHash
  license       : License
  /-- Derived search column: `sig.ins[0].dtype`, recomputed on write,
      checked on read. -/
  inDtype0      : DType := derived sig.inDtype0
  /-- Derived search column: `sig.outs[0].dtype`. -/
  outDtype0     : DType := derived sig.outDtype0
  /-- Derived search column: `sig.ins[0].rank`. -/
  rank0         : Nat := derived sig.rank0
  deriving Repr, LeanDb.Entity

/-- Refuses a `maxArch` from another vendor or below `minArch`. The
    derived columns need no help: their defaults compute them. -/
def Kernel.make (name : KernelName) (op : OpKind) (lang : Lang) (variant : Variant)
    (sig : KernelSig) (minArch : Arch) (maxArch : Option Arch) (launch : LaunchConfig)
    (deterministic : Bool) (accum : DType) (fuses : EnumSet OpKind) (source : SourceHash)
    (license : License) : Except String Kernel := do
  if let some mx := maxArch then
    unless mx.supports minArch do
      throw s!"maxArch {LeanDb.ClosedEnum.encodeName mx} does not support minArch {LeanDb.ClosedEnum.encodeName minArch}"
  return { name, op, lang, variant, sig, minArch, maxArch, launch, deterministic, accum,
           fuses, source, license }

/-- One measurement. `sku` is gpumarket's closed world: the CHECK over its
    vocabulary and `Gpu.spec` come with the type. -/
structure Bench where
  kernel     : Ref Kernel
  sku        : GpuMarket.Gpu
  binding    : DimBinding
  precision  : DType
  latency    : Micros
  tflops     : MilliTflops
  bwGBs      : Nat
  occupancy  : Permille
  warmup     : Nat := 10
  iters      : Nat := 100
  driver     : DriverVersion
  toolchain  : ToolchainVersion
  host       : HostId
  measuredAt : Timestamp
  deriving Repr, LeanDb.Entity

/-- A stored program: the DAG relationally, re-typed on read by
    `Prog.ofRows`. -/
structure Program where
  name    : ProgramName
  sku     : GpuMarket.Gpu
  binding : DimBinding
  deriving Repr, LeanDb.Entity

structure ProgramNode where
  program  : Ref Program
  position : Nat
  kernel   : Ref Kernel
  deriving Repr, LeanDb.Entity

/-- The study's `ProgramNode.feeds : List (Option (Nat × Nat))`, as a
    child table: output `fromOutput` of `fromNode` feeds input `toInput`
    of `toNode`. An input with no edge is a program input. -/
structure ProgramEdge where
  program    : Ref Program
  toNode     : Ref ProgramNode
  toInput    : Nat
  fromNode   : Ref ProgramNode
  fromOutput : Nat
  deriving Repr, LeanDb.Entity

/-- FK-dependency order. -/
def schema : List TableSpec :=
  [Entity.spec Kernel, Entity.spec Bench, Entity.spec Program,
   Entity.spec ProgramNode, Entity.spec ProgramEdge]

end Kernels
