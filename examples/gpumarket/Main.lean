import GpuMarket

/-! The gpumarket CLI. Query names and arities are `query%`-derived from
the defs in `GpuMarket/Queries.lean`; closed-world arguments (gpu,
pricing, provider) parse by variant name and refuse unknown ones typed. -/

open Lean (Json) in
open LeanDb LeanDb.Cli GpuMarket in
def main (args : List String) : IO UInt32 := do
  Cli.run {
    name := "gpumarket"
    dbPath := "data" / "gpumarket.sqlite"
    specs := schema
    tables := [.of Listing, .of Model]
    queries := [
      ("seed", fun _ => do
        seed
        seedModels
        return Json.mkObj [("ok", Json.bool true), ("seeded", Json.bool true)]),
      query% cheapest,
      query% h100,
      query% under,
      query% amd,
      query% bigVram,
      query% catalog,
      query% providerInfo,
      query% chipInfo,
      query% byArch,
      query% minBandwidth,
      query% valueRank,
      query% models,
      query% canServe]
  } args
