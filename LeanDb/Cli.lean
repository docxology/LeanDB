import LeanDb.Db
import LeanDb.Json
import LeanDb.Migrate

namespace LeanDb.Cli

/-! # The derived CLI

A base gets a machine-first CLI by listing its entities and queries; every
verb's behavior and JSON shape is derived from `Entity` instances. Exit
codes per plan.md §4.5: 0 ok, 2 typed `DbError` (JSON on stderr), 3 usage,
4 schema/version mismatch (`DbError.exitCode`).
The argv boundary is the one place strings are inherent; they are parsed
into types immediately and everything past this module is typed.
-/

open Lean (Json)

/-- How a CLI/serve argument string parses into a typed value. Closed
    enums parse by variant name for free; bases add instances for their
    newtypes. -/
class CliArg (α : Type) where
  parse : String → Except String α

instance : CliArg Nat := ⟨fun s => match s.toNat? with
  | some n => .ok n
  | none => .error s!"expected a natural number, got {String.quote s}"⟩

instance : CliArg Int64 := ⟨fun s => match s.toInt? with
  | some i => .ok (Int64.ofInt i)
  | none => .error s!"expected an integer, got {String.quote s}"⟩

instance : CliArg String := ⟨.ok⟩

instance : CliArg (Id α) := ⟨fun s => (CliArg.parse s : Except String Nat).map (⟨Int64.ofNat ·⟩)⟩

instance [ClosedEnum α] : CliArg α := ⟨fun s =>
  match ClosedEnum.decodeName s with
  | some a => .ok a
  | none => .error s!"{String.quote s} is not one of {ClosedEnum.variants α}"⟩

/-- How a query result renders as JSON. -/
class QueryOut (α : Type) where
  json : α → Json

instance [Entity α] : QueryOut (Stored α) := ⟨rowJson α⟩
instance [QueryOut α] [QueryOut β] : QueryOut (α × β) :=
  ⟨fun (a, b) => Json.arr #[QueryOut.json a, QueryOut.json b]⟩
instance [QueryOut α] : QueryOut (Array α) := ⟨fun xs => Json.arr (xs.map QueryOut.json)⟩
instance [QueryOut α] : QueryOut (List α) := ⟨fun xs => Json.arr (xs.map QueryOut.json).toArray⟩
instance [QueryOut α] : QueryOut (Option α) :=
  ⟨fun | none => Json.null | some a => QueryOut.json a⟩
instance : QueryOut Nat := ⟨Lean.toJson⟩
instance : QueryOut String := ⟨Json.str⟩
instance : QueryOut Bool := ⟨Json.bool⟩
instance : QueryOut Unit := ⟨fun _ => Json.null⟩
instance : QueryOut Json := ⟨id⟩

/-- Pop one typed positional argument (used by `query%`-derived handlers). -/
def popArg (α : Type) [CliArg α] (name : String) (args : List String) :
    DbM (α × List String) := do
  match args with
  | [] => throw (.decode "cli" name "missing argument")
  | a :: rest =>
      match CliArg.parse (α := α) a with
      | .ok v => return (v, rest)
      | .error m => throw (.decode "cli" name m)

def doneArgs : List String → DbM Unit
  | [] => pure ()
  | extra => throw (.decode "cli" "args" s!"unexpected extra arguments {extra}")

def okResult (j : Json) : Json := Json.mkObj [("ok", Json.bool true), ("result", j)]

structure CliTable where
  name : String
  insertJson : Json → DbM Json
  getJson : Int64 → DbM Json
  updateJson : Int64 → Json → DbM Json
  deleteRow : Int64 → DbM Json
  /-- `rows` with conjunctive equality filters (plan.md §4.1: `--eq` and
      limit are the CLI's whole filter language — anything more is a
      typed query). -/
  rowsWhere : List (String × String) → Nat → DbM Json

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
  rowsWhere eqs limit := do
    let spec := Entity.spec α
    let mut pred : PushPred := .tt
    for (col, v) in eqs do
      match spec.columns.find? (·.name == col) with
      | none =>
          throw (.decode spec.name col
            s!"no such column; columns: {spec.columns.toList.map (·.name)}")
      | some c =>
          -- a closed-world column refuses unknown variants loudly — a
          -- silent empty result is the exact failure mode LeanDB exists
          -- to kill
          if let some vs := c.enum then
            unless vs.contains v do
              throw (.decode spec.name col
                s!"{String.quote v} is not in the closed world {vs}")
          let cv ← match c.sqlType with
            | .integer =>
                match v.toInt? with
                | some i => pure (Col.int (Int64.ofInt i))
                | none => throw (.decode spec.name col s!"expected an integer, got {String.quote v}")
            | .text => pure (Col.text v)
            | .real => throw (.decode spec.name col "REAL columns cannot be filtered with --eq")
          pred := pred.andS (.cmp 0 col .eq cv)
    let rows ← fetchFiltered α pred
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
      Json.str "rows <table> [--eq col=value]... [--limit n]",
      Json.str "version",
      Json.str "query <name> [args...]",
      Json.str "log [limit]",
      Json.str "migrate status | apply [--allow-destructive]",
      Json.str "serve  (JSON-lines over stdio, persistent connection)"]),
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

private def logJson (limit : Nat) : DbM Json := do
  let rows ← readLog limit
  return Json.mkObj [("ok", Json.bool true), ("count", Lean.toJson rows.size),
    ("entries", Json.arr rows)]

/-- `rows` flags: `--eq col=value`… `--limit n` (or a bare trailing limit). -/
private def parseRowFlags : List String → List (String × String) → Nat →
    Except String (List (String × String) × Nat)
  | [], eqs, limit => .ok (eqs.reverse, limit)
  | "--eq" :: kv :: rest, eqs, limit =>
      match kv.splitOn "=" with
      | [k, v] => parseRowFlags rest ((k, v) :: eqs) limit
      | _ => .error s!"--eq expects col=value, got {String.quote kv}"
  | "--limit" :: n :: rest, eqs, _ =>
      match n.toNat? with
      | some limit => parseRowFlags rest eqs limit
      | none => .error s!"--limit expects a number, got {String.quote n}"
  | [n], eqs, _ =>
      match n.toNat? with
      | some limit => .ok (eqs.reverse, limit)
      | none => .error s!"unrecognized rows argument {String.quote n}"
  | arg :: _, _, _ => .error s!"unrecognized rows argument {String.quote arg}"

/-- Resolve argv into one typed database action (or a usage error). -/
private def command (b : Base) : List String → Except String (DbM Json)
  | ["insert", t, j] => do pure ((← table? b t).insertJson (← parseJson j))
  | ["get", t, i] => do pure ((← table? b t).getJson (← parseId i))
  | ["update", t, i, j] => do
      pure ((← table? b t).updateJson (← parseId i) (← parseJson j))
  | ["delete", t, i] => do pure ((← table? b t).deleteRow (← parseId i))
  | ["log"] => .ok (logJson 50)
  | ["log", n] => do
      let some limit := n.toNat? | throw s!"expected a limit, got {String.quote n}"
      pure (logJson limit)
  | "rows" :: t :: flags => do
      let tbl ← table? b t
      let (eqs, limit) ← parseRowFlags flags [] 100
      pure (tbl.rowsWhere eqs limit)
  | "query" :: name :: qargs =>
      match b.queries.find? (·.1 == name) with
      | some (_, q) => .ok (q qargs)
      | none => .error s!"unknown query {String.quote name}; queries: {b.queries.map (·.1)}"
  | args => .error s!"unrecognized command {args}"

/-- Served mode: JSON-lines over stdio against one persistent connection.
    Each request line is a JSON array of argv strings; each response is one
    JSON object line. EOF ends the session. -/
def serve (b : Base) : IO UInt32 := do
  if let some parent := b.dbPath.parent then
    IO.FS.createDirAll parent
  match ← openDb b.dbPath b.specs with
  | .error e =>
      IO.eprintln e.toJson.compress
      return e.exitCode
  | .ok conn =>
      let stdin ← IO.getStdin
      let out ← IO.getStdout
      repeat
        let line ← stdin.getLine
        if line.isEmpty then break
        let line := line.trimAscii.toString
        if line.isEmpty then continue
        let argv? := Lean.Json.parse line >>= fun j => do
          let arr ← j.getArr?
          arr.toList.mapM (·.getStr?)
        match argv? with
        | .error m =>
            out.putStrLn (Json.mkObj [("ok", Json.bool false), ("code", Json.str "usage"),
              ("message", Json.str s!"expected a JSON array of argv strings: {m}")]).compress
        | .ok ["schema"] =>
            out.putStrLn (schemaJson b.name b.specs).compress
        | .ok argv =>
            match command b argv with
            | .error m =>
                out.putStrLn (Json.mkObj [("ok", Json.bool false),
                  ("code", Json.str "usage"), ("message", Json.str m)]).compress
            | .ok act =>
                match ← act.run conn with
                | .ok j => out.putStrLn j.compress
                | .error e => out.putStrLn e.toJson.compress
        out.flush
      return 0

def run (b : Base) (args : List String) : IO UInt32 := do
  match args with
  | ["serve"] => serve b
  | [] | ["help"] | ["--help"] =>
      IO.println (usageJson b).compress
      return 0
  | ["schema"] =>
      IO.println (schemaJson b.name b.specs).compress
      return 0
  | ["version"] =>
      let codeFp := fingerprint b.specs
      let (instFp, instVer) ← do
        match ← instanceInfo b.dbPath with
        | none => pure (Json.null, Json.null)
        | some (fp, ver) =>
            pure (fp.map Json.str |>.getD Json.null,
              (ver.map fun v => Lean.toJson v).getD Json.null)
      IO.println (Json.mkObj [("ok", Json.bool true),
        ("code_fingerprint", Json.str codeFp),
        ("instance_fingerprint", instFp),
        ("schema_version", instVer),
        ("in_sync", Json.bool (instFp == Json.str codeFp))]).compress
      return 0
  | "migrate" :: rest =>
      let apply ← match rest with
        | ["status"] => pure (some (false, false))
        | ["apply"] => pure (some (true, false))
        | ["apply", "--allow-destructive"] => pure (some (true, true))
        | _ => pure none
      match apply with
      | none =>
          IO.eprintln (Json.mkObj [("ok", Json.bool false), ("code", Json.str "usage"),
            ("message", Json.str "migrate status | apply [--allow-destructive]")]).compress
          return 3
      | some (apply, allowDestructive) =>
          if let some parent := b.dbPath.parent then
            IO.FS.createDirAll parent
          match ← migrate b.dbPath b.specs apply allowDestructive with
          | .error e =>
              IO.eprintln e.toJson.compress
              return 2
          | .ok (plan?, report?) =>
              match report? with
              | some r => IO.println r.toJson.compress
              | none =>
                  let plan := plan?.getD {}
                  IO.println (Json.mkObj [("ok", Json.bool true),
                    ("steps", Json.arr (plan.steps.map (Json.str ·.describe)).toArray),
                    ("destructive", Json.bool plan.isDestructive),
                    ("notes", Json.arr (plan.notes.map Json.str).toArray)]).compress
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
              return e.exitCode

end LeanDb.Cli
