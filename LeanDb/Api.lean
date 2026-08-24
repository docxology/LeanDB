import LeanDb.Examples.Gpu
import LeanDb.Examples.Hotel
import LeanDb.Examples.Restaurant

namespace LeanDb.Api
open LeanDb
open LeanDb.Examples

inductive ApiError where
  | usage (message : String)
  | unknownCommand (command : String)
  | unknownOption (option : String)
  | missingValue (option : String)
  | invalidNat (option value : String)
  | invalidStrategy (value : String)
  deriving Repr

def ApiError.code : ApiError → String
  | .usage _ => "usage"
  | .unknownCommand _ => "unknown_command"
  | .unknownOption _ => "unknown_option"
  | .missingValue _ => "missing_value"
  | .invalidNat _ _ => "invalid_nat"
  | .invalidStrategy _ => "invalid_strategy"

def ApiError.message : ApiError → String
  | .usage message => message
  | .unknownCommand command => s!"unknown command or query kind: {command}"
  | .unknownOption option => s!"unknown option: {option}"
  | .missingValue option => s!"missing value for {option}"
  | .invalidNat option value => s!"{option} expects a natural number, got: {value}"
  | .invalidStrategy value => s!"strategy must be sorted, pareto, or knee; got: {value}"

def ApiError.toJson (error : ApiError) : String := jsonObject [
  ("ok", "false"),
  ("error", jsonObject [
    ("code", jsonString error.code),
    ("message", jsonString error.message)
  ])
]

private def optionValue (wanted : String) : List String → Except ApiError (Option String)
  | [] => .ok none
  | option :: rest =>
      if option = wanted then
        match rest with
        | [] => .error (.missingValue option)
        | value :: _ =>
            if value.startsWith "--" then .error (.missingValue option)
            else .ok (some value)
      else
        optionValue wanted rest

private def validateOptions (allowed : List String) : List String → Except ApiError Unit
  | [] => .ok ()
  | option :: rest =>
      if !option.startsWith "--" then
        .error (.unknownOption option)
      else if !allowed.contains option then
        .error (.unknownOption option)
      else
        match rest with
        | [] => .error (.missingValue option)
        | value :: tail =>
            if value.startsWith "--" then .error (.missingValue option)
            else validateOptions allowed tail

private def natOption (args : List String) (name : String) (fallback : Nat) : Except ApiError Nat := do
  match ← optionValue name args with
  | none => pure fallback
  | some value =>
      match value.toNat? with
      | some number => pure number
      | none => throw (.invalidNat name value)

private def stringOption (args : List String) (name : String) : Except ApiError (Option String) :=
  optionValue name args

private def strategyOption (args : List String) : Except ApiError Strategy := do
  match ← optionValue "--strategy" args with
  | none => pure .sorted
  | some value =>
      match Strategy.parse? value with
      | some strategy => pure strategy
      | none => throw (.invalidStrategy value)

private def strategyName : Strategy → String
  | .sorted => "sorted"
  | .pareto => "pareto"
  | .knee => "knee"

private def response (kind : String) (strategy : Strategy) (rows : List String) : String :=
  jsonObject [
    ("ok", "true"),
    ("kind", jsonString kind),
    ("strategy", jsonString (strategyName strategy)),
    ("count", toString rows.length),
    ("rows", jsonArray rows)
  ]

private def queryGpus (args : List String) : Except ApiError String := do
  validateOptions ["--min-vram", "--max-price", "--max-power", "--strategy"] args
  let strategy ← strategyOption args
  let request : Gpu.Request := {
    minVramGb := ← natOption args "--min-vram" 0
    maxPriceDollars := ← natOption args "--max-price" 1000000
    maxPowerWatts := ← natOption args "--max-power" 1000000
    strategy
  }
  pure <| response "gpus" strategy (Gpu.query request |>.map Gpu.toJson)

private def queryHotels (args : List String) : Except ApiError String := do
  validateOptions ["--max-nightly", "--min-rating", "--max-distance", "--strategy"] args
  let strategy ← strategyOption args
  let request : Hotel.Request := {
    maxNightlyDollars := ← natOption args "--max-nightly" 1000000
    minRatingTenths := ← natOption args "--min-rating" 0
    maxDistanceTenthsKm := ← natOption args "--max-distance" 1000000
    strategy
  }
  pure <| response "hotels" strategy (Hotel.query request |>.map Hotel.toJson)

private def queryRestaurants (args : List String) : Except ApiError String := do
  validateOptions ["--cuisine", "--max-price-level", "--min-rating", "--max-distance", "--strategy"] args
  let strategy ← strategyOption args
  let request : Restaurant.Request := {
    cuisine := ← stringOption args "--cuisine"
    maxPriceLevel := ← natOption args "--max-price-level" 4
    minRatingTenths := ← natOption args "--min-rating" 0
    maxDistanceTenthsKm := ← natOption args "--max-distance" 1000000
    strategy
  }
  pure <| response "restaurants" strategy (Restaurant.query request |>.map Restaurant.toJson)

private def schemaField (name type : String) (unit : Option String := none) : String :=
  jsonObject <| [("name", jsonString name), ("type", jsonString type)] ++
    (unit.map fun value => ("unit", jsonString value)).toList

private def schemaType (name : String) (fields objectives : List String) : String :=
  jsonObject [
    ("name", jsonString name),
    ("fields", jsonArray fields),
    ("objectives", jsonArray (objectives.map jsonString))
  ]

def schemaJson : String := jsonObject [
  ("ok", "true"),
  ("schema_version", "1"),
  ("types", jsonArray [
    schemaType "Gpu" [
      schemaField "name" "GpuName",
      schemaField "vram_gb" "Nat" (some "GB"),
      schemaField "price_cents" "Money" (some "USD cents"),
      schemaField "throughput_tflops" "Nat" (some "TFLOPS"),
      schemaField "power_watts" "Nat" (some "W")
    ] ["maximize:throughput_tflops", "maximize:vram_gb", "minimize:price_cents", "minimize:power_watts"],
    schemaType "Hotel" [
      schemaField "name" "HotelName",
      schemaField "nightly_cents" "Money" (some "USD cents"),
      schemaField "rating_tenths" "Rating" (some "tenths/50"),
      schemaField "distance_tenths_km" "DistanceKm" (some "0.1 km"),
      schemaField "available" "Bool"
    ] ["maximize:rating_tenths", "minimize:nightly_cents", "minimize:distance_tenths_km"],
    schemaType "Restaurant" [
      schemaField "name" "RestaurantName",
      schemaField "cuisine" "Cuisine",
      schemaField "price_level" "Nat" (some "1-4"),
      schemaField "rating_tenths" "Rating" (some "tenths/50"),
      schemaField "distance_tenths_km" "DistanceKm" (some "0.1 km"),
      schemaField "open_now" "Bool"
    ] ["maximize:rating_tenths", "minimize:price_level", "minimize:distance_tenths_km"]
  ]),
  ("strategies", jsonArray (["sorted", "pareto", "knee"].map jsonString))
]

def helpJson : String := jsonObject [
  ("ok", "true"),
  ("usage", jsonString "leandb schema | leandb query <gpus|hotels|restaurants> [options]"),
  ("examples", jsonArray [
    jsonString "leandb query gpus --min-vram 16 --max-price 1000 --strategy pareto",
    jsonString "leandb query hotels --max-nightly 250 --min-rating 44 --strategy knee",
    jsonString "leandb query restaurants --cuisine Japanese --max-price-level 3"
  ])
]

def run : List String → Except ApiError String
  | [] => .ok helpJson
  | ["help"] => .ok helpJson
  | ["--help"] => .ok helpJson
  | ["schema"] => .ok schemaJson
  | "query" :: "gpus" :: args => queryGpus args
  | "query" :: "hotels" :: args => queryHotels args
  | "query" :: "restaurants" :: args => queryRestaurants args
  | "query" :: kind :: _ => .error (.unknownCommand kind)
  | command :: _ => .error (.unknownCommand command)

end LeanDb.Api
