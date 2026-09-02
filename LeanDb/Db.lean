import SQLite
import Std.Data.HashMap
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
  /-- The registered query being run, if any: `query <name>` sets it so
      the log can attribute the plans it records. -/
  queryName : IO.Ref (Option String)

def Conn.ofRaw (raw : SQLite) : IO Conn := do
  return { raw, queryName := ← IO.mkRef none }

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

def bindCol (stmt : SQLite.Stmt) (idx : Int32) : Col → IO Unit
  | .int v => stmt.bindInt64 idx v
  | .text v => stmt.bindText idx v
  | .real v => stmt.bindFloat idx v
  | .null => stmt.bindNull idx

/-- Bind row values starting at parameter `first` (bind params are 1-based). -/
def bindCols (stmt : SQLite.Stmt) (first : Nat) (cols : Array Col) : IO Unit := do
  for h : i in [0:cols.size] do
    bindCol stmt (Int32.ofNat (first + i)) cols[i]

/-- A column we cannot represent (`none`) is a decode failure like any
    other; the caller names the table and field it came from. -/
def readCol (stmt : SQLite.Stmt) (i : Int32) : IO (Option Col) := do
  match ← stmt.columnType i with
  | .integer => return some (.int (← stmt.columnInt64 i))
  | .float => return some (.real (← stmt.columnDouble i))
  | .text => return some (.text (← stmt.columnText i))
  | .null => return some .null
  | .blob => return none

/-- Read `n` result columns starting at `first`. `label i` names the
    `(table, field)` column `i` was selected from — consulted only when a
    value cannot be represented, so a row decode allocates nothing for it. -/
def readRow (stmt : SQLite.Stmt) (first n : Nat) (label : Nat → String × String) :
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
private def logOp (verb detail : String) (ok : Bool) (error : Option String) (rows : Nat)
    (plan : Option String) : DbM Unit := fun conn => ExceptT.mk do
  try
    let query ← conn.queryName.get
    let stmt ← conn.raw.prepare
      "INSERT INTO _leandb_log (verb, detail, ok, error, rows, plan, query) VALUES (?, ?, ?, ?, ?, ?, ?)"
    stmt.bindText 1 verb
    stmt.bindText 2 detail
    stmt.bindInt64 3 (if ok then 1 else 0)
    match error with
    | some e => stmt.bindText 4 e
    | none => stmt.bindNull 4
    stmt.bindInt64 5 (Int64.ofNat rows)
    match plan with
    | some p => stmt.bindText 6 p
    | none => stmt.bindNull 6
    match query with
    | some q => stmt.bindText 7 q
    | none => stmt.bindNull 7
    stmt.exec
    return .ok ()
  catch _ => return .ok ()

/-- Run an operation and log it: verb, detail, outcome, row count, and for
    a select the plan as data. The query log is the audit trail and the
    agent's episodic memory (plan.md §4.4) — on by default. -/
private def withLog (verb detail : String) (count : α → Nat) (act : DbM α)
    (plan : Option String := none) : DbM α := do
  match ← fun conn => ExceptT.mk (.ok <$> (act conn).run) with
  | .ok a =>
      logOp verb detail true none (count a) plan
      return a
  | .error e =>
      logOp verb detail false (some e.code) 0 plan
      throw e

private def liftExcept (r : Except DbError α) : DbM α := DbM.ofExcept r

private def quoteId (s : String) : String := quoteIdent s

private def columnList (α : Type) [Entity α] : String :=
  String.intercalate ", " ("id" :: (Entity.columns α).toList.map (quoteId ·.name))

private def placeholders (n : Nat) : String :=
  String.intercalate ", " (List.replicate n "?")

/-! ## Child tables (LEP-0003 D)

A parent's child lists live in their own tables and are *part of the
parent's value*: every read reattaches them, every write owns them.
Reads cost one engine-internal statement per child table per fetch —
`WHERE parent IN (…)` over the fetched parents, chunked — never one per
row. Writes run inside a transaction. -/

/-- Run `act` inside `BEGIN … COMMIT`; any failure rolls back and re-raises
    the typed error. Used by the verbs that write more than one row. -/
private def transaction (act : DbM α) : DbM α := fun conn => ExceptT.mk do
  let exec (sql : String) : IO (Except DbError Unit) :=
    try conn.raw.exec sql; pure (.ok ()) catch e => pure (.error (.sqlite (toString e)))
  match ← exec "BEGIN" with
  | .error e => return .error e
  | .ok () =>
    let r ← try (act conn).run catch e => pure (.error (.sqlite (toString e)))
    match r with
    | .ok a =>
        match ← exec "COMMIT" with
        | .ok () => return .ok a
        | .error e => discard <| exec "ROLLBACK"; return .error e
    | .error e => discard <| exec "ROLLBACK"; return .error e

/-- How many parent ids one child fetch names: SQLite's default parameter
    limit is far above this, and the statement text stays small. -/
private def childChunk : Nat := 500

/-- Attach every child list of `α` to `rows`: per child table, one
    `SELECT parent, position, <record columns> … WHERE parent IN (…) ORDER
    BY parent, position` per chunk of parent ids, grouped by parent, then
    `ChildLink.attach` (which also checks derived columns computed from
    the list). Order and length of `rows` are preserved; an entity without
    children costs nothing. -/
private def attachChildren (α : Type) [Entity α] (rows : Array (Stored α)) :
    DbM (Array (Stored α)) := do
  let links := Entity.children (α := α)
  if links.isEmpty || rows.isEmpty then return rows
  -- distinct parent ids (a joined result repeats a parent per product row)
  let ids := (rows.map (·.id.toInt64)).qsort (· < ·)
  let ids := ids.foldl (init := #[]) fun acc i =>
    if acc.back? == some i then acc else acc.push i
  let mut rows := rows
  for link in links do
    let cols := link.spec.columns
    let parentCol := cols.getD 0 default |>.name
    let positionCol := cols.getD 1 default |>.name
    let names := String.intercalate ", " (cols.toList.map (quoteId ·.name))
    let n := link.recordColumns.size
    let label (i : Nat) : String × String := (link.table, ((cols[i + 2]?).map (·.name)).getD "?")
    let mut groups : Std.HashMap Int64 (Array (Nat × Array Col)) := {}
    for start in [0:ids.size:childChunk] do
      let chunk := ids.extract start (start + childChunk)
      let sql := s!"SELECT {names} FROM {quoteId link.table} WHERE {quoteId parentCol} IN ({placeholders chunk.size}) ORDER BY {quoteId parentCol}, {quoteId positionCol}"
      let raw ← sqlite fun db => do
        let stmt ← db.prepare sql
        for h : i in [0:chunk.size] do stmt.bindInt64 (Int32.ofNat (i + 1)) chunk[i]
        let mut out : Array (Int64 × Nat × Except DbError (Array Col)) := #[]
        repeat
          if ← stmt.step then
            let parent ← stmt.columnInt64 0
            let position ← stmt.columnInt64 1
            out := out.push (parent, position.toNatClampNeg, ← readRow stmt 2 n label)
          else break
        return out
      for (parent, position, r) in raw do
        let cols ← liftExcept r
        groups := groups.insert parent ((groups.getD parent #[]).push (position, cols))
    rows ← rows.mapM fun r => do
      let v ← liftExcept (link.attach (groups.getD r.id.toInt64 #[]) r.val)
      return ⟨r.id, v⟩
  return rows

/-- Write the child rows of one list for parent `id`: positions `0…`, the
    record's columns after `parent` and `position`. -/
private def insertChildren [Entity α] (link : ChildLink α) (id : Int64) (a : α) : DbM Unit := do
  let rows := link.rows a
  if rows.isEmpty then return
  let names := String.intercalate ", " (link.spec.columns.toList.map (quoteId ·.name))
  let sql := s!"INSERT INTO {quoteId link.table} ({names}) VALUES ({placeholders link.spec.columns.size})"
  sqliteWith (constraintError link.table (.missingRef link.table)) fun db => do
    let stmt ← db.prepare sql
    for h : i in [0:rows.size] do
      stmt.reset
      stmt.clearBindings
      stmt.bindInt64 1 id
      stmt.bindInt64 2 (Int64.ofNat i)
      bindCols stmt 3 rows[i]
      stmt.exec

/-- `INSERT` a value; returns it with its assigned identity. A parent with
    child lists writes its own row and then every child row, in one
    transaction. -/
def insert (α : Type) [Entity α] (a : α) : DbM (Stored α) := withLog "insert" (Entity.tableName α) (fun _ => 1) do
  let spec := Entity.spec α
  let links := Entity.children (α := α)
  let names := String.intercalate ", " (spec.columns.toList.map (quoteId ·.name))
  let sql := if spec.columns.isEmpty then
    s!"INSERT INTO {quoteId spec.name} DEFAULT VALUES"
  else
    s!"INSERT INTO {quoteId spec.name} ({names}) VALUES ({placeholders spec.columns.size})"
  let act : DbM (Stored α) := do
    sqliteWith (constraintError spec.name (.missingRef spec.name)) fun db => do
      let stmt ← db.prepare sql
      unless spec.columns.isEmpty do bindCols stmt 1 (Entity.encode a)
      stmt.exec
    let id ← sqlite (·.lastInsertRowId)
    for link in links do insertChildren link id a
    return ⟨⟨id⟩, a⟩
  if links.isEmpty then act else transaction act

/-- Fetch one row by typed identity. -/
def get [Entity α] (id : Id α) : DbM (Option (Stored α)) := do
  let sql := s!"SELECT {columnList α} FROM {quoteId (Entity.tableName α)} WHERE id = ?"
  let row ← sqlite fun db => do
    let stmt ← db.prepare sql
    stmt.bindInt64 1 id.toInt64
    if ← stmt.step then some <$> readStored α stmt else return none
  match row with
  | none => return none
  | some r => do
      let rows ← attachChildren α #[← liftExcept r]
      return rows[0]?

/-- Every row of `α`'s table, in id order. -/
def fetchAll (α : Type) [Entity α] : DbM (Array (Stored α)) := do
  let sql := s!"SELECT {columnList α} FROM {quoteId (Entity.tableName α)} ORDER BY id"
  let rows ← sqlite fun db => do
    let stmt ← db.prepare sql
    let mut out := #[]
    repeat
      if ← stmt.step then out := out.push (← readStored α stmt) else break
    return out
  attachChildren α (← rows.mapM liftExcept)

/-- Compare-and-swap update: `SET` to `new` only where the row still equals
    `old`, id included. A lost race is a typed `.stale`, never a silent
    clobber. `IS` (not `=`) so `NULL` columns pin correctly. The CAS is on
    the parent's own columns; once it holds, every child list is replaced
    wholesale (`DELETE … WHERE parent = ?`, then re-inserted), in the same
    transaction. -/
def update [Entity α] (old : Stored α) (new : α) : DbM (Stored α) := withLog "update" (Entity.tableName α) (fun _ => 1) do
  let spec := Entity.spec α
  let links := Entity.children (α := α)
  let cas : DbM Unit := do
    if spec.columns.isEmpty then
      let changed ← sqlite fun db => do
        let stmt ← db.prepare s!"UPDATE {quoteId spec.name} SET id = id WHERE id = ?"
        stmt.bindInt64 1 old.id.toInt64
        stmt.exec
        db.changes
      if changed == 0 then throw (.notFound spec.name old.id.toInt64)
      return
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
  let act : DbM (Stored α) := do
    cas
    for link in links do
      let parentCol := (link.spec.columns.getD 0 default).name
      sqlite fun db => do
        let stmt ← db.prepare s!"DELETE FROM {quoteId link.table} WHERE {quoteId parentCol} = ?"
        stmt.bindInt64 1 old.id.toInt64
        stmt.exec
      insertChildren link old.id.toInt64 new
    return ⟨old.id, new⟩
  if links.isEmpty then act else transaction act

/-- Delete by typed identity. Rows referenced elsewhere refuse with
    `.restricted` (FK RESTRICT) — destruction is loud. A parent's own child
    rows go with it (the child FK cascades: they are part of its value),
    while any other table's `Ref` to it still restricts. -/
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
  attachChildren α (← rows.mapM liftExcept)

/-- The live database as a row `Source`, ignoring plans. Rows come with
    their child lists attached, so `selectSpec` over it — the reference
    semantics — sees whole values. -/
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
  let rows ← RowsOf.mapTables (ts := ts) (fun α _ rows => attachChildren α rows) rows
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

/-- A column reference as JSON: the table at its row position and its name. -/
private def colJson (names : Nat → String) {ts : List Type} {τ : Type} {i : ColCodec τ}
    (c : Pred.Col ts τ i) : Lean.Json :=
  Lean.Json.mkObj [("table", Lean.Json.str (names c.tableIdx)), ("column", Lean.Json.str c.name)]

/-- The plan as data (the log stores this next to `describe`'s text): one
    object per node, values in their stored encoding, the residual as
    `{"opaque":true}`. Quantifiers carry the child table and their body
    over `child :: ts`. -/
partial def Pred.toJsonWith {ts : List Type} (names : Nat → String) : Pred ts → Lean.Json
  | .tt => Lean.Json.mkObj [("kind", Lean.Json.str "tt")]
  | .ff => Lean.Json.mkObj [("kind", Lean.Json.str "ff")]
  | .eq (i := i) c op v =>
      Lean.Json.mkObj [("kind", Lean.Json.str "eq"), ("col", colJson names c),
        ("op", Lean.Json.str op.sql), ("value", (@toCol _ i v).toJson)]
  | .ord (i := i) (so := _) c op v =>
      Lean.Json.mkObj [("kind", Lean.Json.str "ord"), ("col", colJson names c),
        ("op", Lean.Json.str op.sql), ("value", (@toCol _ i v).toJson)]
  | .eq2 a op b =>
      Lean.Json.mkObj [("kind", Lean.Json.str "eq2"), ("left", colJson names a),
        ("op", Lean.Json.str op.sql), ("right", colJson names b)]
  | .ord2 (so := _) a op b =>
      Lean.Json.mkObj [("kind", Lean.Json.str "ord2"), ("left", colJson names a),
        ("op", Lean.Json.str op.sql), ("right", colJson names b)]
  | .isNull c => Lean.Json.mkObj [("kind", Lean.Json.str "isNull"), ("col", colJson names c)]
  | .isNotNull c => Lean.Json.mkObj [("kind", Lean.Json.str "isNotNull"), ("col", colJson names c)]
  | .bit (ce := ce) c a set =>
      Lean.Json.mkObj [("kind", Lean.Json.str "bit"), ("col", colJson names c),
        ("variant", Lean.Json.str (@ClosedEnum.encodeName _ ce a)), ("set", Lean.Json.bool set)]
  | .and a b => Lean.Json.mkObj [("kind", Lean.Json.str "and"),
      ("a", a.toJsonWith names), ("b", b.toJsonWith names)]
  | .or a b => Lean.Json.mkObj [("kind", Lean.Json.str "or"),
      ("a", a.toJsonWith names), ("b", b.toJsonWith names)]
  | .opaque _ => Lean.Json.mkObj [("opaque", Lean.Json.bool true)]
  | .exists (child := child) (ent := ent) parent fk body =>
      let childName := @Entity.tableName child ent
      let inner := fun i => if i == 0 then childName else names (i - 1)
      Lean.Json.mkObj [("kind", Lean.Json.str "exists"), ("child", Lean.Json.str childName),
        ("parent", colJson names parent), ("fk", colJson inner fk), ("body", body.toJsonWith inner)]
  | .forall (child := child) (ent := ent) parent fk body =>
      let childName := @Entity.tableName child ent
      let inner := fun i => if i == 0 then childName else names (i - 1)
      Lean.Json.mkObj [("kind", Lean.Json.str "forall"), ("child", Lean.Json.str childName),
        ("parent", colJson names parent), ("fk", colJson inner fk), ("body", body.toJsonWith inner)]

def Footprint.toJson (f : Footprint) : Lean.Json :=
  Lean.Json.mkObj [("tables", Lean.Json.arr (f.tables.map Lean.Json.str).toArray),
    ("columns", Lean.Json.arr (f.columns.map fun (t, c) => Lean.Json.str s!"{t}.{c}").toArray),
    ("residual", Lean.Json.bool f.residual)]

/-- What the log stores for a select: the tables, the plan, its footprint. -/
private def planJson (ts : List Type) [RowsOf ts] (p : Pred ts) : String :=
  let specs := RowsOf.specs ts
  let names := fun i => (specs[i]?.map (·.name)).getD s!"t{i}"
  (Lean.Json.mkObj [("tables", Lean.Json.arr (specs.map (Lean.Json.str ·.name)).toArray),
    ("plan", p.toJsonWith names), ("footprint", p.footprint.toJson)]).compress

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
  withLog "select" (selectDetail ts plan.plan) (·.size) (plan := some (planJson ts plan.plan)) <|
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
  withLog "select" (selectDetail ts p) (·.size) (plan := some (planJson ts p)) do
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

/-- Columns the log gained after 0.2.0: the plan as data and the query
    it ran under. -/
def logColumns : List (String × String) := [("plan", "TEXT"), ("query", "TEXT")]

def readMeta (db : SQLite) (key : String) : IO (Option String) := do
  let stmt ← db.prepare "SELECT value FROM _leandb_meta WHERE key = ?"
  stmt.bindText 1 key
  if ← stmt.step then some <$> stmt.columnText 0 else return none

def writeMeta (db : SQLite) (key value : String) : IO Unit := do
  let stmt ← db.prepare "INSERT OR REPLACE INTO _leandb_meta (key, value) VALUES (?, ?)"
  stmt.bindText 1 key
  stmt.bindText 2 value
  stmt.exec

/-- Add the columns of an engine bookkeeping table that an older engine
    did not create (idempotent; `PRAGMA table_info` decides). Only the
    engine's own tables are ever touched this way. -/
def ensureColumns (db : SQLite) (table : String) (cols : List (String × String)) : IO Unit := do
  let stmt ← db.prepare s!"PRAGMA table_info({quoteId table})"
  let mut present : List String := []
  repeat
    if ← stmt.step then
      present := (← stmt.columnText 1) :: present
    else break
  for (name, decl) in cols do
    unless present.contains name do
      db.exec s!"ALTER TABLE {quoteId table} ADD COLUMN {quoteId name} {decl}"

/-- Columns the journal gained after 0.2.0: the versions a migration moved
    between, the backup taken before it, and a free-form note. -/
def journalColumns : List (String × String) :=
  [("from_version", "INTEGER"), ("to_version", "INTEGER"), ("backup", "TEXT"), ("note", "TEXT")]

/-- SQLite's clock, so backups and journal rows agree on the epoch. -/
def unixNow (conn : Conn) : IO Nat := do
  let stmt ← conn.raw.prepare "SELECT unixepoch()"
  if ← stmt.step then return (← stmt.columnInt64 0).toNatClampNeg else return 0

/-- A full, consistent copy of the instance at `dest` (`VACUUM INTO`),
    after a WAL checkpoint so nothing is left in a `-wal` file. `dest`
    must not exist. -/
def backupTo (conn : Conn) (dest : System.FilePath) : IO Unit := do
  if let some parent := dest.parent then
    IO.FS.createDirAll parent
  if ← dest.pathExists then
    throw <| IO.userError s!"backup target already exists: {dest}"
  conn.raw.exec "PRAGMA wal_checkpoint(TRUNCATE)"
  let quoted := "'" ++ (dest.toString.replace "'" "''") ++ "'"
  conn.raw.exec s!"VACUUM INTO {quoted}"

/-- The migration journal, newest first. -/
def readJournal (conn : Conn) (limit : Nat) : IO (Array Lean.Json) := do
  let stmt ← conn.raw.prepare
    "SELECT idx, steps, fingerprint, applied_at, ok, from_version, to_version, backup, note \
FROM _leandb_migrations ORDER BY idx DESC LIMIT ?"
  stmt.bindInt64 1 (Int64.ofNat limit)
  let mut out := #[]
  let optText := fun (i : Int32) => do
    if (← stmt.columnType i) == .null then pure Lean.Json.null
    else Lean.Json.str <$> stmt.columnText i
  let optInt := fun (i : Int32) => do
    if (← stmt.columnType i) == .null then pure Lean.Json.null
    else pure (Lean.toJson (← stmt.columnInt64 i).toInt)
  repeat
    if ← stmt.step then
      let steps := (Lean.Json.parse (← stmt.columnText 1)).toOption.getD Lean.Json.null
      out := out.push <| Lean.Json.mkObj [
        ("idx", Lean.toJson (← stmt.columnInt64 0).toInt),
        ("steps", steps),
        ("fingerprint", Lean.Json.str (← stmt.columnText 2)),
        ("applied_at", Lean.toJson (← stmt.columnInt64 3).toInt),
        ("ok", Lean.Json.bool ((← stmt.columnInt64 4) == 1)),
        ("from_version", ← optInt 5),
        ("to_version", ← optInt 6),
        ("backup", ← optText 7),
        ("note", ← optText 8)]
    else break
  return out

/-- Open the file (creating it if absent) and make sure the engine's own
    bookkeeping tables exist — nothing about the base's schema is checked
    or applied. A server holds a connection opened this way so it can
    answer `version`/`migrate` on a drifted instance; `Conn.verify` is the
    step that admits the base's verbs. -/
def openDbRaw (path : System.FilePath) : IO (Except DbError Conn) := do
  try
    let db ← SQLite.open path
    db.exec "PRAGMA foreign_keys = ON"
    db.exec metaDdl
    db.exec logDdl
    db.exec migrationsDdl
    ensureColumns db "_leandb_migrations" journalColumns
    ensureColumns db "_leandb_log" logColumns
    return .ok (← Conn.ofRaw db)
  catch e =>
    return .error (.sqlite (toString e))

/-- Check the open instance against the code's schema: refuse fingerprint
    drift, apply DDL idempotently, scan stored closed-world values for
    drift, and record the schema. Drift is an error, not a surprise. -/
def Conn.verify (conn : Conn) (specs : List TableSpec) (initialVersion : Nat := 1) :
    IO (Except DbError Unit) := do
  if let .error e := validateSchema specs then return .error e
  try
    let db := conn.raw
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
        -- an EnumSet column: no stored bit outside the world's mask
        if let some vs := c.enumSet then
          let stmt ← db.prepare
            s!"SELECT {quoteId c.name} FROM {quoteId spec.name} WHERE ({quoteId c.name} & ~{enumSetMask vs.size}) != 0 LIMIT 1"
          if ← stmt.step then
            return .error (.enumDrift spec.name c.name (toString (← stmt.columnInt64 0)))
    writeMeta db "schema_fingerprint" fp
    writeMeta db "schema_json" (specsToJson specs).compress
    if (← readMeta db "schema_version").isNone then
      writeMeta db "schema_version" (toString initialVersion)
    return .ok ()
  catch e =>
    return .error (.sqlite (toString e))

/-- Open (creating if absent) an instance for the given schema: `openDbRaw`
    then `Conn.verify`. Refuses to open an instance whose fingerprint
    disagrees with the code's. -/
def openDb (path : System.FilePath) (specs : List TableSpec) : IO (Except DbError Conn) := do
  match ← openDbRaw path with
  | .error e => return .error e
  | .ok conn =>
      match ← conn.verify specs with
      | .error e => return .error e
      | .ok () => return .ok conn

/-- Recent query-log entries, newest first, as JSON rows. -/
def readLog (limit : Nat) : DbM (Array Lean.Json) := sqlite fun db => do
  let stmt ← db.prepare
    "SELECT id, at, verb, detail, ok, error, rows, plan, query FROM _leandb_log ORDER BY id DESC LIMIT ?"
  stmt.bindInt64 1 (Int64.ofNat limit)
  let mut out := #[]
  repeat
    if ← stmt.step then
      let err ← (do if (← stmt.columnType 5) == .null then pure Lean.Json.null
                    else Lean.Json.str <$> stmt.columnText 5)
      let plan ← (do if (← stmt.columnType 7) == .null then pure Lean.Json.null
                     else pure ((Lean.Json.parse (← stmt.columnText 7)).toOption.getD Lean.Json.null))
      let query ← (do if (← stmt.columnType 8) == .null then pure Lean.Json.null
                      else Lean.Json.str <$> stmt.columnText 8)
      out := out.push <| Lean.Json.mkObj [
        ("id", Lean.toJson (← stmt.columnInt64 0).toInt),
        ("at", Lean.toJson (← stmt.columnInt64 1).toInt),
        ("verb", Lean.Json.str (← stmt.columnText 2)),
        ("detail", Lean.Json.str (← stmt.columnText 3)),
        ("ok", Lean.Json.bool ((← stmt.columnInt64 4) == 1)),
        ("error", err),
        ("rows", Lean.toJson (← stmt.columnInt64 6).toInt),
        ("plan", plan),
        ("query", query)]
    else break
  return out

/-- Logged selects, newest first: `(query name, footprint columns)` — what
    `migrate status` scans to say which recorded runs a change touches. -/
def logFootprints (conn : Conn) (limit : Nat) : IO (Array (Option String × List (String × String))) := do
  let stmt ← conn.raw.prepare
    "SELECT query, plan FROM _leandb_log WHERE verb = 'select' AND plan IS NOT NULL ORDER BY id DESC LIMIT ?"
  stmt.bindInt64 1 (Int64.ofNat limit)
  let mut out := #[]
  repeat
    if ← stmt.step then
      let q ← (do if (← stmt.columnType 0) == .null then pure none else some <$> stmt.columnText 0)
      let plan := (Lean.Json.parse (← stmt.columnText 1)).toOption.getD Lean.Json.null
      let cols := ((plan.getObjVal? "footprint" >>= (·.getObjValAs? (Array String) "columns")).toOption.getD #[]).toList
      let pairs := cols.filterMap fun s =>
        match s.splitOn "." with
        | [t, c] => some (t, c)
        | _ => none
      out := out.push (q, pairs)
    else break
  return out

/-- Open, run, and report — the whole lifecycle for scripts and tests. -/
def withDb (path : System.FilePath) (specs : List TableSpec) (act : DbM α) :
    IO (Except DbError α) := do
  match ← openDb path specs with
  | .error e => return .error e
  | .ok conn => act.run conn

end LeanDb
