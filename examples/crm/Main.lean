import Crm

/-! The crm CLI: tables, schema, and row JSON derived from the entity
declarations; queries `query%`-derived from the query defs' signatures —
only the imperative `seed` verb is hand-written. -/

open Lean (Json) in
open LeanDb LeanDb.Cli Crm in
instance : CliArg Timestamp := ⟨fun s =>
  match s.toNat? with
  | some n => .ok ⟨n⟩
  | none => .error s!"expected an epoch-seconds timestamp, got {String.quote s}"⟩

open Lean (Json) in
open LeanDb LeanDb.Cli Crm in
def main (args : List String) : IO UInt32 := do
  Cli.run {
    name := "crm"
    dbPath := "data" / "crm.sqlite"
    specs := schema
    tables := [.of Company, .of Person, .of Interaction, .of Ask]
    queries := [
      ("seed", fun _ => do
        seed
        return Json.mkObj [("ok", Json.bool true), ("seeded", Json.bool true)]),
      query% liveAsks,
      query% pipelineFor,
      query% staleAsks,
      query% contactsOf]
  } args
