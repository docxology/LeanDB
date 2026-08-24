import Shop

/-! The shop CLI: tables, schema, and row JSON derived from the entity
declarations; queries `query%`-derived from the query defs' signatures —
only the imperative `seed` verb is hand-written. -/

open Lean (Json) in
open LeanDb LeanDb.Cli Shop in
def main (args : List String) : IO UInt32 := do
  Cli.run {
    name := "shop"
    dbPath := "data" / "shop.sqlite"
    specs := schema
    tables := [.of Customer, .of Product, .of Purchase, .of LineItem]
    queries := [
      ("seed", fun _ => do
        seed
        return Json.mkObj [("ok", Json.bool true), ("seeded", Json.bool true)]),
      query% activeOrders,
      query% lowStock,
      query% basketOf,
      query% revenueRows]
  } args
