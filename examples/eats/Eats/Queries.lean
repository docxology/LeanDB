import Eats.Entities

/-! # Queries

Domain logic as plain defs over `select`. Each docstring says what pushes
to SQL and what stays residual (`eats log` shows the plan per call).
Dishes are named by slug and resolved once, in `resolveDish` — the one
place LEP-0001 row symbols will slot in. -/

namespace Eats

open LeanDb

/-! ## Vocabulary helpers -/

/-- Every diet a dish satisfies, given its ingredient rows: a fold over
    the closed world — no table, no tag. An ingredient passes if the diet
    allows its kind or it can be left out. -/
def dietsOk (ings : Array (Stored DishIngredient × Stored Ingredient)) : List Diet :=
  (ClosedEnum.all (α := Diet)).toList.filter fun d =>
    ings.all fun (di, i) => d.allows i.val.kind || di.val.removable

/-- Is the kitchen taking orders at `t`? The `if` on a column comparison
    reifies as `(c ∧ t) ∨ (¬c ∧ e)`, each comparison pushes through
    `.minutes`, and the midnight wrap (`closes < opens`) is the
    disjunction — residual 0. -/
@[db] def Hours.servesAt (h : Hours) (t : Clock) : Bool :=
  if h.closes.minutes < h.opens.minutes
  then t.minutes ≥ h.opens.minutes || t.minutes < h.lastOrder.minutes
  else h.opens.minutes ≤ t.minutes && t.minutes < h.lastOrder.minutes

/-- The canonical row behind a slug, or a typed `decode` error naming the
    slug (`notFound` addresses rows by id; a slug is not one). Slug
    equality pushes through the `Slug` codec. -/
def resolveDish (slug : Slug) : DbM (Stored CanonicalDish) := do
  let rows ← select [CanonicalDish] (fun c => c.val.slug == slug)
  match rows[0]? with
  | some c => pure c
  | none => throw (.decode "canonical_dish" "slug" s!"no canonical dish with slug {String.quote slug.raw}")

/-! ## The query universe -/

/-- "Average cost of a chai latte in San Francisco": the join, the city,
    the canonical reference and `available` all push; the mean is a Lean
    fold over the fetch (aggregates are not a verb yet, study §3.5).
    `none` when no restaurant in the city lists the dish. -/
def avgPrice (dish : Slug) (city : City) : DbM (Option Money) := do
  let cd ← resolveDish dish
  let rows ← select [Dish, Restaurant] (fun (d, r) =>
    d.val.restaurant == r.ref && d.val.canonical == cd.ref
      && r.val.city == city && d.val.available)
  if rows.isEmpty then return none
  let total := rows.foldl (fun acc (d, _) => acc + d.val.price.minor) 0
  return some ⟨total / rows.size⟩

/-- "Where can I get tiramisu on Friday after 9 PM?" Two joins, the dish,
    the weekday and `Hours.servesAt` all push — including the midnight
    wrap; residual 0. Restaurant name order. -/
def openFor (dish : Slug) (day : Weekday) (t : Clock) :
    DbM (Array (Stored Restaurant × Stored Dish × Stored Hours)) := do
  let cd ← resolveDish dish
  select [Restaurant, Dish, Hours] (fun (r, d, h) =>
    d.val.restaurant == r.ref && h.val.restaurant == r.ref
      && d.val.canonical == cd.ref && d.val.available
      && h.val.day == day && h.val.servesAt t)
    (.key fun (r, _, _) => r.val.name)

/-- Candidate dishes of a family in a city whose ingredient list is
    complete — the only dishes a dietary answer may mention. -/
private def candidates (fam : DishFamily) (city : City) :
    DbM (Array (Stored Dish × Stored Restaurant × Stored CanonicalDish)) :=
  select [Dish, Restaurant, CanonicalDish] (fun (d, r, c) =>
    d.val.restaurant == r.ref && d.val.canonical == c.ref
      && c.val.family == fam && r.val.city == city && d.val.available
      && d.val.ingredientsComplete)
    (.key fun (_, r, _) => r.val.name)

/-- The anti-join: drop every candidate that has an offending ingredient
    row. In Lean, over two fetches. -/
private def antiJoin (dishes : Array (Stored Dish × Stored Restaurant × Stored CanonicalDish))
    (offending : Array (Stored DishIngredient × Stored Ingredient)) :
    Array (Stored Dish × Stored Restaurant) :=
  let bad := offending.map (·.1.val.dish)
  dishes.filterMap fun (d, r, _) => if bad.contains d.ref then none else some (d, r)

/-- "Places that serve ramen I can eat" — vegetarian, or no pork/beef.
    The question is `∀` over a child table: every ingredient row of the
    dish is allowed by the diet or removable. No lambda over the outer
    rows can say that — it mentions rows they were not given — so the plan
    is written as data (LEP-0004): `pred%` reifies the candidate filter
    exactly as `select` would, `Pred.all` quantifies over `DishIngredient`
    rows keyed to the dish, and an inner `Pred.exists` reaches the 1:1
    `Ingredient` row (a join expressed as a quantifier, exact because the
    key is 1:1).

    Everything pushes, residual 0: one `selectP`, rendering the quantifier
    as a correlated `NOT EXISTS` subquery with the captured `diet`
    case-split into a closed `kind IS ?` disjunction inside it (`eats log`
    shows the plan). Absence of data is not a guarantee: only dishes with
    `ingredientsComplete` are candidates. `suitableTwoPhase` is the same
    question as two fetches and a set difference in Lean; the tests hold
    the two equal on every `(family, diet, city)` in the seed. -/
def suitable (fam : DishFamily) (diet : Diet) (city : City) :
    DbM (Array (Stored Dish × Stored Restaurant)) := do
  let rows ← selectP [Dish, Restaurant, CanonicalDish]
    (.and
      (pred% [Dish, Restaurant, CanonicalDish] fun (d, r, c) =>
        d.val.restaurant == r.ref && d.val.canonical == c.ref
          && c.val.family == fam && r.val.city == city
          && d.val.available && d.val.ingredientsComplete)
      (Pred.all (.here DishIngredient.Field.dish)
        (Pred.exists (.here DishIngredient.Field.ingredient) .id
          (pred% [Ingredient, DishIngredient, Dish, Restaurant, CanonicalDish]
            fun (i, di, _, _, _) => diet.allows i.val.kind || di.val.removable))))
    (.key fun (_, r, _) => r.val.name)
  return rows.map fun (d, r, _) => (d, r)

/-- `suitable` before LEP-0004, kept as the differential's reference:
    the candidates, then every offending ingredient row, then the set
    difference in Lean (`antiJoin`). Both fetches push with residual 0 —
    on the ingredient side the join, `!removable`, and `diet.allows` via
    the same case split — but the `∀` itself never reaches SQL. -/
def suitableTwoPhase (fam : DishFamily) (diet : Diet) (city : City) :
    DbM (Array (Stored Dish × Stored Restaurant)) := do
  let dishes ← candidates fam city
  let offending ← select [DishIngredient, Ingredient] (fun (di, i) =>
    di.val.ingredient == i.ref && !di.val.removable && !(diet.allows i.val.kind))
  return antiJoin dishes offending

/-- A diet typed on the command line: `--avoid pork,beef,shellfish`. -/
structure AdHocDiet where
  avoid : List IngredientKind
  deriving Repr

/-- The same question for an ad-hoc diet, in the two-phase form: the
    ingredient conjunct is residual *by nature* — the planner cannot emit
    a disjunction whose length it does not know at compile time — and a
    residual inside a quantifier body would only widen its subquery to
    vacuous truth. Closed profiles push; ad-hoc ones do not. -/
def suitableAdHoc (fam : DishFamily) (diet : AdHocDiet) (city : City) :
    DbM (Array (Stored Dish × Stored Restaurant)) := do
  let dishes ← candidates fam city
  let offending ← select [DishIngredient, Ingredient] (fun (di, i) =>
    di.val.ingredient == i.ref && !di.val.removable && diet.avoid.contains i.val.kind)
  return antiJoin dishes offending

/-- Every diet one dish satisfies, from its ingredient rows. `[]` for a
    dish whose ingredient list is incomplete — not even `.omnivore`, which
    every complete dish satisfies — because absence of data is not a
    dietary guarantee. -/
def dietsFor (dish : Ref Dish) : DbM (List Diet) := do
  let some d ← get dish | throw (.notFound "dish" dish.toInt64)
  unless d.val.ingredientsComplete do return []
  let ings ← select [DishIngredient, Ingredient] (fun (di, i) =>
    di.val.ingredient == i.ref && di.val.dish == dish)
  return dietsOk ings

/-- The price of a dish with modifications applied, clamped at zero.
    `mods` must all belong to the dish; a stranger is `not_found`. The
    dish filter pushes; membership in a runtime list is residual. -/
def priceWith (dish : Ref Dish) (mods : List (Ref Modification)) : DbM Money := do
  let some d ← get dish | throw (.notFound "dish" dish.toInt64)
  let chosen ← select [Modification] (fun m => m.val.dish == dish && mods.contains m.ref)
  for m in mods do
    unless chosen.any (·.ref == m) do throw (.notFound "modification" m.toInt64)
  let total := chosen.foldl (fun acc m => acc + m.val.delta.minor) (Int64.ofNat d.val.price.minor)
  return ⟨total.toNatClampNeg⟩

/-- Great-circle distance in metres between two points, for the residual
    cut of `nearby`. -/
def haversineM (lat1 lon1 lat2 lon2 : MicroDeg) : Float :=
  let rad := fun (d : MicroDeg) => d.toDegrees * 3.141592653589793 / 180.0
  let φ1 := rad lat1
  let φ2 := rad lat2
  let dφ := φ2 - φ1
  let dl := rad lon2 - rad lon1
  let sq := fun (x : Float) => x * x
  let a := sq (Float.sin (dφ / 2)) + Float.cos φ1 * Float.cos φ2 * sq (Float.sin (dl / 2))
  2 * 6371000.0 * Float.asin (Float.sqrt a)

/-- Restaurants within `radiusM` metres of a point. A deliberately loose
    bounding box pushes as four ordered comparisons on the integer
    microdegree columns (1 m ≈ 9 µ° of latitude and ≈ 11 µ° of longitude
    at the Bay's latitude; the box uses 10 and 15); the exact haversine
    is residual, correctly — it is `Float` arithmetic. -/
def nearby (lat lon : MicroDeg) (radiusM : Nat) : DbM (Array (Stored Restaurant)) := do
  let dLat := Int64.ofNat (radiusM * 10)
  let dLon := Int64.ofNat (radiusM * 15)
  let box ← select [Restaurant] (fun r =>
    r.val.lat.micro ≥ lat.micro - dLat && r.val.lat.micro ≤ lat.micro + dLat
      && r.val.lon.micro ≥ lon.micro - dLon && r.val.lon.micro ≤ lon.micro + dLon)
    (.key (·.val.name))
  return box.filter fun r => haversineM lat lon r.val.lat r.val.lon ≤ radiusM.toFloat

/-- Price history of one dish, newest first. The dish filter pushes. -/
def history (dish : Ref Dish) : DbM (Array (Stored PriceObs)) :=
  select [PriceObs] (fun p => p.val.dish == dish) (.desc (.key (·.val.observedAt)))

end Eats
