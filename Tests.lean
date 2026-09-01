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

structure Marker where
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
  check ((fromCol (α := UInt16) (.int 65535)).toOption == some 65535)
    "UInt16 maximum must decode"
  check ((fromCol (α := UInt16) (.int 65536)).isOk == false)
    "UInt16 size must not wrap to zero"
  check ((fromCol (α := UInt32) (.int 4294967295)).toOption == some 4294967295)
    "UInt32 maximum must decode"
  check ((fromCol (α := UInt32) (.int 4294967296)).isOk == false)
    "UInt32 size must not wrap to zero"

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
  let missingFk := validateSchema [Entity.spec Book]
  check (missingFk.isOk == false) "schema rejects a reference to an omitted table"
  let duplicate := validateSchema [Entity.spec Author, Entity.spec Author]
  check (duplicate.isOk == false) "schema rejects duplicate table names"
  let reserved : TableSpec := ⟨"_leandb_user", #[]⟩
  check ((validateSchema [reserved]).isOk == false) "schema rejects the internal table prefix"

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
  deriving Repr, DecidableEq, Ord, LeanDb.ClosedEnum

structure Todo where
  title : String
  status : Status
  deriving Repr, LeanDb.Entity

private def Status.rank : Status → Nat
  | .backlog => 0 | .inProgress => 1 | .done => 2

private instance : LT Status := ⟨fun a b => a.rank < b.rank⟩
private instance (a b : Status) : Decidable (a < b) := by
  change Decidable (a.rank < b.rank)
  infer_instance

private instance (a b : Option Nat) : Decidable (a < b) := by
  change Decidable (Option.lt (fun x y : Nat => x < y) a b)
  cases a <;> cases b <;> simp [Option.lt] <;> infer_instance

structure MaybeRank where
  score : Option Nat
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
  note : Option Nat := some 5
  deriving Repr, LeanDb.Entity

private def testDefaults : IO Unit := do
  let cols := Entity.columns Draft
  check (cols.map (·.dflt) == #[none, some (.text "backlog"), some (.int 10), some (.int 5)])
    s!"defaults reified into the column specs, got {repr (cols.map (·.dflt))}"
  let ddl := (Entity.spec Draft).ddl
  check (((ddl.splitOn "DEFAULT 'backlog'").length == 2) && ((ddl.splitOn "DEFAULT 10").length == 2))
    s!"DDL carries DEFAULT clauses, got {ddl}"
  let d1 := (Lean.Json.parse "{\"title\":\"t\"}").toOption.bind
    fun j => (rowOfJson Draft j).toOption
  check (d1.map (fun d => d.status == .backlog && d.score == 10 && d.note == some 5) == some true)
    "omitted fields take defaults"
  let d2 := (Lean.Json.parse "{\"title\":\"t\",\"note\":null}").toOption.bind
    fun j => (rowOfJson Draft j).toOption
  check (d2.map (·.note == none) == some true) "explicit null beats a default"

private def testClosedEnum : IO Unit := do
  check (roundtrip Status.inProgress && roundtrip Status.done) "closed enum roundtrip"
  check ((fromCol (α := Status) (.text "cancelled")).isOk == false)
    "unknown variant must fail decode"
  check (ClosedEnum.variants Status == #["backlog", "inProgress", "done"]) "variant names"
  check (ClosedEnum.all (α := Status) == #[.backlog, .inProgress, .done]) "all enumerates the world"
  check ((ClosedEnum.all (α := Status)).all fun s => ClosedEnum.decodeName (ClosedEnum.encodeName s) == some s)
    "encode/decode total over the world"
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

-- `if` on a column comparison: the shape a midnight-wrapping opening-hours
-- predicate takes (`if closes < opens then … else …`)
private def itePlan : PlanFor (fun (a : Stored Author) =>
    if a.val.age < 30 then a.val.name == "x" else a.val.age > 50) := by leandb_plan
private def iteResidualPlan : PlanFor (fun (a : Stored Author) =>
    if opaquePred a then a.val.age < 30 else true) := by leandb_plan

private def nullableOrderPlan : PlanFor (fun (r : Stored MaybeRank) =>
    decide (r.val.score < some 4)) := by
  leandb_plan

private def enumOrderPlan : PlanFor (fun (t : Stored Todo) =>
    decide (t.val.status < Status.done)) := by
  leandb_plan

private def orResidualPlan : PlanFor (fun (a : Stored Author) =>
    a.val.age < 30 || opaquePred a) := by leandb_plan

private def matchPlan : PlanFor (fun (t : Stored Todo) =>
    match t.val.status with | .done => false | _ => true) := by leandb_plan

@[db] private def Status.weight : Status → Nat
  | .backlog => 0 | .inProgress => 1 | .done => 2
private def weightPlan : PlanFor (fun (t : Stored Todo) => t.val.status.weight ≥ 1) := by
  leandb_plan

private def weightCapturedPlan (n : Nat) : PlanFor (fun (t : Stored Todo) =>
    t.val.status.weight ≥ n) := by leandb_plan

/-! Validated newtypes: a column stored *through* a projection. The
    planner may only unwrap the projection when it is the codec's own
    encoding — `Milli` qualifies, `Span` (whose codec mixes both fields)
    does not, and must stay residual. -/

private structure Milli where
  v : Nat
  deriving Repr, DecidableEq

private instance : ColCodec Milli := ColCodec.via (·.v) (.ok ⟨·⟩)

private structure Span where
  lo : Nat
  hi : Nat
  deriving Repr, DecidableEq

private instance : ColCodec Span :=
  ColCodec.via (fun s => s.lo * 1000 + s.hi) (fun n => .ok ⟨n / 1000, n % 1000⟩)

private structure Priced where
  price : Milli
  span : Span

private def newtypeEqPlan : PlanFor (fun (r : Stored Priced) => r.val.price.v == 500) := by
  leandb_plan

private def newtypeLePlan : PlanFor (fun (r : Stored Priced) =>
    r.val.price.v ≤ 500) := by leandb_plan

private def newtypeCapturedPlan (n : Nat) : PlanFor (fun (r : Stored Priced) =>
    r.val.price.v ≤ n) := by leandb_plan

private def newtypeGePlan (n : Nat) : PlanFor (fun (r : Stored Priced) =>
    r.val.price.v ≥ n) := by leandb_plan

private def newtypeAndPlan (n : Nat) : PlanFor (fun (r : Stored Priced) =>
    r.val.price.v ≤ n && r.val.price.v ≥ 10) := by leandb_plan

/-- The guard doing its job: same syntactic shape, different codec. -/
private def foreignProjPlan : PlanFor (fun (r : Stored Priced) =>
    r.val.span.lo ≤ 5) := by leandb_plan

private def foreignProjEqPlan : PlanFor (fun (r : Stored Priced) =>
    r.val.span.hi == 5) := by leandb_plan

/-! Case splits on a *captured parameter* of closed-enum type: after the
    column split, a `@[db]` function that inspects its parameter before
    its column argument (or a derived form like `!(d.forbids.contains k)`)
    is stuck on the parameter; the tactic splits on its world too, with a
    value/value guard. -/

inductive Diet where
  | vegetarian | pescatarian | omnivore
  deriving Repr, DecidableEq, LeanDb.ClosedEnum

inductive Kind where
  | meat | fish | plant
  deriving Repr, DecidableEq, LeanDb.ClosedEnum

structure Ingredient where
  name : String
  kind : Kind
  deriving Repr, LeanDb.Entity

private def Diet.forbids : Diet → List Kind
  | .vegetarian => [.meat, .fish] | .pescatarian => [.meat] | .omnivore => []

/-- The derived form: list membership, no `match` on the column at all. -/
@[db] private def Diet.allows (d : Diet) (k : Kind) : Bool := !(d.forbids.contains k)

/-- Matches on the parameter first: `whnf` is stuck on `d` once the
    column has been substituted. -/
@[db] private def Diet.allowsParamFirst (d : Diet) (k : Kind) : Bool :=
  match d with
  | .omnivore => true
  | .pescatarian => k != .meat
  | .vegetarian => k == .plant

/-- Matches on the column first: the column split alone leaves
    `d OP constant`, the plain value/value path. -/
@[db] private def Diet.allowsColumnFirst (d : Diet) (k : Kind) : Bool :=
  match k with
  | .plant => true
  | .fish => d != .vegetarian
  | .meat => d == .omnivore

private def allowsPlan (d : Diet) : PlanFor (fun (i : Stored Ingredient) =>
    d.allows i.val.kind) := by leandb_plan

private def paramFirstPlan (d : Diet) : PlanFor (fun (i : Stored Ingredient) =>
    d.allowsParamFirst i.val.kind) := by leandb_plan

private def columnFirstPlan (d : Diet) : PlanFor (fun (i : Stored Ingredient) =>
    d.allowsColumnFirst i.val.kind) := by leandb_plan

/-- A captured `Nat` is not a closed world: after the column split the
    branch `kindBonus n .plant` is stuck on `n` and must stay residual. -/
private def kindBonus (n : Nat) (k : Kind) : Bool :=
  match k with | .plant => n > 3 | _ => false
private def natParamPlan (n : Nat) : PlanFor (fun (i : Stored Ingredient) =>
    kindBonus n i.val.kind) := by leandb_plan

/-- An enum parameter inside a genuinely opaque function: the split fires
    but no branch can be evaluated, so the conjunct stays residual. -/
@[irreducible] private def dietOpaque (d : Diet) (k : Kind) : Bool :=
  d == .omnivore || k == .plant
private def opaqueParamPlan (d : Diet) : PlanFor (fun (i : Stored Ingredient) =>
    dietOpaque d i.val.kind) := by leandb_plan

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
  checkPlan itePlan
    (.or (.and (.cmp 0 "age" .lt (.int 30)) (.cmp 0 "name" .eq (.text "x")))
         (.and (.cmp 0 "age" .ge (.int 30)) (.cmp 0 "age" .gt (.int 50))))
    0 "if-then-else on columns pushes as (c ∧ t) ∨ (¬c ∧ e)"
  checkPlan iteResidualPlan .tt 1 "if with an opaque condition is fully residual"
  checkPlan nullableOrderPlan .tt 1 "nullable ordering remains residual"
  checkPlan enumOrderPlan
    (.or (.cmp 0 "status" .eq (.text "backlog"))
      (.cmp 0 "status" .eq (.text "inProgress"))) 0
    "closed-enum ordering case-splits instead of using SQL text order"
  checkPlan orResidualPlan .tt 1 "or with unpushable side is fully residual"
  checkPlan matchPlan
    (.or (.cmp 0 "status" .eq (.text "backlog")) (.cmp 0 "status" .eq (.text "inProgress")))
    0 "match on closed enum case-splits to a disjunction"
  checkPlan weightPlan
    (.or (.cmp 0 "status" .eq (.text "inProgress")) (.cmp 0 "status" .eq (.text "done")))
    0 "enum-table function case-splits, false branches drop"
  -- the value/value guards a case split leaves behind compare two values
  -- that are both known when the plan is built (`cmpVVS`), so `0 ≥ 1`
  -- folds to `ff` and drops its branch: only the surviving columns reach SQL
  checkPlan (weightCapturedPlan 1)
    (.or (.cmp 0 "status" .eq (.text "inProgress")) (.cmp 0 "status" .eq (.text "done")))
    0 "case split against a captured threshold folds the value tests"
  checkPlan newtypeEqPlan (.cmp 0 "price" .eq (.int 500)) 0
    "newtype projection that is the codec's encoding pushes (eq, literal)"
  checkPlan newtypeLePlan (.cmp 0 "price" .le (.int 500)) 0
    "ordering through the encoding projection pushes (literal)"
  checkPlan (newtypeCapturedPlan 700) (.cmp 0 "price" .le (.int 700)) 0
    "ordering through the encoding projection pushes (captured variable)"
  checkPlan (newtypeGePlan 700) (.cmp 0 "price" .ge (.int 700)) 0
    "reverse ordering through the encoding projection pushes"
  checkPlan (newtypeAndPlan 700)
    (.and (.cmp 0 "price" .le (.int 700)) (.cmp 0 "price" .ge (.int 10))) 0
    "both bounds through the projection push"
  checkPlan foreignProjPlan .tt 1
    "projection that is not the codec's encoding stays residual (order)"
  checkPlan foreignProjEqPlan .tt 1
    "projection that is not the codec's encoding stays residual (equality)"
  -- captured closed-enum parameter: the world of `d` is split too, guarded
  -- by `d IS 'c'` — known at plan build, so every guard but one folds away
  -- and both match orders leave the same column condition
  checkPlan (paramFirstPlan .vegetarian) (.cmp 0 "kind" .eq (.text "plant")) 0
    "@[db] function matching on the parameter first splits on its world"
  checkPlan (columnFirstPlan .vegetarian) (.cmp 0 "kind" .eq (.text "plant")) 0
    "@[db] function matching on the column first reaches the same plan"
  for d in ClosedEnum.all (α := Diet) do
    check ((allowsPlan d).plan.residual == 0)
      s!"derived allows ({repr d}) pushes with residual 0"
    check ((paramFirstPlan d).plan.residual == 0)
      s!"param-first allows ({repr d}) pushes with residual 0"
    check ((columnFirstPlan d).plan.residual == 0)
      s!"column-first allows ({repr d}) pushes with residual 0"
  check ((allowsPlan .vegetarian).plan.pred.describe ==
      "(t0.\"kind\" IS NOT ? AND t0.\"kind\" IS NOT ?)")
    s!"derived allows folds to the forbidden kinds, got {(allowsPlan .vegetarian).plan.pred.describe}"
  -- omnivore forbids nothing: the whole conjunct folds to `true` — no
  -- narrowing, no residual
  checkPlan (paramFirstPlan .omnivore) .tt 0 "a diet that allows everything folds to tt"
  checkPlan (natParamPlan 5) .tt 1 "captured Nat inside a non-@[db] function stays residual"
  checkPlan (opaqueParamPlan .omnivore) .tt 1
    "enum parameter inside an opaque function stays residual"

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
  check ((rowOfJson Draft (← parseJ "null")).isOk == false)
    "insert input must be an object even when every field has a default"
  check ((rowOfJson Draft (← parseJ "{\"title\":\"t\",\"scroe\":9}")).isOk == false)
    "insert must reject unknown fields instead of silently taking a default"
  check ((rowMergeJson Book b.val (← parseJ "{\"titel\":\"typo\"}")).isOk == false)
    "update must reject unknown fields instead of silently doing nothing"
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
  -- dangling Ref: inserting/updating toward a nonexistent row is
  -- missing_ref, not "referenced by other rows"
  expectErr (← withDb dbPath schema do discard <| insert Book ⟨"Ghost", ⟨99999⟩, none⟩)
    "missing_ref" "insert with dangling Ref"
  expectErr (← withDb dbPath schema do
      let books ← select [Book] (fun _ => true)
      match books[0]? with
      | some b => discard <| update b { b.val with author := ⟨99999⟩ }
      | none => throw (.sqlite "no book to update"))
    "missing_ref" "update to dangling Ref"
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

private def dietDbPath : System.FilePath := ".lake" / "leandb_test_diet.sqlite"

/-- Differential: the parameter-split plans must agree with the unplanned
    reference for every diet, and with the hand-written expectation. -/
private def testParamSplitEndToEnd : IO Unit := do
  if ← dietDbPath.pathExists then IO.FS.removeFile dietDbPath
  let r ← withDb dietDbPath [Entity.spec Ingredient] do
    discard <| insert Ingredient ⟨"pork", .meat⟩
    discard <| insert Ingredient ⟨"salmon", .fish⟩
    discard <| insert Ingredient ⟨"tofu", .plant⟩
    discard <| insert Ingredient ⟨"lentils", .plant⟩
    let byName : SortBy (Stored Ingredient) := .key (·.val.name)
    let names (rows : Array (Stored Ingredient)) := rows.map (·.val.name)
    for d in ClosedEnum.all (α := Diet) do
      let allowed := fun (i : Stored Ingredient) => d.allows i.val.kind
      let planned ← select [Ingredient] allowed byName
      let reference ← selectUnplanned [Ingredient] allowed byName
      unless names planned == names reference do
        throw (.sqlite s!"FAIL: derived allows ({repr d}): planned {names planned} vs reference {names reference}")
      let forbidden := fun (i : Stored Ingredient) => !(d.allows i.val.kind)
      let plannedF ← select [Ingredient] forbidden byName
      let referenceF ← selectUnplanned [Ingredient] forbidden byName
      unless names plannedF == names referenceF do
        throw (.sqlite s!"FAIL: negated allows ({repr d}): planned {names plannedF} vs reference {names referenceF}")
      let paramFirst := fun (i : Stored Ingredient) => d.allowsParamFirst i.val.kind
      let plannedP ← select [Ingredient] paramFirst byName
      let referenceP ← selectUnplanned [Ingredient] paramFirst byName
      unless names plannedP == names referenceP do
        throw (.sqlite s!"FAIL: param-first allows ({repr d}): planned {names plannedP} vs reference {names referenceP}")
    let vegetarian ← select [Ingredient] (fun i => Diet.vegetarian.allows i.val.kind) byName
    let pescatarian ← select [Ingredient] (fun i => Diet.pescatarian.allows i.val.kind) byName
    let omnivore ← select [Ingredient] (fun i => Diet.omnivore.allows i.val.kind) byName
    return (names vegetarian, names pescatarian, names omnivore)
  let (veg, pesc, omni) ← expectOk r "diet queries"
  check (veg == #["lentils", "tofu"]) s!"vegetarian sees plants only, got {veg}"
  check (pesc == #["lentils", "salmon", "tofu"]) s!"pescatarian adds fish, got {pesc}"
  check (omni == #["lentils", "pork", "salmon", "tofu"]) s!"omnivore sees everything, got {omni}"

/-! ## Migrations (additive auto-apply, loud destruction, world rebuilds) -/

private def migDbPath : System.FilePath := ".lake" / "leandb_test_mig.sqlite"

private def col (name : String) (ty : SqlType) (nullable : Bool := false)
    (enum : Option (Array String) := none) (dflt : Option Col := none) : ColumnSpec :=
  { name, sqlType := ty, nullable, fkTable := none, enum, dflt }

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
  -- ...but a NOT NULL column WITH a default backfills existing rows
  let vDef : TableSpec := ⟨"author",
    #[col "name" .text, col "nick" .text (nullable := true),
      col "score" .integer (dflt := some (.int 7))]⟩
  discard <| expectOk (← migrate migDbPath [vDef] (apply := true)) "defaulted NOT NULL add"
  let dbv ← SQLite.open migDbPath
  let stv ← dbv.prepare "SELECT score FROM author WHERE name = 'Ada'"
  discard <| stv.step
  check ((← stv.columnInt64 0) == 7) "existing row took the declared default"
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
  -- Corrupt metadata is not an empty schema: migration must stop instead
  -- of blessing the live database with a new fingerprint.
  db4.exec "UPDATE _leandb_meta SET value = 'not-json' WHERE key = 'schema_json'"
  expectErr (← migrate migDbPath [grown] (apply := false)) "migrate"
    "invalid stored schema metadata must be reported"

private def quoteDbPath : System.FilePath := ".lake" / "leandb_test_quote.sqlite"

private def testSqlQuoting : IO Unit := do
  if ← quoteDbPath.pathExists then IO.FS.removeFile quoteDbPath
  let quoted : TableSpec := ⟨"odd\"table",
    #[col "odd\"column" .text (enum := some #["it's"])]⟩
  discard <| expectOk (← withDb quoteDbPath [quoted] (pure ()))
    "quoted SQL identifiers and enum values"
  let db ← SQLite.open quoteDbPath
  db.exec "INSERT INTO \"odd\"\"table\" (\"odd\"\"column\") VALUES ('it''s')"

private def emptyDbPath : System.FilePath := ".lake" / "leandb_test_empty.sqlite"

private def testEmptyEntity : IO Unit := do
  if ← emptyDbPath.pathExists then IO.FS.removeFile emptyDbPath
  let stored ← expectOk (← withDb emptyDbPath [Entity.spec Marker] do
    let row ← insert Marker {}
    update row {}) "zero-field insert and update"
  check (stored.id.toInt64 == 1) "zero-field entity gets a row identity"
  discard <| expectOk (← withDb emptyDbPath [Entity.spec Marker] do delete stored.id)
    "zero-field delete"

private def blobDbPath : System.FilePath := ".lake" / "leandb_test_blob.sqlite"

/-- A BLOB is a decode failure like any other bad value: typed, and naming
    the column it came from. -/
private def expectBlobDecode (r : Except DbError Unit) (context : String) : IO Unit := do
  expectErr r "decode" context
  match r with
  | .error e =>
      check (e.message == "author.name: BLOB columns are not supported")
        s!"{context}: decode error names the table and field, got {e}"
  | .ok _ => pure ()

/-- Only raw SQL can plant a BLOB in a typed column, so the fixture goes in
    behind the typed layer — then every read path must refuse it the same
    way. -/
private def testBlobColumn : IO Unit := do
  if ← blobDbPath.pathExists then IO.FS.removeFile blobDbPath
  discard <| expectOk (← withDb blobDbPath schema do
    let a ← insert Author ⟨"Ada", 36⟩
    discard <| insert Book ⟨"Notes", a.ref, none⟩) "seed before planting a BLOB"
  let db ← SQLite.open blobDbPath
  db.exec "UPDATE author SET name = x'414243'"
  expectBlobDecode (← withDb blobDbPath schema do
    discard <| get (α := Author) ⟨1⟩) "get over a BLOB column"
  expectBlobDecode (← withDb blobDbPath schema do
    discard <| select [Author] (fun _ => true)) "unfiltered select over a BLOB column"
  expectBlobDecode (← withDb blobDbPath schema do
    discard <| select [Author] (fun a => a.val.age ≥ 1)) "filtered select over a BLOB column"
  expectBlobDecode (← withDb blobDbPath schema do
    discard <| select [Book, Author] (fun (b, a) => b.val.author == a.ref))
    "joined select over a BLOB column"

private def uniqDbPath : System.FilePath := ".lake" / "leandb_test_unique.sqlite"

/-- The `duplicate` classification depends on SQLite's message text (see
    `constraintError`); pin it so a re-wording fails here, not in the field. -/
private def testUniqueConstraint : IO Unit := do
  if ← uniqDbPath.pathExists then IO.FS.removeFile uniqDbPath
  discard <| expectOk (← withDb uniqDbPath schema do
    discard <| insert Author ⟨"Ada", 36⟩) "seed before the unique index"
  let db ← SQLite.open uniqDbPath
  db.exec "CREATE UNIQUE INDEX u_author_name ON author(name)"
  expectErr (← withDb uniqDbPath schema do discard <| insert Author ⟨"Ada", 41⟩)
    "duplicate" "uniqueness violation is typed, not a raw sqlite error"

/-! ## Importer: what it reports as not carried (§5.3 — partial support is
fine, *silent* partiality is not). `planOf` is pure, so this drives it
over a hand-built schema rather than a database file. -/

section Importer
open LeanDb.Import

/-- A table whose DDL *looks* like it has UNIQUE and CHECK but does not, and
    which `PRAGMA index_list` correctly reports as index-free. -/
private def phantomTable : RawTable :=
  { name := "phantom"
    createSql :=
      "CREATE TABLE phantom (\n" ++
      "  id INTEGER PRIMARY KEY,\n" ++
      "  check_digit TEXT NOT NULL,          -- looks like CHECK but is not\n" ++
      "  unique_ref TEXT,                    -- looks like UNIQUE but is not\n" ++
      "  label TEXT NOT NULL DEFAULT 'UNIQUE and CHECK live here',\n" ++
      "  \"CHECK\" TEXT,\n" ++
      "  [unique] TEXT\n" ++
      "  /* a comment that says UNIQUE and CHECK */\n" ++
      ")"
    columns := #[
      { name := "id", declType := "INTEGER", notnull := true, pkIndex := 1,
        defaultSql := none },
      { name := "check_digit", declType := "TEXT", notnull := true,
        pkIndex := 0, defaultSql := none },
      { name := "unique_ref", declType := "TEXT", notnull := false,
        pkIndex := 0, defaultSql := none }]
    fks := #[]
    indexes := #[] }

/-- Real constraints: an inline `UNIQUE`, a named `CONSTRAINT ... CHECK`,
    an unnamed inline `CHECK`, and a table-level `UNIQUE (sku, qty)`. -/
private def realTable : RawTable :=
  { name := "real_constraints"
    createSql :=
      "CREATE TABLE real_constraints (\n" ++
      "  id INTEGER PRIMARY KEY,\n" ++
      "  sku TEXT NOT NULL UNIQUE,\n" ++
      "  qty INT NOT NULL CHECK (qty > 0),\n" ++
      "  grade TEXT,\n" ++
      "  CONSTRAINT grade_range CHECK (grade IN ('a','b')),\n" ++
      "  CONSTRAINT sku_qty_uq UNIQUE (sku, qty)\n" ++
      ")"
    columns := #[
      { name := "id", declType := "INTEGER", notnull := true, pkIndex := 1,
        defaultSql := none },
      { name := "sku", declType := "TEXT", notnull := true, pkIndex := 0,
        defaultSql := none },
      { name := "qty", declType := "INT", notnull := true, pkIndex := 0,
        defaultSql := none },
      { name := "grade", declType := "TEXT", notnull := false, pkIndex := 0,
        defaultSql := none }]
    fks := #[]
    indexes := #[
      { name := "uq_grade", isUnique := true, origin := "c",
        isPartial := false, columns := #[some "grade"] },
      { name := "sqlite_autoindex_real_constraints_2", isUnique := true,
        origin := "u", isPartial := false,
        columns := #[some "sku", some "qty"] },
      { name := "sqlite_autoindex_real_constraints_1", isUnique := true,
        origin := "u", isPartial := false, columns := #[some "sku"] }] }

private def testImportNotCarried : IO Unit := do
  let raw : RawSchema :=
    { tables := #[phantomTable, realTable], views := #[], triggers := #[],
      indexes := #["uq_grade"] }
  let plan := planOf "adv" "Adv" raw
  let names := plan.notCarried.map fun e => (e.kind, e.name)
  -- No phantom: a `check_digit` column, a `'UNIQUE and CHECK'` default, a
  -- `"CHECK"` identifier and a comment must not invent constraints.
  check (!names.contains ("unique constraint", "phantom"))
    "phantom table must not report a UNIQUE constraint"
  check (!names.contains ("check", "phantom"))
    "phantom table must not report a CHECK constraint"
  check (plan.notCarried.all fun e => !e.name.startsWith "phantom(")
    "phantom table must not report any UNIQUE constraint by columns"
  -- Real constraints are still reported, now named by column list.
  check (names.contains ("unique constraint", "real_constraints(sku)"))
    "inline UNIQUE is reported by column"
  check (names.contains ("unique constraint", "real_constraints(sku, qty)"))
    "table-level UNIQUE is reported by column list"
  -- `origin = "c"` is a CREATE INDEX: reported once, as an index.
  check (!names.contains ("unique constraint", "real_constraints(grade)"))
    "a CREATE UNIQUE INDEX is not double-reported as a UNIQUE constraint"
  check (names.contains ("index", "uq_grade")) "the unique index is reported"
  check ((plan.notCarried.find? fun e => e.name == "uq_grade").any fun e =>
      (e.reason.splitOn "UNIQUE").length > 1)
    "a UNIQUE index says so in its reason"
  -- CHECKs: the named one by name, the unnamed one counted on the table.
  check (names.contains ("check", "real_constraints.grade_range"))
    "a CONSTRAINT-named CHECK is reported by name"
  check ((plan.notCarried.find? fun e =>
      e.kind == "check" && e.name == "real_constraints").any fun e =>
      (e.reason.splitOn "1 unnamed").length > 1)
    "the unnamed CHECK is reported with a count"

end Importer

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
  testParamSplitEndToEnd
  testMigrations
  testSqlQuoting
  testEmptyEntity
  testBlobColumn
  testUniqueConstraint
  testImportNotCarried
  IO.println "all engine tests passed"
  return 0
