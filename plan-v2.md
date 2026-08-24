# LeanDB — plan v2 (from here)

**2026-08-23.** Supersedes the v0.1 slice and `PLAN_REVIEW.md`. Companion to
`plan.md` (the interface spec), which remains the target surface. This file
exists because the v0.1 slice built a decision-ranking engine instead of a
typed SQL engine; see the review summary at the bottom for what was wrong.

**Intent, restated in one line: strongly typed SQL.** Four verbs —
`insert`, `update`, `delete`, `select` — where the *types* make wrong queries
unwritable, backed by SQLite. Everything not on that spine is deferred.

---

## Ground rules (fixing the v0.1 failures)

1. **Two packages, from the first commit.** `leandb/` is the engine — it
   imports no domain. `examples/tickets/` is a base: a separate Lake package
   that depends on `leandb`. The engine must build with the examples deleted.
   Any engine file importing an example is a build error by construction.
2. **Schema has exactly one source: the types.** Anything schema-shaped that
   is emitted (DDL, `schema` JSON, CLI help) is *derived* from the entity
   declarations. Never a hand-written literal.
3. **No `String` where a type can stand.** Concretely:
   - No shared `TextValue`. Each string-carrying newtype owns its constructor
     and its invariant. A `Handle` and a `Title` share no code path.
   - No `name : String` fields for identity inside the engine. Identity is a
     Lean declaration; the elaborator has `Name`s when it needs them.
   - JSON via `Lean.Json` and derived `ToJson`/`FromJson` — never string
     concatenation.
   - Closed vocabularies (status, cuisine, priority…) are inductives, never
     validated strings.
4. **Sort keys are typed:** `.key (f : α → κ)` with `[Ord κ]`, per plan.md §8.
   Never "everything is a `Nat`".
5. **Anti-over-engineering rule:** correctness machinery first, optimization
   machinery only when a test demands it. In particular: `select` may run its
   predicate client-side in v1 (semantics = the four-line spec); SQL pushdown
   is an *optimization added underneath* without changing user code. No
   planner, no importer, no server, no log-replay, no templates beyond
   `tickets` until the four verbs are real.

## What happens to the v0.1 code

Delete `LeanDb/Query.lean` (Pareto/knee), `LeanDb/Api.lean`,
`LeanDb/Examples/*`, `LeanDb/Core.lean` as engine code. Git history keeps
them; the Pareto/knee logic can return one day as `@[db]` domain functions in
an example base, which is where multi-objective *choice* always belonged.
Keep: lakefile/toolchain scaffolding, the `leandb_tests` executable pattern.

---

## M1 — Typed core + one entity round-trip ✅ (2026-08-23)

Engine (`LeanDb/`):
- `Id α` (opaque row id, phantom-typed) and `Ref α` (foreign reference).
  `Ref User ≠ Ref Ticket` at the type level.
- `class ColCodec (α : Type)` — how a scalar lives in a SQLite column:
  `toCol : α → Col`, `fromCol : Col → Except DbError α`, plus the SQL column
  type. Instances for `Nat/Int/String/Bool/Option`, and a helper so a
  newtype's instance goes through its smart constructor (decode can fail
  *typed*, never yield an unvalidated value).
- `DbError` as an inductive (constructor = machine code; no string codes).
- `leansqlite` (leanprover/leansqlite, LowLevel layer) added as the only
  dependency. `Conn`, `DbM := ReaderT Conn (ExceptT DbError IO)`.
- `deriving LeanDb.Entity` for flat structures whose fields are `ColCodec`
  scalars, `Option`, or `Ref` — produces a `TableSpec` (name, columns, FKs)
  registered in an environment extension (the catalog), plus row encode/decode.
  **This is the highest-risk item in the whole plan; it goes first.**
- DDL generation from `TableSpec`; `createTables`; `_leandb_meta` with a
  schema fingerprint checked at open.

Exit test: a base package defines `User` and `Ticket` (with `Ref User`),
creates a fresh sqlite file, and property-tests
`decode (encode row) = row` for generated rows, engine built with zero
knowledge of either type.

## M2 — The four verbs, dependently typed ✅ (2026-08-23)

Per plan.md §8 / Architecture §8 signatures:

```
insert : (α : Type) → [Entity α] → α → DbM (Id α)
get    : [Entity α] → Id α → DbM (Option α)
update : [Entity α] → (old new : α) → DbM Unit      -- CAS: WHERE pins old
delete : [Entity α] → Id α → DbM Unit               -- FK RESTRICT surfaces as typed error
select : (ts : List Type) → [EntityList ts]
       → (where' : Rows ts → Bool) → (sortBy : SortBy (Rows ts))
       → DbM (Array (Rows ts))
```

- `Rows : List Type → Type` computed by recursion on the list — the dependent
  part is real; `select [Ticket, User]` forces the predicate's type.
- `SortBy` with `.key (f : ρ → κ) [Ord κ]`, `.cmp`, `.andThen`.
- `update old new` is compare-and-swap; a lost race is a typed `.stale`.
- **v1 execution is honest and simple:** `SELECT *` the involved tables,
  build the product, run `where'`/`sortBy` in Lean. This *is* `select.spec`,
  the reference semantics — it exists first, and everything later is measured
  against it. A `.limit`-free full scan is acceptable at this stage; the type
  system is the product, the optimizer is not.

Exit test: the tickets base runs `myQueue`/`openByPriority`-shaped queries
end-to-end against a real sqlite file; CAS conflict test; delete-restricted
test (`delete` on a referenced `User` → typed `.restricted`, data intact).

## M3 — Closed worlds ✅ core (2026-08-23; mirror tables + EnumSet deferred)

- `deriving LeanDb.Closed` for payload-free inductives: stored as TEXT (or
  INT ordinal) with a CHECK constraint, mirrored into a seeded read-only
  lookup table so FKs and plain sqlite tooling still work.
- Enum-drift check at open (constructors vs mirror table).
- Closed types get no delete/insert — removing a variant is a *migration*,
  i.e. a compiler-refereed refactor. This is the "delete H100 → compile
  error" demo from the original discussion, and it becomes writable here.
- `EnumSet` bitmask column for small closed enums.

Exit test: tickets `Status`/`Priority`/`Label` as closed enums; a
`#guard_msgs` negative test showing that inserting into a closed world does
not typecheck.

## M4 — Pushdown as an optimization (the elaborator, minimal fragment)

Only now, with differential tests ready on both sides:
- `select` becomes an elaborator that *reflects* the elaborated `where'` term.
  Fragment v1: conjunctions of comparisons on fields, equality on closed
  enums, `Ref`-equality (recognized as equi-joins), captured free variables →
  bound parameters. Anything else stays a client-side residual — correct
  first, pushed when recognized.
- `#explain` prints pushed vs residual conjuncts.
- `@[db]` function unfolding (match on closed enum → CASE) is the *last*
  step of this milestone, and only for total, non-recursive defs.

Exit test: differential — every query in the tickets base runs both through
`select.spec` and through the emitter, results byte-equal; golden SQL tests
for the pushed fragment.

## M5 — Surface: derived CLI + schema output

- `schema` command emits JSON *derived from the catalog* (walk the env
  extension → `Lean.Json`). Deleting a field changes the output with no other
  edit — the drift test from v0.1 becomes impossible.
- `@[query]` defs → CLI verbs with flags derived from argument types
  (a `Timestamp` arg parses as one or fails typed). Row verbs
  (`insert/get/update/delete` from JSON through smart constructors) per
  plan.md §4.1.
- Exit codes and typed-error JSON per plan.md §4.5.

## Deferred, deliberately (revisit only after M5)

Migrations synthesis (M4's fingerprint check + "recreate + reseed" covers
pre-1.0), SQL import, `serve`/MCP, query log & replay, `--output-lean`,
templates beyond tickets, the benchmark gauntlet. Each is real in plan.md;
none earns machinery before the four verbs are trustworthy.

---

## Appendix — why v0.1 was discarded (review summary)

1. **Wrong program.** Built: Pareto/knee ranking over hardcoded in-memory
   lists. Specified: four typed SQL verbs over SQLite. No persistence, no
   verbs, no deriving, no `Ref`/`Id`, no leansqlite dependency at all.
2. **Engine/instance fusion.** `LeanDb.lean` and `LeanDb/Api.lean` import the
   GPU/hotel/restaurant examples; the CLI hardcodes per-domain commands; the
   `schema` output was a hand-written string literal duplicating (and free to
   drift from) the actual structures; seed rows compiled into the engine.
3. **Stringly-typed core.** One shared `TextValue` with a runtime field-name
   string instead of per-type smart constructors; `Constraint.name`/
   `Objective.name : String` as identity; all sort keys coerced to `Nat`;
   hand-rolled JSON string concatenation; `Cuisine` as free text matched
   case-insensitively against a raw `Option String` — in the engine whose
   thesis is "no anonymous primitives".
