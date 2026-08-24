import LeanDb.Examples.Common

namespace LeanDb.Examples.Gpu
open LeanDb

structure GpuName where
  value : TextValue
  deriving Repr, DecidableEq, Inhabited

structure Gpu where
  name : GpuName
  vramGb : Nat
  price : Money
  throughput : Nat
  powerWatts : Nat
  deriving Repr

private def name! (value : String) : GpuName :=
  match TextValue.create "gpu.name" value with
  | .ok text => ⟨text⟩
  | .error _ => panic! "invalid built-in GPU name"

def rows : List Gpu := [
  ⟨name! "Arc B580", 12, Money.dollars 249, 13, 190⟩,
  ⟨name! "RTX 4070 Super", 12, Money.dollars 599, 36, 220⟩,
  ⟨name! "RX 7900 GRE", 16, Money.dollars 549, 46, 260⟩,
  ⟨name! "RTX 4080 Super", 16, Money.dollars 999, 52, 320⟩,
  ⟨name! "RTX 4090", 24, Money.dollars 1599, 83, 450⟩
]

structure Request where
  minVramGb : Nat := 0
  maxPriceDollars : Nat := 1000000
  maxPowerWatts : Nat := 1000000
  strategy : Examples.Strategy := .sorted

def constraints (request : Request) : List (Constraint Gpu) := [
  ⟨"minimum_vram", fun gpu => gpu.vramGb ≥ request.minVramGb⟩,
  ⟨"maximum_price", fun gpu => gpu.price.cents ≤ request.maxPriceDollars * 100⟩,
  ⟨"maximum_power", fun gpu => gpu.powerWatts ≤ request.maxPowerWatts⟩
]

def objectives : List (Objective Gpu) := [
  ⟨"throughput", .maximize, (fun gpu => gpu.throughput)⟩,
  ⟨"vram_gb", .maximize, (fun gpu => gpu.vramGb)⟩,
  ⟨"price_cents", .minimize, (fun gpu => gpu.price.cents)⟩,
  ⟨"power_watts", .minimize, (fun gpu => gpu.powerWatts)⟩
]

def query (request : Request) : List Gpu :=
  let candidates := feasible (constraints request) rows
  Examples.choose request.strategy objectives (fun gpu => gpu.throughput) candidates

def toJson (gpu : Gpu) : String := jsonObject [
  ("name", jsonString gpu.name.value.raw),
  ("vram_gb", toString gpu.vramGb),
  ("price_cents", toString gpu.price.cents),
  ("throughput_tflops", toString gpu.throughput),
  ("power_watts", toString gpu.powerWatts)
]

end LeanDb.Examples.Gpu
