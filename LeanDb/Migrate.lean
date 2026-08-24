import LeanDb.Db
import LeanDb.Json

namespace LeanDb

/-! # Migrations v1: additive auto-migration, loud destruction

The instance remembers the schema it was last shaped to (`schema_json` in
`_leandb_meta`). `planMigration` diffs that against the code's specs and
produces steps:

- new table → `CREATE TABLE`;
- new column → `ALTER TABLE ADD COLUMN` — the column must be nullable
  (`Option`), because existing rows need a value and v1 refuses to invent
  one (backfills are a judgment call, per plan.md §6);
- changed column (type, nullability, FK target, or a changed closed world)
  → table rebuild: create under a scratch name with the new DDL, copy the
  surviving columns, drop, rename. A *shrunk* closed world hits the new
  CHECK during the copy and aborts the transaction — vocabulary can only
  shrink through a migration, and only when the data already conforms;
- dropped column/table → destructive, refused unless explicitly allowed.

Everything applies in one transaction with a foreign-key check before
commit. `openDb` still refuses fingerprint drift; `migrate` is the one
explicit gate through which schemas move.
-/

inductive MigStep where
  | createTable (spec : TableSpec)
  | addColumn (table : String) (col : ColumnSpec)
  | dropColumn (table col : String)
  | dropTable (name : String)
  /-- Rebuild `spec.name` under the new spec, copying `copyCols`. -/
  | rebuildTable (spec : TableSpec) (copyCols : List String)
  deriving Repr

def MigStep.describe : MigStep → String
  | .createTable spec => s!"create table \"{spec.name}\""
  | .addColumn t c => s!"add column \"{t}\".\"{c.name}\""
  | .dropColumn t c => s!"DROP column \"{t}\".\"{c}\""
  | .dropTable t => s!"DROP table \"{t}\""
  | .rebuildTable spec cols =>
      s!"rebuild table \"{spec.name}\" (copying {cols.length} columns)"

def MigStep.destructive : MigStep → Bool
  | .dropColumn .. | .dropTable .. => true
  | _ => false

def MigStep.sql : MigStep → List String
  | .createTable spec => [spec.ddl]
  | .addColumn t c => [s!"ALTER TABLE \"{t}\" ADD COLUMN {c.ddlFragment}"]
  | .dropColumn t c => [s!"ALTER TABLE \"{t}\" DROP COLUMN \"{c}\""]
  | .dropTable t => [s!"DROP TABLE \"{t}\""]
  | .rebuildTable spec copyCols =>
      let tmp := s!"_leandb_new_{spec.name}"
      let cols := String.intercalate ", " ("id" :: copyCols.map (s!"\"{·}\""))
      [ spec.ddlNamed tmp,
        s!"INSERT INTO \"{tmp}\" ({cols}) SELECT {cols} FROM \"{spec.name}\"",
        s!"DROP TABLE \"{spec.name}\"",
        s!"ALTER TABLE \"{tmp}\" RENAME TO \"{spec.name}\"" ]

structure MigPlan where
  steps : List MigStep := []
  notes : List String := []
  /-- Set by `migrate` from `destructiveAgainst` — step kinds alone miss
      rebuilds that drop columns. -/
  isDestructive : Bool := false
  deriving Repr

/-- Diff two schemas into a plan. Errors are refusals with reasons —
    never a silent guess. -/
def planMigration (old new : List TableSpec) : Except String MigPlan := do
  let mut steps : List MigStep := []
  let mut notes : List String := []
  -- new and changed tables
  for spec in new do
    match old.find? (·.name == spec.name) with
    | none => steps := steps ++ [.createTable spec]
    | some oldSpec =>
        if oldSpec == spec then continue
        let added := spec.columns.toList.filter fun c =>
          (oldSpec.columns.find? (·.name == c.name)).isNone
        let dropped := oldSpec.columns.toList.filter fun c =>
          (spec.columns.find? (·.name == c.name)).isNone
        let changed := spec.columns.toList.filter fun c =>
          match oldSpec.columns.find? (·.name == c.name) with
          | some o => o != c
          | none => false
        for c in added do
          unless c.nullable || c.dflt.isSome do
            throw s!"table \"{spec.name}\": new column \"{c.name}\" is NOT NULL with no \
default — existing rows have no value for it. Make it `Option`, or give it a \
`:= default` (existing rows take the default), or migrate by hand."
        if changed.isEmpty then
          steps := steps ++ added.map (.addColumn spec.name ·)
            ++ dropped.map (.dropColumn spec.name ·.name)
        else
          -- rebuild carries adds and drops along
          let copyCols := spec.columns.toList.filterMap fun c =>
            if (oldSpec.columns.find? (·.name == c.name)).isSome then some c.name else none
          for c in changed do
            notes := notes ++ [s!"\"{spec.name}\".\"{c.name}\" changed shape → table rebuild"]
          unless dropped.isEmpty do
            notes := notes ++ [s!"rebuild of \"{spec.name}\" DROPS columns {dropped.map (·.name)}"]
          for c in added do
            unless c.nullable || c.dflt.isSome do
              throw s!"table \"{spec.name}\": new column \"{c.name}\" must be nullable or \
carry a default (rebuild)"
          steps := steps ++ [.rebuildTable spec copyCols]
  -- dropped tables
  for oldSpec in old do
    if (new.find? (·.name == oldSpec.name)).isNone then
      steps := steps ++ [.dropTable oldSpec.name]
  return { steps, notes }

/-- Is this plan destructive? dropTable/dropColumn, or a rebuild whose copy
    list is shorter than the old table's columns. -/
def MigPlan.destructiveAgainst (p : MigPlan) (old : List TableSpec) : Bool :=
  p.steps.any fun s =>
    s.destructive ||
      match s with
      | .rebuildTable spec copyCols =>
          match old.find? (·.name == spec.name) with
          | some o => copyCols.length < o.columns.size
          | none => false
      | _ => false

structure MigrateReport where
  applied : List String
  notes : List String
  fingerprint : String
  deriving Repr

open Lean (Json) in
def MigrateReport.toJson (r : MigrateReport) : Json :=
  Json.mkObj [("ok", Json.bool true),
    ("applied", Json.arr (r.applied.map Json.str).toArray),
    ("notes", Json.arr (r.notes.map Json.str).toArray),
    ("fingerprint", Json.str r.fingerprint)]

private def readStoredSchema (db : SQLite) : IO (Option (List TableSpec)) := do
  let stmt ← db.prepare "SELECT value FROM _leandb_meta WHERE key = 'schema_json'"
  if ← stmt.step then
    let raw ← stmt.columnText 0
    match Lean.Json.parse raw >>= specsFromJson? with
    | .ok specs => return some specs
    | .error _ => return none
  else
    return none

private def writeStoredSchema (db : SQLite) (specs : List TableSpec) : IO Unit := do
  let stmt ← db.prepare "INSERT OR REPLACE INTO _leandb_meta (key, value) VALUES (?, ?)"
  stmt.bindText 1 "schema_json"
  stmt.bindText 2 (specsToJson specs).compress
  stmt.exec
  stmt.reset
  stmt.clearBindings
  stmt.bindText 1 "schema_fingerprint"
  stmt.bindText 2 (fingerprint specs)
  stmt.exec

/-- Plan (and optionally apply) the migration from an instance's stored
    schema to the code's schema. `apply := false` only reports. -/
def migrate (path : System.FilePath) (specs : List TableSpec)
    (apply : Bool) (allowDestructive : Bool := false) :
    IO (Except DbError (Option MigPlan × Option MigrateReport)) := do
  try
    let db ← SQLite.open path
    db.exec "PRAGMA foreign_keys = ON"
    db.exec "CREATE TABLE IF NOT EXISTS _leandb_meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)"
    db.exec migrationsDdl
    let old? ← readStoredSchema db
    let old := old?.getD []
    match planMigration old specs with
    | .error msg => return .error (.migrate msg)
    | .ok plan =>
        let plan := { plan with isDestructive := plan.destructiveAgainst old }
        if plan.steps.isEmpty then
          if apply then writeStoredSchema db specs
          return .ok (some plan, some ⟨[], ["schema already up to date"], fingerprint specs⟩)
        if !apply then
          return .ok (some plan, none)
        if plan.isDestructive && !allowDestructive then
          return .error (.migrate
            "plan is destructive (drops tables or columns); pass --allow-destructive")
        db.exec "PRAGMA foreign_keys = OFF"
        db.exec "BEGIN"
        try
          for step in plan.steps do
            for sql in step.sql do
              db.exec sql
          -- referential integrity must survive the migration
          let stmt ← db.prepare "PRAGMA foreign_key_check"
          if ← stmt.step then
            let t ← stmt.columnText 0
            throw <| IO.userError s!"foreign_key_check failed on table {t}"
          writeStoredSchema db specs
          -- version bump + journal, atomic with the migration itself
          let ver := (((← readMeta db "schema_version").bind (·.toNat?)).getD 0) + 1
          writeMeta db "schema_version" (toString ver)
          let j ← db.prepare
            "INSERT INTO _leandb_migrations (steps, fingerprint, ok) VALUES (?, ?, 1)"
          j.bindText 1 (Lean.Json.arr
            (plan.steps.map (Lean.Json.str ·.describe)).toArray).compress
          j.bindText 2 (fingerprint specs)
          j.exec
          db.exec "COMMIT"
        catch e =>
          db.exec "ROLLBACK"
          db.exec "PRAGMA foreign_keys = ON"
          return .error (.migrate (toString e))
        db.exec "PRAGMA foreign_keys = ON"
        return .ok (some plan, some ⟨plan.steps.map (·.describe), plan.notes, fingerprint specs⟩)
  catch e =>
    return .error (.sqlite (toString e))

/-- What an instance says about itself, readable even when drifted:
    (fingerprint, schema_version). `none` = file or meta absent. -/
def instanceInfo (path : System.FilePath) : IO (Option (Option String × Option Nat)) := do
  if !(← path.pathExists) then return none
  try
    let db ← SQLite.open path
    let fp ← readMeta db "schema_fingerprint"
    let ver ← readMeta db "schema_version"
    return some (fp, ver.bind (·.toNat?))
  catch _ =>
    return some (none, none)

end LeanDb
