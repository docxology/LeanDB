import Shop

/-! The shop CLI: `LeanDb.Cli.run` over this base's entities and queries.
Tables, schema output, and row JSON are all derived from the entity
declarations; only the query registrations below are base code. -/

open Lean (Json) in
open LeanDb LeanDb.Cli Shop in
def main (args : List String) : IO UInt32 := do
  let purchaseRows := fun (rows : Array (Stored Purchase)) =>
    Json.mkObj [("ok", Json.bool true), ("count", Lean.toJson rows.size),
      ("rows", Json.arr (rows.map (rowJson Purchase)))]
  let argNat := fun (args : List String) (name : String) => do
    match args with
    | [v] =>
        match v.toNat? with
        | some n => pure n
        | none => throw (DbError.decode "cli" name s!"expected a natural number, got {v}")
    | _ => throw (DbError.decode "cli" name "exactly one argument expected")
  Cli.run {
    name := "shop"
    dbPath := "data" / "shop.sqlite"
    specs := schema
    tables := [.of Customer, .of Product, .of Purchase, .of LineItem]
    queries := [
      ("seed", fun _ => do
        seed
        return Json.mkObj [("ok", Json.bool true), ("seeded", Json.bool true)]),
      ("active", fun _ => purchaseRows <$> activeOrders),
      ("low", fun args => do
        let threshold ← argNat args "threshold"
        let rows ← lowStock threshold
        return Json.mkObj [("ok", Json.bool true), ("count", Lean.toJson rows.size),
          ("rows", Json.arr (rows.map (rowJson Product)))]),
      ("basket", fun args => do
        let oid ← argNat args "order-id"
        let rows ← basketOf ⟨Int64.ofNat oid⟩
        return Json.mkObj [("ok", Json.bool true), ("count", Lean.toJson rows.size),
          ("rows", Json.arr (rows.map fun (li, p) =>
            Json.mkObj [("item", rowJson LineItem li), ("product", rowJson Product p)]))]),
      ("revenue", fun _ => do
        let rows ← revenueRows
        return Json.mkObj [("ok", Json.bool true), ("count", Lean.toJson rows.size),
          ("totalCents", Lean.toJson (revenueCents rows)),
          ("rows", Json.arr (rows.map fun (o, li) =>
            Json.mkObj [("purchase", rowJson Purchase o), ("item", rowJson LineItem li)]))])]
  } args
