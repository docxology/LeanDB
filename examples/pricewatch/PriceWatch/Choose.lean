import PriceWatch.Entities

/-! # Tradeoff selection — the decision layer over `select`

The queries this base exists for are decision queries: hard constraints
plus "give me the best tradeoff" over competing objectives (price down,
rating up, delivery down). `select` answers the constraints in SQL; these
pure functions pick from the feasible set — Pareto front, or the knee
(the normalized max–min compromise). Ordinary Lean over the results:
no engine support needed, and the whole pipeline stays typed. -/

namespace PriceWatch

open LeanDb

inductive Direction where
  | minimize | maximize
  deriving Repr, DecidableEq

structure Objective (ρ : Type) where
  direction : Direction
  score : ρ → Nat

def dominates (objectives : List (Objective ρ)) (a b : ρ) : Bool :=
  !objectives.isEmpty
    && objectives.all (fun o => match o.direction with
        | .minimize => o.score a ≤ o.score b
        | .maximize => o.score a ≥ o.score b)
    && objectives.any (fun o => match o.direction with
        | .minimize => o.score a < o.score b
        | .maximize => o.score a > o.score b)

/-- Rows not dominated on every objective. -/
def paretoFront (objectives : List (Objective ρ)) (rows : Array ρ) : Array ρ :=
  rows.filter fun candidate =>
    !(rows.any fun challenger => dominates objectives challenger candidate)

private def utility (rows : Array ρ) (o : Objective ρ) (r : ρ) : Nat :=
  let scores := rows.map o.score
  let low := scores.foldl min (o.score r)
  let high := scores.foldl max (o.score r)
  if high == low then 1000000
  else
    let numerator := match o.direction with
      | .maximize => o.score r - low
      | .minimize => high - o.score r
    numerator * 1000000 / (high - low)

/-- The knee: the Pareto row maximizing its worst normalized objective —
    a deterministic "balanced best". Ties keep first-seen order. -/
def knee? (objectives : List (Objective ρ)) (rows : Array ρ) : Option ρ :=
  let front := paretoFront objectives rows
  front.foldl (init := none) fun best candidate =>
    match best with
    | none => some candidate
    | some b =>
        let worst := fun r => objectives.foldl (fun acc o => min acc (utility front o r)) 1000000
        if worst candidate > worst b then some candidate else best

/-- Cheap · well-rated · fast: the standard shopping tradeoff for a
    (Product, Listing) row. Missing ratings score 0, missing delivery
    estimates score 30 days — absent data never wins a tradeoff. -/
def shoppingObjectives : List (Objective (Stored Product × Stored Listing)) := [
  ⟨.minimize, fun (_, l) => l.val.price.minor⟩,
  ⟨.maximize, fun (_, l) => ((l.val.rating.map (·.tenths)).getD 0) * 1000
      + min ((l.val.reviews.getD 0) / 10) 999⟩,
  ⟨.minimize, fun (_, l) => l.val.deliveryDays.getD 30⟩]

end PriceWatch
