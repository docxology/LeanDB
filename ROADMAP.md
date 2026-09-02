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
| R4 | LEP-0003 nested values · LEP-0004 child-table quantifiers | done 2026-09-01 |
| R5 | Query universe as a type; log as data; LEP-0001 row symbols | after R3 |
| R6 | Bases as packages, versioned typed migrations, hosting, importable bases (S0–S8) | S0 done 2026-09-02 |

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

- **LEP-0004, child-table quantifiers** — landed. `exists`/`forall` in
  `Pred` (now an inductive family over `ts`), `Snapshot` denotation,
  `approx_sound` extended, alias-function rendering (`describe` byte-
  identical), `selectP` taking a plan as data, `pred%`, `Pred.all`/`any`.
  eats' `suitable` is one `selectP` rendering nested `NOT EXISTS`, with a
  780-combination differential against its two-fetch form. Baseline:
  identical everywhere but the two `suitable` lines.
- **LEP-0003, nested values.** B1–B3 landed: `deriving LeanDb.DbJson`
  (defaults honoured, Lean-compatible encoding), `JsonShape` carried on
  the codec into `ColumnSpec`, the fingerprint and `schema_json`;
  `planMigration` restamps additive-with-defaults shape changes and
  refuses the rest by name; derived columns via `:= derived expr`
  (attributes are not allowed on fields) recomputed on write and checked
  on read. kernels: `KernelSig`/`LaunchConfig` through `ColCodec.json`,
  search columns derived, raw-SQL desync refused on read; every
  shape-less base's fingerprint unchanged. **A landed:** `EnumSet α` as an
  INTEGER bitmask with a mask CHECK, drift scan, names-array JSON,
  `Pred.bit` (membership pushes as `(col & ?) != 0`, `a ∈ s` recognized),
  migrations append/truncate only (reorder/middle-removal refused — bits
  would change meaning), fingerprint covers the variant names; kernels'
  `fuses` uses it. **C landed:** `deriving LeanDb.Inline`; a parent flattens an inline
  field into `f_sub` columns with flat symbols, `group` for nested row
  JSON (both spellings accepted, both-at-once refused), split defaults,
  `colOf?` resolves `k.val.launch.smemBytes` to the flattened symbol;
  kernels' `LaunchConfig` and `NumericProps` inline. eats' `KindSet` is
  now `EnumSet`. **D landed:** `List R` of an `Inline` record is a
  generated child entity (`Parent.Ins`, table `parent_ins`, cascading
  `parent`, `position`), attached on every read, written in the verb's
  transaction, nested in row JSON; `.any`/`.all` over the list reify to
  LEP-0004 quantifiers; derived-from-child columns checked at attach.
  kernels' `ins`/`outs`; "every input has rank ≥ 3" and "any input
  column-major" push, "exactly two inputs" stays residual (aggregate).
  Baseline: identical everywhere but kernels.

## R4b — LEP-0005, configurable entities

Modifiers and variants as a stored function over a finite configuration
type: rule (truth), tabulation (child rows), bounds (columns).

**Stage 1 landed 2026-09-01, by hand in eats:** `EspressoConfig` (180
configurations, 125 valid), typed `EspressoOption`/`Pattern`, `PriceRule`
with `overridesDisjoint`/`nonNegative` proved by `decide +kernel` for
every seed rule and refused by the codec otherwise, `EspressoOffer` with
hand-maintained bounds, tabulated `OfferPrice`, `OrderLine`; queries
`priceOf`, `cheapestConfigured` (residual 0), `cheapestMatching`
(runtime pattern: residual 1), `offersWith`, `configurationsFor`,
`quote`, `placeOrder`; `eats_offers_tests`; evidence in
`examples/eats/README.md`. Findings: an `Option α` filter parameter was
fully residual — **fixed the same day**: the tactic now splits a captured
`Option α` for closed `α`, and `cheapestOptional` pushes with residual 0
for every argument combination; hand-maintained bounds and tabulation
desynchronize under `update` exactly as kernels' search columns did
before LEP-0003 B3.

Engine stages (`deriving Config`, `Pattern`/`PriceRule` as library types,
derived child rows, the rule-coverage migration check) follow LEP-0003 C
and D.

## R5 — The universe

- Log stores the plan as data (needs R3); replay before `migrate apply`.
- `Query : Type → Type` per study §5 in both bases; CLI derived from it.
- LEP-0001 row symbols; `KnownDish` replaces slugs in `eats`.

## R6 — Bases as packages, typed migrations, hosting (2026-09-02 plan)

Three nouns (plan.md §10): package = truth, instance = state, server =
process. Stages, each keeping the release check green and every base's
logged plans byte-identical:

- **S0 — done 2026-09-02.** `LeanDb.Base` in the base library
  (`<Base>/Base.lean`), `Main.lean` one line; schema derived from tables
  (`Base.specs`, golden-checked against the hand-written list in every
  base's tests); `Instance` resolved at run time (`--db`, `$LEANDB_DB`,
  default); `QueryEntry` with params; derived `seed` verb; importer emits
  the same shape.
- **S1** — `Base.handle` (one transport-agnostic handler), `openDbRaw` +
  `Conn.verify`, `migrate`/`version`/`backup` on a live connection (so
  `serve` can migrate a drifted instance).
- **S2** — backups (`VACUUM INTO`) before every apply, journal
  `from_version`/`to_version`/`backup`, `migrate rollback`, `backup` /
  `restore` / `migrate history`.
- **S3** — `migrate freeze` writes `<Base>/Migrations/V<n>.lean` (schema
  snapshot as data + generated raw structures), typed chain
  (`Migration`, `Step.transformT`), build-time `leandb_check_head`,
  lineage check at open.
- **S4** — static query footprints from the plan tactic; `migrate status`
  reports rows, destructive, transform required/provided, and which
  queries a change touches; log stores the plan as data; `--replay`
  (the R5 log item lands here).
- **S5** — `<base> serve --http <port>` on `Std.Http.Server`, fingerprint
  handshake; **S6** — `leandb host` multi-base supervisor and
  `serve --mcp`; **S7** — `Base.withInstance`, `examples/dashboard`
  importing two bases, `client%` typed remote stubs; **S8** —
  `leandb new` scaffolder with a git require, tag v0.3.0.

## Deferred, by name

Aggregates as a verb; pushed `SortBy`/`LIMIT`; cross-instance queries
(`ATTACH`); proof fields in `deriving Entity`; `Float` ordering (correctly
refused — NaN); MCP/HTTP serve; migration source synthesis.
