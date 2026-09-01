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
| R0 | Land the verified 0.2.x fixes and the design documents | in progress |
| R1 | `examples/eats` — restaurant base, plus the captured-parameter case split | in progress |
| R2 | `examples/kernels` — kernel base, evidence for nested values | in progress |
| R3 | LEP-0002 — typed predicate IR | designed |
| R4 | LEP-0003 nested values · LEP-0004 child-table quantifiers | to be written from R1/R2 evidence |
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

Includes one small engine change, done alongside because the base's
`Diet.allows` needs it: **case-splitting on a captured closed-enum
parameter** (study §3.4). Today the tactic splits only on enum *columns*;
a `@[db]` function that matches on its parameter first goes residual.
The extension splits on the parameter the same way, emitting `cmpVV`.

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

As proposed, with one amendment before implementation: reserve the
`exists` constructor (study §3.3) so the IR's shape is not closed before
R4. Acceptance criteria are in the LEP; R1 and R2 are additional goldens —
their `log` output must be byte-identical before and after.

## R4 — LEP-0003 and LEP-0004

- **LEP-0003, nested values.** Which of `@[dbJson]` / inline flatten /
  child table to derive, decided from R2's account. `EnumSet` (plan-v2 M3)
  is the cheapest piece and may land first.
- **LEP-0004, child-table quantifiers.** `exists`/`forall` in `Pred`,
  rendering as `EXISTS`/`NOT EXISTS`; `suitable` becomes one `select`.
  R1 is the acceptance test.

## R5 — The universe

- Log stores the plan as data (needs R3); replay before `migrate apply`.
- `Query : Type → Type` per study §5 in both bases; CLI derived from it.
- LEP-0001 row symbols; `KnownDish` replaces slugs in `eats`.

## Deferred, by name

Aggregates as a verb; pushed `SortBy`/`LIMIT`; cross-instance queries
(`ATTACH`); proof fields in `deriving Entity`; `Float` ordering (correctly
refused — NaN); MCP/HTTP serve; migration source synthesis.
