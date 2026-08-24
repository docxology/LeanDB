import PriceWatch

/-! The pricewatch CLI. NO seed verb by design: rows arrive only through
the (separate) scraper + normalizer, whose contract is this base's smart
constructors — `insert listing '{"price":0,…}'` and friends fail typed
today, on an empty instance, exactly as they will fail on a full one. -/

open Lean (Json) in
open LeanDb LeanDb.Cli PriceWatch in
def main (args : List String) : IO UInt32 := do
  Cli.run {
    name := "pricewatch"
    dbPath := "data" / "pricewatch.sqlite"
    specs := schema
    tables := [.of Product, .of Listing]
    queries := [
      query% find,
      query% wellRated,
      query% PriceWatch.compare,
      query% cheapest,
      query% deals,
      query% fastDelivery,
      query% atStore,
      query% products]
  } args
