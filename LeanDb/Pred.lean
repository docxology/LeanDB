import LeanDb.Select

namespace LeanDb

/-! # The typed predicate IR (LEP-0002, stage 2)

`Pred ts` is a select predicate as data, indexed by the same table list
that types the predicate lambda. Its column references (`Pred.Col`) are
Lean values built from the generated field symbols, so a plan over a
column that does not exist, over a table not in the `select`, or against
a value of the wrong type is *unrepresentable*. `denote` gives every plan
a meaning over `Rows ts`; `approx` is the part that ships to SQL, and
`approx_sound` proves it never excludes a row the plan would accept.

This is the plan `select` carries: `leandb_plan` (`LeanDb.PlanElab`)
reifies the call-site lambda into a `Pred`, the executor sends `approx`
to SQL and still applies the lambda to what comes back (`finishRows`), so
pushdown narrows a fetch and never decides a result.

Two names collide with the encoded-value layer on purpose and are kept
apart by namespace: `LeanDb.Col` is a SQL value; `LeanDb.Pred.Col` is a
column reference. Inside `namespace Pred`, `Col` means the reference.
-/

/-! ## Rows, by shape

`Rows [α]` is `Stored α`, not a pair (see `LeanDb.Select`), so anything
walking a `Rows (α :: ts)` splits on `ts`. -/

/-- The head table's row. -/
def Rows.head : {α : Type} → {ts : List Type} → Rows (α :: ts) → Stored α
  | _, [], r => r
  | _, _ :: _, r => r.1

/-- The rows of every table but the head; only defined when there is one. -/
def Rows.tail {α β : Type} {ts : List Type} (r : Rows (α :: β :: ts)) : Rows (β :: ts) := r.2

/-! ## Operators -/

/-- Null-safe equality, rendered `IS` / `IS NOT`. -/
inductive EqOp where
  | eq | ne
  deriving Repr, DecidableEq, BEq

def EqOp.sql : EqOp → String
  | .eq => "IS"
  | .ne => "IS NOT"

def EqOp.negate : EqOp → EqOp
  | .eq => .ne
  | .ne => .eq

/-- Equality in the encoded domain: `IS` on NULL means "both NULL", which
    is a fact about `LeanDb.Col` (`.null == .null`), not about `τ`. -/
def EqOp.eval : EqOp → LeanDb.Col → LeanDb.Col → Bool
  | .eq, a, b => a == b
  | .ne, a, b => a != b

/-- Ordered comparison; only ever over `SqlOrd` types. -/
inductive OrdOp where
  | lt | le | gt | ge
  deriving Repr, DecidableEq, BEq

def OrdOp.sql : OrdOp → String
  | .lt => "<"
  | .le => "<="
  | .gt => ">"
  | .ge => ">="

def OrdOp.negate : OrdOp → OrdOp
  | .lt => .ge
  | .le => .gt
  | .gt => .le
  | .ge => .lt

def OrdOp.holds : OrdOp → Ordering → Bool
  | .lt, o => o == .lt
  | .le, o => o != .gt
  | .gt, o => o == .gt
  | .ge, o => o != .lt

/-- Order of two encoded values, total: defined within one INTEGER or TEXT
    class (what SQLite's BINARY collation orders), `none` otherwise — REAL
    (NaN), NULL, or mixed classes. -/
def Col.order : LeanDb.Col → LeanDb.Col → Option Ordering
  | .int a, .int b => some (compare a b)
  | .text a, .text b => some (compare a b)
  | _, _ => none

/-- Ordered comparison in the encoded domain: `false` wherever `Col.order`
    is undefined. `ord` is denoted this way (rather than in the Lean
    domain) because `SqlOrd τ` carries no `Ord`; the `SqlOrd` law — the
    encoding preserves the type's order — is then exactly what makes this
    agree with the lambda, and `neg` exact: under the law an `ord` column
    is INTEGER/TEXT and never NULL, so `Col.order` is always `some`. -/
def OrdOp.eval (op : OrdOp) (a b : LeanDb.Col) : Bool :=
  match Col.order a b with
  | some o => op.holds o
  | none => false

namespace Pred

/-! ## Column references -/

/-- A column of one of the tables in `ts`, positionally (de Bruijn:
    `here`/`there`), with its Lean type `τ` and its STORAGE codec `i` — the
    codec that produced the bytes SQLite compares. Indexing by the codec is
    what makes `via`'s proof mean what it must. -/
inductive Col : List Type → (τ : Type) → ColCodec τ → Type 1 where
  /-- A declared field of the head table, from its symbol. The entity is
      recovered from the symbol type (`FieldOf`), so `Col.here
      Ticket.Field.title` needs no annotation. -/
  | here {F α : Type} {ts : List Type} [ent : Entity α] [fo : FieldOf F α] (f : F) :
      Col (α :: ts) (Entity.fieldTy (FieldOf.sym f)) (Entity.codec (FieldOf.sym f))
  /-- The head table's row identity (`Stored.id` / `.ref`). -/
  | id {α : Type} {ts : List Type} [ent : Entity α] : Col (α :: ts) (Id α) inferInstance
  /-- Skip one table. -/
  | there {α : Type} {ts : List Type} {τ : Type} {i : ColCodec τ} :
      Col ts τ i → Col (α :: ts) τ i
  /-- View a column through a function that is its own encoding. `h` is
      stated against the column's STORAGE codec `i`, so it says exactly
      that SQLite compares what the Lean predicate compares. `rfl` for
      any `ColCodec.via` newtype, and for `some`. -/
  | via {ts : List Type} {τ σ : Type} {i : ColCodec τ} {j : ColCodec σ}
      (c : Col ts τ i) (f : τ → σ) (h : ∀ a, i.toCol a = j.toCol (f a)) : Col ts σ j

/-- `Col [] τ i` is empty: every constructor but `via` lengthens the list,
    and `via` only re-types an existing reference. -/
theorem Col.nil_elim {τ : Type} {i : ColCodec τ} : Col [] τ i → False
  | .via c _ _ => Col.nil_elim c

/-- The storage codec, read off the index. -/
abbrev Col.codec {ts : List Type} {τ : Type} {i : ColCodec τ} (_ : Col ts τ i) : ColCodec τ := i

/-- Position of the referenced table in the `select` list. -/
def Col.tableIdx {ts : List Type} {τ : Type} {i : ColCodec τ} : Col ts τ i → Nat
  | .here (ent := _) (fo := _) _ => 0
  | .id (ent := _) => 0
  | .there c => c.tableIdx + 1
  | .via c _ _ => c.tableIdx

/-- The column name, for rendering only; `via` does not rename. -/
def Col.name {ts : List Type} {τ : Type} {i : ColCodec τ} : Col ts τ i → String
  | .here (ent := ent) (fo := fo) f => @Entity.fieldName _ ent (@FieldOf.sym _ _ ent fo f)
  | .id (ent := _) => "id"
  | .there c => c.name
  | .via c _ _ => c.name

/-- Read the column off a row. -/
def Col.proj : {ts : List Type} → {τ : Type} → {i : ColCodec τ} → Col ts τ i → Rows ts → τ
  | _, _, _, .here (ent := ent) (fo := fo) f, r =>
      @Entity.get _ ent (@FieldOf.sym _ _ ent fo f) (Rows.head r).val
  | _, _, _, .id (ent := _), r => (Rows.head r).id
  | _ :: [], _, _, .there c, _ => (Col.nil_elim c).elim
  | _ :: _ :: _, _, _, .there c, r => c.proj (Rows.tail r)
  | _, _, _, .via c f _, r => f (c.proj r)

end Pred

/-! ## The plan -/

/-- A select predicate as data over `Rows ts`. Three things are
    structural here that an untyped tree leaves to tactic discipline: an ordered
    comparison needs `SqlOrd τ` at the constructor (so no nullable or
    closed-enum column can appear in one, which is what makes `neg` exact);
    the comparison value is a `τ`, not a `LeanDb.Col`; and the residual is
    a leaf in the same tree. -/
inductive Pred (ts : List Type) : Type 1 where
  | tt
  | ff
  /-- Column vs value, null-safe (`IS`/`IS NOT`). Denoted in the ENCODED
      domain, because `IS` on NULL is a fact about the encoding. -/
  | eq {τ : Type} {i : ColCodec τ} (c : Pred.Col ts τ i) (op : EqOp) (v : τ)
  /-- Ordered. `[SqlOrd τ]` AT THE CONSTRUCTOR is what makes `neg` exact.
      Denoted in the encoded domain through `Col.order` (see `OrdOp.eval`). -/
  | ord {τ : Type} {i : ColCodec τ} [so : SqlOrd τ] (c : Pred.Col ts τ i) (op : OrdOp) (v : τ)
  /-- Column vs column; across distinct tables this is a join condition. -/
  | eq2 {τ : Type} {i j : ColCodec τ} (a : Pred.Col ts τ i) (op : EqOp) (b : Pred.Col ts τ j)
  | ord2 {τ : Type} {i j : ColCodec τ} [so : SqlOrd τ]
      (a : Pred.Col ts τ i) (op : OrdOp) (b : Pred.Col ts τ j)
  | isNull {τ : Type} {i : ColCodec (Option τ)} (c : Pred.Col ts (Option τ) i)
  | isNotNull {τ : Type} {i : ColCodec (Option τ)} (c : Pred.Col ts (Option τ) i)
  | and (a b : Pred ts)
  | or (a b : Pred ts)
  /-- The residual, as a leaf: runs in Lean, never in SQL. -/
  | opaque (f : Rows ts → Bool)
  -- RESERVED for LEP-0004, deliberately NOT a constructor yet (a
  -- constructor with no denote/render would be a lie): exists/forall over
  -- a child table related by a foreign key. See the LEP.

instance : Inhabited (Pred ts) := ⟨.tt⟩

namespace Pred

variable {ts : List Type}

/-! ### Smart constructors -/

/-- Simplifying conjunction. -/
def andS : Pred ts → Pred ts → Pred ts
  | .tt, b => b
  | .ff, _ => .ff
  | a, .tt => a
  | _, .ff => .ff
  | a, b => .and a b

/-- Simplifying disjunction. -/
def orS : Pred ts → Pred ts → Pred ts
  | .ff, b => b
  | .tt, _ => .tt
  | a, .ff => a
  | _, .tt => .tt
  | a, b => .or a b

/-- Value/value equality. Both sides are Lean values of one type when the
    plan is built, so this always decides — in the encoded domain, with
    `IS` semantics. A closed-world case split against a captured parameter
    leaves these guards; every one folds, and the tree collapses to the
    surviving column conditions before SQL. -/
def vvEq {τ : Type} [ColCodec τ] (a : τ) (op : EqOp) (b : τ) : Pred ts :=
  if op.eval (toCol a) (toCol b) then .tt else .ff

/-- Value/value ordering. Decided now within one INTEGER/TEXT class — which
    is every case under the `SqlOrd` law. Outside it (a custom `SqlOrd`
    codec storing REAL) the leaf stays opaque so `approx` drops it and the
    lambda decides; its own denotation follows `OrdOp.eval`. -/
def vvOrd {τ : Type} [ColCodec τ] [SqlOrd τ] (a : τ) (op : OrdOp) (b : τ) : Pred ts :=
  match Col.order (toCol a) (toCol b) with
  | some o => if op.holds o then .tt else .ff
  | none => .opaque fun _ => false

/-- Exact negation. `ord`/`ord2` flip the operator, exact by the `SqlOrd`
    argument at the constructor; `eq`/`eq2` flip `IS`/`IS NOT`; null tests
    swap; `and`/`or` by De Morgan; the residual negates its function. -/
def neg : Pred ts → Pred ts
  | .tt => .ff
  | .ff => .tt
  | .eq c op v => .eq c op.negate v
  | .ord (so := so) c op v => .ord (so := so) c op.negate v
  | .eq2 a op b => .eq2 a op.negate b
  | .ord2 (so := so) a op b => .ord2 (so := so) a op.negate b
  | .isNull c => .isNotNull c
  | .isNotNull c => .isNull c
  | .and a b => .or a.neg b.neg
  | .or a b => .and a.neg b.neg
  | .opaque f => .opaque fun r => !f r

/-! ### Denotation -/

/-- What a plan means over a row. `eq`/`isNull` in the encoded domain;
    `ord` in the encoded domain too (`OrdOp.eval`, see there); the residual
    is its function. -/
def denote : Pred ts → Rows ts → Bool
  | .tt, _ => true
  | .ff, _ => false
  | .eq (i := i) c op v, r => op.eval (i.toCol (c.proj r)) (i.toCol v)
  | .ord (i := i) (so := _) c op v, r => op.eval (i.toCol (c.proj r)) (i.toCol v)
  | .eq2 (i := i) (j := j) a op b, r => op.eval (i.toCol (a.proj r)) (j.toCol (b.proj r))
  | .ord2 (i := i) (j := j) (so := _) a op b, r =>
      op.eval (i.toCol (a.proj r)) (j.toCol (b.proj r))
  | .isNull (i := i) c, r => i.toCol (c.proj r) == .null
  | .isNotNull (i := i) c, r => !(i.toCol (c.proj r) == .null)
  | .and a b, r => a.denote r && b.denote r
  | .or a b, r => a.denote r || b.denote r
  | .opaque f, r => f r

/-- Every opaque leaf weakened to `true`, simplifying as it goes. Monotone
    recursion suffices: `and`/`or` are monotone, so weakening each side
    upward weakens the whole upward. -/
def approx : Pred ts → Pred ts
  | .and a b => andS a.approx b.approx
  | .or a b => orS a.approx b.approx
  | .opaque _ => .tt
  | p => p

/-- Opaque leaves: the conjuncts left to the lambda. -/
def residuals : Pred ts → Nat
  | .opaque _ => 1
  | .and a b => a.residuals + b.residuals
  | .or a b => a.residuals + b.residuals
  | _ => 0

def hasOpaque (p : Pred ts) : Bool := p.residuals != 0

theorem denote_andS (a b : Pred ts) (r : Rows ts) :
    (andS a b).denote r = (a.denote r && b.denote r) := by
  unfold andS
  split <;> simp [denote]

theorem denote_orS (a b : Pred ts) (r : Rows ts) :
    (orS a b).denote r = (a.denote r || b.denote r) := by
  unfold orS
  split <;> simp [denote]

/-- No over-narrowing: whatever the plan accepts, its pushable projection
    accepts. This is the property the strict/lenient split of the tactic
    argues for; here it is a theorem, once. -/
theorem approx_sound : ∀ (p : Pred ts) (r : Rows ts),
    p.denote r = true → p.approx.denote r = true
  | .and a b, r, h => by
      have h' : a.denote r = true ∧ b.denote r = true := by simpa [denote] using h
      show (andS a.approx b.approx).denote r = true
      rw [denote_andS, approx_sound a r h'.1, approx_sound b r h'.2]
      rfl
  | .or a b, r, h => by
      have h' : a.denote r = true ∨ b.denote r = true := by simpa [denote] using h
      show (orS a.approx b.approx).denote r = true
      rw [denote_orS]
      rcases h' with h' | h'
      · rw [approx_sound a r h']
        rfl
      · rw [approx_sound b r h', Bool.or_true]
  | .opaque _, _, _ => rfl
  | .tt, _, h => h
  | .ff, _, h => h
  | .eq .., _, h => h
  | .ord (so := _) .., _, h => h
  | .eq2 .., _, h => h
  | .ord2 (so := _) .., _, h => h
  | .isNull .., _, h => h
  | .isNotNull .., _, h => h

/-! ### The plan surface -/

/-- Table indices a predicate touches. -/
def tables : Pred ts → List Nat
  | .tt | .ff | .opaque _ => []
  | .eq c .. => [c.tableIdx]
  | .ord (so := _) c .. => [c.tableIdx]
  | .isNull c => [c.tableIdx]
  | .isNotNull c => [c.tableIdx]
  | .eq2 a _ b => [a.tableIdx, b.tableIdx]
  | .ord2 (so := _) a _ b => [a.tableIdx, b.tableIdx]
  | .and a b | .or a b => (a.tables ++ b.tables).eraseDups

/-- Does the predicate relate two distinct tables? -/
def hasJoin : Pred ts → Bool
  | .eq2 a _ b => a.tableIdx != b.tableIdx
  | .ord2 (so := _) a _ b => a.tableIdx != b.tableIdx
  | .and a b | .or a b => a.hasJoin || b.hasJoin
  | _ => false

/-- Top-level conjuncts. -/
def conjuncts : Pred ts → List (Pred ts)
  | .and a b => a.conjuncts ++ b.conjuncts
  | .tt => []
  | p => [p]

/-- The part of the predicate pushable onto table `i` alone: the top-level
    conjuncts that touch only `i`. Dropping the rest only widens the fetch
    — never wrong. The result stays a `Pred ts`; the alias-free renderer
    ignores table indices, exactly as today. -/
def forTable (i : Nat) (p : Pred ts) : Pred ts :=
  (p.conjuncts.filter fun c => c.tables == [i]).foldl andS .tt

/-- Render as SQL. `alias?` qualifies columns (`t0."col"`) for the joined
    executor; `false` leaves them bare for single-table fetches. Returns
    the SQL and the bind values in placeholder order. Total: an opaque leaf
    renders as `1` — callers pass `p.approx`, which has none. -/
def render (alias? : Bool) : Pred ts → String × Array LeanDb.Col
  | .tt => ("1", #[])
  | .ff => ("0", #[])
  | .eq (i := i) c op v => (s!"{col alias? c} {op.sql} ?", #[i.toCol v])
  | .ord (i := i) (so := _) c op v => (s!"{col alias? c} {op.sql} ?", #[i.toCol v])
  | .eq2 a op b =>
      -- col/col comparison: `IS`/`IS NOT` are valid SQLite binary operators
      (s!"{col alias? a} {op.sql} {col alias? b}", #[])
  | .ord2 (so := _) a op b => (s!"{col alias? a} {op.sql} {col alias? b}", #[])
  | .isNull c => (s!"{col alias? c} IS NULL", #[])
  | .isNotNull c => (s!"{col alias? c} IS NOT NULL", #[])
  | .and a b =>
      let (sa, ba) := a.render alias?
      let (sb, bb) := b.render alias?
      (s!"({sa} AND {sb})", ba ++ bb)
  | .or a b =>
      let (sa, ba) := a.render alias?
      let (sb, bb) := b.render alias?
      (s!"({sa} OR {sb})", ba ++ bb)
  | .opaque _ => ("1", #[])
where
  col {ts : List Type} {τ : Type} {i : ColCodec τ} (alias? : Bool) (c : Col ts τ i) : String :=
    if alias? then s!"t{c.tableIdx}.\"{c.name}\"" else s!"\"{c.name}\""

/-- The human form logged per `select`: the SQL of the pushable projection
    and the number of conjuncts left to the lambda. -/
def describe (p : Pred ts) : String :=
  s!"pushed: {(p.approx.render true).1}, residual conjuncts: {p.residuals}"

/-- Exactly `tt`: nothing to push, so a fetch needs no `WHERE` at all. -/
def isTrivial : Pred ts → Bool
  | .tt => true
  | _ => false

end Pred

/-- Marker type carrying the predicate in its *type*, so the `leandb_plan`
    default-argument tactic can reflect the actual call-site lambda from
    its goal. Runtime-wise this is just `Pred ts`. -/
def PlanFor {ts : List Type} (_where' : Rows ts → Bool) : Type 1 := Pred ts

instance {ts : List Type} {w : Rows ts → Bool} : Inhabited (PlanFor w) := ⟨(.tt : Pred ts)⟩

def PlanFor.plan {ts : List Type} {w : Rows ts → Bool} (p : PlanFor w) : Pred ts := p

end LeanDb
