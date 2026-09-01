import Kernels.Sig
import GpuMarket.Enums

/-! # The open world

Four tables plus one child table. `Kernel` carries the study's nested
values three different ways, deliberately, so the base can report on each:

- `sig : KernelSig` — one opaque JSON TEXT column; SQL can test it only
  for equality.
- `launch : LaunchConfig` — three scalars, *also* stored as one JSON
  column (the inline-flatten candidate, kept nested to show what that
  costs: `smemBytes ≤ 100000` is residual).
- `deterministic`/`accum` — `NumericProps` inline-flattened by hand into
  sibling columns; both push.
- `fuses : FusedOps` — a set of a closed world as canonical TEXT (the
  `EnumSet` gap).

The search columns `inDtype0`/`outDtype0`/`rank0` are copies of facts
inside `sig`, filled by `Kernel.make` so the common filters push. The
invariant that they agree with `sig` is cross-field: it is checked on the
`Kernel.make` path only, and **not** on `update` or on a CLI `insert`
whose JSON supplies the columns directly — `deriving LeanDb.Entity`
refuses proof fields today (study §3.2). -/

namespace Kernels

open LeanDb

/-- Launch shape: threads per block, dynamic shared memory in bytes,
    pipeline stages. Small and fixed — the study's inline-flatten
    candidate — stored here as one JSON column on purpose. -/
structure LaunchConfig where
  block     : Nat
  smemBytes : Nat
  stages    : Nat := 1
  deriving Repr, DecidableEq, Lean.ToJson

def LaunchConfig.make (block smemBytes : Nat) (stages : Nat := 1) : Except String LaunchConfig := do
  if block == 0 || block > 1024 || block % 32 != 0 then
    throw s!"block must be a positive multiple of 32 up to 1024, got {block}"
  if smemBytes > 232448 then throw s!"dynamic shared memory above 227 KiB ({smemBytes}) fits no supported arch"
  if stages == 0 then throw "stages must be positive"
  return { block, smemBytes, stages }

instance : Lean.FromJson LaunchConfig where
  fromJson? j := do
    LaunchConfig.make (← j.getObjValAs? Nat "block") (← j.getObjValAs? Nat "smemBytes")
      (← j.getObjValAs? Nat "stages")

instance : ColCodec LaunchConfig :=
  ColCodec.via (fun c => (Lean.toJson c).compress)
               (fun t => Lean.Json.parse t >>= Lean.fromJson?)

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
  fuses         : FusedOps
  source        : SourceHash
  license       : License
  /-- Search column: `sig.ins[0].dtype`. -/
  inDtype0      : DType
  /-- Search column: `sig.outs[0].dtype`. -/
  outDtype0     : DType
  /-- Search column: `sig.ins[0].rank`. -/
  rank0         : Nat
  deriving Repr, LeanDb.Entity

/-- The only path that keeps the search columns honest. Also refuses a
    `maxArch` from another vendor or below `minArch`. -/
def Kernel.make (name : KernelName) (op : OpKind) (lang : Lang) (variant : Variant)
    (sig : KernelSig) (minArch : Arch) (maxArch : Option Arch) (launch : LaunchConfig)
    (deterministic : Bool) (accum : DType) (fuses : FusedOps) (source : SourceHash)
    (license : License) : Except String Kernel := do
  if let some mx := maxArch then
    unless mx.supports minArch do
      throw s!"maxArch {LeanDb.ClosedEnum.encodeName mx} does not support minArch {LeanDb.ClosedEnum.encodeName minArch}"
  let some i0 := sig.ins[0]? | throw "signature has no inputs"
  let some o0 := sig.outs[0]? | throw "signature has no outputs"
  return { name, op, lang, variant, sig, minArch, maxArch, launch, deterministic, accum,
           fuses, source, license,
           inDtype0 := i0.dtype, outDtype0 := o0.dtype, rank0 := i0.rank }

/-- Do the search columns still describe `sig`? True for every row that
    came through `Kernel.make`; a CLI `update` of `sig` alone can make it
    false, which is the cross-field gap. -/
def Kernel.searchColumnsAgree (k : Kernel) : Bool :=
  match k.sig.ins[0]?, k.sig.outs[0]? with
  | some i0, some o0 => k.inDtype0 == i0.dtype && k.outDtype0 == o0.dtype && k.rank0 == i0.rank
  | _, _ => false

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
