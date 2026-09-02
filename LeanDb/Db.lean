import SQLite
import LeanDb.Select
import LeanDb.PlanElab
import LeanDb.Json

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

private def hasSub (s sub : String) : Bool := (s.splitOn sub).length > 1

/-- SQLite reports every constraint violation as primary code 19; the
    message distinguishes the kinds — but an FK failure means different
    things per verb (dangling `Ref` on insert/update, referenced-row on
    delete), so the caller says what it means via `fkError`.

    TEXT-SHAPE DEPENDENCY. The seam that separates `.missingRef`,
    `.restricted` and `.duplicate` from a catch-all `.sqlite` *should* be
    SQLite's extended result code — SQLITE_CONSTRAINT_FOREIGNKEY 787,
    _UNIQUE 2067, _PRIMARYKEY 1555, each `19 ||| (subtype <<< 8)`, so the
    low byte stays 19. It is not: bundled `leansqlite` passes
    `sqlite3_step`/`sqlite3_exec`'s return value straight to
    `IO.Error.otherError` (bindings/leansqlite.c) and binds neither
    `sqlite3_extended_result_codes` nor `sqlite3_extended_errcode` — and
    SQLite has no PRAGMA for either — so extended codes stay off and only
    19 ever arrives. That leaves the human-readable message, which is not
    a stable API, deciding which typed error the caller sees.

    So: match the extended codes anyway (free today, correct the day
    upstream binds `sqlite3_extended_result_codes`), and fall back to a
    case-insensitive substring match, which survives the re-wordings that
    `startsWith` on "FOREIGN KEY" / "UNIQUE" would silently downgrade. -/
private def constraintError (table : String) (fkError : DbError) (e : IO.Error) : DbError :=
  match e with
  | .otherError code details =>
      if code % 256 != 19 then .sqlite (toString e) else
      let msg := details.toLower
      if code == 787 || hasSub msg "foreign key" then fkError
      -- _UNIQUE and _PRIMARYKEY both read "UNIQUE constraint failed: t.c".
      else if code == 2067 || code == 1555 || hasSub msg "unique" || hasSub msg "primary key" then
        .duplicate table details
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

/-- A column we cannot represent (`none`) is a decode failure like any
    other; the caller names the table and field it came from. -/
private def readCol (stmt : SQLite.Stmt) (i : Int32) : IO (Option Col) := do
  match ← stmt.columnType i with
  | .integer => return some (.int (← stmt.columnInt64 i))
  | .float => return some (.real (← stmt.columnDouble i))
  | .text => return some (.text (← stmt.columnText i))
  | .null => return some .null
  | .blob => return none

/-- Read `n` result columns starting at `first`. `label i` names the
    `(table, field)` column `i` was selected from — consulted only when a
    value cannot be represented, so a row decode allocates nothing for it. -/
private def readRow (stmt : SQLite.Stmt) (first n : Nat) (label : Nat → String × String) :
    IO (Except DbError (Array Col)) := do
  let mut cols : Array Col := Array.mkEmpty n
  for i in [0:n] do
    match ← readCol stmt (Int32.ofNat (first + i)) with
    | some c => cols := cols.push c
    | none =>
        let (table, field) := label i
        return .error (.decode table field "BLOB columns are not supported")
  return .ok cols

/-- Read the current result row as `id` (column 0) plus the entity columns. -/
private def readStored (α : Type) [Entity α] (stmt : SQLite.Stmt) :
    IO (Except DbError (Stored α)) := do
  let id ← stmt.columnInt64 0
  let fields := Entity.fields (α := α)
  let label (i : Nat) : String × String :=
    (Entity.tableName α, (fields[i]?.map Entity.fieldName).getD "?")
  match ← readRow stmt 1 fields.size label with
  | .error e => return .error e
  | .ok cols => return (Entity.decode cols).map (⟨⟨id⟩, ·⟩)

/-- Lift a typed result into `DbM`. -/
def DbM.ofExcept (r : Except DbError α) : DbM α :=
  fun _ => ExceptT.mk (pure r)

/-- Append to `_leandb_log`. Best-effort: the log never fails an operation. -/
private def logOp (verb detail : String) (ok : Bool) (error : Option String) (rows : Nat) :
    DbM Unit := fun conn => ExceptT.mk do
  try
    let stmt ← conn.raw.prepare
      "INSERT INTO _leandb_log (verb, detail, ok, error, rows) VALUES (?, ?, ?, ?, ?)"
    stmt.bindText 1 verb
    stmt.bindText 2 detail
    stmt.bindInt64 3 (if ok then 1 else 0)
    match error with
    | some e => stmt.bindText 4 e
    | none => stmt.bindNull 4
    stmt.bindInt64 5 (Int64.ofNat rows)
    stmt.exec
    return .ok ()
  catch _ => return .ok ()

/-- Run an operation and log it: verb, detail, outcome, row count. The
    query log is the audit trail and the agent's episodic memory
    (plan.md §4.4) — on by default. -/
private def withLog (verb detail : String) (count : α → Nat) (act : DbM α) : DbM α := do
  match ← fun conn => ExceptT.mk (.ok <$> (act conn).run) with
  | .ok a =>
      logOp verb detail true none (count a)
      return a
  | .error e =>
      logOp verb detail false (some e.code) 0
      throw e

private def liftExcept (r : Except DbError α) : DbM α := DbM.ofExcept r

private def quoteId (s : String) : String := quoteIdent s

private def columnList (α : Type) [Entity α] : String :=
  String.intercalate ", " ("id" :: (Entity.columns α).toList.map (quoteId ·.name))

private def placeholders (n : Nat) : String :=
  String.intercalate ", " (List.replicate n "?")

/-- `INSERT` a value; returns it with its assigned identity. -/
def insert (α : Type) [Entity α] (a : α) : DbM (Stored α) := withLog "insert" (Entity.tableName α) (fun _ => 1) do
  let spec := Entity.spec α
  let names := String.intercalate ", " (spec.columns.toList.map (quoteId ·.name))
  let sql := if spec.columns.isEmpty then
    s!"INSERT INTO {quoteId spec.name} DEFAULT VALUES"
  else
    s!"INSERT INTO {quoteId spec.name} ({names}) VALUES ({placeholders spec.columns.size})"
  sqliteWith (constraintError spec.name (.missingRef spec.name)) fun db => do
    let stmt ← db.prepare sql
    unless spec.columns.isEmpty do bindCols stmt 1 (Entity.encode a)
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
def update [Entity α] (old : Stored α) (new : α) : DbM (Stored α) := withLog "update" (Entity.tableName α) (fun _ => 1) do
  let spec := Entity.spec α
  if spec.columns.isEmpty then
    let changed ← sqlite fun db => do
      let stmt ← db.prepare s!"UPDATE {quoteId spec.name} SET id = id WHERE id = ?"
      stmt.bindInt64 1 old.id.toInt64
      stmt.exec
      db.changes
    if changed == 0 then throw (.notFound spec.name old.id.toInt64)
    return ⟨old.id, new⟩
  let sets := String.intercalate ", " (spec.columns.toList.map (s!"{quoteId ·.name} = ?"))
  let pins := String.intercalate " AND " (spec.columns.toList.map (s!"{quoteId ·.name} IS ?"))
  let sql := s!"UPDATE {quoteId spec.name} SET {sets} WHERE id = ? AND {pins}"
  let n := spec.columns.size
  let changed ← sqliteWith (constraintError spec.name (.missingRef spec.name)) fun db => do
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
def delete [Entity α] (id : Id α) : DbM Unit := withLog "delete" (Entity.tableName α) (fun _ => 1) do
  let table := Entity.tableName α
  let changed ← sqliteWith (constraintError table (.restricted table id.toInt64)) fun db => do
    let stmt ← db.prepare s!"DELETE FROM {quoteId table} WHERE id = ?"
    stmt.bindInt64 1 id.toInt64
    stmt.exec
    db.changes
  if changed == 0 then throw (.notFound table id.toInt64)

/-- Rows of `α`'s table matching a pushed predicate, in id order. The
    table is aliased `t0` and every index of the predicate renders as
    `t0` — only conjuncts over `α`'s own columns may reach here
    (`Pred.forTable`), and a quantifier among them needs the alias to
    correlate its subquery with the outer row. Callers pass an opaque-free
    tree (`Pred.approx`). -/
def fetchFiltered (α : Type) [Entity α] {ts : List Type} (pred : Pred ts) :
    DbM (Array (Stored α)) := do
  if pred.isTrivial then return ← fetchAll α
  let (whereSql, binds) := pred.render fun _ => "t0"
  let sql := s!"SELECT {columnList α} FROM {quoteId (Entity.tableName α)} AS t0 WHERE {whereSql} ORDER BY id"
  let rows ← sqlite fun db => do
    let stmt ← db.prepare sql
    bindCols stmt 1 binds
    let mut out := #[]
    repeat
      if ← stmt.step then out := out.push (← readStored α stmt) else break
    return out
  rows.mapM liftExcept

/-- The live database as a row `Source`, ignoring plans. -/
def dbSource : Source DbM := ⟨fun _ α _ => fetchAll α⟩

/-- The live database narrowed by a pushed plan's per-table conjuncts. -/
def plannedSource {ts : List Type} (pushed : Pred ts) : Source DbM :=
  ⟨fun i α _ => fetchFiltered α (pushed.forTable i)⟩

/-- Joined execution: one SQL statement over all involved tables with the
    whole pushed predicate (join conditions included) as `WHERE`. Used
    when the plan relates tables — the pushed joins cut the product in
    SQL instead of materializing it client-side. `pushed` is opaque-free
    (`Pred.approx`). -/
def selectJoined (ts : List Type) [RowsOf ts] (pushed : Pred ts)
    (where' : Rows ts → Bool) (sortBy : SortBy (Rows ts)) : DbM (Array (Rows ts)) := do
  let specs := RowsOf.specs ts
  let froms := specs.zipIdx.map fun (spec, i) => s!"{quoteId spec.name} AS t{i}"
  let sel := specs.zipIdx.map fun (spec, i) =>
    String.intercalate ", " (s!"t{i}.id" :: spec.columns.toList.map fun c => s!"t{i}.{quoteId c.name}")
  let order := specs.zipIdx.map fun (_, i) => s!"t{i}.id"
  let (whereSql, binds) := pushed.renderT
  let sql := s!"SELECT {String.intercalate ", " sel} FROM {String.intercalate ", " froms} " ++
    s!"WHERE {whereSql} ORDER BY {String.intercalate ", " order}"
  -- One label per selected column, in the same order as `sel` above, so a
  -- bad value names the table and field it actually came from.
  let labels : Array (String × String) := specs.foldl (init := #[]) fun acc spec =>
    acc.push (spec.name, "id") ++ (spec.columns.map fun c => (spec.name, c.name))
  let raw ← sqlite fun db => do
    let stmt ← db.prepare sql
    bindCols stmt 1 binds
    let mut out : Array (Except DbError (Array Col)) := #[]
    repeat
      if ← stmt.step then
        out := out.push (← readRow stmt 0 labels.size (labels.getD · ("?", "?")))
      else break
    return out
  let rows ← raw.mapM fun r => do
    let cols ← liftExcept r
    liftExcept (RowsOf.decodeFrom (ts := ts) cols 0)
  return finishRows ts rows where' sortBy

/-- Run a pushed plan and a decider: the opaque-free `pushed` ships to
    SQL — the joined executor when it relates tables, per-table fetches
    otherwise — and `where'` is applied to what comes back. The one path
    under both `select` and `selectP`, so they cannot diverge. -/
private def runPlanned (ts : List Type) [RowsOf ts] (pushed : Pred ts)
    (where' : Rows ts → Bool) (sortBy : SortBy (Rows ts)) : DbM (Array (Rows ts)) :=
  if pushed.hasJoin then
    selectJoined ts pushed where' sortBy
  else
    selectSpec ts (plannedSource pushed) where' sortBy

private def selectDetail (ts : List Type) [RowsOf ts] (p : Pred ts) : String :=
  s!"{String.intercalate "×" ((RowsOf.specs ts).map (·.name))} | {p.describe}"

/-- The typed select. The trailing `plan` is reified from `where'` by the
    `leandb_plan` tactic at each call site as a `Pred ts`; what ships to
    SQL is its pushable projection `approx` (`Pred.approx_sound`: it never
    excludes a row the plan accepts). Join conditions route to the joined
    executor, everything else narrows per-table fetches. The lambda is
    still applied to what comes back (`finishRows`), so the reference
    semantics (`selectSpec` over an unfiltered source) define the result
    and pushdown can only be an optimization. -/
def select (ts : List Type) [RowsOf ts] (where' : Rows ts → Bool)
    (sortBy : SortBy (Rows ts) := .preserve)
    (plan : PlanFor where' := by leandb_plan) : DbM (Array (Rows ts)) :=
  withLog "select" (selectDetail ts plan.plan) (·.size) <|
    runPlanned ts plan.plan.approx where' sortBy

/-- The snapshot a plan quantifies over (LEP-0004): every child table it
    mentions, whole, via `fetchAll`. One fetch per quantified child per
    select — bounded by the child table, not by the product; a few hundred
    rows in these bases. Narrowing it to the children of the fetched
    parents (`IN (…)`) is a later optimization. -/
def Pred.snapshot {ts : List Type} (p : Pred ts) : DbM Pred.Snapshot :=
  go p.children .empty
where
  go : List ((β : Type) × Entity β) → Pred.Snapshot → DbM Pred.Snapshot
    | [], snap => pure snap
    | ⟨β, ent⟩ :: rest, snap => do
        let rows ← @fetchAll β ent
        go rest (@Pred.Snapshot.add snap β ent rows)

/-- The typed select over a plan given as data (LEP-0004) — the only way
    to write a plan that quantifies over a child table, since a lambda over
    `Rows ts` cannot mention rows it was not given. Same executor as
    `select` (`runPlanned`), same log line; the decider is the plan's own
    denotation over a snapshot of its child tables, so the
    lambda-always-runs invariant holds literally: `finishRows` filters by
    `p.denote`, and pushdown (`p.approx`) can only narrow the fetch. -/
def selectP (ts : List Type) [RowsOf ts] (p : Pred ts)
    (sortBy : SortBy (Rows ts) := .preserve) : DbM (Array (Rows ts)) :=
  withLog "select" (selectDetail ts p) (·.size) do
    let snap ← p.snapshot
    runPlanned ts p.approx (p.denote snap) sortBy

/-- `select` with pushdown disabled — the executable reference, for
    differential testing against the planned path. -/
def selectUnplanned (ts : List Type) [RowsOf ts] (where' : Rows ts → Bool)
    (sortBy : SortBy (Rows ts) := .preserve) : DbM (Array (Rows ts)) :=
  selectSpec ts dbSource where' sortBy

/-! ## Opening an instance -/

private def metaDdl : String :=
  "CREATE TABLE IF NOT EXISTS _leandb_meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)"

def migrationsDdl : String :=
  "CREATE TABLE IF NOT EXISTS _leandb_migrations (idx INTEGER PRIMARY KEY AUTOINCREMENT, \
steps TEXT NOT NULL, fingerprint TEXT NOT NULL, \
applied_at INTEGER NOT NULL DEFAULT (unixepoch()), ok INTEGER NOT NULL)"

private def logDdl : String :=
  "CREATE TABLE IF NOT EXISTS _leandb_log (id INTEGER PRIMARY KEY AUTOINCREMENT, \
at INTEGER NOT NULL DEFAULT (unixepoch()), verb TEXT NOT NULL, detail TEXT NOT NULL, \
ok INTEGER NOT NULL, error TEXT, rows INTEGER NOT NULL)"

def readMeta (db : SQLite) (key : String) : IO (Option String) := do
  let stmt ← db.prepare "SELECT value FROM _leandb_meta WHERE key = ?"
  stmt.bindText 1 key
  if ← stmt.step then some <$> stmt.columnText 0 else return none

def writeMeta (db : SQLite) (key value : String) : IO Unit := do
  let stmt ← db.prepare "INSERT OR REPLACE INTO _leandb_meta (key, value) VALUES (?, ?)"
  stmt.bindText 1 key
  stmt.bindText 2 value
  stmt.exec

/-- Open (creating if absent) an instance for the given schema. Applies
    DDL idempotently and refuses to open an instance whose fingerprint
    disagrees with the code's — drift is an error, not a surprise. -/
def openDb (path : System.FilePath) (specs : List TableSpec) : IO (Except DbError Conn) := do
  if let .error e := validateSchema specs then return .error e
  try
    let db ← SQLite.open path
    db.exec "PRAGMA foreign_keys = ON"
    db.exec metaDdl
    db.exec logDdl
    db.exec migrationsDdl
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
    writeMeta db "schema_json" (specsToJson specs).compress
    if (← readMeta db "schema_version").isNone then
      writeMeta db "schema_version" "1"
    return .ok ⟨db⟩
  catch e =>
    return .error (.sqlite (toString e))

/-- Recent query-log entries, newest first, as JSON rows. -/
def readLog (limit : Nat) : DbM (Array Lean.Json) := sqlite fun db => do
  let stmt ← db.prepare
    "SELECT id, at, verb, detail, ok, error, rows FROM _leandb_log ORDER BY id DESC LIMIT ?"
  stmt.bindInt64 1 (Int64.ofNat limit)
  let mut out := #[]
  repeat
    if ← stmt.step then
      let err ← (do if (← stmt.columnType 5) == .null then pure Lean.Json.null
                    else Lean.Json.str <$> stmt.columnText 5)
      out := out.push <| Lean.Json.mkObj [
        ("id", Lean.toJson (← stmt.columnInt64 0).toInt),
        ("at", Lean.toJson (← stmt.columnInt64 1).toInt),
        ("verb", Lean.Json.str (← stmt.columnText 2)),
        ("detail", Lean.Json.str (← stmt.columnText 3)),
        ("ok", Lean.Json.bool ((← stmt.columnInt64 4) == 1)),
        ("error", err),
        ("rows", Lean.toJson (← stmt.columnInt64 6).toInt)]
    else break
  return out

/-- Open, run, and report — the whole lifecycle for scripts and tests. -/
def withDb (path : System.FilePath) (specs : List TableSpec) (act : DbM α) :
    IO (Except DbError α) := do
  match ← openDb path specs with
  | .error e => return .error e
  | .ok conn => act.run conn

end LeanDb
