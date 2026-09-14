import B2T2.Fixtures
import B2T2.Ops

/-! Example programs from B2T2 ExamplePrograms.md.

Generic programs that compute column names are **not** claimed as
direct LeanDB support. Adaptations that take typed field functions or
a static header list are labeled specialized.
-/

namespace B2T2.Programs

open LeanDb B2T2.Ops

/-- specialized extra Lean: both columns must be `Nat` because the
    projectors say so — not because a `ColName` was proven numeric. -/
def dotProduct (t : Array (Stored Gradebook)) (c1 c2 : Gradebook → Nat) : Nat :=
  let ns := getColumn t c1
  let ms := getColumn t c2
  (ns.zip ms).foldl (fun acc (n, m) => acc + n * m) 0

/-- Deterministic LCG for `sampleRows`. Not B2T2's RNG; tests check
    invariants, not the sample shown in the spec. -/
def lcg (s : Nat) : Nat := (s * 1664525 + 1013904223) % 2147483648

def sampleIndexes (len n seed : Nat) : Array Nat :=
  Id.run do
    let mut pool : Array Nat := (Array.range len)
    let mut s := seed
    let mut out : Array Nat := #[]
    for _ in [0:n] do
      if pool.size == 0 then
        break
      s := lcg s
      let j := s % pool.size
      match pool[j]? with
      | some v =>
          out := out.push v
          pool := pool.eraseIdx! j
      | none => break
    return out

/-- specialized extra Lean: `n ≤ nrows`; output is a subset of the same schema. -/
def sampleRows (rows : Array α) (n seed : Nat) : Except String (Array α) :=
  if n > rows.size then
    .error s!"sample size {n} not in range({rows.size} + 1)"
  else
    selectRowsNs rows (sampleIndexes rows.size n seed).toList

/-- Two-sided Fisher's exact p-value for a 2×2 table. Extra Lean helper. -/
def binom (n k : Nat) : Nat :=
  if k > n then 0
  else
    let k := min k (n - k)
    Id.run do
      let mut acc : Nat := 1
      for i in [0:k] do
        acc := acc * (n - i) / (i + 1)
      return acc

def hypergeom (a b c d : Nat) : Float :=
  let n := a + b + c + d
  let num := (binom (a + b) a) * (binom (c + d) c)
  let den := binom n (a + c)
  if den == 0 then 0.0 else num.toFloat / den.toFloat

def fisherTest (xs ys : Array Bool) : Except String Float :=
  if xs.size != ys.size then
    .error "fisherTest: sequences must have the same length"
  else Id.run do
    let mut a := 0
    let mut b := 0
    let mut c := 0
    let mut d := 0
    for i in [0:xs.size] do
      match xs[i]?, ys[i]? with
      | some true, some true => a := a + 1
      | some true, some false => b := b + 1
      | some false, some true => c := c + 1
      | some false, some false => d := d + 1
      | _, _ => pure ()
    let row1 := a + b
    let col1 := a + c
    let n := xs.size
    let lo := if col1 + row1 > n then col1 + row1 - n else 0
    let hi := min col1 row1
    let obs := hypergeom a b c d
    let mut p := 0.0
    for a' in [lo : hi + 1] do
      let b' := row1 - a'
      let c' := col1 - a'
      let d' := n - a' - b' - c'
      let pr := hypergeom a' b' c' d'
      if pr ≤ obs + 1e-12 then p := p + pr
    return .ok p

structure ColorCol where
  name : String
  get : JellyAnon → Bool

/-- specialized: static header of boolean color columns, not `header(t)`
    as first-class computed names. -/
def jellyColors : List ColorCol := [
  ⟨"red", (·.red)⟩, ⟨"black", (·.black)⟩, ⟨"white", (·.white)⟩,
  ⟨"green", (·.green)⟩, ⟨"yellow", (·.yellow)⟩, ⟨"brown", (·.brown)⟩,
  ⟨"orange", (·.orange)⟩, ⟨"pink", (·.pink)⟩, ⟨"purple", (·.purple)⟩]

/-- specialized extra Lean: `pHackingHomogeneous` over `JellyAnon`. -/
def pHacking (t : Array (Stored JellyAnon)) : Except String (Array String) := do
  let acne := getColumn t (·.getAcne)
  let mut hits : Array String := #[]
  for c in jellyColors do
    let col := getColumn t c.get
    let p ← fisherTest acne col
    if p < 0.05 then hits := hits.push c.name
  return hits

/-- Drop the name column by projecting to `JellyAnon` — specialized, not
    generic `dropColumns` on a computed header. -/
def dropName (t : Array (Stored JellyNamed)) : Array JellyAnon :=
  t.map fun r =>
    { getAcne := r.val.getAcne, red := r.val.red, black := r.val.black,
      white := r.val.white, green := r.val.green, yellow := r.val.yellow,
      brown := r.val.brown, orange := r.val.orange, pink := r.val.pink,
      purple := r.val.purple }

def pHackingNamed (t : Array (Stored JellyNamed)) : Except String (Array String) :=
  pHacking (dropName t |>.map fun v => ⟨⟨0⟩, v⟩)

/-- specialized: quiz fields are named in the type, not discovered by
    `startsWith(..., "quiz")`. -/
def quizAverage (g : Gradebook) : Float :=
  (g.quiz1 + g.quiz2 + g.quiz3 + g.quiz4).toFloat / 4.0

def quizScoreFilter (t : Array (Stored Gradebook)) : Array (String × Float) :=
  t.map fun r => (r.val.name, quizAverage r.val)

/-- specialized: manufactured names `quiz1`…`quiz4` are Lean fields, not
    `concat("quiz", colNameOfNumber i)`. -/
def quizScoreSelect (t : Array (Stored Gradebook)) : Array (String × Float) :=
  quizScoreFilter t

/-- extra Lean: group rows by a typed key; groups stay Lean arrays, not
    table-valued cells. -/
def groupByRetentive (rows : Array α) (key : α → β) [BEq β] :
    Array (β × Array α) :=
  Id.run do
    let mut keys : Array β := #[]
    for r in rows do
      let k := key r
      unless keys.any (· == k) do keys := keys.push k
    return keys.map fun k => (k, rows.filter (fun r => key r == k))

/-- extra Lean: same groups with the key projected out. -/
def groupBySubtractive (rows : Array α) (key : α → β) (drop : α → γ) [BEq β] :
    Array (β × Array γ) :=
  (groupByRetentive rows key).map fun (k, rs) => (k, rs.map drop)

/-- extra Lean: corrected `employeeToDepartment` (Errors.md). -/
def employeeToDepartment (name : String) (emps : Array (Stored Employee))
    (depts : Array (Stored Department)) : Except String String := do
  let matched := tfilter emps (fun e => e.val.lastName == name)
  let row ← getRow matched 0
  match row.val.departmentId with
  | none => .error s!"{name} has no department"
  | some id =>
      let ds := tfilter depts (fun d => d.val.departmentId == id)
      let d ← getRow ds 0
      return d.val.departmentName

end B2T2.Programs
