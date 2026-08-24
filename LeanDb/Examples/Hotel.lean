import LeanDb.Examples.Common

namespace LeanDb.Examples.Hotel
open LeanDb

structure HotelName where value : TextValue deriving Repr, DecidableEq, Inhabited

structure Hotel where
  name : HotelName
  nightly : Money
  rating : Rating
  distance : DistanceKm
  available : Bool
  deriving Repr

private def name! (value : String) : HotelName :=
  match TextValue.create "hotel.name" value with
  | .ok text => ⟨text⟩
  | .error _ => panic! "invalid built-in hotel name"

private def rating! (tenths : Nat) : Rating :=
  if h : tenths ≤ 50 then ⟨tenths, h⟩ else panic! "invalid built-in rating"

def rows : List Hotel := [
  ⟨name! "Harbor House", Money.dollars 170, rating! 44, ⟨12⟩, true⟩,
  ⟨name! "Market Street Inn", Money.dollars 230, rating! 48, ⟨4⟩, true⟩,
  ⟨name! "Juniper Lodge", Money.dollars 135, rating! 41, ⟨25⟩, true⟩,
  ⟨name! "Grand Meridian", Money.dollars 390, rating! 49, ⟨2⟩, true⟩,
  ⟨name! "Civic Suites", Money.dollars 155, rating! 43, ⟨7⟩, false⟩
]

structure Request where
  maxNightlyDollars : Nat := 1000000
  minRatingTenths : Nat := 0
  maxDistanceTenthsKm : Nat := 1000000
  strategy : Examples.Strategy := .sorted

def constraints (request : Request) : List (Constraint Hotel) := [
  ⟨"available", (fun hotel => hotel.available)⟩,
  ⟨"maximum_nightly", (fun hotel => hotel.nightly.cents ≤ request.maxNightlyDollars * 100)⟩,
  ⟨"minimum_rating", (fun hotel => hotel.rating.tenths ≥ request.minRatingTenths)⟩,
  ⟨"maximum_distance", (fun hotel => hotel.distance.tenths ≤ request.maxDistanceTenthsKm)⟩
]

def objectives : List (Objective Hotel) := [
  ⟨"rating_tenths", .maximize, (fun hotel => hotel.rating.tenths)⟩,
  ⟨"nightly_cents", .minimize, (fun hotel => hotel.nightly.cents)⟩,
  ⟨"distance_tenths_km", .minimize, (fun hotel => hotel.distance.tenths)⟩
]

def query (request : Request) : List Hotel :=
  let candidates := feasible (constraints request) rows
  Examples.choose request.strategy objectives (fun hotel => hotel.rating.tenths) candidates

def toJson (hotel : Hotel) : String := jsonObject [
  ("name", jsonString hotel.name.value.raw),
  ("nightly_cents", toString hotel.nightly.cents),
  ("rating_tenths", toString hotel.rating.tenths),
  ("distance_tenths_km", toString hotel.distance.tenths),
  ("available", jsonBool hotel.available)
]

end LeanDb.Examples.Hotel
