import LeanDb
import FixturePortable

deriving instance LeanDb.ClosedEnum for PortableRole
deriving instance LeanDb.Inline for PortableReply

/-! LDB-01: the public transaction combinator and `LeanDb.Runtime.Service`.

Engine-level acceptance tests: nested savepoint rollback leaves the outer
transaction intact; `.abort` returns the value and rolls back; `BEGIN
IMMEDIATE` blocks a second writer until commit; reentrancy through
`withConnection` is a typed error; a throwing callback leaves the service
ready. -/

namespace TestsLdb01

open LeanDb

private def check (condition : Bool) (message : String) : IO Unit :=
  unless condition do throw <| IO.userError s!"FAIL: {message}"

private def check' (condition : Bool) (message : String) : DbM Unit :=
  unless condition do throw (.sqlite s!"FAIL: {message}")

private def expectOk (r : Except DbError α) (context : String) : IO α :=
  match r with
  | .ok a => pure a
  | .error e => throw <| IO.userError s!"FAIL: {context}: {e}"

structure TxAuthor where
  name : String
  deriving Repr, LeanDb.Entity

private def specs : List TableSpec := [Entity.spec TxAuthor]

private def dbPath : System.FilePath := ".lake" / "leandb_test_ldb01.sqlite"
private def dbPath2 : System.FilePath := ".lake" / "leandb_test_ldb01_svc.sqlite"

private def fresh (p : System.FilePath) : IO Unit := do
  if ← p.pathExists then IO.FS.removeFile p
  for suffix in ["-wal", "-shm"] do
    let side : System.FilePath := p.toString ++ suffix
    if ← side.pathExists then IO.FS.removeFile side

/-- `.abort` returns the value and rolls the write back. -/
private def testAbort : IO Unit := do
  fresh dbPath
  let r ← withDb dbPath specs do
    let r ← transaction do
      discard <| insert TxAuthor ⟨"ghost"⟩
      return (Tx.abort "domain says no" : Tx String Unit)
    check' (r matches .error "domain says no") "abort carries the domain value"
    let all ← fetchAll TxAuthor
    check' all.isEmpty "aborted insert leaves no row"
  discard <| expectOk r "abort test"

/-- A nested transaction aborts via savepoint; the outer commits. -/
private def testNestedSavepoint : IO Unit := do
  fresh dbPath
  let r ← withDb dbPath specs do
    let r : Except String Unit ← transaction do
      discard <| insert TxAuthor ⟨"outer"⟩
      let inner ← transaction do
        discard <| insert TxAuthor ⟨"inner"⟩
        return (Tx.abort "inner abort" : Tx String Unit)
      check' (inner matches .error "inner abort") "inner abort value"
      return Tx.commit ()
    check' (r matches .ok ()) "outer commits despite inner abort"
    let names ← (·.map (·.val.name)) <$> fetchAll TxAuthor
    check' (names == #["outer"]) s!"outer row survives, inner rolled back (got {names})"
  discard <| expectOk r "nested savepoint test"

/-- `withTransaction` commits; a `DbError` inside rolls back and re-raises. -/
private def testWithTransaction : IO Unit := do
  fresh dbPath
  let r ← withDb dbPath specs do
    withTransaction do
      discard <| insert TxAuthor ⟨"committed"⟩
    let names ← (·.map (·.val.name)) <$> fetchAll TxAuthor
    check' (names == #["committed"]) "withTransaction commits"
  discard <| expectOk r "withTransaction commit"
  let r ← withDb dbPath specs do
    let act : DbM Unit := withTransaction do
      discard <| insert TxAuthor ⟨"rolled back"⟩
      throw (.sqlite "boom")
    match ← (fun conn => ExceptT.mk (.ok <$> (act conn).run)) with
    | .error e => check' (e.code == "sqlite") "error re-raised"
    | .ok () => throw (.sqlite "FAIL: expected error")
    let names ← (·.map (·.val.name)) <$> fetchAll TxAuthor
    check' (names == #["committed"]) "failed withTransaction rolled back"
  discard <| expectOk r "withTransaction rollback"

/-- `untrackedSqlite` runs raw SQL inside the open transaction. -/
private def testUntracked : IO Unit := do
  fresh dbPath
  let r ← withDb dbPath specs do
    withTransaction do
      discard <| insert TxAuthor ⟨"typed"⟩
      untrackedSqlite fun db =>
        db.exec "INSERT INTO \"tx_author\" (\"name\") VALUES ('raw')"
    let names ← (·.map (·.val.name)) <$> fetchAll TxAuthor
    check' (names == #["typed", "raw"]) "raw write inside the transaction commits"
  discard <| expectOk r "untrackedSqlite"

/-- `BEGIN IMMEDIATE` holds the write lock: a second connection's write
    waits for the first commit (busy_timeout honoured). -/
private def testImmediateBlocks : IO Unit := do
  fresh dbPath
  discard <| expectOk (← withDb dbPath specs (pure ())) "create"
  let conn1 ← expectOk (← openDb dbPath specs) "conn1"
  let conn2 ← expectOk (← openDb dbPath specs) "conn2"
  -- conn1 holds BEGIN IMMEDIATE for ~400ms; conn2's writer must land after.
  let t1 ← IO.asTask (prio := .default) do
    DbM.run conn1 <| transaction do
      discard <| insert TxAuthor ⟨"first"⟩
      untrackedSqlite fun _ => IO.sleep 400
      return (Tx.commit (← IO.monoMsNow) : Tx String Nat)
  IO.sleep 100
  let started ← IO.monoMsNow
  let r2 ← DbM.run conn2 <| withTransaction do
    discard <| insert TxAuthor ⟨"second"⟩
  let done ← IO.monoMsNow
  discard <| expectOk r2 "second writer waits then commits"
  let committedAt := (← expectOk (← IO.ofExcept t1.get) "first transaction").toOption.getD 0
  check (done >= committedAt) s!"second writer ran before first committed ({done} < {committedAt})"
  check (done - started >= 200) s!"second writer did not wait ({done - started}ms)"
  let names ← expectOk (← DbM.run conn1 ((·.map (·.val.name)) <$> fetchAll TxAuthor)) "read back"
  check (names == #["first", "second"]) s!"both rows committed: {names}"

private def svcBase : Base :=
  { name := "ldb01svc", tables := [CliTable.of TxAuthor] }

/-- `withConnection` reentrancy is a typed error; a throwing callback
    leaves the service ready; drain/resume/close gate admission. -/
private def testService : IO Unit := do
  fresh dbPath2
  let svc ← Runtime.Service.new svcBase (Instance.ofPath dbPath2) .serve true
  check (← svc.ready) "service ready after open"
  check ((← svc.state) == .ready) "state ready"
  check (!svc.session.readOnly) "serve session is not read-only"
  -- reentrancy: the callback calls back in on the same thread
  let r : Except Runtime.RuntimeError (Except Runtime.RuntimeError Unit) ←
    svc.withConnection fun _ => svc.withConnection fun _ => pure ()
  match r with
  | .ok (.error .reentrant) | .error .reentrant => pure ()
  | _ => throw <| IO.userError "FAIL: reentrant withConnection must be rejected"
  -- a throwing callback becomes .host and the service stays ready
  let r : Except Runtime.RuntimeError Unit ← svc.withConnection fun _ =>
    throw <| IO.userError "boom"
  match r with
  | .error (.host _) => pure ()
  | _ => throw <| IO.userError "FAIL: host exception must be typed"
  check (← svc.ready) "service ready after a throwing callback"
  -- work runs on the connection
  let r : Except Runtime.RuntimeError _ ← svc.withConnection fun conn =>
    DbM.run conn (insert TxAuthor ⟨"via service"⟩)
  match r with
  | .ok (.ok _) => pure ()
  | _ => throw <| IO.userError s!"FAIL: insert through service: {repr r}"
  -- drain refuses new admission, resume restores it
  svc.drain
  check ((← svc.state) == .draining) "draining state"
  check (!(← svc.ready)) "not ready while draining"
  let r ← svc.withConnection fun _ => pure ()
  check (r matches .error (.notReady .draining)) "drain refuses admission"
  svc.resume
  check (← svc.ready) "ready after resume"
  -- snapshot writes a copy
  let snap : System.FilePath := ".lake" / "leandb_test_ldb01_snap.sqlite"
  if ← snap.pathExists then IO.FS.removeFile snap
  let r ← svc.snapshot snap
  check r.isOk "snapshot succeeds"
  check (← snap.pathExists) "snapshot file exists"
  -- restore replaces the file and re-verifies
  let r ← svc.restore snap
  check r.isOk s!"restore succeeds: {repr r}"
  check (← svc.ready) "ready after restore"
  -- status reports private diagnostics
  let st ← Runtime.status svc
  check ((st.getObjValAs? String "database").toOption == some dbPath2.toString)
    "status names the database"
  check ((st.getObjValAs? Bool "ready").toOption == some true) "status ready"
  -- close is terminal
  svc.close
  check ((← svc.state) == .closed) "closed state"
  let r ← svc.withConnection fun _ => pure ()
  check (r matches .error (.notReady .closed)) "closed refuses admission"

/-- An inspection session is never ready. -/
private def testInspectSession : IO Unit := do
  fresh dbPath2
  let svc ← Runtime.Service.new svcBase (Instance.ofPath dbPath2) .inspect true
  check (svc.session.readOnly) "inspect session is read-only"
  check (!(← svc.ready)) "inspection session is never ready"
  svc.close

structure IndexedDoc where
  doc : String
  revision : Nat
  deriving Repr, LeanDb.Entity

instance : Indexes IndexedDoc where
  indexes := #[{ unique := true, columns := #["doc", "revision"] }]

structure Counted where
  tag : String
  deriving Repr, LeanDb.Entity

structure PortableRow where
  role : PortableRole
  note : String
  deriving Repr, LeanDb.Entity

private def io (act : IO α) : DbM α :=
  fun _ => ExceptT.mk (Except.ok <$> act)

private def testIndexes : IO Unit := do
  fresh dbPath
  let specs := [Entity.spec IndexedDoc]
  check ((Entity.spec IndexedDoc).indexes.size == 1) "Indexes instance reaches TableSpec"
  let r ← withDb dbPath specs do
    discard <| insert IndexedDoc ⟨"a", 1⟩
    let act : DbM Unit := discard <| insert IndexedDoc ⟨"a", 1⟩
    match ← (fun conn => ExceptT.mk (.ok <$> (act conn).run)) with
    | .error e => check' (e.code == "duplicate") "unique index names the violation"
    | .ok () => throw (.sqlite "FAIL: expected duplicate")
  discard <| expectOk r "indexes"

private def testCountExists : IO Unit := do
  fresh dbPath
  let r ← withDb dbPath [Entity.spec Counted] do
    discard <| insert Counted ⟨"x"⟩
    discard <| insert Counted ⟨"x"⟩
    discard <| insert Counted ⟨"y"⟩
    let n ← countP (ts := [Counted]) .tt
    check' (n == 3) s!"countP tt = 3, got {n}"
    let yes ← existsP (ts := [Counted]) .tt
    check' yes "existsP tt"
  discard <| expectOk r "count/exists"

private def testPatchInsertManyScan : IO Unit := do
  fresh dbPath
  let r ← withDb dbPath [Entity.spec Counted] do
    let stored ← insertMany Counted #[⟨"a"⟩, ⟨"b"⟩, ⟨"c"⟩]
    check' (stored.size == 3) "insertMany returns 3"
    let some first := stored[0]? | throw (.sqlite "FAIL: empty insertMany")
    let p : Patch Counted :=
      { sets := #[Assignment.of Counted.Field.tag "aa"] }
    let pr ← patch first.id p
    check' (pr == .updated) "patch updates"
    let got ← get first.id
    check' (got.map (·.val.tag) == some "aa") "patched column"
    let n ← io (IO.mkRef (0 : Nat))
    scan (α := Counted) .tt 2 fun chunk => do
      io (n.modify (· + chunk.size))
      return true
    let total ← io n.get
    check' (total == 3) s!"scan visited {total}"
  discard <| expectOk r "patch/insertMany/scan"

private def testOpenConfigAndLogPolicy : IO Unit := do
  fresh dbPath
  let log : LogConfig := { verbs := .failuresOnly }
  let conn ← expectOk (← openDb dbPath [Entity.spec Counted] log
    { synchronous := .normal, busyTimeoutMs := 2500 }) "open with config"
  discard <| expectOk (← DbM.run conn (insert Counted ⟨"z"⟩)) "insert"
  let logs ← expectOk (← DbM.run conn (readLog 10)) "readLog"
  check (logs.isEmpty) s!"failuresOnly writes no success rows, got {logs.size}"
  check (conn.openConfig.synchronous == .normal) "openConfig recorded"
  check (!conn.readOnly) "writer is not read-only"

private def testPostHocDeriving : IO Unit := do
  fresh dbPath
  check (ClosedEnum.variants (α := PortableRole) == #["admin", "user"])
    "post-hoc ClosedEnum variants"
  let r ← withDb dbPath [Entity.spec PortableRow] do
    discard <| insert PortableRow ⟨.admin, "ok"⟩
    let rows ← fetchAll PortableRow
    check' (rows.size == 1) "portable row round-trips"
  discard <| expectOk r "post-hoc deriving"

private def testReadOnlyGuard : IO Unit := do
  fresh dbPath
  discard <| expectOk (← withDb dbPath [Entity.spec Counted] (pure ())) "create"
  let ro ← expectOk (← openDbRaw dbPath {} {} true) "open readonly"
  check ro.readOnly "flag set"
  let r ← DbM.run ro (insert Counted ⟨"nope"⟩)
  match r with
  | .error e => check (e.code == "read_only") s!"readOnly error, got {e}"
  | .ok _ => throw <| IO.userError "FAIL: write on readonly must fail"

def run : IO Unit := do
  testAbort
  testNestedSavepoint
  testWithTransaction
  testUntracked
  testImmediateBlocks
  testService
  testInspectSession
  testIndexes
  testCountExists
  testPatchInsertManyScan
  testOpenConfigAndLogPolicy
  testPostHocDeriving
  testReadOnlyGuard

end TestsLdb01
