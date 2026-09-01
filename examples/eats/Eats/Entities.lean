import Eats.Scalars
import Eats.Enums

/-! # Entities

The open world: canonical dishes, restaurants, their hours, their menus,
and the ingredient rows the dietary questions quantify over. Note what is
*absent*: no dish carries a diet tag, no restaurant carries an "open now"
flag. Both are computed. -/

namespace Eats

open LeanDb

/-- The vocabulary of dishes: open (thousands, grows weekly) but queried
    *by name in code* — `avgPrice "chai-latte"` today, `KnownDish.chaiLatte`
    once LEP-0001 row symbols land. `slug` is the stable key. -/
structure CanonicalDish where
  slug    : Slug
  display : DisplayName
  family  : DishFamily
  course  : Course
  deriving Repr, LeanDb.Entity

structure Restaurant where
  name         : RestaurantName
  city         : City
  neighborhood : Neighborhood
  lat          : MicroDeg
  lon          : MicroDeg
  cuisine      : Cuisine
  priceTier    : PriceTier
  deriving Repr, LeanDb.Entity

/-- One row per (restaurant, weekday); no row means closed that day.
    `closes < opens` means the interval wraps midnight, and the row belongs
    to the service day it *starts* on (Friday 17:00–02:00 is a `fri` row).
    `lastOrder` is what "can I get it after 9 PM" asks. -/
structure Hours where
  restaurant : Ref Restaurant
  day        : Weekday
  opens      : Clock
  lastOrder  : Clock
  closes     : Clock
  deriving Repr, LeanDb.Entity

/-- A menu line. `menuName` is the menu's spelling; `canonical` is what
    it *is*. Suitability is `∀` over ingredient rows, which is vacuously
    true for a dish with none recorded, so an unlisted ramen must read as
    *unknown*, never as vegan: `ingredientsComplete` gates every dietary
    query, and it defaults to `false`. -/
structure Dish where
  restaurant : Ref Restaurant
  canonical  : Ref CanonicalDish
  menuName   : MenuName
  price      : Money
  size       : Option Size
  available  : Bool := true
  ingredientsComplete : Bool := false
  deriving Repr, LeanDb.Entity

structure Ingredient where
  name : IngredientName
  kind : IngredientKind
  deriving Repr, LeanDb.Entity

/-- The child table dietary questions quantify over. `removable` is
    "hold the chashu"; `substitutable` points at what can stand in. -/
structure DishIngredient where
  dish          : Ref Dish
  ingredient    : Ref Ingredient
  removable     : Bool := false
  substitutable : Option (Ref Ingredient)
  deriving Repr, LeanDb.Entity

/-- A priced option on a dish. `removes` says which kind the modification
    takes out, so "ramen, no pork" is data rather than a label match. -/
structure Modification where
  dish    : Ref Dish
  label   : ModLabel
  delta   : Delta
  removes : Option IngredientKind
  deriving Repr, LeanDb.Entity

/-- Observed prices over time; `Dish.price` is the current one. -/
structure PriceObs where
  dish       : Ref Dish
  price      : Money
  observedAt : Timestamp
  source     : Source
  deriving Repr, LeanDb.Entity

/-- FK-dependency order: referenced tables first. -/
def schema : List TableSpec :=
  [Entity.spec CanonicalDish, Entity.spec Restaurant, Entity.spec Ingredient,
   Entity.spec Hours, Entity.spec Dish, Entity.spec DishIngredient,
   Entity.spec Modification, Entity.spec PriceObs]

end Eats
