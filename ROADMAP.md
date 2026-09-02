# LeanDB roadmap

**2026-09-01.** From v0.2.0. Companion to `plan-v2.md` (what was built and
why) and `proposals/` (what is designed). This file is the order of work
and the acceptance test for each step; it is updated as steps land.

The discipline is unchanged from plan-v2: *correctness machinery first,
optimization machinery only when a test demands it.* Concretely — every
engine change below is preceded by a base that already exists and already
has the query that needs it.

| Step | Milestone | Status |
|---|---|---|
| R0 | Land the verified 0.2.x fixes and the design documents | done 2026-09-01 |
| R1 | `examples/eats` — restaurant base, plus the captured-parameter case split | done 2026-09-01 |
| R2 | `examples/kernels` — kernel base, evidence for nested values | done 2026-09-01 |
| R3 | LEP-0002 — typed predicate IR | done 2026-09-01 |
| R4 | LEP-0003 nested values · LEP-0004 child-table quantifiers | next — to be written from R1/R2 evidence |
| R5 | Query universe as a type; log as data; LEP-0001 row symbols | after R3 |

---

## R0 — Land what is verified

Four defects fixed and green under `scripts/release_check.sh` (pushdown
through newtype projections; BLOB as a typed `decode`; importer
not-carried precision; hardened constraint classification), plus
LEP-0002 and the stress-domain study.

**Done when:** committed on `main`, release check passing.

## R1 — Restaurant base (`examples/eats`)

The base from study §2, built against the engine *as it is*. It exercises
the largest share of what exists — closed worlds with total functions,
ordering through validated newtypes, `||`/`if` on columns for the
midnight wrap, three-table joins, `Option (Ref _)` — and exposes exactly
one missing thing in its central query.

Included three small engine changes the base needed, each with goldens:
**case-splitting on a captured closed-enum parameter** (study §3.4 — a
`@[db]` function matching on its parameter first no longer goes
residual); **folding value/value guards at plan build** (`cmpVVS`: the
guards a parameter split leaves are decidable once the parameter is
known, so the tree collapses to the surviving column conditions — both
match orders of `Diet.allows` yield the same SQL); and **`if`/`cond` on
columns** as `(c ∧ t) ∨ (¬c ∧ e)`, which the study assumed and the tactic
lacked. Also `rows --eq` now splits at the first `=` only, found by R2.

**Done when:**
- `eats query avgPrice chai-latte sanFrancisco`, `openFor tiramisu fri 21:30`,
  `suitable ramen vegetarian sanFrancisco`, `suitable ramen noPorkBeef sanFrancisco`
  answer correctly over seed data, with a checked-in `CLI_TRANSCRIPT.md`.
- `eats log` shows `residual conjuncts: 0` for `openFor` and for the
  ingredient-side fetch of `suitable`, in either match order of `Diet.allows`.
- `suitable` is two fetches and says so in its docstring — it is LEP-0004's
  golden.
- No diet is stored anywhere; `Dish.ingredientsComplete` gates every
  dietary answer.
- Engine goldens: a `@[db]` function matching on a captured enum parameter
  first pushes with residual 0; end-to-end differential equal to
  `selectUnplanned`.
- Added to `release_check.sh`.

## R2 — Kernel base (`examples/kernels`)

The base from study §1. Its job is to make the nested-values decision
concrete: `KernelSig` stored as a JSON-codec'd column (opaque to SQL) with
denormalized search columns, `Prog ins outs` and composition entirely in
Lean, `Bench.sku` from gpumarket's `Gpu` (first cross-base type reuse).

**Done when:**
- `Prog.seq` of a kernel whose output dtype does not match the next
  kernel's input is a `#check_failure` — typed composition, demonstrated.
- `synthesize [gemm, rmsNorm]` returns a program over seed kernels;
  `fastest`, `composable`, `regressions` (self-join), `roofline` answer
  over seed benches. `CLI_TRANSCRIPT.md` checked in.
- `KernelSig` round-trips through its codec; a malformed signature is
  refused by `KernelSig.make` at insert.
- A written account (in the base's `README.md`) of what the opaque column
  could not do — which filters stayed residual, which invariants
  `migrate` cannot see — so LEP-0003 is written from evidence.
- Added to `release_check.sh`.

## R3 — LEP-0002, typed predicate IR

Landed in three commits: field symbols (`Ticket.Field`, `FieldOf`,
`Entity.columns` computed), the IR (`Col` indexed by its storage codec,
`Pred` with `opaque` leaves, `denote`, `approx_sound` proved), and the
switch (tactic emits `Pred`; `PushPred`/`SelectPlan`/`Plan.lean` deleted;
`rows --eq` decodes through the column's codec). Acceptance met: the
LEP's `#check`/`#check_failure` block, coherence `denote (reify p) r = p r`
over the goldens, and every base's logged plan byte-identical — 59 plans
replayed from the eight transcripts, zero differences. `exists` stays
reserved for R4.

## R4 — LEP-0003 and LEP-0004

Both written 2026-09-01 from R1/R2 evidence; implementation order below.

- **LEP-0004, child-table quantifiers** (first — smaller, and D of
  LEP-0003 depends on it). `exists`/`forall` in `Pred` with a `Snapshot`
  denotation, alias-function rendering, `selectP` taking a plan as data,
  `pred%`; `suitable` becomes one `select` rendering `NOT EXISTS`, kept
  differential against its two-fetch form.
- **LEP-0003, nested values**, in stages: A `EnumSet` (+ `Pred.bit`);
  B JSON derive honouring defaults + type shape in the fingerprint and the
  migration diff (additive-with-defaults restamps, anything else refused
  by name) + `@[derived]` columns recomputed on write and checked on read;
  C inline flatten; D child tables (after LEP-0004). kernels is the
  acceptance base for A–C.

## R4b — LEP-0005, configurable entities (after LEP-0003 C)

Modifiers and variants as a stored function over a finite configuration
type: rule (truth, JSON with shape), tabulation (derived child rows),
bounds (derived columns). Stage 1 is built by hand in eats after LEP-0004
lands there, to measure the hand-maintenance cost; engine pieces
(`deriving Config`, `Pattern`/`PriceRule`, derived child rows) follow
LEP-0003 C and D.

## R5 — The universe

- Log stores the plan as data (needs R3); replay before `migrate apply`.
- `Query : Type → Type` per study §5 in both bases; CLI derived from it.
- LEP-0001 row symbols; `KnownDish` replaces slugs in `eats`.

## Deferred, by name

Aggregates as a verb; pushed `SortBy`/`LIMIT`; cross-instance queries
(`ATTACH`); proof fields in `deriving Entity`; `Float` ordering (correctly
refused — NaN); MCP/HTTP serve; migration source synthesis.
