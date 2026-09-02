# LEP-0004: Child-table quantifiers

| Field | Value |
|---|---|
| Status | Draft |
| Number | LEP-0004 |
| Created | 2026-09-01 |
| Target | Post-LEP-0002 |
| Primary goal | `∃`/`∀` over a related table as one pushed `select` |
| Depends on | LEP-0002 (typed predicate IR) |

## Summary

`select` computes a filtered product. It can find dishes that *have* an
offending ingredient; it cannot find dishes that have *none*, because
"none" is a universal quantifier over another table's rows and a product
has no way to say it. The restaurant base's central query — "ramen I can
eat" — is therefore two fetches and a set difference in Lean today
(`examples/eats/Eats/Queries.lean`, `suitable`), correct and documented,
and not one query.

This proposal adds two constructors to `Pred`, reserved there since
LEP-0002:

```lean
| exists (parent : Col ts (Id α) i) (fk : Col [child] (Id α) j) (body : Pred (child :: ts))
| forall (parent : Col ts (Id α) i) (fk : Col [child] (Id α) j) (body : Pred (child :: ts))
```

They render as `EXISTS (SELECT 1 FROM child … WHERE child.fk IS parent AND
body)` and `NOT EXISTS (… AND NOT body)`, denote against a snapshot of the
child table, are monotone (so `approx_sound` extends by two cases), and
negate into each other exactly. With them `suitable` is one `select`, and
the kernel base's per-input questions ("every input has rank ≥ 3", "any
input is column-major") become pushable once inputs are rows (LEP-0003).

Quantified predicates are written as **`Pred` values**, not lambdas: a
lambda over `Rows ts` cannot mention rows it was not given. This is the
first place the engine takes a plan as data at the call site, which is
also the first step of the query universe (study §5).

## Why do this

The evidence is one query, but it is the query the base exists for, and
it is the shape every "for all related rows" question takes:

- **eats:** `suitable fam diet city` — every ingredient row of the dish is
  allowed by the diet or removable. Two fetches, anti-join in Lean.
- **kernels:** "exactly two inputs", "every input has rank ≥ 3", "any
  input column-major" — residual today because inputs live inside a JSON
  column; with inputs as child rows (LEP-0003 stage D) they are exactly
  `forall`/`exists` over `KernelInput`.
- **tickets:** "tickets with no comments", "users who reported nothing
  open" — the same shape, unbuilt.

The reference semantics must be able to *state* these to remain the
semantics. A quantifier that only exists in the executor is not a
reference.

## Terminology

**Parent reference**: a column of the outer rows typed `Id α` — usually
`Col.id` of one table, but any `Ref α` column qualifies (quantify over
the hours of the restaurant *a dish points at*, without joining
`Restaurant` into the outer product).

**Child key**: a column of the child table typed `Id α`, the foreign key
that relates it to the parent reference. Typing both as `Id α` is what
makes a mismatched quantifier unrepresentable.

**Snapshot**: the child rows the denotation quantifies over — the
database's, in the executor; a fixture's, in tests.

## Design

### Constructors

```lean
inductive Pred (ts : List Type) : Type 1 where
  …
  /-- Some row of `child` whose `fk` equals `parent` satisfies `body`,
      which may mention that row (position 0) and every outer row. -/
  | exists {α child : Type} {i : ColCodec (Id α)} {j : ColCodec (Id α)} [Entity child]
      (parent : Col ts (Id α) i) (fk : Col [child] (Id α) j) (body : Pred (child :: ts))
  /-- Every such row does. `forall` is `¬ exists ¬`; it is a constructor so
      the rendering (`NOT EXISTS … NOT`) and the denotation are direct. -/
  | forall {α child : Type} {i j : ColCodec (Id α)} [Entity child]
      (parent : Col ts (Id α) i) (fk : Col [child] (Id α) j) (body : Pred (child :: ts))
```

`body : Pred (child :: ts)`: the child row is table 0 inside the body,
the outer tables shift up by one. Nested quantifiers nest the list.

### Denotation against a snapshot

`denote` today is `Pred ts → Rows ts → Bool`. A quantifier needs the
child rows, so `denote` takes them:

```lean
/-- The rows the reference semantics quantifies over. -/
structure Snapshot where
  rows : (β : Type) → [Entity β] → Array (Stored β)

def Pred.denote (snap : Snapshot) : Pred ts → Rows ts → Bool
  | .exists parent fk body, r =>
      (snap.rows child).any fun c =>
        j.toCol (fk.proj c) == i.toCol (parent.proj r) && body.denote snap (Rows.cons c r)
  | .forall parent fk body, r =>
      (snap.rows child).all fun c =>
        !(j.toCol (fk.proj c) == i.toCol (parent.proj r)) || body.denote snap (Rows.cons c r)
```

`Rows.cons : Stored child → Rows ts → Rows (child :: ts)` splits on `ts`
like `Rows.head`/`tail` do. Ids compare in the encoded domain, consistent
with `eq2`. Every existing case ignores `snap`; existing tests pass a
snapshot with no rows.

### Soundness

`approx` recurses into `body`; `residuals` counts through it. Both
quantifiers are monotone in `body` — a larger body set makes `any` larger
and `all` larger — so `approx_sound` gains two cases proved from
`Array.any`/`Array.all` monotonicity lemmas. `neg`:

```lean
| .exists p fk b => .forall p fk b.neg
| .forall p fk b => .exists p fk b.neg
```

exact, because the body's negation is exact (LEP-0002).

### Rendering

Aliases become a function. Today `render (alias? : Bool)`; the joined
executor names tables `t0…`, the single-table fetch leaves columns bare.
A subquery must qualify the outer column or SQLite resolves `"id"` to
the *child's* id — so:

```lean
def Pred.render (aliasOf : Nat → String) (depth : Nat := 0) : Pred ts → String × Array Col
  | .exists parent fk body =>
      let s := s!"s{depth}"
      let (bs, bb) := body.render (fun | 0 => s | n + 1 => aliasOf n) (depth + 1)
      (s!"EXISTS (SELECT 1 FROM {quoteIdent (Entity.tableName child)} AS {s} \
          WHERE {s}.{quote fk.name} IS {aliasOf parent.tableIdx}.{quote parent.name} AND {bs})", bb)
  | .forall parent fk body => -- NOT EXISTS (… AND NOT (body)) via body.neg, so no `NOT (` textual negation
```

The top-level call uses `fun n => s!"t{n}"`, which reproduces today's
output byte for byte for every existing plan. `fetchFiltered` switches
from bare columns to the same aliasing (`FROM "table" AS t0`); that SQL is
not logged, so the R3 baseline is unaffected — re-verify it anyway.

`tables`: a quantifier touches `parent.tableIdx` and every outer table
its body references (body indices ≥ 1, shifted down). `forTable`/`hasJoin`
follow.

### Executor

`select` keeps its lambda form. A second entry point takes the plan as
data:

```lean
def selectP (ts : List Type) [RowsOf ts] (p : Pred ts)
    (sortBy : SortBy (Rows ts) := .preserve) : DbM (Array (Rows ts)) := do
  let snap ← Pred.snapshot p          -- fetchAll for each child table the plan quantifies over
  let rows ← fetch (pushed := p.approx)   -- joined or per-table, exactly as `select`
  return finishRows ts rows (p.denote snap) sortBy
```

The lambda-always-runs invariant is kept literally: `finishRows` filters
by the plan's denotation. The cost is one `fetchAll` per quantified child
table per select — bounded by the child table, not by the product. For
these bases that is a few hundred rows; note it in the docstring, and
revisit if a base with a large child table appears (the natural fix is
to fetch only children of the fetched parents, which needs `IN (…)` and
is a later optimization).

`Pred.snapshot` needs the child types at runtime: `Pred.children : Pred ts
→ List (Σ β : Type, Entity β)` — a list of packed entity instances, which
is what makes the fetch typed.

### Surface

The tactic does not learn `.any`/`.all`: there is no Lean expression a
lambda could write for "the child rows of this dish". Instead the body
lambdas are reified by a **term elaborator** that exposes the plan tactic:

```lean
/-- `pred% [Dish, Restaurant] (fun (d, r) => …) : Pred [Dish, Restaurant]`. -/
elab "pred% " ts:term " " f:term : term
```

and two combinators fix the common case where the parent reference is
the row identity of table 0:

```lean
def Pred.all (child : Type) [Entity child] (fk : Entity.Field child)
    (h : Entity.fieldTy fk = Id α) (body : Pred (child :: α :: ts)) : Pred (α :: ts)
def Pred.any …
```

`suitable` then reads:

```lean
def suitable (fam : DishFamily) (diet : Diet) (city : City) :=
  selectP [Dish, Restaurant, CanonicalDish]
    ((pred% [Dish, Restaurant, CanonicalDish] fun (d, r, c) =>
        d.val.restaurant == r.ref && d.val.canonical == c.ref
          && c.val.family == fam && r.val.city == city
          && d.val.available && d.val.ingredientsComplete)
      |>.and (Pred.all DishIngredient .dish rfl
        (Pred.any Ingredient .id ⟨…⟩   -- the 1:1 ingredient row, joined inside the quantifier
          (pred% [Ingredient, DishIngredient, Dish, Restaurant, CanonicalDish]
            fun (i, di, _, _, _) => diet.allows i.val.kind || di.val.removable))))
    (.key fun (_, r, _) => r.val.name)
```

rendering as

```sql
… AND NOT EXISTS (SELECT 1 FROM "dish_ingredient" AS s0
      WHERE s0."dish" IS t0."id" AND NOT (s0."removable" IS ? OR EXISTS (
        SELECT 1 FROM "ingredient" AS s1 WHERE s1."id" IS s0."ingredient"
          AND (s1."kind" IS ? OR …))))
```

The inner `any` over `Ingredient` is a join expressed as a quantifier;
since the FK is 1:1 it is exact. A `join` combinator that flattens that
into the child list is a later ergonomic, not part of this proposal.

### Boundaries

- The log's `describe` covers quantifiers: they render.
- `rows --eq` is unchanged: conjunctive equality only, by design.
- Serialization (R5) gets two more constructor tags.

## What is not in scope

- Teaching the tactic to recognize any lambda form for quantifiers.
- Correlated `IN`-narrowing of the snapshot fetch.
- Aggregates (`COUNT` of children ≥ n). "Exactly two inputs" is
  `exists position=0 ∧ exists position=1 ∧ ¬exists position=2` — expressible,
  ugly, and the honest answer until an aggregate verb exists.

## Staging

1. `Snapshot`, `Rows.cons`, the two constructors, `denote`, `neg`,
   `approx`, `residuals`, `tables`, the extended `approx_sound`. Pure
   addition; all existing goldens unchanged (they pass an empty snapshot).
2. `render` with alias functions; `fetchFiltered` aliased. Baseline
   replay: zero differences.
3. `selectP`, `Pred.snapshot`, `pred%`, `Pred.all`/`any`.
4. eats: `suitable` as one `selectP`; its two-fetch form kept as
   `suitableTwoPhase` for the differential test — both must return the
   same rows for every `(family, diet, city)` in the seed. Transcript
   regenerated; the `NOT EXISTS` plan appears in `log`.
5. kernels: once LEP-0003 stage D lands, `highRank`/`anyColMajor` as
   quantifiers; until then, nothing.

## Alternatives considered

### Lambdas with a `Children` handle

Give `Stored Dish` a phantom `ingredients : Children DishIngredient` the
tactic recognizes. The lambda must still *execute* in `finishRows`, and a
handle with no rows behind it cannot; the only fix is to prefetch and
attach the children to every row, which changes `Rows` for every select.
Writing the quantifier as data is smaller and is where the design was
going anyway.

### Anti-join in the joined executor

`LEFT JOIN … WHERE child.id IS NULL` handles `∀ ¬` but not `∀ body` with
a non-trivial body, and it has no denotation. `NOT EXISTS` is what the
reference semantics says.

### Aggregates first

`COUNT(*) = 0` subsumes `¬∃` but not `∀ body`, and aggregates are a
different verb. Quantifiers are the smaller, more general step.

## Acceptance criteria

```lean
#check (Pred.forall (ts := [Dish]) .id (.here DishIngredient.Field.dish) body : Pred [Dish])
#check_failure (Pred.forall (ts := [Dish]) .id (.here Hours.Field.day) body)         -- fk not an Id
#check_failure (Pred.forall (ts := [Dish]) .id (.here Hours.Field.restaurant) body)  -- Id of the wrong entity
theorem Pred.approx_sound … -- extended, no sorry
```

1. Every pre-LEP golden unchanged; baseline replay across all eight bases
   zero differences.
2. `suitable` as one `selectP` equals `suitableTwoPhase` on every seed
   `(family, diet, city)`; its logged plan contains `NOT EXISTS` and
   residual 0.
3. `denote` of a `forall` plan over a fixture snapshot equals the
   hand-written two-fetch answer for the engine fixtures.
4. A quantifier whose body has an opaque leaf: `approx` drops the leaf,
   the executor's re-check restores the answer, and the differential
   against `selectUnplanned` (over the same snapshot) holds.
