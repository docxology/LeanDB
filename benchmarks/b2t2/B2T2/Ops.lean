import B2T2.Entities

/-! B2T2 Table API operations that this evaluation implements.

Each function is labeled in comments as **direct** (LeanDB verb / type),
**extra Lean** (decoded rows or schema-static helpers), or is omitted
here and recorded as **unsupported** in INVENTORY.md.

Same-schema transformers run on `Array (Stored α)` after a typed fetch.
Schema-changing operations return a new Lean type, not a dynamically
named table.
-/

namespace B2T2.Ops

open LeanDb

/-- extra Lean: `Array.size` on a fetched table. SQL equivalent: `COUNT(*)`. -/
def nrows (rows : Array α) : Nat := rows.size

/-- extra Lean over `Entity.spec`: compile-time column count, excluding `id`. -/
def ncols (α : Type) [Entity α] : Nat := (Entity.spec α).columns.size

/-- extra Lean: Lean identifiers as stored column names, not B2T2 display names. -/
def header (α : Type) [Entity α] : List String :=
  (Entity.spec α).columns.toList.map (·.name)

/-- extra Lean: project a typed field. Not a first-class `ColName`. -/
def getColumn (rows : Array (Stored α)) (f : α → β) : Array β :=
  rows.map fun r => f r.val

/-- extra Lean: positional column via `Entity.encode`. -/
def getColumnN (α : Type) [Entity α] (rows : Array (Stored α)) (n : Nat) :
    Except String (Array Col) := do
  if n >= ncols α then .error s!"column index {n} not in range({ncols α})"
  else .ok (rows.map fun r => (Entity.encode r.val)[n]!)

/-- extra Lean: string-named field at the decode boundary. -/
def getValue (α : Type) [Entity α] (row : α) (c : String) : Except String Col :=
  match Entity.fieldOfName? α c with
  | none => .error s!"no such column {String.quote c}; columns: {header α}"
  | some f => .ok ((Entity.codec f).toCol (Entity.get f row))

/-- extra Lean: positional row. B2T2 requires `n ∈ range(nrows)`. -/
def getRow (rows : Array α) (n : Nat) : Except String α :=
  match rows[n]? with
  | some r => .ok r
  | none => .error s!"row index {n} not in range({rows.size})"

/-- extra Lean / direct: filter. The DbM form is LeanDB `select`. -/
def tfilter (rows : Array α) (p : α → Bool) : Array α := rows.filter p

def tfilterDb (α : Type) [Entity α] (p : Stored α → Bool) : DbM (Array (Stored α)) :=
  select [α] p

/-- extra Lean: keep rows at the given indices (`selectRows` on numbers). -/
def selectRowsNs (rows : Array α) (ns : List Nat) : Except String (Array α) := do
  let mut out : Array α := #[]
  for n in ns do
    match rows[n]? with
    | some r => out := out.push r
    | none => throw s!"row index {n} not in range({rows.size})"
  return out

/-- extra Lean: boolean mask (`selectRows` on booleans). -/
def selectRowsBs (rows : Array α) (bs : Array Bool) : Except String (Array α) := do
  if bs.size != rows.size then
    .error s!"mask length {bs.size} != nrows {rows.size}"
  else
    let mut out : Array α := #[]
    for i in [0:rows.size] do
      if h : i < bs.size ∧ i < rows.size then
        if bs[i] then out := out.push rows[i]
    return out

/-- extra Lean: first `n` rows, or drop `|n|` from the end if negative. -/
def head (rows : Array α) (n : Int) : Except String (Array α) :=
  if n ≥ 0 then
    let k := n.toNat
    if k > rows.size then .error s!"head {n} not in range({rows.size})"
    else .ok (rows.take k)
  else
    let k := (-n).toNat
    if k > rows.size then .error s!"head {n} not in range({rows.size})"
    else .ok (rows.take (rows.size - k))

/-- extra Lean: unique decoded rows by a key (B2T2 `distinct` on values).
    LeanDB ids make stored rows unique even when values repeat. -/
def distinctBy (rows : Array α) (key : α → β) [BEq β] : Array α :=
  Id.run do
    let mut seen : Array β := #[]
    let mut out : Array α := #[]
    for r in rows do
      let k := key r
      unless seen.any (· == k) do
        seen := seen.push k
        out := out.push r
    return out

/-- extra Lean: drop rows with any missing cell, given a completeness test. -/
def dropna (rows : Array α) (complete : α → Bool) : Array α :=
  rows.filter complete

/-- extra Lean: replace `none` in one optional column. -/
def fillna (v : Option β) (fill : β) : β := v.getD fill

/-- extra Lean: per-row mask of non-missing cells. -/
def completeCases (col : Array (Option β)) : Array Bool :=
  col.map fun
    | none => false
    | some _ => true

/-- extra Lean: frequency table. Output schema is a Lean pair, not a new Entity. -/
def count [BEq α] [Ord α] (vs : Array α) : Array (α × Nat) :=
  Id.run do
    let mut keys : Array α := #[]
    for v in vs do
      unless keys.any (· == v) do keys := keys.push v
    return keys.map fun k => (k, vs.foldl (fun n v => if v == k then n + 1 else n) 0)

/-- extra Lean: left join on a key. Unmatched right side is `none`. -/
def leftJoin (left : Array α) (right : Array β) (match? : α → β → Bool) :
    Array (α × Option β) :=
  left.map fun a =>
    (a, right.find? (match? a))

/-- extra Lean: inner join on a key. -/
def innerJoin (left : Array α) (right : Array β) (match? : α → β → Bool) :
    Array (α × β) :=
  left.flatMap fun a => (right.filter (match? a)).map fun b => (a, b)

/-- extra Lean: cartesian product (`crossJoin`) on already-fetched tables. -/
def crossJoin (left : Array α) (right : Array β) : Array (α × β) :=
  left.flatMap fun a => right.map fun b => (a, b)

/-- extra Lean: vertical concat of same-type rows. -/
def vcat (a b : Array α) : Array α := a ++ b

/-- extra Lean: sort by a typed key. The DbM form is LeanDB `SortBy`. -/
def tsort (rows : Array α) (key : α → κ) [Ord κ] (asc : Bool) : Array α :=
  rows.qsort fun x y =>
    let o := compare (key x) (key y)
    if asc then o.isLT else o.isGT

/-- Insertion order after seed: LeanDB ids are assigned sequentially. -/
def loadOrdered (α : Type) [Entity α] : DbM (Array (Stored α)) :=
  select [α] (fun _ => true) (.key (·.id))

/-- extra Lean: `addRows` is insert-each. -/
def addRows (α : Type) [Entity α] (rs : Array α) : DbM Unit := do
  for r in rs do discard <| insert α r

/-- extra Lean: flatten parallel sequence cells. -/
def flattenQuizzes (rows : Array GradebookSeq) : Array (String × Nat × Nat × Nat) :=
  rows.flatMap fun r =>
    r.quizzes.toArray.map fun q => (r.name, r.age, q, r.midterm)

end B2T2.Ops
