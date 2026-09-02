import Kernels.Sig
import GpuMarket.Enums

/-! # The open world

Five entities, seven tables. `Kernel` carries the study's nested values
four different ways, deliberately, so the base can report on each:

- `sig : KernelSig` — one JSON TEXT column with a declared shape
  (`ColCodec.json`, LEP-0003 B2); SQL can test it only for equality.
- `ins`/`outs : List KernelInput` — **child tables** `kernel_ins` and
  `kernel_outs` (LEP-0003 D): one row per tensor with `parent`,
  `position` and the record's columns (`dtype`, `rank`, `layoutKind`,
  `full`). The lists are part of the value — every read reattaches them,
  every write owns them, deleting a kernel cascades — and
  `k.val.ins.all (·.rank ≥ 3)` / `.any (·.layoutKind == .colMajor)` push
  as `NOT EXISTS`/`EXISTS` over `kernel_ins` (LEP-0004).
- `launch : LaunchConfig` and `numeric : NumericProps` — small fixed
  structures, **inline-flattened** by the derive (LEP-0003 C): one
  column per field (`launch_block`, `launch_smemBytes`, `launch_stages`,
  `numeric_deterministic`, `numeric_accum`), one symbol per column
  (`Kernel.Field.launch_smemBytes`), so every field pushes and migrations
  see each. Row JSON nests them back (`"launch": {…}`).
- `fuses : EnumSet OpKind` — a set of a closed world as an INTEGER
  bitmask (LEP-0003 A): membership pushes as a bit test, the DDL CHECK
  bounds the mask, row JSON shows the names.

The search columns `inDtype0`/`outDtype0`/`rank0` are **derived** (LEP-0003
B3) from the first child of `ins`/`outs`: `Entity.encode` recomputes them
on every write (a supplied value is ignored); on read the check happens
once the list is attached (`ChildLink.attach`), failing with `decode`
naming the column if the stored value disagrees; JSON input may omit
them. The invariant that they agree with the first input is the engine's,
on both sides of the boundary — not `Kernel.make`'s. -/

namespace Kernels

open LeanDb

/-- Launch shape: threads per block, dynamic shared memory in bytes,
    pipeline stages. Small and fixed — stored inline as three sibling
    columns of `kernel` (LEP-0003 C); `stages` has a column DEFAULT. -/
structure LaunchConfig where
  block     : Nat
  smemBytes : Nat
  stages    : Nat := 1
  deriving Repr, DecidableEq, Lean.ToJson, LeanDb.Inline

/-- The constructor the base uses: a block that is a positive multiple of
    32 up to 1024, shared memory that fits some supported arch, a
    positive stage count. (The column boundary checks each field's
    *type*; this whole-value check is the Lean side's.) -/
def LaunchConfig.make (block smemBytes : Nat) (stages : Nat := 1) : Except String LaunchConfig := do
  if block == 0 || block > 1024 || block % 32 != 0 then
    throw s!"block must be a positive multiple of 32 up to 1024, got {block}"
  if smemBytes > 232448 then throw s!"dynamic shared memory above 227 KiB ({smemBytes}) fits no supported arch"
  if stages == 0 then throw "stages must be positive"
  return { block, smemBytes, stages }

/-- Numeric properties: bitwise-reproducible across runs, and the
    accumulation dtype. Inline, like `LaunchConfig` — the two columns the
    base used to flatten by hand. -/
structure NumericProps where
  deterministic : Bool
  accum         : DType
  deriving Repr, DecidableEq, Lean.ToJson, LeanDb.Inline

structure Kernel where
  name          : KernelName
  op            : OpKind
  lang          : Lang
  variant       : Variant
  sig           : KernelSig
  /-- The inputs, as child rows of `kernel_ins` (LEP-0003 D). -/
  ins           : List KernelInput
  /-- The outputs, as child rows of `kernel_outs`. -/
  outs          : List KernelInput
  minArch       : Arch
  maxArch       : Option Arch
  launch        : LaunchConfig
  numeric       : NumericProps
  fuses         : EnumSet OpKind
  source        : SourceHash
  license       : License
  /-- Derived search column: `ins[0].dtype`, recomputed on write, checked
      on read once the list is attached. -/
  inDtype0      : DType := derived ((ins.head?.map (·.dtype)).getD .f32)
  /-- Derived search column: `outs[0].dtype`. -/
  outDtype0     : DType := derived ((outs.head?.map (·.dtype)).getD .f32)
  /-- Derived search column: `ins[0].rank`. -/
  rank0         : Nat := derived ((ins.head?.map (·.rank)).getD 0)
  deriving Repr, LeanDb.Entity

/-- The tensors back out of the child rows. -/
def Kernel.tensorIns (k : Kernel) : List TensorTy := k.ins.map (·.full)
def Kernel.tensorOuts (k : Kernel) : List TensorTy := k.outs.map (·.full)

/-- The whole signature, pretty-printed: `∀ M N K, (bf16[M,K], …) → (…)`. -/
def Kernel.describeSig (k : Kernel) : String := k.sig.describe k.tensorIns k.tensorOuts

/-- `KernelSig.instantiate` over the kernel's own tensors. -/
def Kernel.instantiate (k : Kernel) (b : DimBinding) : Except String (List TensorTy × List TensorTy) :=
  k.sig.instantiate k.tensorIns k.tensorOuts b

/-- `KernelSig.instantiates` over the kernel's own tensors — what
    `Prog.kernel`'s proof states. -/
def Kernel.instantiates (k : Kernel) (b : DimBinding) (ins outs : List TensorTy) : Bool :=
  k.sig.instantiates k.tensorIns k.tensorOuts b ins outs

/-- Refuses tensors that do not fit the signature (`KernelSig.checkTensors`)
    and a `maxArch` from another vendor or below `minArch`. The child rows
    are built through `KernelInput.ofTensorTy`; the derived columns need no
    help: their defaults compute them from the first child. -/
def Kernel.make (name : KernelName) (op : OpKind) (lang : Lang) (variant : Variant)
    (sig : KernelSig) (ins outs : List TensorTy) (minArch : Arch) (maxArch : Option Arch)
    (launch : LaunchConfig) (numeric : NumericProps) (fuses : EnumSet OpKind)
    (source : SourceHash) (license : License) : Except String Kernel := do
  sig.checkTensors ins outs
  if let some mx := maxArch then
    unless mx.supports minArch do
      throw s!"maxArch {LeanDb.ClosedEnum.encodeName mx} does not support minArch {LeanDb.ClosedEnum.encodeName minArch}"
  return { name, op, lang, variant, sig, ins := ins.map KernelInput.ofTensorTy
           outs := outs.map KernelInput.ofTensorTy, minArch, maxArch, launch, numeric, fuses
           source, license }

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

/-- FK-dependency order. `Entity.specs Kernel` is the kernel table and
    its two child tables. -/
def schema : List TableSpec :=
  Entity.specs Kernel ++ [Entity.spec Bench, Entity.spec Program,
   Entity.spec ProgramNode, Entity.spec ProgramEdge]

end Kernels
