import LeanDb.Db
import LeanDb.Json

namespace LeanDb.Cli

/-! # The derived CLI

A base gets a machine-first CLI by listing its entities and queries; every
verb's behavior and JSON shape is derived from `Entity` instances. Exit
codes per plan.md §4.5: 0 ok, 2 typed `DbError` (JSON on stderr), 3 usage.
The argv boundary is the one place strings are inherent; they are parsed
into types immediately and everything past this module is typed.
-/

open Lean (Json)

structure CliTable where
  name : String
  insertJson : Json → DbM Json
  getJson : Int64 → DbM Json
  updateJson : Int64 → Json → DbM Json
  deleteRow : Int64 → DbM Json
  rowsJson : Nat → DbM Json

private def okRow (j : Json) : Json := Json.mkObj [("ok", Json.bool true), ("row", j)]

def CliTable.of (α : Type) [Entity α] : CliTable where
  name := Entity.tableName α
  insertJson j := do
    let a ← DbM.ofExcept (rowOfJson α j)
    return okRow (rowJson α (← insert α a))
  getJson id := do
    match ← get (⟨id⟩ : Id α) with
    | some s => return okRow (rowJson α s)
    | none => throw (.notFound (Entity.tableName α) id)
  updateJson id j := do
    match ← get (⟨id⟩ : Id α) with
    | some old =>
        let new ← DbM.ofExcept (rowMergeJson α old.val j)
        return okRow (rowJson α (← update old new))
    | none => throw (.notFound (Entity.tableName α) id)
  deleteRow id := do
    delete (⟨id⟩ : Id α)
    return Json.mkObj [("ok", Json.bool true), ("deleted", Lean.toJson id.toInt)]
  rowsJson limit := do
    let rows ← fetchAll α
    let rows := rows.toList.take limit
    return Json.mkObj [("ok", Json.bool true), ("count", Lean.toJson rows.length),
      ("rows", Json.arr (rows.map (rowJson α)).toArray)]

/-- A base, as the CLI sees it: name, default instance path, specs (both
    derived from the types), tables, and named queries. -/
structure Base where
  name : String
  dbPath : System.FilePath
  specs : List TableSpec
  tables : List CliTable
  queries : List (String × (List String → DbM Json)) := []

private def usageJson (b : Base) : Json :=
  Json.mkObj [
    ("ok", Json.bool true),
    ("base", Json.str b.name),
    ("usage", Json.arr #[
      Json.str "schema",
      Json.str "insert <table> <json>",
      Json.str "get <table> <id>",
      Json.str "update <table> <id> <partial-json>",
      Json.str "delete <table> <id>",
      Json.str "rows <table> [limit]",
      Json.str "query <name> [args...]"]),
    ("tables", Json.arr (b.tables.map (Json.str ·.name)).toArray),
    ("queries", Json.arr (b.queries.map (Json.str ·.1)).toArray)]

private def parseId (s : String) : Except String Int64 :=
  match s.toNat? with
  | some n => .ok (Int64.ofNat n)
  | none => .error s!"expected a row id, got {String.quote s}"

private def parseJson (s : String) : Except String Json := Json.parse s

private def table? (b : Base) (name : String) : Except String CliTable :=
  match b.tables.find? (·.name == name) with
  | some t => .ok t
  | none => .error s!"unknown table {String.quote name}; tables: {b.tables.map (·.name)}"

/-- Resolve argv into one typed database action (or a usage error). -/
private def command (b : Base) : List String → Except String (DbM Json)
  | ["insert", t, j] => do pure ((← table? b t).insertJson (← parseJson j))
  | ["get", t, i] => do pure ((← table? b t).getJson (← parseId i))
  | ["update", t, i, j] => do
      pure ((← table? b t).updateJson (← parseId i) (← parseJson j))
  | ["delete", t, i] => do pure ((← table? b t).deleteRow (← parseId i))
  | ["rows", t] => do pure ((← table? b t).rowsJson 100)
  | ["rows", t, n] => do
      let some limit := n.toNat? | throw s!"expected a limit, got {String.quote n}"
      pure ((← table? b t).rowsJson limit)
  | "query" :: name :: qargs =>
      match b.queries.find? (·.1 == name) with
      | some (_, q) => .ok (q qargs)
      | none => .error s!"unknown query {String.quote name}; queries: {b.queries.map (·.1)}"
  | args => .error s!"unrecognized command {args}"

def run (b : Base) (args : List String) : IO UInt32 := do
  match args with
  | [] | ["help"] | ["--help"] =>
      IO.println (usageJson b).compress
      return 0
  | ["schema"] =>
      IO.println (schemaJson b.name b.specs).compress
      return 0
  | args =>
      match command b args with
      | .error msg =>
          IO.eprintln (Json.mkObj [("ok", Json.bool false), ("code", Json.str "usage"),
            ("message", Json.str msg)]).compress
          return 3
      | .ok act =>
          if let some parent := b.dbPath.parent then
            IO.FS.createDirAll parent
          match ← withDb b.dbPath b.specs act with
          | .ok j =>
              IO.println j.compress
              return 0
          | .error e =>
              IO.eprintln e.toJson.compress
              return 2

end LeanDb.Cli
