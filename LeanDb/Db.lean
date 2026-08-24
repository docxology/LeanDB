import SQLite
import LeanDb.Select
import LeanDb.PlanElab

namespace LeanDb

/-! # The runtime: connections, `DbM`, and the four verbs

Backed by `leansqlite` (bundled SQLite). SQL text appears only in this file
— it is the compilation target of the typed layer, never its interface.
-/

structure Conn where
  raw : SQLite

/-- The database monad: a connection, typed errors, IO. -/
abbrev DbM := ReaderT Conn (ExceptT DbError IO)

def DbM.run (conn : Conn) (act : DbM α) : IO (Except DbError α) :=
  (act conn).run

/-- Run a SQLite IO action, converting failures via `onErr`. -/
private def sqliteWith (onErr : IO.Error → DbError) (act : SQLite → IO α) : DbM α :=
  fun conn => ExceptT.mk <|
    try (.ok <$> act conn.raw) catch e => pure (.error (onErr e))

private def sqlite (act : SQLite → IO α) : DbM α :=
  sqliteWith (fun e => .sqlite (toString e)) act

/-- SQLite reports every constraint violation as primary code 19; the
    message distinguishes the kinds. -/
private def constraintError (table : String) (id : Int64) (e : IO.Error) : DbError :=
  match e with
  | .otherError 19 details =>
      if details.startsWith "FOREIGN KEY" then .restricted table id
      else if details.startsWith "UNIQUE" then .duplicate table details
      else .sqlite s!"constraint: {details}"
  | e => .sqlite (toString e)

private def bindCol (stmt : SQLite.Stmt) (idx : Int32) : Col → IO Unit
  | .int v => stmt.bindInt64 idx v
  | .text v => stmt.bindText idx v
  | .real v => stmt.bindFloat idx v
  | .null => stmt.bindNull idx

/-- Bind row values starting at parameter `first` (bind params are 1-based). -/
private def bindCols (stmt : SQLite.Stmt) (first : Nat) (cols : Array Col) : IO Unit := do
  for h : i in [0:cols.size] do
    bindCol stmt (Int32.ofNat (first + i)) cols[i]

private def readCol (stmt : SQLite.Stmt) (i : Int32) : IO Col := do
  match ← stmt.columnType i with
  | .integer => .int <$> stmt.columnInt64 i
  | .float => .real <$> stmt.columnDouble i
  | .text => .text <$> stmt.columnText i
  | .null => return .null
  | .blob => throw <| IO.userError "BLOB columns are not supported"

/-- Read the current result row as `id` (column 0) plus the entity columns. -/
private def readStored (α : Type) [Entity α] (stmt : SQLite.Stmt) :
    IO (Except DbError (Stored α)) := do
  let id ← stmt.columnInt64 0
  let n := (Entity.columns α).size
  let mut cols : Array Col := #[]
  for i in [0:n] do
    cols := cols.push (← readCol stmt (Int32.ofNat (i + 1)))
  return (Entity.decode cols).map (⟨⟨id⟩, ·⟩)

private def liftExcept (r : Except DbError α) : DbM α :=
  fun _ => ExceptT.mk (pure r)

private def quoteId (s : String) : String := "\"" ++ s ++ "\""

private def columnList (α : Type) [Entity α] : String :=
  String.intercalate ", " ("id" :: (Entity.columns α).toList.map (quoteId ·.name))

private def placeholders (n : Nat) : String :=
  String.intercalate ", " (List.replicate n "?")

/-- `INSERT` a value; returns it with its assigned identity. -/
def insert (α : Type) [Entity α] (a : α) : DbM (Stored α) := do
  let spec := Entity.spec α
  let names := String.intercalate ", " (spec.columns.toList.map (quoteId ·.name))
  let sql := s!"INSERT INTO {quoteId spec.name} ({names}) VALUES ({placeholders spec.columns.size})"
  sqliteWith (constraintError spec.name 0) fun db => do
    let stmt ← db.prepare sql
    bindCols stmt 1 (Entity.encode a)
    stmt.exec
  let id ← sqlite (·.lastInsertRowId)
  return ⟨⟨id⟩, a⟩

/-- Fetch one row by typed identity. -/
def get [Entity α] (id : Id α) : DbM (Option (Stored α)) := do
  let sql := s!"SELECT {columnList α} FROM {quoteId (Entity.tableName α)} WHERE id = ?"
  let row ← sqlite fun db => do
    let stmt ← db.prepare sql
    stmt.bindInt64 1 id.toInt64
    if ← stmt.step then some <$> readStored α stmt else return none
  match row with
  | none => return none
  | some r => some <$> liftExcept r

/-- Every row of `α`'s table, in id order. -/
def fetchAll (α : Type) [Entity α] : DbM (Array (Stored α)) := do
  let sql := s!"SELECT {columnList α} FROM {quoteId (Entity.tableName α)} ORDER BY id"
  let rows ← sqlite fun db => do
    let stmt ← db.prepare sql
    let mut out := #[]
    repeat
      if ← stmt.step then out := out.push (← readStored α stmt) else break
    return out
  rows.mapM liftExcept

/-- Compare-and-swap update: `SET` to `new` only where the row still equals
    `old`, id included. A lost race is a typed `.stale`, never a silent
    clobber. `IS` (not `=`) so `NULL` columns pin correctly. -/
def update [Entity α] (old : Stored α) (new : α) : DbM (Stored α) := do
  let spec := Entity.spec α
  let sets := String.intercalate ", " (spec.columns.toList.map (s!"{quoteId ·.name} = ?"))
  let pins := String.intercalate " AND " (spec.columns.toList.map (s!"{quoteId ·.name} IS ?"))
  let sql := s!"UPDATE {quoteId spec.name} SET {sets} WHERE id = ? AND {pins}"
  let n := spec.columns.size
  let changed ← sqliteWith (constraintError spec.name old.id.toInt64) fun db => do
    let stmt ← db.prepare sql
    bindCols stmt 1 (Entity.encode new)
    stmt.bindInt64 (Int32.ofNat (n + 1)) old.id.toInt64
    bindCols stmt (n + 2) (Entity.encode old.val)
    stmt.exec
    db.changes
  if changed == 0 then
    match ← get old.id with
    | some _ => throw (.stale spec.name old.id.toInt64)
    | none => throw (.notFound spec.name old.id.toInt64)
  return ⟨old.id, new⟩

/-- Delete by typed identity. Rows referenced elsewhere refuse with
    `.restricted` (FK RESTRICT) — destruction is loud. -/
def delete [Entity α] (id : Id α) : DbM Unit := do
  let table := Entity.tableName α
  let changed ← sqliteWith (constraintError table id.toInt64) fun db => do
    let stmt ← db.prepare s!"DELETE FROM {quoteId table} WHERE id = ?"
    stmt.bindInt64 1 id.toInt64
    stmt.exec
    db.changes
  if changed == 0 then throw (.notFound table id.toInt64)

/-- Rows of `α`'s table matching every pushed conjunct, in id order. -/
def fetchFiltered (α : Type) [Entity α] (conds : Array PushCond) : DbM (Array (Stored α)) := do
  if conds.isEmpty then return ← fetchAll α
  let condSql := fun (c : PushCond) => match c with
    | .cmp col op _ => s!"{quoteId col} {op.sql} ?"
    | .isNull col => s!"{quoteId col} IS NULL"
    | .isNotNull col => s!"{quoteId col} IS NOT NULL"
  let whereSql := String.intercalate " AND " (conds.toList.map condSql)
  let sql := s!"SELECT {columnList α} FROM {quoteId (Entity.tableName α)} WHERE {whereSql} ORDER BY id"
  let rows ← sqlite fun db => do
    let stmt ← db.prepare sql
    let mut idx : Nat := 1
    for c in conds do
      if let .cmp _ _ v := c then
        bindCol stmt (Int32.ofNat idx) v
        idx := idx + 1
    let mut out := #[]
    repeat
      if ← stmt.step then out := out.push (← readStored α stmt) else break
    return out
  rows.mapM liftExcept

/-- The live database as a row `Source`, ignoring plans. -/
def dbSource : Source DbM := ⟨fun _ α _ => fetchAll α⟩

/-- The live database narrowed by a plan's pushed conjuncts. -/
def plannedSource (plan : SelectPlan) : Source DbM :=
  ⟨fun i α _ => fetchFiltered α (plan.forTable i)⟩

/-- The typed select. The trailing `plan` is reified from `where'` by the
    `leandb_plan` tactic at each call site and narrows each table's fetch
    via SQL `WHERE`; the lambda is still applied to what comes back, so the
    reference semantics (`selectSpec` over an unfiltered source) define the
    result and pushdown can only be an optimization. -/
def select (ts : List Type) [RowsOf ts] (where' : Rows ts → Bool)
    (sortBy : SortBy (Rows ts) := .preserve)
    (plan : PlanFor where' := by leandb_plan) : DbM (Array (Rows ts)) :=
  selectSpec ts (plannedSource plan.plan) where' sortBy

/-- `select` with pushdown disabled — the executable reference, for
    differential testing against the planned path. -/
def selectUnplanned (ts : List Type) [RowsOf ts] (where' : Rows ts → Bool)
    (sortBy : SortBy (Rows ts) := .preserve) : DbM (Array (Rows ts)) :=
  selectSpec ts dbSource where' sortBy

/-! ## Opening an instance -/

private def metaDdl : String :=
  "CREATE TABLE IF NOT EXISTS _leandb_meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)"

private def readMeta (db : SQLite) (key : String) : IO (Option String) := do
  let stmt ← db.prepare "SELECT value FROM _leandb_meta WHERE key = ?"
  stmt.bindText 1 key
  if ← stmt.step then some <$> stmt.columnText 0 else return none

private def writeMeta (db : SQLite) (key value : String) : IO Unit := do
  let stmt ← db.prepare "INSERT OR REPLACE INTO _leandb_meta (key, value) VALUES (?, ?)"
  stmt.bindText 1 key
  stmt.bindText 2 value
  stmt.exec

/-- Open (creating if absent) an instance for the given schema. Applies
    DDL idempotently and refuses to open an instance whose fingerprint
    disagrees with the code's — drift is an error, not a surprise. -/
def openDb (path : System.FilePath) (specs : List TableSpec) : IO (Except DbError Conn) := do
  try
    let db ← SQLite.open path
    db.exec "PRAGMA foreign_keys = ON"
    db.exec metaDdl
    let fp := fingerprint specs
    match ← readMeta db "schema_fingerprint" with
    | some stored =>
        if stored != fp then
          return .error (.schemaMismatch fp stored)
    | none => pure ()
    for spec in specs do
      db.exec spec.ddl
    -- Drift scan: stored closed-world values must still be in the vocabulary.
    -- CHECK guards new writes; this guards data written under an older world.
    for spec in specs do
      for c in spec.columns do
        if let some vs := c.enum then
          let stmt ← db.prepare
            s!"SELECT DISTINCT {quoteId c.name} FROM {quoteId spec.name} WHERE {quoteId c.name} IS NOT NULL"
          repeat
            if ← stmt.step then
              let v ← stmt.columnText 0
              unless vs.contains v do
                return .error (.enumDrift spec.name c.name v)
            else break
    writeMeta db "schema_fingerprint" fp
    return .ok ⟨db⟩
  catch e =>
    return .error (.sqlite (toString e))

/-- Open, run, and report — the whole lifecycle for scripts and tests. -/
def withDb (path : System.FilePath) (specs : List TableSpec) (act : DbM α) :
    IO (Except DbError α) := do
  match ← openDb path specs with
  | .error e => return .error e
  | .ok conn => act.run conn

end LeanDb
