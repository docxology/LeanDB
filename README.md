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
LeanDb/Db.lean       Conn/DbM, the four verbs, open (fingerprint + drift checks)
Tests.lean           engine tests: codecs, deriving, e2e, closed worlds, negatives
examples/tickets/    the first base: scalars, enums, entities, queries, seed, tests
```

`select` v1 executes `selectSpec` — the four-line reference semantics
(product → filter → sort → id tiebreak) — directly. SQL pushdown is a
planned optimization underneath the same signature and must stay
observationally equal to the spec (plan-v2 M4).

## Status

Tracked in [`plan-v2.md`](plan-v2.md). Done: M1 (typed core + deriving),
M2 (the four verbs, e2e), M3 core (closed worlds: codec, CHECK, drift scan;
mirror tables deferred). Next: M4 (reifying elaborator: pushdown of the
conjunctive fragment, `#explain`), M5 (derived CLI/schema surface).
Deliberately deferred: migrations synthesis, SQL import, serve/MCP, query
log — see plan-v2 "Deferred".

`plan.md` is the standing interface spec; `claude-discussion.md` holds the
original design discussion; v0.1 (discarded, reviewed in plan-v2 appendix)
is preserved in git history.
