import Kernels.Prog
import GpuMarket.Arch

/-! # Queries — domain logic as plain Lean over `select`

Every docstring says what pushes and what stays residual; `kernels log`
is the proof. The pattern throughout: SQL narrows on the flat columns
(enums, search columns, the inline `launch_*`/`numeric_*` columns, the
canonical `binding` TEXT, `Ref`s) and, since LEP-0003 D, on the *child
rows* of `kernel_ins`/`kernel_outs` through `.any`/`.all` (LEP-0004
quantifiers); Lean does everything that looks *inside* `sig` or a
tensor's `full` type — instantiation, unification, composition — because
those columns are opaque to SQL. -/

namespace Kernels

open LeanDb LeanDb.Cli
open GpuMarket (Gpu)

/-! ## CLI argument parsing for this base's newtypes -/

instance : CliArg DimBinding := ⟨DimBinding.decode⟩
instance : CliArg KernelName := ⟨KernelName.make⟩
instance : CliArg ProgramName := ⟨ProgramName.make⟩

/-- `gemm,rmsNorm` — a comma-separated list of the closed world. -/
instance : CliArg (List OpKind) := ⟨fun s =>
  (s.splitOn ",").mapM fun n =>
    match ClosedEnum.decodeName (α := OpKind) n with
    | some op => .ok op
    | none => .error s!"{String.quote n} is not one of {ClosedEnum.variants OpKind}"⟩

/-! ## Candidates -/

/-- Kernels for an op on an arch at an input dtype. All four conjuncts
    push: the enum and the search column as `IS`, `Arch.supports` as a
    case split over `minArch` folded at plan build to `minArch IS 'c' OR
    …` over the architectures `arch` supports, and the `maxArch` test as
    `IS NULL OR IS ?`. -/
def candidates (op : OpKind) (arch : Arch) (dt : DType) : DbM (Array (Stored Kernel)) :=
  select [Kernel] (fun k =>
      k.val.op == op && k.val.inDtype0 == dt
        && arch.supports k.val.minArch
        && (k.val.maxArch.isNone || k.val.maxArch == some arch))
    (.key (·.val.name))

/-- `candidates` without the dtype: the first node of a synthesized chain
    has no upstream to fix its input type. -/
def forArch (op : OpKind) (arch : Arch) : DbM (Array (Stored Kernel)) :=
  select [Kernel] (fun k =>
      k.val.op == op && arch.supports k.val.minArch
        && (k.val.maxArch.isNone || k.val.maxArch == some arch))
    (.key (·.val.name))

/-- Kernels whose epilogue fuses `op`. `fuses` is an `EnumSet OpKind`
    (LEP-0003 A): membership pushes as a bit test on the INTEGER mask,
    `("fuses" & ?) != 0`, residual 0 — the question a set is for, which
    the canonical-TEXT encoding it replaced could not answer in SQL. -/
def fusing (op : OpKind) : DbM (Array (Stored Kernel)) :=
  select [Kernel] (fun k => k.val.fuses.contains op) (.key (·.val.name))

/-- Kernels whose dynamic shared memory fits in `n` bytes. `launch` is an
    inline structure (LEP-0003 C): `k.val.launch.smemBytes` is the
    flattened column `launch_smemBytes`, and the comparison pushes as
    `t0."launch_smemBytes" <= ?`, residual 0 — the predicate the JSON
    column could not answer in SQL. -/
def fitsSmem (n : Nat) : DbM (Array (Stored Kernel)) :=
  select [Kernel] (fun k => k.val.launch.smemBytes ≤ n) (.key (·.val.name))

/-- Deterministic kernels accumulating in `accum`. `numeric` is inline
    too: both tests push as `IS` on `numeric_deterministic` and
    `numeric_accum` — exactly what the hand-flattened columns gave, with
    the grouping kept in the type and in row JSON. -/
def reproducible (accum : DType) : DbM (Array (Stored Kernel)) :=
  select [Kernel] (fun k => k.val.numeric.deterministic && k.val.numeric.accum == accum)
    (.key (·.val.name))

/-- Kernels whose first input is rank ≥ `minRank` *and* whose every input
    is. Before stage D the second conjunct read `sig` and was the smallest
    honest example of the gap (`residual conjuncts: 1`); now the inputs
    are child rows and `k.val.ins.all …` is LEP-0004's `forall`, pushed as
    `NOT EXISTS (SELECT 1 FROM "kernel_ins" AS s0 WHERE s0."parent" IS
    t0."id" AND s0."rank" < ?)` beside the search column, residual 0. -/
def highRank (minRank : Nat) : DbM (Array (Stored Kernel)) :=
  select [Kernel] (fun k =>
      k.val.rank0 ≥ minRank && k.val.ins.all (·.rank ≥ minRank))
    (.key (·.val.name))

/-- "Every input has rank ≥ n": the quantifier alone, `NOT EXISTS` over
    `kernel_ins`, residual 0. Vacuously true of a kernel with no inputs
    (`Kernel.make` refuses one). -/
def allHighRank (n : Nat) : DbM (Array (Stored Kernel)) :=
  select [Kernel] (fun k => k.val.ins.all (·.rank ≥ n)) (.key (·.val.name))

/-- "Any input is column-major": `EXISTS` over `kernel_ins` on the closed
    `layoutKind` column, residual 0. -/
def anyColMajor : DbM (Array (Stored Kernel)) :=
  select [Kernel] (fun k => k.val.ins.any (·.layoutKind == .colMajor)) (.key (·.val.name))

/-- "Exactly two inputs" **stays residual** (`pushed: 1, residual
    conjuncts: 1`): `ins.length` is an aggregate over the child rows, and
    the engine has no aggregate verb — LEP-0004 names `∃ position=0 ∧ ∃
    position=1 ∧ ¬∃ position=2` as the expressible-but-ugly spelling until
    one exists. The lambda decides over the attached list. -/
def exactlyTwoInputs : DbM (Array (Stored Kernel)) :=
  select [Kernel] (fun k => k.val.ins.length == 2) (.key (·.val.name))

/-! ## Performance -/

/-- Fastest measured kernel for an op on a SKU at a binding. Join, enum,
    SKU and the canonical-TEXT binding all push; the sort is client-side
    and the "first" is a `take` (no pushed LIMIT — study §3.5). -/
def fastest (op : OpKind) (sku : Gpu) (b : DimBinding) :
    DbM (Option (Stored Kernel × Stored Bench)) := do
  let rows ← select [Kernel, Bench] (fun (k, m) =>
      m.val.kernel == k.ref && k.val.op == op
        && m.val.sku == sku && m.val.binding == b)
    (.key fun (_, m) => m.val.latency)
  return rows[0]?

/-- Later sample slower than an earlier one by more than 10% for the same
    kernel/SKU/binding: a self-join. Kernel equality, both SKU tests, the
    binding equality and the timestamp ordering push (`cmp2` across
    `t0`/`t1`, ordering through `.epochSeconds`); the 10% arithmetic is
    the one residual conjunct — column arithmetic is named deferred. -/
def regressions (sku : Gpu) : DbM (Array (Stored Bench × Stored Bench)) :=
  select [Bench, Bench] (fun (a, c) =>
      a.val.kernel == c.val.kernel && a.val.sku == sku && c.val.sku == sku
        && a.val.binding == c.val.binding
        && a.val.measuredAt.epochSeconds < c.val.measuredAt.epochSeconds
        && c.val.latency.us * 10 > a.val.latency.us * 11)
    (.key fun (a, _) => a.val.kernel)

open Lean (Json) in
/-- Every measurement on a SKU against the datasheet: achieved vs peak
    dense TFLOPS at the bench's precision (`Gpu.tflops`), achieved vs peak
    bandwidth (`Gpu.spec`), arithmetic intensity vs the ridge point, and
    which side of the roof it sits on. The fetch pushes; the arithmetic
    is Lean over gpumarket's vocabulary — no lookup table anywhere. -/
def roofline (sku : Gpu) : DbM Json := do
  let rows ← select [Bench, Kernel]
    (fun (m, k) => m.val.kernel == k.ref && m.val.sku == sku)
    (.key fun (m, _) => m.val.latency)
  let spec := sku.spec
  let peakBw := spec.memBwGBs
  let items := rows.filterMap fun (m, k) => do
    let prec ← m.val.precision.precision
    let peak ← sku.tflops prec
    let achieved := m.val.tflops.milli
    -- flop/byte in thousandths: milli-TFLOPS·1e9 / (GB/s·1e9) = milli / GBs
    let ridge := peak * 1000 * 1000 / peakBw
    let intensity := if m.val.bwGBs == 0 then 0 else achieved * 1000 / m.val.bwGBs
    return Json.mkObj [
      ("kernel", Json.str k.val.name.raw),
      ("binding", Json.str m.val.binding.encode),
      ("precision", Json.str (ClosedEnum.encodeName m.val.precision)),
      ("latency_us", Lean.toJson m.val.latency.us),
      ("tflops_milli", Lean.toJson achieved),
      ("peak_tflops", Lean.toJson peak),
      ("compute_permille", Lean.toJson (achieved / peak)),
      ("bw_gbs", Lean.toJson m.val.bwGBs),
      ("bw_permille", Lean.toJson (m.val.bwGBs * 1000 / peakBw)),
      ("intensity_milliflop_per_byte", Lean.toJson intensity),
      ("ridge_milliflop_per_byte", Lean.toJson ridge),
      ("bound", Json.str (if intensity ≥ ridge then "compute" else "memory"))]
  return Json.mkObj [
    ("sku", Json.str (ClosedEnum.encodeName sku)),
    ("marketing", Json.str spec.marketing),
    ("peak_bw_gbs", Lean.toJson peakBw),
    ("rows", Json.arr items)]

/-! ## Composition -/

/-- Kernels whose first input unifies with `n`'s first output. SQL narrows
    on the search column (`inDtype0 IS ?`); unification over the two
    tensors' `full` types is Lean over the opaque column — residual by
    nature, and where every symbolic-shape question ends up (rank and
    layout kind, by contrast, are child columns now). -/
def composable (n : KernelName) : DbM (Array (Stored Kernel)) := do
  let some k := (← select [Kernel] (fun c => c.val.name == n))[0]? | return #[]
  let cands ← select [Kernel] (fun c => c.val.inDtype0 == k.val.outDtype0) (.key (·.val.name))
  return cands.filter fun c =>
    match k.val.outs[0]?, c.val.ins[0]? with
    | some o, some i => (unify o.full i.full).isSome
    | _, _ => false

/-- Measured latency lookup on one SKU: the best sample per
    (kernel, binding). One pushed fetch, then a closure. -/
def benchLookup (sku : Gpu) : DbM (Ref Kernel → DimBinding → Option Micros) := do
  let rows ← select [Bench] (fun m => m.val.sku == sku)
  return fun k b =>
    let hits := rows.filterMap fun m =>
      if m.val.kernel == k && m.val.binding == b then some m.val.latency.us else none
    hits.foldl (fun acc us => some (match acc with | some a => ⟨min a.us us⟩ | none => ⟨us⟩)) none

private def rankBy (lookup : Ref Kernel → DimBinding → Option Micros) (b : DimBinding)
    (ks : Array (Stored Kernel)) : Array (Stored Kernel) :=
  ks.qsort fun x y =>
    match lookup x.ref b, lookup y.ref b with
    | some a, some c => a.us < c.us || (a.us == c.us && x.val.name.raw < y.val.name.raw)
    | some _, none => true
    | none, some _ => false
    | none, none => x.val.name.raw < y.val.name.raw

/-- Depth-first over candidates for the remaining ops, threading edge
    types: each candidate is bound by unifying its inputs with the
    upstream outputs, then `Prog.extend` either typechecks the seam or
    names why not and the search moves on. -/
private def extendChain (arch : Arch) (lookup : Ref Kernel → DimBinding → Option Micros)
    (userB : DimBinding) : SomeProg → List OpKind → DbM (Option SomeProg)
  | acc, [] => return some acc
  | acc, op :: rest => do
      let some first := acc.outs[0]? | return none
      let cands ← candidates op arch first.dtype
      let mut result : Option SomeProg := none
      for k in rankBy lookup userB cands do
        if result.isSome then break
        match bindByShape k.val.sig k.val.tensorIns acc.outs userB >>= Prog.extend acc k with
        | .ok acc' => result ← extendChain arch lookup userB acc' rest
        | .error _ => pure ()
      return result

/-- Synthesize a typed program for a chain of ops on a SKU: the first
    op's candidates are ranked by measured latency at `b` (unmeasured
    last), each later op's by its own best sample; the first chain whose
    every seam typechecks wins. Pure Lean over `candidates` — SQL only
    ever sees the flat columns. -/
def synthesizeProg (ops : List OpKind) (sku : Gpu) (b : DimBinding) : DbM (Option SomeProg) := do
  let arch := Arch.ofGpu sku
  let lookup ← benchLookup sku
  match ops with
  | [] => return none
  | op :: rest =>
      let mut result : Option SomeProg := none
      for k in rankBy lookup b (← forArch op arch) do
        if result.isSome then break
        match Prog.start k b with
        | .ok acc => result ← extendChain arch lookup b acc rest
        | .error _ => pure ()
      return result

open Lean (Json) in
/-- `synthesizeProg` for the CLI: `query synthesize gemm,rmsNorm h100Sxm M=4096,N=4096,K=4096`. -/
def synthesize (ops : List OpKind) (sku : Gpu) (b : DimBinding) : DbM Json := do
  match ← synthesizeProg ops sku b with
  | none => return Json.mkObj [("found", Json.bool false)]
  | some sp =>
      let lookup ← benchLookup sku
      return (sp.toJson sku (sp.2.2.estimate lookup))

open Lean (Json) in
/-- Re-type a stored program through `Prog.ofRows` and render it. The
    node/edge fetches push on the program `Ref`; the gate is Lean. -/
def program (n : ProgramName) : DbM Json := do
  let some p := (← select [Program] (fun p => p.val.name == n))[0]?
    | throw (.notFound "program" 0)
  let nodes ← select [ProgramNode] (fun x => x.val.program == p.ref)
  let edges ← select [ProgramEdge] (fun e => e.val.program == p.ref)
  let kernels ← fetchAll Kernel
  match Prog.ofRows p nodes edges (fun r => kernels.find? (·.id == r)) with
  | .error e => return Json.mkObj [("program", Json.str n.raw), ("typed", Json.bool false), ("reason", Json.str e)]
  | .ok sp =>
      let lookup ← benchLookup p.val.sku
      return Json.mkObj [("program", Json.str n.raw), ("typed", Json.bool true),
        ("prog", sp.toJson p.val.sku (sp.2.2.estimate lookup))]

open Lean (Json) in
/-- One kernel, with its signature pretty-printed from `sig` and the child
    rows. The search columns are derived: a row that reached this point
    has them agreeing with its first input, because `attach` refused it
    otherwise — there is nothing to check here. -/
def kernelInfo (n : KernelName) : DbM Json := do
  let some k := (← select [Kernel] (fun c => c.val.name == n))[0]?
    | throw (.notFound "kernel" 0)
  return Json.mkObj [
    ("id", Lean.toJson k.id.toInt64.toInt),
    ("name", Json.str k.val.name.raw),
    ("op", Json.str (ClosedEnum.encodeName k.val.op)),
    ("sig", Json.str k.val.describeSig),
    ("ins", Json.arr (k.val.ins.map fun i => Json.str i.full.describe).toArray),
    ("outs", Json.arr (k.val.outs.map fun o => Json.str o.full.describe).toArray),
    ("launch", Lean.toJson k.val.launch),
    ("numeric", Lean.toJson k.val.numeric),
    ("fuses", Lean.toJson k.val.fuses.names),
    ("inDtype0", Json.str (ClosedEnum.encodeName k.val.inDtype0)),
    ("outDtype0", Json.str (ClosedEnum.encodeName k.val.outDtype0)),
    ("rank0", Lean.toJson k.val.rank0)]

end Kernels
