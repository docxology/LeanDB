# LeanDB — Interface & DX Specification

**v0.1 — 2026-08-23. Companion to the Architecture doc (v0.14): that document says what LeanDB *is*; this one says what it feels like to touch.** Where semantics are already settled there (§ references throughout), this doc doesn't re-argue them — it binds them to a surface.

---

## 1. Aim

**Design principles**

1. **Forward compatibility with SQL.** You can point LeanDB at an existing SQL database, import it, and start using it directly (§5). The reverse — LeanDB bases as faithful, tool-agnostic SQL interchange — is not promised.
2. **The general shape of SQL is preserved.** The operations are `select` (from / where / sortBy), `insert`, `update`, `delete` — dependently typed, per Architecture §8.
3. **Designed by humans, for agents, by agents.** Humans design vocabularies; agents are the primary operators. Every command emits machine-parseable output, every error is a typed value, every query is logged and replayable.
4. **Strongly typed data and queries; full dependent types supported and encouraged.** No anonymous primitives (Arch §4.2), validation as inhabitation (§4.3), `Rows ts` and friends (§8.2).
5. **Typed, easy, safe migrations** (Arch §6): hole-driven authoring, both directions loud, one transaction.

**Non-concerns**

- Ergonomics of *human* interactive querying (no REPL polish, no pretty TUI — humans edit Lean files and read JSON like everyone else here).
- Backward compatibility: pre-1.0 breaks freely; the sqlite file is an implementation detail, not an interchange format.
- Full SQL coverage on import — unsupported features are *reported*, never silently dropped (§5.3).
- Full coverage of Lean's type system — what LeanDB can't store is a compile-time error with a named reason, not a runtime surprise.

---

## 2. The shape of a LeanDB database

**A LeanDB database is a Lean codebase with an associated SQLite file.** One directory holds both by default:

```
tickets/
  leandb.toml                    # manifest: name, backend, logging, strictness
  lakefile.toml                  # an ordinary Lake package depending on `leandb`
  lean-toolchain
  Tickets.lean                   # root module: exports `schema` and `chain`
  Tickets/
    Scalars.lean                 # named newtypes (no anonymous primitives)
    Enums.lean                   # closed world
    Entities.lean                # open world
    Functions.lean               # @[db] domain logic
    Queries/Core.lean            # the query library — lives inside the base
    Migrations/
      Snapshots/V1.lean          # history as data (Arch §6.1)
      M0001_init.lean
      Chain.lean                 # def chain : Migration v0 head
  seeds/Seed.lean                # demo rows; regenerates the demo state
  data/tickets.sqlite            # the instance (gitignored by default)
```

The fusion is the ergonomic default, not a change of ontology: the three nouns from Architecture §10.1 (package = truth, instance = state, server = process) still exist. `leandb.toml` binds the base to its default instance; `--data <path>` rebinds any command to another instance (dev/prod) of the same base; `leandb <db> serve` remains the optional served mode. **The code is the description of the database at rest** — editable like any codebase, because it is one.

**Versioning is mandatory and stored in SQL.** `base_version` = the index of the applied migration head. The instance carries it (with the schema fingerprint) in `_leandb_meta`; the code carries it as the snapshot head; `head_is_current` (Arch §6.1) keeps them honest at build time, and every command checks them against each other at open time.

Reserved tables, underscore-prefixed in every instance:

| Table | Contents |
|---|---|
| `_leandb_meta` | `base_name`, `base_version`, `schema_fingerprint`, `created_at`, `leandb_version` |
| `_leandb_migrations` | journal of applied steps: index, name, fingerprint, applied_at, ok |
| `_leandb_log` | the query log (§4.4) |

---

## 3. Lifecycle commands

### 3.1 Create

```bash
leandb create database tickets --path ./tickets [--template tickets]
```

Creates the directory above, initializes the Lake package, writes snapshot `V1` and migration `M0001_init`, creates `data/tickets.sqlite`, applies the chain, writes `_leandb_meta`, runs `seeds/Seed.lean`. The point of the template and seeds: **the user or agent sees LeanDB in action immediately** — `leandb tickets query Tickets/Queries/Core.lean --def openByPriority` returns real rows thirty seconds after create.

Templates (each a source tree in the LeanDB repo, §7): `tickets` (default — the multi-user tracker below), `catalog` (the commerce shape, Arch Appendix B), `crm` (people/interactions/asks), `blank` (scalars + meta only).

### 3.2 Schema commands are code generators

```bash
leandb tickets add table Sprint --fields "name:Title, start:Date, finish:Date"
leandb tickets add column Ticket estimate:'Option Estimate'
leandb tickets delete table Sprint --i-know-this-deletes-data
leandb tickets rename column Ticket finish dueDate
```

The invariant that keeps the whole system coherent: **the CLI never mutates schema behind the code's back.** Every schema command (1) edits or generates Lean source in the base, (2) runs `makemigration` (typed holes and all, Arch §6.5), (3) snapshots, (4) applies, (5) bumps `base_version`. If a step needs judgment — a backfill, a `DataLoss` ack — the command *stops at the generated file with holes* and prints their locations and types; it does not guess. `delete table` demands the ack flag because destruction is loud by design (Arch §6.2). Field specs resolve against the base's named types; an unknown name generates a newtype stub (identity smart constructor — an address before content, Arch §4.2) rather than admitting a bare primitive.

Humans can skip all of this and just edit the Lean files; `leandb tickets migrate make && leandb tickets migrate apply` is the same pipeline entered one step later.

### 3.3 Migrate, version, serve

```bash
leandb tickets migrate status | make | apply [--dry-run] [--backup]
leandb tickets version          # prints code head + instance applied version + fingerprints
leandb tickets serve --port 7411   # optional served mode; semantics per Arch §10
```

`--dry-run` rehearses on a file copy and reports rows touched / rejects / duration (Arch §6.4). `version` makes drift visible in one line; agents call it before anything else.

---

## 4. Data and queries

### 4.1 Row verbs

```bash
leandb tickets insert Ticket '{"title":"Importer chokes on views","priority":"p1","reporter":1}'
leandb tickets get Ticket 42
leandb tickets update Ticket 42 '{"status":"inProgress"}'        # CAS against current row
leandb tickets delete Ticket 42
leandb tickets rows Ticket --eq status=backlog --eq priority=p0 --limit 20
```

JSON decodes **through the smart constructors** — an agent can be wrong, never ill-typed (Arch §2.4); errors come back as the typed `DbError` serialized (§4.5). `rows` supports only conjunctive equality filters and limit — deliberately. Anything more expressive is a query file; the CLI does not grow a second, stringly query language.

### 4.2 Query files

Queries are Lean, and the query library lives **inside the base** (`Tickets/Queries/`), so it's versioned, compiled, and migrated with the vocabulary it speaks:

```bash
leandb tickets query Tickets/Queries/Core.lean --def slaRisks --now 2026-08-23T12:00:00Z \
    --output-json out.json
leandb tickets query Tickets/Queries/Core.lean --def slaRisks --now ... --output-lean out.lean
```

Contract: the file's `@[query]`-tagged defs become invocable; a def's arguments become CLI flags (types drive parsing — a `Timestamp` flag parses as one or fails with a typed error); a single tagged def needs no `--def`. Files inside the base compile incrementally with it; a file *outside* the base is linked into a scratch target (works, slower first time, and the tool says so).

**`--output-json`** goes through the derived encoders. **`--output-lean`** emits the results as *typed literals* importing the base:

```lean
-- generated by leandb · base tickets v7 · query slaRisks#a91f · 2026-08-23T12:00:14Z
import Tickets
def result : Array (Ticket × User) := #[⟨…⟩, …]
```

Such files aren't standalone-executable — they need a project that imports the base — and that's fine, as specified: their value is being **data as code**: importable as fixtures, diffable in git, replayable as seeds, checkable by the compiler against the vocabulary version stamped in the header.

### 4.3 Determinism for agents

Same instance state + same query + same params ⇒ byte-identical output: `select` results carry an implicit final tiebreak on primary key, JSON encoding is canonical (sorted keys), and the provenance header is the only timestamp-bearing line (suppressible with `--no-provenance`). Agents can diff runs; that's the point.

### 4.4 The query log

**On by default.** Every verb appends to `_leandb_log`: timestamp, `base_version`, verb, query name, the **reified `Pred`/plan as data** (not SQL text — Arch §8.3 makes queries values, so the log stores the value), parameters (`--no-log-params` or `@[sensitive]` fields redact), and output metadata: row count, bytes, duration, pushed-vs-residual conjunct counts, ok/typed-error.

Because the log holds typed queries, it is **replayable**:

```bash
leandb tickets log replay --since v6 --against --dry-run   # rerun history against a candidate migration
leandb tickets log show --slow 500ms --residual-heavy      # find what isn't pushing
```

The log is simultaneously the audit trail, the agent's episodic memory of what it asked, the regression suite for migrations (replay before `apply`), and the performance worklist (`residual-heavy` is `#explain` over history).

### 4.5 Machine conventions

Exit 0 = ok; 2 = typed `DbError` (JSON on stderr, `code` field matching the constructor — `restricted`, `stale`, `enumDrift`, …); 3 = Lean compile error (diagnostics as JSON with file/line/expected-type — a hole's type *is* the message); 4 = version/fingerprint mismatch. `--json` is accepted everywhere and is the default for non-TTY stdout. An MCP server over this same surface is the thin later layer Architecture §10.2 already reserves.

---

## 5. Importing an existing SQL database

```bash
leandb import sqlite ./legacy.db --name legacy [--copy] [--infer-enums] [--strict]
```

### 5.1 What import generates

Introspection (`sqlite_master`, `PRAGMA table_info/foreign_key_list/index_list`) produces a full base: one entity per table; `Option` for nullable; `Ref` for single-column FKs onto row keys; indexes and uniques carried onto `@[index]`/`@[uniqueIndex]`; recognized `CHECK`s lifted into smart-constructor validations, unrecognized ones preserved verbatim and flagged.

**The string ban survives import** — this is the part that makes "directly start using it" honest rather than a loophole. Every TEXT column becomes a *named newtype with an identity smart constructor*: `legacy.customers.name` imports as `structure CustomerName where raw : String`, validating nothing yet. An address before content (Arch §4.2): the imported base is loose but never anonymous, and every future validation is a `tighten` migration away. **Import loose; tighten forever.**

`--infer-enums` samples TEXT columns with few distinct values and *proposes* closed enums in the import report — proposes, never applies: closing a world is a judgment call, so it lands as a generated migration file with the remap hole ready, waiting for a human or an explicitly-authorized agent.

### 5.2 Adoption

The sqlite file is adopted in place (or copied with `--copy`); the introspected schema becomes snapshot `V1`; `_leandb_meta` is written; `Queries/Imported.lean` gets one example query per table so the first `leandb legacy query …` works immediately.

### 5.3 The import report

Partial SQL support is a stated non-concern — but *silent* partiality is not. The report enumerates: tables/columns imported cleanly; features imported opaquely (unparsed CHECKs); features **not carried** (views, triggers, generated columns, virtual tables — listed by name with the reason); type mappings chosen. The report is JSON and also lands as `IMPORT.md` in the base. What LeanDB doesn't support, you can always *see*.

---

## 6. The `tickets` template — sample types

Chosen to show the type-system range while being immediately useful: a multi-user tracker whose story is on-brand for principle 3 — **agents file and triage tickets** (note the `agentFiled` label and that seeds include an agent user).

```lean
/- Tickets/Scalars.lean — no anonymous primitives (Arch §4.2) -/
structure Title  where raw : String   -- smart ctor: trimmed, nonempty, ≤ 200
@[freeText]
structure Body   where raw : String   -- prose: unbranchable, fuzzy-leaf only
structure Handle where raw : String   -- lowercase, [a-z0-9-], 3–30
structure Email  where raw : String   -- format-validated; CHECK mirrored
def Estimate := { n : UInt16 // n ≤ 240 }   -- hours; validation as inhabitation

/- Tickets/Enums.lean — the closed world -/
inductive Status   where | backlog | inProgress | blocked | inReview | done
inductive Priority where | p0 | p1 | p2 | p3
inductive Label    where | bug | feature | docs | infra | design | agentFiled
  -- all deriving LeanDb.Closed, DecidableEq, Repr

/- Tickets/Entities.lean — the open world -/
structure User where
  handle  : Handle
  email   : Email
  display : Title
  deriving LeanDb.Entity          -- @[uniqueIndex User (handle)]

structure Sprint where
  name         : Title
  start finish : Date
  ord          : start < finish   -- cross-field invariant as a field (Arch §4.3)
  deriving LeanDb.Entity

structure Ticket where
  title        : Title
  body         : Body
  status       : Status   := .backlog
  priority     : Priority := .p2
  reporter     : Ref User
  assignee     : Option (Ref User)
  labels       : EnumSet Label := {}      -- bitmask at rest
  sprint       : Option (Ref Sprint)
  estimate     : Option Estimate
  createdAt    : Timestamp
  lastActivity : Timestamp
  deriving LeanDb.Entity

structure Comment where
  ticket : Ref Ticket
  author : Ref User
  body   : Body
  at     : Timestamp
  deriving LeanDb.Entity

inductive TicketEvent where               -- stored sum: tag + CHECKed groups (Arch §4)
  | statusChanged (from to : Status)
  | assigned      (to : Ref User)
  | labeled       (l : Label)
  deriving LeanDb.Row

structure Activity where
  ticket : Ref Ticket
  actor  : Ref User
  event  : TicketEvent
  at     : Timestamp
  deriving LeanDb.Entity

/- Tickets/Functions.lean — logic that travels (Arch §10.6) -/
@[db] def Priority.slaHours : Priority → UInt32
  | .p0 => 4 | .p1 => 24 | .p2 => 72 | .p3 => 240      -- match → CASE

@[db] def Ticket.isOpen (t : Ticket) : Bool := t.status != .done
@[db] def slaBreached (p : Priority) (ageHours : UInt32) : Bool := ageHours > p.slaHours
@[db] def isStale (now last : Timestamp) : Bool := now - last > days 14   -- monus rule applies
```

Coverage, deliberately: validated newtypes and declared prose; a subtype with an arithmetic bound; a proof field (`Sprint.ord`); closed enums, one carrying an SLA table as a total function; an `EnumSet` bitmask; `Option` and `Ref` joins; defaults; a unique index; a stored sum with payloads; and `@[db]` functions exercising the CASE and monus compilation rules. One template, every §4 row of the Architecture doc touched.

```lean
/- Tickets/Queries/Core.lean — the query library, in the base -/
@[query] def openByPriority : DbM (Array Ticket) :=
  select [Ticket] (where' := (·.isOpen))
    (sortBy := .andThen (.key (·.priority)) (.key (·.createdAt)))

@[query] def myQueue (h : Handle) : DbM (Array Ticket) :=
  select [Ticket, User]
    (where' := fun (t, u) => t.assignee == some u.id && u.handle == h && t.isOpen)
    (sortBy := .key (fun (t, _) => t.priority)) |>.map (·.map Prod.fst)

@[query] def slaRisks (now : Timestamp) : DbM (Array (Ticket × User)) :=
  select [Ticket, User]
    (where' := fun (t, u) =>
      t.reporter == u.id && t.isOpen
      && slaBreached t.priority (hoursBetween t.createdAt now))
    (sortBy := .key (fun (t, _) => t.priority))

@[query] def staleUnassigned (now : Timestamp) : DbM (Array Ticket) :=
  select [Ticket]
    (where' := fun t => t.assignee == none && t.isOpen && isStale now t.lastActivity)
```

`seeds/Seed.lean` inserts three users (one an agent), two sprints, a dozen tickets across statuses and priorities, comments, and activity rows — enough that every query above returns non-empty on first run.

---

## 7. How the LeanDB code itself is organized

The tool's own repo, mapping onto the Architecture doc's layers (§3):

```
leandb/
  LeanDb/Core/       -- ColTy universe, Row interp, ColCodec (§4.4), Id/Ref, DbError
  LeanDb/Derive/     -- Entity/Closed/Row deriving, catalog env-extension, attributes
  LeanDb/Schema/     -- TableSpec, fingerprint, DDL gen, diff
  LeanDb/Migrate/    -- Step/Migration, makemigration synthesis, apply, dry-run, replay hooks
  LeanDb/Query/      -- Pred/SortBy, reifying elaborator, planner, SQLite emitter,
                     --   residual execution, select.spec (the reference interpreter)
  LeanDb/Runtime/    -- Conn (.local/.remote), DbM, transactions, stmt cache, log writer
  LeanDb/Sqlite/     -- adapter over leansqlite LowLevel
  LeanDb/CliGen/     -- @[query]/@[cli] → verbs, flag derivation, JSON/Lean output emitters
  Main/              -- the `leandb` executable: Lake driving, scaffolding, import, templates
  Templates/         -- tickets/ catalog/ crm/ blank/ as literal source trees
  Tests/             -- roundtrip lemmas + Plausible, differential (spec vs engine), golden SQL,
                     --   golden CLI transcripts per template
```

A base depends on `leandb` the package like any Lake dependency; the CLI is orchestration over `lake` plus the instance file (Arch §10.2). Nothing in a base is magical — delete the CLI and the base still builds, queries still run from any Lean program importing it. The CLI is convenience over a library, in that order.

---

## 8. Open ends, named

Three decisions this spec makes provisionally, flagged rather than buried: (1) `data/` gitignored with seeds as the reproducible demo state — right for templates, revisit for bases whose *data* is the product; (2) the `rows --eq` mini-filter is capped at conjunctive equality forever — pressure to grow it should be redirected to query files, on purpose; (3) log storage lives in the same sqlite file — simplest, measurable write amplification, split to a sibling file if it ever shows up in `--dry-run` timings.
