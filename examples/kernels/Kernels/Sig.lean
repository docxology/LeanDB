import Kernels.Scalars

/-! # Signatures as data

A kernel is shape-polymorphic (`∀ M N K, T[M,K] → T[K,N] → T[M,N]`); a row
cannot hold a Π-type, so it holds the *code* of one — `KernelSig` — and
Lean interprets it (`instantiate`, `unify`, `Prog`). Every type here is
ordinary Lean with derived JSON instances: payload-carrying sums and
nested lists are fine because none of them is ever a bare column. The one
column is `KernelSig` itself, stored as one compressed JSON TEXT through
`ColCodec.via` — opaque to SQL, which is precisely what this base is
measuring (README).

Invariants live in `KernelSig.make`, and the `FromJson` instance goes
through it, so the JSON boundary (CLI `insert`, the SQLite codec) refuses
a malformed signature the same way the Lean constructor path does. -/

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
  deriving Repr, DecidableEq, Lean.ToJson, Lean.FromJson

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
  deriving Repr, DecidableEq, Lean.ToJson, Lean.FromJson

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
  deriving Repr, DecidableEq, Lean.ToJson, Lean.FromJson

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

inductive DimConstraint where
  | divides (k : Nat) (d : Dim)
  | le (a b : Dim)
  | eq (a b : Dim)
  deriving Repr, DecidableEq, Lean.ToJson, Lean.FromJson

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

/-- The signature. A `KernelSig` that exists is well-formed: every
    variable in `ins`/`outs`/`constraints` is bound in `vars`, every
    variable in an output appears in some input (outputs are determined),
    and there is at least one input and one output (the search columns
    `inDtype0`/`outDtype0`/`rank0` are read from them). -/
structure KernelSig where
  vars        : List DimVar
  ins         : List TensorTy
  outs        : List TensorTy
  scalars     : List (ScalarName × DType)
  constraints : List DimConstraint
  deriving Repr, DecidableEq, Lean.ToJson

def KernelSig.make (vars : List DimVar) (ins outs : List TensorTy)
    (scalars : List (ScalarName × DType) := []) (constraints : List DimConstraint := []) :
    Except String KernelSig := do
  if vars.eraseDups.length != vars.length then throw "duplicate shape variable"
  if ins.isEmpty then throw "a kernel needs at least one input"
  if outs.isEmpty then throw "a kernel needs at least one output"
  let inVars := ins.flatMap TensorTy.vars
  let used := inVars ++ outs.flatMap TensorTy.vars ++ constraints.flatMap DimConstraint.vars
  for v in used do
    unless vars.contains v do throw s!"shape variable {v.name} is used but not declared in vars"
  for v in outs.flatMap TensorTy.vars do
    unless inVars.contains v do throw s!"output shape variable {v.name} appears in no input"
  return { vars, ins, outs, scalars, constraints }

/-- Decoding goes through `make`: JSON that names an undeclared variable
    is refused at the boundary, whether it arrives from the CLI or from a
    row written by an older build. -/
instance : Lean.FromJson KernelSig where
  fromJson? j := do
    let vars ← j.getObjValAs? (List DimVar) "vars"
    let ins ← j.getObjValAs? (List TensorTy) "ins"
    let outs ← j.getObjValAs? (List TensorTy) "outs"
    let scalars ← j.getObjValAs? (List (ScalarName × DType)) "scalars"
    let constraints ← j.getObjValAs? (List DimConstraint) "constraints"
    KernelSig.make vars ins outs scalars constraints

/-- The one nested column: compressed JSON TEXT. SQL sees a string. -/
instance : ColCodec KernelSig :=
  ColCodec.via (fun s => (Lean.toJson s).compress)
               (fun t => Lean.Json.parse t >>= Lean.fromJson?)

def KernelSig.describe (s : KernelSig) : String :=
  let ins := String.intercalate ", " (s.ins.map TensorTy.describe)
  let outs := String.intercalate ", " (s.outs.map TensorTy.describe)
  let vars := String.intercalate " " (s.vars.map (·.name))
  let cs := if s.constraints.isEmpty then "" else
    s!" where {String.intercalate ", " (s.constraints.map DimConstraint.describe)}"
  s!"∀ {vars}, ({ins}) → ({outs}){cs}"

/-- Instantiate at a binding: the monomorphic in/out types, or a named
    reason (unbound variable, violated constraint). -/
def KernelSig.instantiate (s : KernelSig) (b : DimBinding) :
    Except String (List TensorTy × List TensorTy) := do
  let env := b.lookup
  for v in s.vars do
    if (env v).isNone then throw s!"binding {b} leaves {v.name} unbound"
  for c in s.constraints do
    unless ← c.holds env do throw s!"constraint {c.describe} fails at {b}"
  let ins ← s.ins.mapM (·.instantiate env)
  let outs ← s.outs.mapM (·.instantiate env)
  return (ins, outs)

/-- Boolean form of "instantiating `s` at `b` gives exactly `ins`/`outs`";
    `Prog.kernel` carries a proof that it is `true`, obtained by `if h :`
    on fetched rows and by `rfl` on closed terms. -/
def KernelSig.instantiates (s : KernelSig) (b : DimBinding) (ins outs : List TensorTy) : Bool :=
  match s.instantiate b with
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
    (`pattern`, symbolic) against upstream outputs (`concrete`, literal);
    variables the shape does not determine come from `fallback`. -/
def bindByShape (sig : KernelSig) (concrete : List TensorTy) (fallback : DimBinding) :
    Except String DimBinding := do
  let pattern := sig.ins.take concrete.length
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
