import LeanDb.Core
import LeanDb.Query

namespace LeanDb.Examples

inductive Strategy where
  | sorted
  | pareto
  | knee
  deriving Repr, DecidableEq

def Strategy.parse? : String → Option Strategy
  | "sorted" => some .sorted
  | "pareto" => some .pareto
  | "knee" => some .knee
  | _ => none

def choose (strategy : Strategy) (objectives : List (Objective α))
    (defaultScore : α → Nat) (values : List α) : List α :=
  match strategy with
  | .sorted => descendingBy defaultScore values
  | .pareto => paretoFront objectives values
  | .knee => (knee? objectives values).toList

end LeanDb.Examples
