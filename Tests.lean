import LeanDb

/-! Engine tests: codecs, deriving, the dependent select against a real
SQLite file, CAS staleness, FK restriction. Fixture types live here — the
engine library itself imports no domain. -/

open LeanDb

private def check (condition : Bool) (message : String) : IO Unit :=
  unless condition do throw <| IO.userError s!"FAIL: {message}"

/-! ## Fixtures -/

structure Author where
  name : String
  age : Nat
  deriving Repr, LeanDb.Entity

structure Book where
  title : String
  author : Ref Author
  rating : Option Float
  deriving Repr, LeanDb.Entity

def schema : List TableSpec := [Entity.spec Author, Entity.spec Book]

/-! ## Pure tests -/

private def roundtrip [ColCodec α] [BEq α] (a : α) : Bool :=
  match fromCol (toCol a) with
  | .ok b => a == b
  | .error _ => false

private def testCodecs : IO Unit := do
  check (roundtrip (42 : Int64)) "Int64 roundtrip"
  check (roundtrip (7 : Nat)) "Nat roundtrip"
  check (roundtrip true && roundtrip false) "Bool roundtrip"
  check (roundtrip "quote \" and unicode λ") "String roundtrip"
  check (roundtrip (some (3 : Nat)) && roundtrip (none : Option Nat)) "Option roundtrip"
  check ((fromCol (α := Nat) (.int (-1))).isOk == false) "negative Nat must fail decode"
  check ((fromCol (α := Bool) (.int 2)).isOk == false) "Bool 2 must fail decode"
  check ((fromCol (α := String) (.int 5)).isOk == false) "String from INTEGER must fail"

private def testDerivedSpec : IO Unit := do
  check (Entity.tableName Author == "author") "table name snake_case"
  let cols := Entity.columns Book
  check (cols.map (·.name) == #["title", "author", "rating"]) "Book column names"
  check ((cols.getD 1 default).fkTable == some "author") "Ref column carries FK target"
  check ((cols.getD 2 default).nullable == true) "Option column is nullable"
  check ((cols.getD 0 default).nullable == false) "plain column is NOT NULL"
  let a : Author := ⟨"Ada", 36⟩
  let rt : Except DbError Author := Entity.decode (Entity.encode a)
  check (rt.toOption.map (·.name) == some "Ada") "entity encode/decode roundtrip"
  check (((Entity.decode #[.int 1] : Except DbError Author)).isOk == false)
    "wrong column count must fail decode"

private def testSortBy : IO Unit := do
  let xs := #[(3, "c"), (1, "b"), (1, "a"), (2, "z")]
  let byFst : SortBy (Nat × String) := .key (·.1)
  let both : SortBy (Nat × String) := .andThen (.key (·.1)) (.desc (.key (·.2)))
  check ((xs.qsort (fun a b => (byFst.ord a b).isLT)).map (·.1) == #[1, 1, 2, 3]) "key sort"
  check ((xs.qsort (fun a b => (both.ord a b).isLT)) == #[(1, "b"), (1, "a"), (2, "z"), (3, "c")])
    "andThen + desc sort"

/-! ## Closed worlds -/

inductive Status where
  | backlog | inProgress | done
  deriving Repr, DecidableEq, LeanDb.ClosedEnum

structure Todo where
  title : String
  status : Status
  deriving Repr, LeanDb.Entity

-- Closed types are not entities: there is nothing to insert into or
-- delete from — this must not typecheck.
#check_failure insert Status Status.backlog

/-- Regression: structure field defaults must compile in the derived
    instance and be honored when JSON omits the field. -/
structure Draft where
  title : String
  status : Status := .backlog
  score : Nat := 10
  deriving Repr, LeanDb.Entity

private def testDefaults : IO Unit := do
  check (Entity.defaults Draft == #[none, some (.text "backlog"), some (.int 10)])
    s!"defaults reified from the structure, got {repr (Entity.defaults Draft)}"
  match Lean.Json.parse "{\"title\":\"t\"}" with
  | .error e => throw <| IO.userError s!"FAIL: {e}"
  | .ok j =>
      match rowOfJson Draft j with
      | .ok d => check (d.status == .backlog && d.score == 10) "omitted fields take defaults"
      | .error e => throw <| IO.userError s!"FAIL: defaults not applied: {e}"

private def testClosedEnum : IO Unit := do
  check (roundtrip Status.inProgress && roundtrip Status.done) "closed enum roundtrip"
  check ((fromCol (α := Status) (.text "cancelled")).isOk == false)
    "unknown variant must fail decode"
  check (ClosedEnum.variants Status == #["backlog", "inProgress", "done"]) "variant names"
  let cols := Entity.columns Todo
  check ((cols.getD 1 default).enum == some #["backlog", "inProgress", "done"])
    "status column carries its closed world"
  check (((Entity.spec Todo).ddl.splitOn "CHECK").length == 2) "DDL contains CHECK"

/-! ## Plan reflection (M4: pushdown as fetch narrowing) -/

private def agePlan : PlanFor (fun (a : Stored Author) => a.val.age ≥ 40) := by leandb_plan

private def capturedPlan (n : Nat) : PlanFor (fun (a : Stored Author) => a.val.age ≥ n) := by
  leandb_plan

private def joinPlan : PlanFor (fun (r : Stored Book × Stored Author) =>
    r.1.val.author == r.2.ref && r.2.val.age ≥ 40 && r.1.val.rating == none) := by leandb_plan

private def somePlan : PlanFor (fun (b : Stored Book) => b.val.rating == some 4.5) := by
  leandb_plan

private def enumPlan : PlanFor (fun (t : Stored Todo) => t.val.status == Status.done) := by
  leandb_plan

private structure Flag where on : Bool
private def boolPlan : PlanFor (fun (f : Stored Flag) => f.val.on) := by leandb_plan

private def opaquePred (a : Stored Author) : Bool := a.val.age % 2 == 0
private def residualPlan : PlanFor opaquePred := by leandb_plan

@[db] private def Author.isAdult (a : Author) : Bool := a.age ≥ 40
private def dbFnPlan : PlanFor (fun (a : Stored Author) => a.val.isAdult) := by leandb_plan

private def isNonePlan : PlanFor (fun (b : Stored Book) => b.val.rating.isNone) := by leandb_plan
private def isSomePlan : PlanFor (fun (b : Stored Book) => b.val.rating.isSome) := by leandb_plan

private def orPlan : PlanFor (fun (a : Stored Author) =>
    a.val.age < 30 || a.val.age > 50) := by leandb_plan

private def notPlan : PlanFor (fun (a : Stored Author) => !(a.val.age ≥ 40)) := by leandb_plan

private def orResidualPlan : PlanFor (fun (a : Stored Author) =>
    a.val.age < 30 || opaquePred a) := by leandb_plan

private def matchPlan : PlanFor (fun (t : Stored Todo) =>
    match t.val.status with | .done => false | _ => true) := by leandb_plan

@[db] private def Status.weight : Status → Nat
  | .backlog => 0 | .inProgress => 1 | .done => 2
private def weightPlan : PlanFor (fun (t : Stored Todo) => t.val.status.weight ≥ 1) := by
  leandb_plan

private def checkPlan (p : PlanFor w) (pred : PushPred) (residual : Nat) (label : String) :
    IO Unit :=
  unless p.plan.pred == pred && p.plan.residual == residual do
    throw <| IO.userError s!"FAIL: {label}: got {repr p.plan}"

private def testPlans : IO Unit := do
  checkPlan agePlan (.cmp 0 "age" .ge (.int 40)) 0 "age plan fully pushed"
  checkPlan (capturedPlan 41) (.cmp 0 "age" .ge (.int 41)) 0 "captured variable as bound param"
  checkPlan joinPlan
    (.and (.and (.cmp2 0 "author" .eq 1 "id") (.cmp 1 "age" .ge (.int 40)))
      (.cmp 0 "rating" .eq .null)) 0 "equi-join pushes as cmp2 + per-table conds"
  check joinPlan.plan.pred.hasJoin "join plan routes to joined executor"
  checkPlan somePlan (.cmp 0 "rating" .eq (.real 4.5)) 0 "some-literal via Option codec"
  checkPlan enumPlan (.cmp 0 "status" .eq (.text "done")) 0 "closed enum pushes as its name"
  checkPlan boolPlan (.cmp 0 "on" .eq (.int 1)) 0 "bare Bool column"
  checkPlan residualPlan .tt 1 "opaque predicate is fully residual"
  checkPlan dbFnPlan (.cmp 0 "age" .ge (.int 40)) 0 "@[db] def unfolds"
  checkPlan isNonePlan (.isNull 0 "rating") 0 "isNone as IS NULL"
  checkPlan isSomePlan (.isNotNull 0 "rating") 0 "isSome as IS NOT NULL"
  checkPlan orPlan (.or (.cmp 0 "age" .lt (.int 30)) (.cmp 0 "age" .gt (.int 50))) 0
    "disjunction pushes whole"
  checkPlan notPlan (.cmp 0 "age" .lt (.int 40)) 0 "negation is exact"
  checkPlan orResidualPlan .tt 1 "or with unpushable side is fully residual"
  checkPlan matchPlan
    (.or (.cmp 0 "status" .eq (.text "backlog")) (.cmp 0 "status" .eq (.text "inProgress")))
    0 "match on closed enum case-splits to a disjunction"
  checkPlan weightPlan
    (.or (.cmp 0 "status" .eq (.text "inProgress")) (.cmp 0 "status" .eq (.text "done")))
    0 "enum-table function case-splits, false branches drop"

/-! ## JSON, derived from the schema (M5) -/

private def parseJ (str : String) : IO Lean.Json :=
  match Lean.Json.parse str with
  | .ok j => pure j
  | .error e => throw <| IO.userError s!"FAIL: json parse: {e}"

private def testJson : IO Unit := do
  let b : Stored Book := ⟨⟨7⟩, ⟨"T", ⟨3⟩, none⟩⟩
  check ((rowJson Book b).compress == "{\"author\":3,\"id\":7,\"rating\":null,\"title\":\"T\"}")
    s!"row JSON shape, got {(rowJson Book b).compress}"
  let j ← parseJ "{\"title\":\"T2\",\"author\":3}"
  let full := rowOfJson Book j
  check (full.toOption.map (fun bk => bk.title == "T2" && bk.rating == none) == some true)
    "rowOfJson decodes with missing nullable as none"
  let merged := rowMergeJson Book b.val j
  check (merged.toOption.map (fun bk => bk.title == "T2" && bk.author == b.val.author) == some true)
    "rowMergeJson overlays only present fields"
  check ((rowOfJson Book (← parseJ "{\"author\":3}")).isOk == false)
    "missing required field must fail"
  let bogus := rowMergeJson Todo ⟨"x", .backlog⟩ (← parseJ "{\"status\":\"bogus\"}")
  match bogus with
  | .error (.decode "todo" "status" _) => pure ()
  | _ => throw <| IO.userError "FAIL: closed world must reject bogus via JSON"

/-! ## End-to-end against SQLite -/

private def dbPath : System.FilePath := ".lake" / "leandb_test.sqlite"

private def freshDb : IO Unit := do
  if ← dbPath.pathExists then IO.FS.removeFile dbPath

private def expectOk (r : Except DbError α) (context : String) : IO α :=
  match r with
  | .ok a => pure a
  | .error e => throw <| IO.userError s!"FAIL: {context}: {e}"

private def expectErr (r : Except DbError α) (code : String) (context : String) : IO Unit :=
  match r with
  | .ok _ => throw <| IO.userError s!"FAIL: {context}: expected [{code}], got success"
  | .error e =>
      unless e.code == code do
        throw <| IO.userError s!"FAIL: {context}: expected [{code}], got {e}"

private def seed : DbM (Stored Author × Stored Author × Stored Book) := do
  let ada ← insert Author ⟨"Ada", 36⟩
  let alan ← insert Author ⟨"Alan", 41⟩
  let book ← insert Book ⟨"On Computable Numbers", alan.ref, some 4.5⟩
  discard <| insert Book ⟨"Notes on the Analytical Engine", ada.ref, none⟩
  return (ada, alan, book)

private def testEndToEnd : IO Unit := do
  freshDb
  let r ← withDb dbPath schema do
    let (ada, alan, _) ← seed
    -- get
    let got ← get ada.id
    check' (got.map (·.val.name) == some "Ada") "get returns the row"
    -- single-table select: dependent type is Stored Author
    let adults ← select [Author] (fun a => a.val.age ≥ 40) (.key (·.val.name))
    check' (adults.map (·.val.name) == #["Alan"]) "typed where' filters"
    -- join: Rows [Book, Author] = Stored Book × Stored Author
    let byAuthor ← select [Book, Author]
      (fun (b, a) => b.val.author == a.ref)
      (.key fun (b, _) => b.val.title)
    check' (byAuthor.map (fun (b, a) => ((b.val.title.take 5).toString, a.val.name))
      == #[("Notes", "Ada"), ("On Co", "Alan")]) "equi-join via Ref equality"
    -- differential: the planned path must equal the unplanned reference
    let key := fun (r : Stored Book × Stored Author) => (r.1.id.toInt64, r.2.id.toInt64)
    let pred := fun (r : Stored Book × Stored Author) =>
      r.1.val.author == r.2.ref && r.2.val.age ≥ 40 && r.1.val.rating != none
    let planned ← select [Book, Author] pred (.key fun (b, _) => b.val.title)
    let unplanned ← selectUnplanned [Book, Author] pred (.key fun (b, _) => b.val.title)
    check' (planned.map key == unplanned.map key && planned.size == 1)
      "differential: planned select equals the reference"
    -- CAS update
    let alan' ← update alan { alan.val with age := 42 }
    check' (alan'.val.age == 42) "update applies"
    return (ada, alan)
  let (ada, alan) ← expectOk r "seed + queries"
  -- stale CAS: 'alan' still holds age 41 but the row now says 42
  expectErr (← withDb dbPath schema do discard <| update alan { alan.val with name := "A." })
    "stale" "CAS with stale snapshot"
  -- FK RESTRICT: alan is referenced by a book
  expectErr (← withDb dbPath schema do delete alan.id) "restricted" "delete referenced author"
  -- delete of unreferenced row after removing its book, then notFound on re-delete
  let r ← withDb dbPath schema do
    let books ← select [Book] (fun b => b.val.author == ada.ref)
    for b in books do delete b.id
    delete ada.id
  discard <| expectOk r "cascade-by-hand delete"
  expectErr (← withDb dbPath schema do delete ada.id) "not_found" "double delete"
  -- reopen: fingerprint accepted, data persisted
  let names ← withDb dbPath schema do
    return (← select [Author] (fun _ => true) (.key (·.val.name))).map (·.val.name)
  check ((← expectOk names "reopen") == #["Alan"]) "persistence across open"
  -- fingerprint mismatch: same file, different schema
  expectErr (← withDb dbPath [Entity.spec Author] (pure ())) "schema_mismatch"
    "drifted schema must refuse to open"
where
  check' (condition : Bool) (message : String) : DbM Unit :=
    unless condition do throw (.sqlite s!"FAIL: {message}")

private def taskDbPath : System.FilePath := ".lake" / "leandb_test_tasks.sqlite"

private def testClosedEndToEnd : IO Unit := do
  if ← taskDbPath.pathExists then IO.FS.removeFile taskDbPath
  let r ← withDb taskDbPath [Entity.spec Todo] do
    discard <| insert Todo ⟨"write plan", .done⟩
    discard <| insert Todo ⟨"build engine", .inProgress⟩
    discard <| insert Todo ⟨"ship", .backlog⟩
    select [Todo] (fun t => t.val.status == .inProgress)
  let active ← expectOk r "closed-enum filter"
  check (active.map (·.val.title) == #["build engine"]) "match on closed world filters"
  -- the file itself refuses vocabulary violations (CHECK), even via raw SQL
  let db ← SQLite.open taskDbPath
  let raw : IO Unit := db.exec "INSERT INTO todo (title, status) VALUES ('rogue', 'cancelled')"
  match ← raw.toBaseIO with
  | .ok _ => throw <| IO.userError "FAIL: CHECK should reject unknown variant"
  | .error e =>
      match e with
      | .otherError 19 details =>
          check ((details.toLower.splitOn "check constraint").length == 2)
            s!"raw insert rejected by CHECK, got: {details}"
      | e => throw <| IO.userError s!"FAIL: expected constraint error 19, got: {e}"

/-! ## Migrations (additive auto-apply, loud destruction, world rebuilds) -/

private def migDbPath : System.FilePath := ".lake" / "leandb_test_mig.sqlite"

private def col (name : String) (ty : SqlType) (nullable : Bool := false)
    (enum : Option (Array String) := none) : ColumnSpec :=
  { name, sqlType := ty, nullable, fkTable := none, enum }

private def testMigrations : IO Unit := do
  if ← migDbPath.pathExists then IO.FS.removeFile migDbPath
  let v1 : TableSpec := ⟨"author", #[col "name" .text]⟩
  let v2 : TableSpec := ⟨"author", #[col "name" .text, col "nick" .text (nullable := true)]⟩
  let vBad : TableSpec := ⟨"author", #[col "name" .text, col "age" .integer]⟩
  -- create at v1 and put a row in
  discard <| expectOk (← withDb migDbPath [v1] (pure ())) "create at v1"
  let db ← SQLite.open migDbPath
  db.exec "INSERT INTO author (name) VALUES ('Ada')"
  -- additive migration applies
  let r ← migrate migDbPath [v2] (apply := true)
  let (_, report?) ← expectOk r "additive migrate"
  check ((report?.map (·.applied)).getD [] == ["add column \"author\".\"nick\""])
    "add-column step applied"
  discard <| expectOk (← withDb migDbPath [v2] (pure ())) "open at v2 after migrate"
  -- NOT NULL addition is refused with guidance
  expectErr (← migrate migDbPath [vBad] (apply := true)) "migrate" "NOT NULL column refused"
  -- destructive requires the flag
  expectErr (← migrate migDbPath [v1] (apply := true)) "migrate" "destructive needs flag"
  discard <| expectOk (← migrate migDbPath [v1] (apply := true) (allowDestructive := true))
    "destructive with flag"
  -- closed-world rebuild: grow, then a shrink that data refuses
  if ← migDbPath.pathExists then IO.FS.removeFile migDbPath
  let small := ⟨"todo", #[col "title" .text, col "status" .text (enum := some #["a", "b"])]⟩
  let grown : TableSpec :=
    ⟨"todo", #[col "title" .text, col "status" .text (enum := some #["a", "b", "c"])]⟩
  let shrunk : TableSpec := ⟨"todo", #[col "title" .text, col "status" .text (enum := some #["a"])]⟩
  discard <| expectOk (← withDb migDbPath [small] (pure ())) "create small world"
  let db2 ← SQLite.open migDbPath
  db2.exec "INSERT INTO todo (title, status) VALUES ('x', 'b')"
  let (_, rep) ← expectOk (← migrate migDbPath [grown] (apply := true)) "grow world"
  check (((rep.map (·.applied)).getD []).any (·.startsWith "rebuild")) "grow is a rebuild"
  let db3 ← SQLite.open migDbPath
  db3.exec "INSERT INTO todo (title, status) VALUES ('y', 'c')"   -- new CHECK admits 'c'
  -- shrink to just 'a': rows say 'b'/'c' → CHECK fails during copy → rolled back
  expectErr (← migrate migDbPath [shrunk] (apply := true)) "migrate"
    "world shrink refused by nonconforming data"
  let db4 ← SQLite.open migDbPath
  let stmt ← db4.prepare "SELECT count(*) FROM todo"
  discard <| stmt.step
  check ((← stmt.columnInt64 0) == 2) "rollback kept the data"

def main : IO UInt32 := do
  testCodecs
  testDerivedSpec
  testSortBy
  testPlans
  testClosedEnum
  testDefaults
  testJson
  testEndToEnd
  testClosedEndToEnd
  testMigrations
  IO.println "all engine tests passed"
  return 0
