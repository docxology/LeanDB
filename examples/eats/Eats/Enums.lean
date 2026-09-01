import LeanDb

/-! # Closed worlds

Cities, weekdays, courses, dish families, ingredient kinds and diets are
vocabulary: stored as TEXT constructor names with a CHECK, never rows.

The dietary vocabulary is the point of this base. **No diet is stored
anywhere.** An `Ingredient` carries a `kind` — pork *is* pork, a fact
about the ingredient — and a `Diet` is nothing but the list of kinds it
forbids. Whether a dish suits a diet is computed from its ingredient rows
at query time; adding `.jain` is a compile-time refactor that walks you to
the one list that defines it, and there is nothing to keep in sync when a
recipe changes.
-/

namespace Eats

/-- Closed for the test base; a `City` table with a `Ref` in production. -/
inductive City where
  | sanFrancisco | oakland | berkeley | paloAlto | sanJose
  deriving Repr, DecidableEq, Ord, LeanDb.ClosedEnum

inductive Weekday where
  | mon | tue | wed | thu | fri | sat | sun
  deriving Repr, DecidableEq, Ord, LeanDb.ClosedEnum

inductive Course where
  | drink | starter | main | dessert | side
  deriving Repr, DecidableEq, Ord, LeanDb.ClosedEnum

/-- The *shape* of a dish. Closed: "ramen" is a family, "Marufuku's
    Hakata tonkotsu" is a canonical dish, "TONKOTSU DX" is a menu name. -/
inductive DishFamily where
  | ramen | pho | curry | pizza | burger | salad | latte | tea | tiramisu | gelato
  | dosa | biryani | pastry
  deriving Repr, DecidableEq, Ord, LeanDb.ClosedEnum

inductive Cuisine where
  | japanese | vietnamese | indian | italian | american | mexican | cafe
  deriving Repr, DecidableEq, Ord, LeanDb.ClosedEnum

inductive PriceTier where
  | budget | mid | upscale
  deriving Repr, DecidableEq, Ord, LeanDb.ClosedEnum

inductive Size where
  | small | regular | large
  deriving Repr, DecidableEq, Ord, LeanDb.ClosedEnum

/-- Where a price observation came from. -/
inductive Source where
  | menu | receipt | deliveryApp | crowd
  deriving Repr, DecidableEq, Ord, LeanDb.ClosedEnum

/-- The only stored classification of an ingredient. A fact, not an
    opinion: no ingredient is "vegetarian", it is `.dairy` or `.pork`. -/
inductive IngredientKind where
  | pork | beef | lamb | chicken | fish | shellfish | egg | dairy
  | gluten | soy | peanut | treeNut | sesame | allium | mushroom | vegetable
  | grain | sugar | alcohol | tea | coffee | spice
  deriving Repr, DecidableEq, Ord, LeanDb.ClosedEnum

/-- Dietary profiles. A query parameter only — no column has this type. -/
inductive Diet where
  | omnivore | noPorkBeef | noBeef | noPork | pescatarian | vegetarian | vegan
  | jain | halal | kosher | glutenFree | nutFree
  deriving Repr, DecidableEq, Ord, LeanDb.ClosedEnum

/-- A diet is the set of kinds it forbids — one list per profile, total
    by `match`. `allows` is derived from it, never written separately. -/
def Diet.forbids : Diet → List IngredientKind
  | .omnivore    => []
  | .noPork      => [.pork]
  | .noBeef      => [.beef]
  | .noPorkBeef  => [.pork, .beef]
  | .pescatarian => [.pork, .beef, .lamb, .chicken]
  | .vegetarian  => [.pork, .beef, .lamb, .chicken, .fish, .shellfish]
  | .vegan       => [.pork, .beef, .lamb, .chicken, .fish, .shellfish, .egg, .dairy]
  | .jain        => [.pork, .beef, .lamb, .chicken, .fish, .shellfish, .egg, .allium, .mushroom]
  | .halal       => [.pork, .alcohol]
  | .kosher      => [.pork, .shellfish]
  | .glutenFree  => [.gluten]
  | .nutFree     => [.peanut, .treeNut]

/-- Derived, and `@[db]` so `select` predicates may unfold it. In a
    predicate the diet is a *captured parameter*: the planner case-splits
    on it and on the `kind` column (study §3.4), each branch reduces to a
    closed `List.contains`, and the conjunct pushes as a disjunction of
    `kind IS ?` — in either match order, with residual 0. -/
@[db] def Diet.allows (d : Diet) (k : IngredientKind) : Bool :=
  !(d.forbids.contains k)

end Eats
