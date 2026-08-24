import LeanDb.Core

namespace LeanDb

/-! # Select plans

A `SelectPlan` is what the `leandb_plan` elaboration tactic (see
`LeanDb.PlanElab`) reifies out of a `select` predicate at each call site:
the conjuncts it recognized, per table, as SQL-pushable — column compared
to a value (captured variables become bound parameters), and `Option`
null tests.

Pushdown is a *fetch-narrowing prefilter*: the executor sends pushed
conjuncts as SQL `WHERE` and still applies the original lambda to what
comes back. The lambda remains the semantics; a pushed conjunct that
over-filters is a bug the differential tests exist to catch, and anything
the tactic doesn't recognize is simply residual — correct, just unfetched.
-/

inductive PushOp where
  | eq | ne | lt | le | gt | ge
  deriving Repr, DecidableEq, BEq

def PushOp.sql : PushOp → String
  | .eq => "IS"        -- null-safe: also covers Option columns
  | .ne => "IS NOT"
  | .lt => "<"
  | .le => "<="
  | .gt => ">"
  | .ge => ">="

/-- One pushable conjunct over a single table's columns. -/
inductive PushCond where
  | cmp (col : String) (op : PushOp) (v : Col)
  | isNull (col : String)
  | isNotNull (col : String)
  deriving Repr, BEq

def PushCond.describe : PushCond → String
  | .cmp col op v => s!"\"{col}\" {op.sql} {v.describe}"
  | .isNull col => s!"\"{col}\" IS NULL"
  | .isNotNull col => s!"\"{col}\" IS NOT NULL"

/-- The reified plan for one `select` call site. `pushed` pairs a table
    index (position in the `ts` list) with a conjunct on that table;
    `residual` counts predicate conjuncts left to the client-side lambda. -/
structure SelectPlan where
  pushed : Array (Nat × PushCond) := #[]
  residual : Nat := 0
  deriving Repr

def SelectPlan.empty : SelectPlan := {}

/-- Conjuncts pushed onto table `i`. -/
def SelectPlan.forTable (p : SelectPlan) (i : Nat) : Array PushCond :=
  p.pushed.filterMap fun (j, c) => if j == i then some c else none

def SelectPlan.describe (p : SelectPlan) : String :=
  let pushed := p.pushed.toList.map fun (i, c) => s!"t{i}: {c.describe}"
  s!"pushed [{String.intercalate ", " pushed}], residual conjuncts: {p.residual}"

/-- Marker type carrying the predicate in its *type*, so the `leandb_plan`
    default-argument tactic can reflect the actual call-site lambda from
    its goal. Runtime-wise this is just `SelectPlan`. -/
def PlanFor {ρ : Type} (_where' : ρ → Bool) : Type := SelectPlan

instance : Inhabited (PlanFor p) := ⟨SelectPlan.empty⟩

def PlanFor.plan (p : PlanFor w) : SelectPlan := p

end LeanDb
