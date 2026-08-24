import LeanDb

open LeanDb
open LeanDb.Examples

private def check (condition : Bool) (message : String) : IO Unit :=
  unless condition do throw <| IO.userError message

private def testValidation : IO Unit := do
  match TextValue.create "name" "   " with
  | .error _ => pure ()
  | .ok _ => throw <| IO.userError "empty named text must be rejected"
  match TextValue.create "name" "  useful  " with
  | .ok value => check (value.raw == "useful") "named text must be trimmed"
  | .error _ => throw <| IO.userError "valid named text was rejected"

private structure Point where
  name : String
  cost : Nat
  quality : Nat

private def pointObjectives : List (Objective Point) := [
  ⟨"cost", .minimize, (fun point => point.cost)⟩,
  ⟨"quality", .maximize, (fun point => point.quality)⟩
]

private def testPareto : IO Unit := do
  let points : List Point := [⟨"cheap", 1, 4⟩, ⟨"balanced", 2, 7⟩, ⟨"premium", 3, 8⟩, ⟨"dominated", 4, 7⟩]
  let front := paretoFront pointObjectives points
  check (front.length == 3) "Pareto front should remove a dominated point"
  check (!(front.any fun point => point.name == "dominated")) "dominated point leaked into front"
  match knee? pointObjectives points with
  | none => throw <| IO.userError "knee should exist for non-empty input"
  | some point => check (point.name == "balanced") "normalized max-min knee chose the wrong point"

private def testGpuQuery : IO Unit := do
  let request : Gpu.Request := { minVramGb := 16, maxPriceDollars := 1000, strategy := .pareto }
  let result := Gpu.query request
  check (!result.isEmpty) "GPU example should return feasible rows"
  check (result.all fun gpu => gpu.vramGb ≥ 16 && gpu.price.cents ≤ 100000) "GPU constraints were not enforced"

private def testHotelKnee : IO Unit := do
  let request : Hotel.Request := { maxNightlyDollars := 250, minRatingTenths := 40, strategy := .knee }
  check ((Hotel.query request).length == 1) "knee strategy must return one hotel"

private def testRestaurantCuisine : IO Unit := do
  let request : Restaurant.Request := { cuisine := some "jApAnEsE", strategy := .sorted }
  let result := Restaurant.query request
  check (result.length == 1) "cuisine filter should be case-insensitive"
  check (result.head?.map (fun row => row.cuisine.value.raw) == some "Japanese") "wrong cuisine row returned"

def main : IO UInt32 := do
  testValidation
  testPareto
  testGpuQuery
  testHotelKnee
  testRestaurantCuisine
  IO.println "{\"ok\":true,\"tests\":5}"
  pure 0
