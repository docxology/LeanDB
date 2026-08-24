# LeanDB

**Strongly typed SQL.** Four verbs — `insert`, `update`, `delete`, `select` —
where the types make wrong queries unwritable, backed by SQLite
([leansqlite](https://github.com/leanprover/leansqlite), bundled engine).

```lean
structure User where
  handle : Handle                -- validated newtype: its own smart constructor
  deriving Repr, LeanDb.Entity   -- schema derived from the type; no other source

structure Ticket where
  title    : Title
  status   : Status := .backlog  -- closed world: deriving LeanDb.ClosedEnum
  reporter : Ref User            -- typed FK; Ref User ≠ Ref Ticket
  deriving Repr, LeanDb.Entity

-- Rows [Ticket, User] = Stored Ticket × Stored User: the predicate's type
-- is forced by the table list; a wrong-table predicate does not typecheck.
select [Ticket, User]
  (fun (t, u) => t.val.reporter == u.ref && t.val.status != .done)
  (.key fun (t, _) => t.val.priority)
```

What the types refuse, the file also refuses, and both refuse loudly:

- **No anonymous primitives.** Scalars are named newtypes with their own
  validators (`ColCodec.via` + smart constructor); a value that fails its
  validation never decodes into the program — a typed `.decode` error does.
- **Closed worlds.** Vocabulary enums (`deriving LeanDb.ClosedEnum`) are not
  entities — inserting into or deleting from one *does not typecheck*.
  At rest they're guarded by a `CHECK` constraint; at open, a drift scan
  rejects stored values the code no longer knows (`.enum_drift`).
- **CAS updates.** `update old new` pins every column of `old` — a lost
  race is a typed `.stale`, never a silent clobber.
- **Loud destruction.** References are `ON DELETE RESTRICT`; deleting a
  referenced row is `.restricted`.
- **No schema drift.** The schema fingerprint is stored in the instance and
  checked at open (`.schema_mismatch`); DDL, specs, and (later) CLI output
  are all derived from the entity declarations.

## Build and test

```bash
lake build
lake build leandb_tests && .lake/build/bin/leandb_tests
```

The example base (a *separate* Lake package depending on the engine — the
engine imports no domain, ever):

```bash
cd examples/tickets
lake build && .lake/build/bin/tickets_tests
```

## Code map

```text
LeanDb/Core.lean     Id/Ref/Stored, Col, ColCodec, ClosedEnum, ColumnSpec, DbError
LeanDb/Entity.lean   Entity class, TableSpec, DDL generation, fingerprint
LeanDb/Derive.lean   deriving LeanDb.Entity / LeanDb.ClosedEnum (metaprogram)
LeanDb/Select.lean   Rows ts, SortBy, RowsOf, selectSpec (reference semantics)
LeanDb/Plan.lean     SelectPlan IR (pushed conjuncts, residual count)
LeanDb/PlanElab.lean leandb_plan reification tactic, @[db], leandb.explain
LeanDb/Db.lean       Conn/DbM, the four verbs, open (fingerprint + drift checks)
LeanDb/Json.lean     schema/row/error JSON derived from Entity; merge decode
LeanDb/Migrate.lean  schema diff → steps; additive auto-apply, rebuilds, refusals
LeanDb/Cli.lean      generic CLI driver: row verbs, log, migrate, serve (JSONL)
LeanDb/CliQuery.lean query% — CLI queries derived from def signatures
Tests.lean           engine tests: codecs, deriving, e2e, closed worlds, negatives
examples/tickets/    the first base: scalars, enums, entities, queries, seed, tests
```

`select`'s semantics are `selectSpec` — the four-line reference
(product → filter → sort → id tiebreak). Under the same signature, a
tactic-reified `SelectPlan` (M4) pushes the recognized fragment of each
predicate — column/value comparisons, closed-enum equality, `Option` null
tests, `@[db]`-tagged helpers unfolded — into per-table SQL `WHERE`
clauses with captured variables as bound parameters; everything else stays
residual and the lambda is always applied, so pushdown can narrow fetches
but never change results (differential-tested). Set
`set_option leandb.explain true` to see call-site plans.

## Status

Tracked in [`plan-v2.md`](plan-v2.md). Done: M1 (typed core + deriving),
M2 (the four verbs, e2e), M3 (closed worlds), M4 full (reified `PushPred`
plans: equi-join pushdown via a joined executor, `||`/`!`, and match→CASE
by closed-world case-splitting — `Chip.vendor c == .amd` compiles to
`chip IS 'mi300x' OR chip IS 'mi325x'`), M5 (derived CLI + `query%`
type-derived query args), M6 (migrations v1 — additive auto-apply, table
rebuilds, destructive gated; `_leandb_log` query log storing each select's
reified plan; `serve` JSON-lines mode on one connection).

Four example bases, each a separate package with tests and a CLI
transcript: `examples/tickets`, `examples/crm`, `examples/shop`,
`examples/gpus`. Try one:

```bash
cd examples/tickets && lake build tickets
.lake/build/bin/tickets query seed
.lake/build/bin/tickets query slaBreached 1700000000
.lake/build/bin/tickets log 3        # see the reified plans it pushed
.lake/build/bin/tickets migrate status
```

SQL import is in: `lake build leandb && .lake/build/bin/leandb
import-sqlite legacy.db --name legacy --out ./legacy` generates a full
typed base from an existing SQLite file — every TEXT column becomes a
named identity newtype ("import loose, tighten forever"), FKs become
`Ref`s, and everything not carried (views, triggers, composite-pk tables,
BLOBs) is listed by name in `IMPORT.md`/`import-report.json`, never
dropped silently. See `examples/import-fixture` + generated
`examples/legacy`.

Still deferred: MCP/HTTP serve (JSONL `serve` exists), log replay,
migration source-file synthesis (v1 diffs live schema as data instead).

`plan.md` is the standing interface spec; `claude-discussion.md` holds the
original design discussion; v0.1 (discarded, reviewed in plan-v2 appendix)
is preserved in git history.
