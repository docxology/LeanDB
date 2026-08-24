namespace LeanDb

structure Constraint (α : Type) where
  name : String
  accepts : α → Bool

inductive Direction where
  | minimize
  | maximize
  deriving Repr, DecidableEq

structure Objective (α : Type) where
  name : String
  direction : Direction
  score : α → Nat

def satisfies (constraints : List (Constraint α)) (value : α) : Bool :=
  constraints.all fun constraint => constraint.accepts value

def feasible (constraints : List (Constraint α)) (values : List α) : List α :=
  values.filter (satisfies constraints)

private def noWorse (objective : Objective α) (a b : α) : Bool :=
  match objective.direction with
  | .minimize => objective.score a ≤ objective.score b
  | .maximize => objective.score a ≥ objective.score b

private def strictlyBetter (objective : Objective α) (a b : α) : Bool :=
  match objective.direction with
  | .minimize => objective.score a < objective.score b
  | .maximize => objective.score a > objective.score b

/-- `a` dominates `b` when it is no worse on every objective and strictly
    better on at least one. -/
def dominates (objectives : List (Objective α)) (a b : α) : Bool :=
  !objectives.isEmpty &&
    objectives.all (fun objective => noWorse objective a b) &&
    objectives.any (fun objective => strictlyBetter objective a b)

def paretoFront (objectives : List (Objective α)) (values : List α) : List α :=
  values.filter fun candidate =>
    !(values.any fun challenger => dominates objectives challenger candidate)

private def bounds (objective : Objective α) (values : List α) : Nat × Nat :=
  match values with
  | [] => (0, 0)
  | first :: rest =>
      rest.foldl
        (fun (low, high) value =>
          let score := objective.score value
          (min low score, max high score))
        (objective.score first, objective.score first)

/-- Integer utility in [0, 1_000_000]. A constant objective gives every row
    full utility and therefore does not distort the compromise. -/
private def utility (values : List α) (objective : Objective α) (value : α) : Nat :=
  let (low, high) := bounds objective values
  if high = low then
    1000000
  else
    let numerator := match objective.direction with
      | .maximize => objective.score value - low
      | .minimize => high - objective.score value
    numerator * 1000000 / (high - low)

def compromiseScore (objectives : List (Objective α)) (values : List α) (value : α) : Nat :=
  match objectives with
  | [] => 0
  | first :: rest =>
      rest.foldl (fun score objective => min score (utility values objective value))
        (utility values first value)

/-- Selects a deterministic Pareto "knee": the point maximizing its worst
    normalized objective utility. Ties retain source order. -/
def knee? (objectives : List (Objective α)) (values : List α) : Option α :=
  let front := paretoFront objectives values
  match front with
  | [] => none
  | first :: rest =>
      some <| rest.foldl
        (fun best candidate =>
          if compromiseScore objectives front candidate > compromiseScore objectives front best
          then candidate else best)
        first

def descendingBy (score : α → Nat) (values : List α) : List α :=
  values.toArray.qsort (fun a b => score a > score b) |>.toList

def ascendingBy (score : α → Nat) (values : List α) : List α :=
  values.toArray.qsort (fun a b => score a < score b) |>.toList

end LeanDb
