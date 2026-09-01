import LeanDb.Core

namespace LeanDb

/-! # Select plans

A `SelectPlan` is what the `leandb_plan` elaboration tactic (see
`LeanDb.PlanElab`) reifies out of a `select` predicate at each call site:
a `PushPred` tree over the involved tables — comparisons of columns
against values (captured variables become bound parameters) or against
other columns (equi-joins and general col/col comparisons), null tests,
and/or/negation — plus a count of conjuncts it could not translate.

Pushdown is a *fetch-narrowing prefilter*: the executor sends the pushed
tree as SQL `WHERE` and still applies the original lambda to what comes
back. The lambda remains the semantics; a pushed predicate that
over-filters is a bug the differential tests exist to catch, and anything
the tactic doesn't recognize is simply `tt` (no narrowing) — correct,
just unoptimized.
-/

inductive PushOp where
  | eq | ne | lt | le | gt | ge
  deriving Repr, DecidableEq, BEq

/-- `eq`/`ne` render as `IS`/`IS NOT`: null-safe, so `Option` columns
    compare like the lambda's `==` on `Option` (`none == none` is true). -/
def PushOp.sql : PushOp → String
  | .eq => "IS"
  | .ne => "IS NOT"
  | .lt => "<"
  | .le => "<="
  | .gt => ">"
  | .ge => ">="

def PushOp.negate : PushOp → PushOp
  | .eq => .ne | .ne => .eq | .lt => .ge | .le => .gt | .gt => .le | .ge => .lt

/-- The pushed fragment of a predicate. Columns are addressed by table
    index (position in the `select` list) and column name. -/
inductive PushPred where
  | tt | ff
  | cmp (table : Nat) (col : String) (op : PushOp) (v : Col)
  /-- column-vs-column; across distinct tables this is a join condition. -/
  | cmp2 (t1 : Nat) (c1 : String) (op : PushOp) (t2 : Nat) (c2 : String)
  /-- value-vs-value: arises when a closed-world case split reduces a
      conjunct to a constant compared against a captured parameter. -/
  | cmpVV (a : Col) (op : PushOp) (b : Col)
  | isNull (table : Nat) (col : String)
  | isNotNull (table : Nat) (col : String)
  | and (a b : PushPred)
  | or (a b : PushPred)
  deriving Repr, BEq

namespace PushPred

/-- Simplifying conjunction. -/
def andS : PushPred → PushPred → PushPred
  | .tt, b => b | .ff, _ => .ff
  | a, .tt => a | _, .ff => .ff
  | a, b => .and a b

/-- Simplifying disjunction. -/
def orS : PushPred → PushPred → PushPred
  | .ff, b => b | .tt, _ => .tt
  | a, .ff => a | _, .tt => .tt
  | a, b => .or a b

/-- Evaluate a value/value comparison when both sides are already known:
    `IS`/`IS NOT` null-safe, ordering only within one storage class.
    Anything else (mixed classes, where SQLite's numeric affinity makes
    `1 IS 1.0` true; REAL ordering, where NaN is NULL) is left to SQLite —
    `none` never folds, which is always safe. -/
def evalCmpVV : PushOp → Col → Col → Option Bool
  | .eq, .null, .null => some true
  | .eq, .null, _ | .eq, _, .null => some false
  | .ne, .null, .null => some false
  | .ne, .null, _ | .ne, _, .null => some true
  | .eq, .int a, .int b => some (a == b)
  | .eq, .text a, .text b => some (a == b)
  | .ne, .int a, .int b => some (a != b)
  | .ne, .text a, .text b => some (a != b)
  | op, .int a, .int b => some (holds op (compare a b))
  | op, .text a, .text b => some (holds op (compare a b))
  | _, _, _ => none
where
  holds : PushOp → Ordering → Bool
    | .lt, o => o == .lt | .le, o => o != .gt
    | .gt, o => o == .gt | .ge, o => o != .lt
    | _, _ => false

/-- `cmpVV`, folded when decidable now. A closed-world case split against
    a captured parameter guards each branch with `param IS 'c'`; at plan
    build time the parameter is known, so every guard but one is `ff` and
    the tree collapses to the surviving column conditions before SQL. -/
def cmpVVS (a : Col) (op : PushOp) (b : Col) : PushPred :=
  match evalCmpVV op a b with
  | some true => .tt
  | some false => .ff
  | none => .cmpVV a op b

/-- Exact negation. Order comparisons only arise on `SqlOrd` columns
    (nullable and closed-enum columns do not opt in), so
    `NOT (a < b)` ↔ `a >= b` holds on everything the tactic emits. -/
def neg : PushPred → PushPred
  | .tt => .ff | .ff => .tt
  | .cmp t c op v => .cmp t c op.negate v
  | .cmp2 t1 c1 op t2 c2 => .cmp2 t1 c1 op.negate t2 c2
  | .cmpVV a op b => .cmpVV a op.negate b
  | .isNull t c => .isNotNull t c
  | .isNotNull t c => .isNull t c
  | .and a b => .or a.neg b.neg
  | .or a b => .and a.neg b.neg

/-- Table indices a predicate touches. -/
def tables : PushPred → List Nat
  | .tt | .ff => []
  | .cmp t .. | .isNull t .. | .isNotNull t .. => [t]
  | .cmp2 t1 _ _ t2 _ => [t1, t2]
  | .cmpVV .. => []
  | .and a b | .or a b => (a.tables ++ b.tables).eraseDups

/-- Does the predicate relate two distinct tables? -/
def hasJoin : PushPred → Bool
  | .cmp2 t1 _ _ t2 _ => t1 != t2
  | .and a b | .or a b => a.hasJoin || b.hasJoin
  | _ => false

/-- Top-level conjuncts. -/
def conjuncts : PushPred → List PushPred
  | .and a b => a.conjuncts ++ b.conjuncts
  | .tt => []
  | p => [p]

/-- The part of the predicate pushable onto table `i` alone: the top-level
    conjuncts that touch only `i`. Dropping the rest only widens the fetch
    — never wrong. -/
def forTable (p : PushPred) (i : Nat) : PushPred :=
  (p.conjuncts.filter fun c => c.tables == [i]).foldl andS .tt

/-- Render as SQL. `alias?` qualifies columns (`t0."col"`) for the joined
    executor; `none` leaves them bare for single-table fetches. Returns
    the SQL and the bind values in placeholder order. -/
def render (alias? : Bool) : PushPred → String × Array Col
  | .tt => ("1", #[])
  | .ff => ("0", #[])
  | .cmp t c op v => (s!"{col alias? t c} {op.sql} ?", #[v])
  | .cmp2 t1 c1 op t2 c2 =>
      -- col/col comparison: `IS`/`IS NOT` are valid SQLite binary operators
      (s!"{col alias? t1 c1} {op.sql} {col alias? t2 c2}", #[])
  | .cmpVV a op b => (s!"? {op.sql} ?", #[a, b])
  | .isNull t c => (s!"{col alias? t c} IS NULL", #[])
  | .isNotNull t c => (s!"{col alias? t c} IS NOT NULL", #[])
  | .and a b =>
      let (sa, ba) := a.render alias?
      let (sb, bb) := b.render alias?
      (s!"({sa} AND {sb})", ba ++ bb)
  | .or a b =>
      let (sa, ba) := a.render alias?
      let (sb, bb) := b.render alias?
      (s!"({sa} OR {sb})", ba ++ bb)
where
  col (alias? : Bool) (t : Nat) (c : String) : String :=
    if alias? then s!"t{t}.\"{c}\"" else s!"\"{c}\""

def describe (p : PushPred) : String := (p.render true).1

end PushPred

/-- The reified plan for one `select` call site. -/
structure SelectPlan where
  pred : PushPred := .tt
  /-- Conjuncts the tactic could not translate (left to the lambda). -/
  residual : Nat := 0
  deriving Repr

def SelectPlan.empty : SelectPlan := {}

def SelectPlan.describe (p : SelectPlan) : String :=
  s!"pushed: {p.pred.describe}, residual conjuncts: {p.residual}"

/-- Marker type carrying the predicate in its *type*, so the `leandb_plan`
    default-argument tactic can reflect the actual call-site lambda from
    its goal. Runtime-wise this is just `SelectPlan`. -/
def PlanFor {ρ : Type} (_where' : ρ → Bool) : Type := SelectPlan

instance : Inhabited (PlanFor p) := ⟨SelectPlan.empty⟩

def PlanFor.plan (p : PlanFor w) : SelectPlan := p

end LeanDb
