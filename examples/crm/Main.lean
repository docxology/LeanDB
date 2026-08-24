import Crm

/-! The crm CLI: `LeanDb.Cli.run` over this base's entities and queries.
Tables, schema output, and row JSON are all derived from the entity
declarations; only the query registrations below are base code. -/

open Lean (Json) in
open LeanDb LeanDb.Cli Crm in
def main (args : List String) : IO UInt32 := do
  let askRows := fun (rows : Array (Stored Ask)) =>
    Json.mkObj [("ok", Json.bool true), ("count", Lean.toJson rows.size),
      ("rows", Json.arr (rows.map (rowJson Ask)))]
  let argNat := fun (args : List String) (name : String) => do
    match args with
    | [v] =>
        match v.toNat? with
        | some n => pure n
        | none => throw (DbError.decode "cli" name s!"expected a natural number, got {v}")
    | _ => throw (DbError.decode "cli" name "exactly one argument expected")
  Cli.run {
    name := "crm"
    dbPath := "data" / "crm.sqlite"
    specs := schema
    tables := [.of Company, .of Person, .of Interaction, .of Ask]
    queries := [
      ("seed", fun _ => do
        seed
        return Json.mkObj [("ok", Json.bool true), ("seeded", Json.bool true)]),
      ("live", fun _ => askRows <$> liveAsks),
      ("pipeline", fun args => do
        let cid ← argNat args "company-id"
        let pipeline ← pipelineFor ⟨Int64.ofNat cid⟩
        return Json.mkObj [("ok", Json.bool true), ("count", Lean.toJson pipeline.size),
          ("rows", Json.arr (pipeline.map fun (a, p) =>
            Json.mkObj [("ask", rowJson Ask a), ("person", rowJson Person p)]))]),
      ("stale", fun args => do
        let now ← argNat args "now-epoch-seconds"
        askRows <$> staleAsks ⟨now⟩),
      ("contacts", fun args => do
        let cid ← argNat args "company-id"
        let people ← contactsOf ⟨Int64.ofNat cid⟩
        return Json.mkObj [("ok", Json.bool true), ("count", Lean.toJson people.size),
          ("rows", Json.arr (people.map (rowJson Person)))])]
  } args
