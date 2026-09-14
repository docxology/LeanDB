import B2T2

/-! B2T2 evaluation suite: fixtures, operations, programs, and errors.
    Successful tests distinguish behavioral output from type guarantees.
-/

open LeanDb B2T2 B2T2.Ops B2T2.Programs

private def check (condition : Bool) (message : String) : IO Unit :=
  unless condition do throw <| IO.userError s!"FAIL: {message}"

private def checkD (condition : Bool) (message : String) : DbM Unit :=
  unless condition do throw (.sqlite s!"FAIL: {message}")

private def expectOk (r : Except DbError α) (context : String) : IO α :=
  match r with
  | .ok a => pure a
  | .error e => throw <| IO.userError s!"FAIL: {context}: {e}"

private def expectE (r : Except String α) (context : String) : IO α :=
  match r with
  | .ok a => pure a
  | .error e => throw <| IO.userError s!"FAIL: {context}: {e}"

private def expectEErr (r : Except String α) (needle : String) (context : String) : IO Unit :=
  match r with
  | .ok _ => throw <| IO.userError s!"FAIL: {context}: expected error containing {needle}"
  | .error e =>
      unless (e.splitOn needle).length > 1 do
        throw <| IO.userError s!"FAIL: {context}: expected {needle}, got {e}"

private def dbPath : System.FilePath := ".lake" / "b2t2_test.sqlite"

/-! ## Type-error cases (Errors.md + constraint violations)

Each `#check_failure` is paired with a valid control so a missing import
cannot count as a successful rejection.
-/

-- err.swappedColumns: age/name types disagree with the schema.
#check ({ name := "Bob", age := 12, favoriteColor := "blue" } : Student)
#check_failure ({ name := 12, age := "Bob", favoriteColor := "blue" } : Student)

-- err.schemaTooShort / missingCell: constructor arity.
#check_failure ({ name := "Bob", age := 12 } : Student)

-- err.schemaTooLong: extra field is not a Student field.
#check_failure ({ name := "Bob", age := 12, favoriteColor := "blue", extra := true } : Student)

-- err.missingSchema: untyped tuple is not an entity row.
#check_failure insert Student ("Bob", 12, "blue")

-- err.midFinal: `mid` is not a Gradebook field; `midterm` is.
#check fun (g : Gradebook) => g.midterm
#check_failure fun (g : Gradebook) => g.mid

-- err.blackAndWhite: no `blackAndWhite` column.
#check fun (j : JellyAnon) => j.black && j.white
#check_failure fun (j : JellyAnon) => j.blackAndWhite

-- err.favoriteColor: a String is not a Bool predicate.
#check select [Student] (fun r => r.val.favoriteColor == "green")
#check_failure select [Student] (fun r => r.val.favoriteColor)

-- err.brownJellybeans: `"color"` is not a JellyAnon column; `brown` is.
#check fun (j : JellyAnon) => j.brown
#check_failure fun (j : JellyAnon) => j.color

-- Wrong-table select (B2T2 getValue on the wrong schema).
#check select [Student] (fun s => s.val.age ≥ 13)
#check_failure select [Student] (fun (g : Stored Gradebook) => g.val.quiz1 > 0)

-- Closed worlds / non-entities cannot be inserted (LeanDB-precise).
#check_failure insert Bool true

-- err.pieCount / err.brownGetAcne: CountRow fields are value/count.
structure CountRow where
  value : Bool
  count : Nat
  deriving Repr

#check fun (r : CountRow) => (r.value, r.count)
#check_failure fun (r : CountRow) => r.«true»
#check_failure fun (r : CountRow) => r.getAcne

/-! ## Runtime suite -/

private def names (rows : Array (Stored Student)) : Array String :=
  rows.map (·.val.name)

private def runSuite : DbM Unit := do
  seed
  -- tbl.students
  let st ← loadOrdered Student
  checkD (st.size == 3) "students nrows"
  checkD (st.map (·.val.name) == #["Bob", "Alice", "Eve"]) "students order by id"
  checkD (st[0]!.val.age == 12 && st[0]!.val.favoriteColor == "blue") "students Bob"
  checkD (st[1]!.val.age == 17 && st[1]!.val.favoriteColor == "green") "students Alice"
  checkD (st[2]!.val.age == 13 && st[2]!.val.favoriteColor == "red") "students Eve"
  checkD (ncols Student == 3) "students ncols (no id)"
  checkD (header Student == ["name", "age", "favoriteColor"]) "students header mapping"

  -- tbl.studentsMissing
  let sm ← loadOrdered StudentMissing
  checkD (sm[0]!.val.age.isNone && sm[0]!.val.favoriteColor == some "blue") "Bob missing age"
  checkD (sm[1]!.val.age == some 17 && sm[1]!.val.favoriteColor == some "green") "Alice complete"
  checkD (sm[2]!.val.age == some 13 && sm[2]!.val.favoriteColor.isNone) "Eve missing color"

  -- tbl.employees / tbl.departments
  let em ← loadOrdered Employee
  let de ← loadOrdered Department
  checkD (em.size == 6 && de.size == 4) "employees + departments nrows"
  checkD (em[5]!.val.lastName == "Williams" && em[5]!.val.departmentId.isNone) "Williams missing dept"

  -- tbl.jellyAnon / tbl.jellyNamed
  let ja ← loadOrdered JellyAnon
  let jn ← loadOrdered JellyNamed
  checkD (ja.size == 10 && jn.size == 10) "jelly nrows"
  checkD (jn[0]!.val.name == "Emily" && jn[0]!.val.orange && jn[0]!.val.getAcne) "Emily orange acne"
  checkD (ncols JellyAnon == 10 && ncols JellyNamed == 11) "jelly ncols"

  -- tbl.gradebook / missing / seq / nested
  let gb ← loadOrdered Gradebook
  let gm ← loadOrdered GradebookMissing
  let gs ← loadOrdered GradebookSeq
  let gn ← loadOrdered GradebookNested
  checkD (gb.size == 3 && gm.size == 3 && gs.size == 3 && gn.size == 3) "gradebook family nrows"
  checkD (gb[0]!.val.quiz1 == 8 && gb[0]!.val.«final» == 87) "Bob gradebook"
  checkD (gm[1]!.val.quiz3.isNone && gm[2]!.val.quiz1.isNone) "gradebookMissing cells"
  checkD (gs[0]!.val.quizzes == [8, 9, 7, 9]) "gradebookSeq quizzes"
  checkD (gn[0]!.val.quizzes.length == 4 && gn[0]!.val.quizzes[1]!.grade == 9) "nested quizzes attached"

  -- api.tfilter / select (SQL path)
  let green ← tfilterDb Student (fun r => r.val.favoriteColor == "green")
  checkD (names green == #["Alice"]) "tfilter favorite green (SQL+Lean)"
  let greenLean := tfilter st (fun r => r.val.favoriteColor == "green")
  checkD (names greenLean == #["Alice"]) "tfilter extra Lean agrees"

  -- api.getRow / api.getValue
  let alice ← match getRow greenLean 0 with
    | .ok r => pure r
    | .error e => throw (.sqlite e)
  checkD (alice.val.favoriteColor == "green") "getRow 0 Alice"
  let color ← match getValue Student alice.val "favoriteColor" with
    | .ok (.text s) => pure s
    | .ok c => throw (.sqlite s!"expected text, got {c.describe}")
    | .error e => throw (.sqlite e)
  checkD (color == "green") "getValue favoriteColor"
  let some bobGb := gb[0]? | throw (.sqlite "FAIL: empty gradebook")
  match getValue Gradebook bobGb.val "mid" with
  | .error e =>
      checkD ((e.splitOn "mid").length > 1) "getValue mid names the field"
  | .ok _ => throw (.sqlite "FAIL: mid should not resolve")

  -- err.getOnlyRow: only index 0 is valid
  match getRow greenLean 1 with
  | .error e => checkD ((e.splitOn "range").length > 1) "getRow 1 out of range"
  | .ok _ => throw (.sqlite "FAIL: getRow 1 should fail")

  -- api.getColumn
  checkD (getColumn st (·.age) == #[12, 17, 13]) "getColumn age"
  let col0 ← match getColumnN Student st 0 with
    | .ok cs => pure cs
    | .error e => throw (.sqlite e)
  checkD (col0 == #[.text "Bob", .text "Alice", .text "Eve"]) "getColumnN 0 = name"

  -- api.selectRows
  let picked ← match selectRowsNs st [2, 0] with
    | .ok rs => pure rs
    | .error e => throw (.sqlite e)
  checkD (names picked == #["Eve", "Bob"]) "selectRows ns order"
  let masked ← match selectRowsBs st #[false, true, true] with
    | .ok rs => pure rs
    | .error e => throw (.sqlite e)
  checkD (names masked == #["Alice", "Eve"]) "selectRows bs"

  -- api.head
  let h2 ← match head st 2 with
    | .ok rs => pure rs
    | .error e => throw (.sqlite e)
  checkD (names h2 == #["Bob", "Alice"]) "head 2"
  let hNeg ← match head st (-1) with
    | .ok rs => pure rs
    | .error e => throw (.sqlite e)
  checkD (names hNeg == #["Bob", "Alice"]) "head -1 drops last"

  -- api.vcat / api.crossJoin
  checkD ((vcat st Array.empty).size == 3) "vcat empty"
  checkD ((crossJoin st de).size == 12) "crossJoin 3×4"

  -- api.tsort / SortBy (SQL path)
  let byAge ← select [Student] (fun _ => true) (.key (·.val.age))
  checkD (names byAge == #["Bob", "Eve", "Alice"]) "tsort age via SortBy"
  checkD (names (tsort st (·.val.age) true) == #["Bob", "Eve", "Alice"]) "tsort extra Lean"
  checkD (names (tsort st (·.val.age) false) == #["Alice", "Eve", "Bob"]) "tsort desc"

  -- api.leftJoin / api.join
  let lj := leftJoin em de (fun e d => e.val.departmentId == some d.val.departmentId)
  checkD (lj.size == 6) "leftJoin keeps Williams"
  checkD (lj[5]!.2.isNone) "Williams unmatched"
  checkD (lj[0]!.2.map (·.val.departmentName) == some "Sales") "Rafferty Sales"
  let ij := innerJoin em de (fun e d => e.val.departmentId == some d.val.departmentId)
  checkD (ij.size == 5) "inner join drops Williams"
  let ijSql ← select [Employee, Department]
    (fun (e, d) => e.val.departmentId == some d.val.departmentId)
    (.key fun (e, _) => e.id)
  checkD (ijSql.size == 5) "select join is inner (SQL+Lean)"

  -- api.dropna / fillna / completeCases
  let complete := dropna sm (fun r => r.val.age.isSome && r.val.favoriteColor.isSome)
  checkD (complete.map (·.val.name) == #["Alice"]) "dropna studentsMissing"
  checkD (completeCases (getColumn sm (·.age)) == #[false, true, true]) "completeCases age"
  checkD (fillna sm[0]!.val.age 0 == 0) "fillna Bob age"

  -- api.count
  let acneCounts := count (getColumn ja (·.getAcne))
  checkD (acneCounts == #[(true, 5), (false, 5)]) "count getAcne"

  -- api.distinct
  let ages := distinctBy st (·.val.age)
  checkD (ages.size == 3) "distinct ages all unique"

  -- api.buildColumn specialized (quiz averages)
  let avgs := quizScoreFilter gb
  checkD (avgs == #[("Bob", 8.25), ("Alice", 7.25), ("Eve", 8.0)]) "quizScoreFilter"
  checkD (quizScoreSelect gb == avgs) "quizScoreSelect specialized"

  -- api.flatten (seq cells)
  checkD ((flattenQuizzes (gs.map (·.val))).size == 12) "flatten 3×4 quizzes"

  -- prog.dotProduct
  checkD (dotProduct gb (·.quiz1) (·.quiz2) == 183) "dotProduct quiz1·quiz2"

  -- prog.sampleRows: invariants, fixed seed
  let sampled ← match sampleRows gm 2 1 with
    | .ok rs => pure rs
    | .error e => throw (.sqlite e)
  checkD (sampled.size == 2) "sampleRows n"
  checkD (sampled.all (fun r => gm.any (fun g => g.id == r.id))) "sampleRows subset"
  match sampleRows gm 4 1 with
  | .error _ => pure ()
  | .ok _ => throw (.sqlite "FAIL: sampleRows n>nrows")

  -- prog.pHacking
  let hits ← match pHacking ja with
    | .ok hs => pure hs
    | .error e => throw (.sqlite e)
  checkD (hits == #["orange"]) "pHackingHomogeneous orange"
  let hitsN ← match pHackingNamed jn with
    | .ok hs => pure hs
    | .error e => throw (.sqlite e)
  checkD (hitsN == #["orange"]) "pHackingHeterogeneous after dropName"

  -- prog.groupBy*
  let byDept := groupByRetentive em (·.val.departmentId)
  checkD (byDept.size == 4) "groupByRetentive keys (31,33,34,none)"
  let eng := byDept.find? (fun (k, _) => k == some 33)
  checkD (eng.map (fun (_, rs) => rs.size) == some 2) "Engineering has Jones+Heisenberg"

  -- err.employeeToDepartment (corrected)
  let sales ← match employeeToDepartment "Rafferty" em de with
    | .ok s => pure s
    | .error e => throw (.sqlite e)
  checkD (sales == "Sales") "employeeToDepartment Rafferty"
  match employeeToDepartment "Williams" em de with
  | .error _ => pure ()
  | .ok s => throw (.sqlite s!"FAIL: Williams should have no dept, got {s}")

  -- persistence
  checkD ((← loadOrdered Student).size == 3) "students persist in-session"

def main : IO UInt32 := do
  unless base.specs == schema do
    throw <| IO.userError "FAIL: Base.specs must equal the ordered schema"
  if ← dbPath.pathExists then IO.FS.removeFile dbPath
  expectOk (← withDb dbPath schema runSuite) "suite"
  -- reopen
  let n ← expectOk (← withDb dbPath schema (do pure (← loadOrdered Student).size)) "reopen"
  check (n == 3) "students persist across reopen"
  -- runtime string-boundary controls (err.midFinal analogue)
  expectEErr (getValue Gradebook
      { name := "Bob", age := 12, quiz1 := 8, quiz2 := 9, midterm := 77,
        quiz3 := 7, quiz4 := 9, «final» := 87 }
      "mid") "mid" "getValue mid"
  discard <| expectE (getValue Gradebook
      { name := "Bob", age := 12, quiz1 := 8, quiz2 := 9, midterm := 77,
        quiz3 := 7, quiz4 := 9, «final» := 87 }
      "midterm") "getValue midterm control"
  IO.println "b2t2: fixture, operation, program, and error tests passed"
  return 0
