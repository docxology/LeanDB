import Kernels.Entities

/-! # Programs — the typed layer, entirely in Lean

`Prog ins outs` is a DAG whose edges are tensor types. A node is a
*stored* kernel plus a proof that its signature instantiates to the node's
edge types; composition is checked by the compiler. The database never
sees this type: rows go in as `Program`/`ProgramNode`/`ProgramEdge` and
come back out through `Prog.ofRows`, the gate that either re-types them or
names why it cannot.

The property that matters: `Prog.seq p q` demands `p`'s outputs *be* `q`'s
inputs, so feeding an f32 GEMM into a kernel expecting bf16 is a type
error (`#check_failure` in the tests), not a runtime surprise. -/

namespace Kernels

open LeanDb

inductive Prog : List TensorTy → List TensorTy → Type where
  /-- A launch of stored kernel `k` at binding `b`; `h` says the signature
      instantiates to exactly these edge types (by `if h :` on fetched
      rows, by `rfl` on closed terms). -/
  | kernel (k : Stored Kernel) (b : DimBinding) (ins outs : List TensorTy)
      (h : k.val.instantiates b ins outs = true) : Prog ins outs
  /-- Pass buffers through untouched — how a program input reaches a
      later node beside an upstream output (`par p (id extra)`). -/
  | id (xs : List TensorTy) : Prog xs xs
  | seq {a b c : List TensorTy} : Prog a b → Prog b c → Prog a c
  | par {a b c d : List TensorTy} : Prog a b → Prog c d → Prog (a ++ c) (b ++ d)
  | swap (x y : TensorTy) : Prog [x, y] [y, x]
  | dup (x : TensorTy) : Prog [x] [x, x]

/-- A program whose edge types are data: what queries return and what
    `ofRows` produces. -/
abbrev SomeProg := Σ ins outs, Prog ins outs

def SomeProg.ins (s : SomeProg) : List TensorTy := s.1
def SomeProg.outs (s : SomeProg) : List TensorTy := s.2.1

/-- One launch's worth of information, in launch order. -/
structure Launch where
  kernel  : Stored Kernel
  binding : DimBinding
  ins     : List TensorTy
  outs    : List TensorTy

def Prog.launches : Prog a b → List Launch
  | .kernel k bnd ins outs _ => [⟨k, bnd, ins, outs⟩]
  | .id _ | .swap _ _ | .dup _ => []
  | .seq p q => p.launches ++ q.launches
  | .par p q => p.launches ++ q.launches

/-- Sum of per-launch latencies from a lookup into `Bench` (launches are
    serialized, so `par` adds too); `none` if any launch is unmeasured. -/
def Prog.estimate (lookup : Ref Kernel → DimBinding → Option Micros) (p : Prog a b) :
    Option Micros := do
  let us ← p.launches.mapM fun l => (lookup l.kernel.ref l.binding).map (·.us)
  return ⟨us.foldl (· + ·) 0⟩

/-! ## Emission — a host-program *skeleton*

Launch order, buffer names, and the dtype/shape on every edge. It is not
CUDA/HIP: the real thing needs each kernel's source (an artifact keyed by
`Kernel.source`) and its ABI; this shows what the typed layer already
knows without them. -/

private structure EmitState where
  next  : Nat := 0
  lines : Array String := #[]

private def fresh (t : TensorTy) : StateM EmitState String := do
  let s ← get
  let name := s!"buf{s.next}"
  let line := s!"alloc  {name} : {t.describe}"
  set { s with next := s.next + 1, lines := s.lines.push line }
  return name

private def Prog.emitM : Prog a b → List String → StateM EmitState (List String)
  | .kernel k bnd _ outs _, names => do
      let outNames ← outs.mapM fresh
      let line := s!"launch {k.val.name.raw} [{bnd}]  ({String.intercalate ", " names}) -> ({String.intercalate ", " outNames})"
      modify fun s => { s with lines := s.lines.push line }
      return outNames
  | .id _, names => pure names
  | .seq p q, names => do q.emitM (← p.emitM names)
  | @Prog.par a _ _ _ p q, names => do
      let l ← p.emitM (names.take a.length)
      let r ← q.emitM (names.drop a.length)
      return l ++ r
  | .swap _ _, names => pure names.reverse
  | .dup _, names => pure (names ++ names)

def Prog.emit (sku : GpuMarket.Gpu) {a b : List TensorTy} (p : Prog a b) : String :=
  let inNames := (List.range a.length).map fun i => s!"in{i}"
  let header := #[s!"// host skeleton for {sku.spec.marketing} — launch order and edge types only, not compilable"]
    ++ (a.zip inNames).toArray.map fun (t, n) => s!"input  {n} : {t.describe}"
  let (outNames, st) := (p.emitM inNames).run { lines := header }
  let footer := (b.zip outNames).toArray.map fun (t, n) => s!"output {n} : {t.describe}"
  String.intercalate "\n" (st.lines ++ footer).toList

/-! ## The gate: rows → typed program -/

/-- A one-node program. -/
def Prog.start (k : Stored Kernel) (b : DimBinding) : Except String SomeProg := do
  let (ins, outs) ← k.val.instantiate b
  if h : k.val.instantiates b ins outs = true then
    return ⟨ins, outs, .kernel k b ins outs h⟩
  else throw "unreachable: instantiate succeeded but instantiates is false"

/-- Append a launch that consumes every upstream output as its leading
    inputs; its remaining inputs become new program inputs. The decidable
    check `ins = mid ++ extra` is where a dtype/shape mismatch is refused. -/
def Prog.extend (acc : SomeProg) (k : Stored Kernel) (b : DimBinding) : Except String SomeProg := do
  let ⟨a, mid, p⟩ := acc
  let (ins, outs) ← k.val.instantiate b
  if h : k.val.instantiates b ins outs = true then
    let extra := ins.drop mid.length
    if h2 : ins = mid ++ extra then
      let q : Prog (mid ++ extra) outs := h2 ▸ Prog.kernel k b ins outs h
      return ⟨a ++ extra, outs, .seq (.par p (.id extra)) q⟩
    else throw s!"{k.val.name.raw} at {b} expects ({String.intercalate ", " ((ins.take mid.length).map TensorTy.describe)}) but upstream produces ({String.intercalate ", " (mid.map TensorTy.describe)})"
  else throw "unreachable: instantiate succeeded but instantiates is false"

/-- Relational rows back into a typed program, or a named reason. Today
    the gate accepts *chains*: node `i+1`'s first inputs are exactly node
    `i`'s outputs (one edge per output, positional), the rest are program
    inputs; each node's binding is what unification with the upstream
    edge types determines, falling back to the program's binding. A DAG
    that is not a chain is refused by name, not approximated. -/
def Prog.ofRows (prog : Stored Program) (nodes : Array (Stored ProgramNode))
    (edges : Array (Stored ProgramEdge)) (kernelOf : Ref Kernel → Option (Stored Kernel)) :
    Except String SomeProg := do
  let nodes := nodes.qsort fun x y => x.val.position < y.val.position
  let mut acc : Option (SomeProg × Stored ProgramNode) := none
  let mut expected := 0
  for node in nodes do
    unless node.val.position == expected do
      throw s!"node positions must be 0..n-1; found {node.val.position} where {expected} was expected"
    expected := expected + 1
    let some k := kernelOf node.val.kernel
      | throw s!"node {node.val.position} references a kernel that was not fetched"
    let incoming := edges.filter (·.val.toNode == node.id)
    match acc with
    | none =>
        unless incoming.isEmpty do throw "the first node has incoming edges"
        acc := some (← Prog.start k prog.val.binding, node)
    | some (sp, prev) =>
        let mid := sp.outs
        unless incoming.size == mid.length do
          throw s!"node {node.val.position} has {incoming.size} incoming edges; a chain needs {mid.length}"
        for j in List.range mid.length do
          unless incoming.any fun e =>
              e.val.toInput == j && e.val.fromNode == prev.id && e.val.fromOutput == j do
            throw s!"node {node.val.position} input {j} is not fed by node {prev.val.position} output {j}; only chains are re-typed today"
        let b ← bindByShape k.val.sig k.val.tensorIns mid prog.val.binding
        acc := some (← Prog.extend sp k b, node)
  match acc with
  | some (sp, _) => return sp
  | none => throw "program has no nodes"

open Lean (Json) in
/-- JSON for the CLI: edge types in and out, launches with their bindings
    and edge types, the latency estimate, and the emitted skeleton. -/
def SomeProg.toJson (sp : SomeProg) (sku : GpuMarket.Gpu) (estimate : Option Micros) : Json :=
  let ⟨_, _, p⟩ := sp
  Json.mkObj [
    ("sku", Json.str (LeanDb.ClosedEnum.encodeName sku)),
    ("inputs", Json.arr (sp.ins.map (Json.str ·.describe)).toArray),
    ("outputs", Json.arr (sp.outs.map (Json.str ·.describe)).toArray),
    ("launches", Json.arr <| (p.launches.zipIdx.map fun (l, i) => Json.mkObj [
      ("position", Lean.toJson i),
      ("kernel", Json.str l.kernel.val.name.raw),
      ("kernel_id", Lean.toJson l.kernel.id.toInt64.toInt),
      ("binding", Json.str l.binding.encode),
      ("ins", Json.arr (l.ins.map (Json.str ·.describe)).toArray),
      ("outs", Json.arr (l.outs.map (Json.str ·.describe)).toArray)]).toArray),
    ("estimate_us", match estimate with | some m => Lean.toJson m.us | none => Json.null),
    ("skeleton", Json.str (p.emit sku))]

end Kernels
