import LeanDb.Examples.Common

namespace LeanDb.Examples.Restaurant
open LeanDb

structure RestaurantName where value : TextValue deriving Repr, DecidableEq, Inhabited
structure Cuisine where value : TextValue deriving Repr, DecidableEq, Inhabited

structure Restaurant where
  name : RestaurantName
  cuisine : Cuisine
  priceLevel : Nat
  rating : Rating
  distance : DistanceKm
  openNow : Bool
  deriving Repr

private def text! (field value : String) : TextValue :=
  match TextValue.create field value with
  | .ok text => text
  | .error _ => panic! "invalid built-in restaurant text"

private def rating! (tenths : Nat) : Rating :=
  if h : tenths ≤ 50 then ⟨tenths, h⟩ else panic! "invalid built-in rating"

def rows : List Restaurant := [
  ⟨⟨text! "restaurant.name" "Saffron Table"⟩, ⟨text! "cuisine" "Indian"⟩, 2, rating! 47, ⟨18⟩, true⟩,
  ⟨⟨text! "restaurant.name" "Nori Counter"⟩, ⟨text! "cuisine" "Japanese"⟩, 3, rating! 49, ⟨9⟩, true⟩,
  ⟨⟨text! "restaurant.name" "Pasta Workshop"⟩, ⟨text! "cuisine" "Italian"⟩, 2, rating! 45, ⟨5⟩, true⟩,
  ⟨⟨text! "restaurant.name" "Taco Norte"⟩, ⟨text! "cuisine" "Mexican"⟩, 1, rating! 43, ⟨7⟩, true⟩,
  ⟨⟨text! "restaurant.name" "Green Ember"⟩, ⟨text! "cuisine" "Vegetarian"⟩, 2, rating! 46, ⟨12⟩, false⟩
]

structure Request where
  cuisine : Option String := none
  maxPriceLevel : Nat := 4
  minRatingTenths : Nat := 0
  maxDistanceTenthsKm : Nat := 1000000
  strategy : Examples.Strategy := .sorted

private def cuisineMatches (wanted : Option String) (restaurant : Restaurant) : Bool :=
  match wanted with
  | none => true
  | some value => restaurant.cuisine.value.raw.toLower = value.toLower

def constraints (request : Request) : List (Constraint Restaurant) := [
  ⟨"open_now", (fun restaurant => restaurant.openNow)⟩,
  ⟨"cuisine", cuisineMatches request.cuisine⟩,
  ⟨"maximum_price_level", (fun restaurant => restaurant.priceLevel ≤ request.maxPriceLevel)⟩,
  ⟨"minimum_rating", (fun restaurant => restaurant.rating.tenths ≥ request.minRatingTenths)⟩,
  ⟨"maximum_distance", (fun restaurant => restaurant.distance.tenths ≤ request.maxDistanceTenthsKm)⟩
]

def objectives : List (Objective Restaurant) := [
  ⟨"rating_tenths", .maximize, (fun restaurant => restaurant.rating.tenths)⟩,
  ⟨"price_level", .minimize, (fun restaurant => restaurant.priceLevel)⟩,
  ⟨"distance_tenths_km", .minimize, (fun restaurant => restaurant.distance.tenths)⟩
]

def query (request : Request) : List Restaurant :=
  let candidates := feasible (constraints request) rows
  Examples.choose request.strategy objectives (fun restaurant => restaurant.rating.tenths) candidates

def toJson (restaurant : Restaurant) : String := jsonObject [
  ("name", jsonString restaurant.name.value.raw),
  ("cuisine", jsonString restaurant.cuisine.value.raw),
  ("price_level", toString restaurant.priceLevel),
  ("rating_tenths", toString restaurant.rating.tenths),
  ("distance_tenths_km", toString restaurant.distance.tenths),
  ("open_now", jsonBool restaurant.openNow)
]

end LeanDb.Examples.Restaurant
