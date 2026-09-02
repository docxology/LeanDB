import Kernels.Scalars

/-! # Signatures as data

A kernel is shape-polymorphic (`∀ M N K, T[M,K] → T[K,N] → T[M,N]`); a row
cannot hold a Π-type, so it holds the *code* of one — `KernelSig` — and
Lean interprets it (`instantiate`, `unify`, `Prog`). Every type here is
ordinary Lean with `deriving LeanDb.DbJson` (LEP-0003 B1/B2): the same
JSON encoding Lean's own derive produces, except that an omitted field
with a default takes the default, plus a `JsonShape` the fingerprint and
`migrate` can see. Payload-carrying sums and nested lists are fine
because none of them is ever a bare column.

Since LEP-0003 D the signature is split in two. `KernelSig` — the
variables, scalar arguments and constraints — is one JSON TEXT column
(`ColCodec.json`), opaque to SQL. The inputs and outputs are **child
rows**: `Kernel.ins`/`Kernel.outs` are `List KernelInput`, an `Inline`
record carrying the facts SQL asks about (`dtype`, `rank`, `layoutKind`)
beside the whole `TensorTy` as a JSON column (`full`), so "every input
has rank ≥ 3" is a `NOT EXISTS` over `kernel_ins` and `instantiate` still
has the full type.

Invariants that live inside one value live in its `make`; the column
codec of `KernelSig` validates through `KernelSig.validate`, so a
constraint over an undeclared variable is refused at the JSON boundary.
The cross-checks between a signature and its tensors (every shape variable
declared, outputs determined by inputs, at least one of each) span the
parent row and its child rows; they are `Kernel.make`'s
(`KernelSig.checkTensors`) — there is no engine hook for a whole-value
validator across tables yet. -/

namespace Kernels

open LeanDb

/-- A symbolic dimension: a literal, a bound variable, or a small affine
    expression in bound variables (`K / 2`, `2 * S + 1`). -/
inductive Dim where
  | lit (n : Nat)
  | var (v : DimVar)
  | mul (k : Nat) (d : Dim)
  | add (a b : Dim)
  | div (d : Dim) (k : Nat)
  deriving Repr, DecidableEq, LeanDb.DbJson

def Dim.vars : Dim → List DimVar
  | .lit _ => []
  | .var v => [v]
  | .mul _ d => d.vars
  | .add a b => a.vars ++ b.vars
  | .div d _ => d.vars

def Dim.eval (env : DimVar → Option Nat) : Dim → Except String Nat
  | .lit n => .ok n
  | .var v => match env v with
      | some n => .ok n
      | none => .error s!"unbound shape variable {v.name}"
  | .mul k d => (k * ·) <$> d.eval env
  | .add a b => do return (← a.eval env) + (← b.eval env)
  | .div d k => do
      if k == 0 then throw "division by zero in a dimension"
      return (← d.eval env) / k

def Dim.describe : Dim → String
  | .lit n => toString n
  | .var v => v.name
  | .mul k d => s!"{k}*{d.describe}"
  | .add a b => s!"({a.describe}+{b.describe})"
  | .div d k => s!"{d.describe}/{k}"

inductive Layout where
  | rowMajor | colMajor
  | strided (strides : List Dim)
  | tiled (tile : List Nat) (inner : Layout)
  deriving Repr, DecidableEq, LeanDb.DbJson

/-- The closed world of layout *kinds*: `Layout` with its payloads
    forgotten, so a child row can carry it as an enum column
    (`KernelInput.layoutKind`) and "any input is column-major" pushes. -/
inductive LayoutKind where
  | rowMajor | colMajor | strided | tiled
  deriving Repr, DecidableEq, Ord, LeanDb.ClosedEnum

def Layout.kind : Layout → LayoutKind
  | .rowMajor => .rowMajor
  | .colMajor => .colMajor
  | .strided _ => .strided
  | .tiled .. => .tiled

def Layout.vars : Layout → List DimVar
  | .rowMajor | .colMajor => []
  | .strided ds => ds.flatMap Dim.vars
  | .tiled _ inner => inner.vars

def Layout.instantiate (env : DimVar → Option Nat) : Layout → Except String Layout
  | .rowMajor => .ok .rowMajor
  | .colMajor => .ok .colMajor
  | .strided ds => .strided <$> ds.mapM fun d => (Dim.lit ·) <$> d.eval env
  | .tiled t inner => .tiled t <$> inner.instantiate env

def Layout.describe : Layout → String
  | .rowMajor => "rowMajor"
  | .colMajor => "colMajor"
  | .strided ds => s!"strided[{String.intercalate "," (ds.map Dim.describe)}]"
  | .tiled t inner => s!"tiled{t}/{inner.describe}"

/-- A tensor type: element type, symbolic shape, layout, memory space,
    alignment in bytes. Fully literal after `instantiate`. -/
structure TensorTy where
  dtype  : DType
  shape  : List Dim
  layout : Layout := .rowMajor
  mem    : MemSpace := .global
  align  : Nat := 16
  deriving Repr, DecidableEq, LeanDb.DbJson

def TensorTy.rank (t : TensorTy) : Nat := t.shape.length

def TensorTy.vars (t : TensorTy) : List DimVar :=
  t.shape.flatMap Dim.vars ++ t.layout.vars

def TensorTy.instantiate (env : DimVar → Option Nat) (t : TensorTy) : Except String TensorTy := do
  let shape ← t.shape.mapM fun d => (Dim.lit ·) <$> d.eval env
  let layout ← t.layout.instantiate env
  return { t with shape, layout }

/-- `bf16[M,K]`, with layout / memory space appended only when not the default. -/
def TensorTy.describe (t : TensorTy) : String :=
  let base := s!"{LeanDb.ClosedEnum.encodeName t.dtype}[{String.intercalate "," (t.shape.map Dim.describe)}]"
  let base := if t.layout == .rowMajor then base else s!"{base}:{t.layout.describe}"
  if t.mem == .global then base else s!"{base}@{LeanDb.ClosedEnum.encodeName t.mem}"

/-- A tensor type as one JSON column: what a child row carries whole, so
    the typed layer (`instantiate`, `unify`) reads the full type back. -/
instance : ColCodec TensorTy := ColCodec.json TensorTy

/-- One input or output of a kernel, as a child row (LEP-0003 D): the
    facts SQL asks about as columns — element type, rank, layout kind —
    and the whole `TensorTy` beside them. Built only through
    `ofTensorTy`, so the three columns agree with `full` by construction
    (an `Inline` record cannot carry a `derived` column; the check-on-read
    that a parent's derived column gets is not available inside one). -/
structure KernelInput where
  dtype      : DType
  rank       : Nat
  layoutKind : LayoutKind
  full       : TensorTy
  deriving Repr, DecidableEq, LeanDb.Inline

def KernelInput.ofTensorTy (t : TensorTy) : KernelInput :=
  { dtype := t.dtype, rank := t.rank, layoutKind := t.layout.kind, full := t }

/-- Name of a scalar kernel argument (`alpha`, `eps`, `causal`): lowercase
    identifier. -/
structure ScalarName where
  raw : String
  deriving Repr, DecidableEq

def ScalarName.make (s : String) : Except String ScalarName :=
  if s.isEmpty || s.length > 32 then .error s!"scalar name must be 1-32 chars, got {String.quote s}"
  else if !s.front.isLower then .error s!"scalar name must start with a lowercase letter: {String.quote s}"
  else if !(s.toList.all fun c => c.isAlphanum || c == '_') then
    .error s!"scalar name must be alphanumeric: {String.quote s}"
  else .ok ⟨s⟩

instance : Lean.ToJson ScalarName := ⟨fun v => .str v.raw⟩
instance : Lean.FromJson ScalarName := ⟨fun j => j.getStr? >>= ScalarName.make⟩
/-- Its JSON is a string; the shape says so. -/
instance : LeanDb.JsonShape ScalarName := ⟨LeanDb.JsonShape.shape String⟩

inductive DimConstraint where
  | divides (k : Nat) (d : Dim)
  | le (a b : Dim)
  | eq (a b : Dim)
  deriving Repr, DecidableEq, LeanDb.DbJson

def DimConstraint.vars : DimConstraint → List DimVar
  | .divides _ d => d.vars
  | .le a b | .eq a b => a.vars ++ b.vars

def DimConstraint.describe : DimConstraint → String
  | .divides k d => s!"{d.describe} % {k} = 0"
  | .le a b => s!"{a.describe} ≤ {b.describe}"
  | .eq a b => s!"{a.describe} = {b.describe}"

def DimConstraint.holds (env : DimVar → Option Nat) : DimConstraint → Except String Bool
  | .divides k d => do
      if k == 0 then throw "divisibility by zero"
      return (← d.eval env) % k == 0
  | .le a b => do return (← a.eval env) ≤ (← b.eval env)
  | .eq a b => do return (← a.eval env) == (← b.eval env)

/-- The signature minus its tensors: the shape variables, the scalar
    arguments and the constraints. A `KernelSig` that exists declares each
    variable once and constrains only declared ones; the tensors it
    quantifies over are the kernel's child rows (`Kernel.ins`/`outs`),
    checked against it by `checkTensors` in `Kernel.make`. -/
structure KernelSig where
  vars        : List DimVar
  scalars     : List (ScalarName × DType)
  constraints : List DimConstraint
  deriving Repr, DecidableEq, LeanDb.DbJson

def KernelSig.make (vars : List DimVar) (scalars : List (ScalarName × DType) := [])
    (constraints : List DimConstraint := []) : Except String KernelSig := do
  if vars.eraseDups.length != vars.length then throw "duplicate shape variable"
  for v in constraints.flatMap DimConstraint.vars do
    unless vars.contains v do throw s!"shape variable {v.name} is used but not declared in vars"
  return { vars, scalars, constraints }

/-- `make` over an already-built value: what the column codec validates
    through, so JSON whose constraints name an undeclared variable is
    refused at the boundary, whether it arrives from the CLI or from a row
    written by an older build. -/
def KernelSig.validate (s : KernelSig) : Except String KernelSig :=
  KernelSig.make s.vars s.scalars s.constraints

/-- The one nested column: compressed JSON TEXT with a declared shape.
    SQL sees a string; the fingerprint and `migrate` see the shape. -/
instance : ColCodec KernelSig := ColCodec.json KernelSig KernelSig.validate

/-- The cross-check between a signature and its tensors: at least one
    input and one output, every shape variable declared, every output
    variable bound by some input (outputs are determined). Spans the
    kernel row and its child rows, so it is `Kernel.make`'s, not a codec's. -/
def KernelSig.checkTensors (s : KernelSig) (ins outs : List TensorTy) : Except String Unit := do
  if ins.isEmpty then throw "a kernel needs at least one input"
  if outs.isEmpty then throw "a kernel needs at least one output"
  let inVars := ins.flatMap TensorTy.vars
  for v in inVars ++ outs.flatMap TensorTy.vars do
    unless s.vars.contains v do throw s!"shape variable {v.name} is used but not declared in vars"
  for v in outs.flatMap TensorTy.vars do
    unless inVars.contains v do throw s!"output shape variable {v.name} appears in no input"

def KernelSig.describe (s : KernelSig) (ins outs : List TensorTy) : String :=
  let ins := String.intercalate ", " (ins.map TensorTy.describe)
  let outs := String.intercalate ", " (outs.map TensorTy.describe)
  let vars := String.intercalate " " (s.vars.map (·.name))
  let cs := if s.constraints.isEmpty then "" else
    s!" where {String.intercalate ", " (s.constraints.map DimConstraint.describe)}"
  s!"∀ {vars}, ({ins}) → ({outs}){cs}"

/-- Instantiate the tensors `ins`/`outs` of signature `s` at a binding:
    the monomorphic in/out types, or a named reason (unbound variable,
    violated constraint). -/
def KernelSig.instantiate (s : KernelSig) (ins outs : List TensorTy) (b : DimBinding) :
    Except String (List TensorTy × List TensorTy) := do
  let env := b.lookup
  for v in s.vars do
    if (env v).isNone then throw s!"binding {b} leaves {v.name} unbound"
  for c in s.constraints do
    unless ← c.holds env do throw s!"constraint {c.describe} fails at {b}"
  let ins ← ins.mapM (·.instantiate env)
  let outs ← outs.mapM (·.instantiate env)
  return (ins, outs)

/-- Boolean form of "instantiating `sigIns`/`sigOuts` under `s` at `b`
    gives exactly `ins`/`outs`"; `Prog.kernel` carries a proof that it is
    `true`, obtained by `if h :` on fetched rows and by `rfl` on closed
    terms. -/
def KernelSig.instantiates (s : KernelSig) (sigIns sigOuts : List TensorTy) (b : DimBinding)
    (ins outs : List TensorTy) : Bool :=
  match s.instantiate sigIns sigOuts b with
  | .ok (i, o) => i == ins && o == outs
  | .error _ => false

/-! ## Unification

Two signatures have separate variable namespaces, so a substitution keys
on a side-tagged variable (`false` = left, `true` = right) and binds it to
a side-tagged term. First-order, no arithmetic inversion: `2*K` unifies
with `2*K'`, never with `8192`. -/

abbrev Subst := List ((Bool × DimVar) × (Bool × Dim))

def Subst.walk (s : Subst) : Nat → Bool × Dim → Bool × Dim
  | 0, t => t
  | fuel + 1, (side, .var v) =>
      match s.find? (·.1 == (side, v)) with
      | some (_, t) => s.walk fuel t
      | none => (side, .var v)
  | _, t => t

def unifyDim (fuel : Nat) (s : Subst) (a b : Bool × Dim) : Option Subst :=
  match fuel with
  | 0 => none
  | fuel + 1 =>
    let a := s.walk (s.length + 1) a
    let b := s.walk (s.length + 1) b
    match a, b with
    | (sa, .var v), (sb, .var w) =>
        if sa == sb && v == w then some s else some (((sa, v), b) :: s)
    | (sa, .var v), t => some (((sa, v), t) :: s)
    | t, (sb, .var w) => some (((sb, w), t) :: s)
    | (_, .lit n), (_, .lit m) => if n == m then some s else none
    | (sa, .mul k d), (sb, .mul k' d') =>
        if k == k' then unifyDim fuel s (sa, d) (sb, d') else none
    | (sa, .add a1 a2), (sb, .add b1 b2) => do
        let s ← unifyDim fuel s (sa, a1) (sb, b1)
        unifyDim fuel s (sa, a2) (sb, b2)
    | (sa, .div d k), (sb, .div d' k') =>
        if k == k' then unifyDim fuel s (sa, d) (sb, d') else none
    | _, _ => none

def unifyDims (fuel : Nat) (s : Subst) : List Dim → List Dim → Option Subst
  | [], [] => some s
  | a :: as, b :: bs => do unifyDims fuel (← unifyDim fuel s (false, a) (true, b)) as bs
  | _, _ => none

def unifyLayout (fuel : Nat) (s : Subst) : Layout → Layout → Option Subst
  | .rowMajor, .rowMajor | .colMajor, .colMajor => some s
  | .strided as, .strided bs => unifyDims fuel s as bs
  | .tiled t a, .tiled t' b => if t == t' then unifyLayout fuel s a b else none
  | _, _ => none

def unifyTy (fuel : Nat) (s : Subst) (a b : TensorTy) : Option Subst := do
  guard (a.dtype == b.dtype && a.mem == b.mem && a.align == b.align)
  let s ← unifyDims fuel s a.shape b.shape
  unifyLayout fuel s a.layout b.layout

/-- Does left's type unify with right's? The substitution, if so. -/
def unify (a b : TensorTy) : Option Subst := unifyTy 64 [] a b

def unifyAll (s : Subst) : List TensorTy → List TensorTy → Option Subst
  | [], [] => some s
  | a :: as, b :: bs => do unifyAll (← unifyTy 64 s a b) as bs
  | _, _ => none

/-- Bind a signature's variables by unifying a prefix of its inputs
    (`sigIns`, symbolic) against upstream outputs (`concrete`, literal);
    variables the shape does not determine come from `fallback`. -/
def bindByShape (sig : KernelSig) (sigIns : List TensorTy) (concrete : List TensorTy)
    (fallback : DimBinding) : Except String DimBinding := do
  let pattern := sigIns.take concrete.length
  let some s := unifyAll [] pattern concrete
    | throw s!"inputs ({String.intercalate ", " (pattern.map TensorTy.describe)}) do not unify with upstream ({String.intercalate ", " (concrete.map TensorTy.describe)})"
  let assign ← sig.vars.mapM fun v =>
    match s.walk (s.length + 1) (false, .var v) with
    | (_, .lit n) => pure (v, n)
    | _ => match fallback.lookup v with
      | some n => pure (v, n)
      | none => throw s!"shape variable {v.name} is neither determined upstream nor bound"
  DimBinding.make assign

end Kernels
