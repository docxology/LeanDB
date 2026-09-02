# LeanDB

**Strongly typed SQL in Lean 4.** LeanDB combines Lean's expressive type
system with SQLite, giving a dependently typed front end to a SQL backend.
That gives you:

- validated, typed data,
- queries checked against the tables they read, and
- schema-derived migrations (with typed data transformations coming soon).

## Typed Data

Model domain values directly. Every value read from SQLite or decoded from
JSON passes through its `ColCodec`, while `Ref User` makes a foreign key's
target part of its Lean type.

```lean
import LeanDb

open LeanDb

structure Title where
  raw : String
  deriving Repr, DecidableEq, Ord

def Title.make (s : String) : Except String Title :=
  let title := s.trimAscii.toString
  if title.isEmpty then .error "title must be nonempty" else .ok ⟨title⟩

instance : ColCodec Title := ColCodec.via (·.raw) Title.make

inductive Status where
  | backlog | inProgress | done
  deriving Repr, DecidableEq, Ord, LeanDb.ClosedEnum

structure User where
  name : String
  deriving Repr, LeanDb.Entity

structure Ticket where
  title    : Title
  status   : Status := .backlog
  reporter : Ref User
  deriving Repr, LeanDb.Entity

def schema : List TableSpec :=
  [Entity.spec User, Entity.spec Ticket]
```

`deriving LeanDb.Entity` produces each table specification; `schema` lists
those tables in foreign-key dependency order. LeanDB derives the columns,
default, foreign-key constraint, JSON codec, and migration metadata from the
entity declarations, so there is no second schema to keep in sync.

## Typed Queries

The table list fixes the predicate's input type, so a predicate for the wrong
table does not compile. This join is checked in Lean and runs as one SQL
statement:

```lean
def activeTickets : DbM (Array (Stored Ticket × Stored User)) :=
  select [Ticket, User]
    (fun (ticket, user) =>
      ticket.val.reporter == user.ref && ticket.val.status != .done)
    (.key fun (ticket, _) => ticket.val.title)

-- `select [User]` requires a `Stored User → Bool`, so this is rejected:
#check_failure
  select [User] (fun (ticket : Stored Ticket) => ticket.val.status == .done)
```

LeanDB reifies the part of the predicate it can express in SQL and always
checks the original Lean predicate on the returned rows, preserving Lean's
reference semantics.

## Schema migrations (typed transformations coming soon)

A migration starts as a type-safe schema edit. For example, adding an optional
field is enough to produce a non-destructive migration plan:

```diff
 structure Ticket where
   title    : Title
   status   : Status := .backlog
   reporter : Ref User
+  assignee : Option (Ref User)
   deriving Repr, LeanDb.Entity
```

```console
$ tickets migrate status
{"destructive":false,"notes":[],"ok":true,"steps":["add column \"ticket\".\"assignee\""]}

$ tickets migrate apply
{"applied":["add column \"ticket\".\"assignee\""],"ok":true,…}
```

LeanDB already derives and transactionally applies schema changes. A future
typed-transformation API will cover changes that need application-specific
row conversion rather than a mechanical SQLite migration.

Backed by SQLite ([leansqlite](https://github.com/leanprover/leansqlite),
bundled — nothing to install). Machine-first: every command emits one JSON
value; errors are typed with stable codes; exit codes mean things.

## Setup

You need [`elan`](https://github.com/leanprover/elan) (the Lean toolchain
manager). Then:

```bash
git clone https://github.com/theoriclabs/LeanDB.git leandb && cd leandb
lake build            # engine (first build compiles bundled SQLite; takes a few minutes)
lake build leandb     # the importer executable (used in "Importing" below)
lake build leandb_tests && .lake/build/bin/leandb_tests   # optional: "all engine tests passed"
```

Maintainers can run the full engine, example, and importer release pass with
`./scripts/release_check.sh`; see `RELEASING.md` for the tag checklist.

## A new base from scratch

A LeanDB database ("base") is an ordinary Lake package depending on
`leandb`. Three files. Make a directory anywhere and add:

**`lean-toolchain`** — must match the engine's (copy it):

```
leanprover/lean4:v4.33.0
```

**`lakefile.toml`**:

```toml
name = "notes"
defaultTargets = ["notes"]

[[require]]
name = "leandb"
path = "/absolute/path/to/leandb"   # or a relative path

[[lean_exe]]
name = "notes"
root = "Main"
```

**`Main.lean`** — a complete base in one file:

```lean
import LeanDb

open LeanDb LeanDb.Cli

/-- A validated newtype: database and JSON decoding use its smart constructor. -/
structure Title where
  raw : String
  deriving Repr

def Title.make (s : String) : Except String Title :=
  let t := s.trimAscii.toString
  if t.isEmpty then .error "title must be nonempty" else .ok ⟨t⟩

instance : ColCodec Title := ColCodec.via (·.raw) Title.make

/-- A closed world: these are ALL the statuses. Stored as TEXT with a
    CHECK constraint; not an entity — you cannot insert or delete one. -/
inductive Status where
  | draft | published
  deriving Repr, DecidableEq, Ord, LeanDb.ClosedEnum

structure Note where
  title  : Title
  body   : String
  status : Status := .draft
  deriving Repr, LeanDb.Entity

def schema : List TableSpec := [Entity.spec Note]

/-- Domain logic the query compiler may unfold into SQL. -/
@[db] def Note.isDraft (n : Note) : Bool := n.status == .draft

def drafts : DbM (Array (Stored Note)) :=
  select [Note] (fun n => n.val.isDraft) (.key (·.val.title.raw))

open Lean (Json) in
def main (args : List String) : IO UInt32 :=
  Cli.run {
    name := "notes"
    dbPath := "data" / "notes.sqlite"
    specs := schema
    tables := [.of Note]
    queries := [query% drafts]   -- CLI arity/parsing derived from the def's signature
  } args
```

Build and use (the instance file is created on first touch):

```bash
lake build
notes=./.lake/build/bin/notes

$ $notes insert note '{"title":"  First  ","body":"hello"}'
{"ok":true,"row":{"body":"hello","id":1,"status":"draft","title":"First"}}
#         title trimmed by the smart constructor ─┘        └─ default filled in

$ $notes insert note '{"title":"   ","body":"no"}'
{"code":"decode","message":"note.title: title must be nonempty","ok":false}   # exit 2

$ $notes query drafts
{"ok":true,"result":[{"body":"hello","id":1,"status":"draft","title":"First"}]}

$ $notes version
{"code_fingerprint":"…","in_sync":true,"instance_fingerprint":"…","ok":true,"schema_version":1}
```

## Changing the schema — migrations

The schema is the code, so a migration starts with an edit. Add a variant
to the closed world and a new field:

```lean
inductive Status where
  | draft | published | archived      -- grew the world
  ...
structure Note where
  title  : Title
  body   : String
  status : Status := .draft
  pinned : Option Bool                -- new column: Option, or give it a default
  ...
```

`lake build`, then watch the instance refuse to lie about what it holds:

```bash
$ $notes rows note
{"code":"schema_mismatch","message":"schema fingerprint mismatch: …","ok":false}   # exit 4

$ $notes migrate status
{"destructive":false,"notes":["\"note\".\"status\" changed shape → table rebuild"],
 "ok":true,"steps":["rebuild table \"note\" (copying 3 columns)"]}

$ $notes migrate apply
{"applied":["rebuild table \"note\" (copying 3 columns)"],"fingerprint":"…","ok":true,…}

$ $notes rows note --eq status=draft
{"count":1,"ok":true,"rows":[{"body":"hello","id":1,"pinned":null,"status":"draft","title":"First"}]}

$ $notes version
{…,"in_sync":true,"schema_version":2}
```

The rules, all loud:

- **New columns must be `Option` or carry a `:= default`** — a declared
  default backfills existing rows (and shows up in the DDL and the
  `schema` output); without one, a `NOT NULL` addition is refused with
  guidance rather than inventing a value.
- **New tables** apply as plain `CREATE TABLE`.
- **Changed column shapes** (a grown/renamed closed world, a type change)
  rebuild the table in place, copying surviving columns. **Shrinking a
  closed world** with rows still using the removed variant fails the new
  CHECK during the copy and **rolls back** — vocabulary shrinks only when
  the data already conforms.
- **Dropping tables or columns** is refused unless you pass
  `migrate apply --allow-destructive`.
- Everything runs in one transaction with a foreign-key check before
  commit; each apply is journaled in `_leandb_migrations` and bumps
  `schema_version`.

## Importing an existing SQLite database

Point the importer at any SQLite file; it generates a complete typed base:

```bash
$ leandb import-sqlite inventory.db --name inventory --out ./inventory \
    --require-path /absolute/path/to/leandb
{"imported":["vendors","parts"],"skipped":[],…}

$ cd inventory && mkdir -p data && cp ../inventory.db data/   # adopt the file
$ lake build
$ ./.lake/build/bin/inventory rows parts --eq vendor_id=1
{"count":1,"ok":true,"rows":[{"id":1,"label":"sprocket","qty":12,"vendor_id":1}]}
```

What you get: `INTEGER` → `Int64`, FKs → `Ref <Table>`, nullable →
`Option`, and **every TEXT column becomes its own named newtype with an
identity smart constructor** — *import loose, tighten forever*: the base
is never stringly, and each future validation is one `make` function away
(followed by the ordinary migration flow above). Everything that can't be
carried — views, triggers, composite-key tables, BLOB columns — is listed
**by name** with a reason in the generated `IMPORT.md` /
`import-report.json`. Silent partiality is forbidden.

The adopted file keeps working with plain `sqlite3` the whole time; LeanDB
adds its `_leandb_*` bookkeeping tables on first open.

## The CLI every base gets

`Cli.run` derives the whole surface from your entity list:

| Command | Meaning |
|---|---|
| `schema` | schema as JSON, derived from the types (closed worlds visible) |
| `version` | code vs instance fingerprint, `schema_version`, `in_sync` |
| `insert <table> <json>` | decode through the smart constructors; defaults fill omitted fields |
| `get <table> <id>` · `delete <table> <id>` | typed row ops; `delete` of a referenced row → `restricted` |
| `update <table> <id> <partial-json>` | column-level merge, re-validated, written compare-and-swap |
| `rows <table> [--eq col=value]… [--limit n]` | conjunctive equality filters — the CLI's whole filter language, by design |
| `query <name> [args…]` | your `query%`-registered queries; args parse by type |
| `migrate status` / `migrate apply [--allow-destructive]` | see above |
| `log [n]` | the query log: verb, reified SQL plan, outcome, row count |
| `serve` | JSON-lines over stdio on one persistent connection (each request is a JSON argv array) |

Exit codes: `0` ok · `2` typed `DbError` (JSON on stderr, `code` field:
`decode`, `not_found`, `stale`, `restricted`, `missing_ref`, `duplicate`, `schema`, `enum_drift`,
`migrate`, `sqlite`) · `3` usage · `4` schema/version mismatch.

## Queries are Lean

`select` takes a plain lambda; the four verbs are all there is:

```lean
insert Ticket {...}         -- : DbM (Stored Ticket), returns assigned id
update old new              -- compare-and-swap: a lost race is .stale, never a clobber
delete someId               -- referenced row → .restricted
select [Ticket, User] (fun (t, u) => t.val.reporter == u.ref && t.val.priority == .p0)
  (.andThen (.key fun (t, _) => t.val.createdAt) (.desc (.key fun (_, u) => u.val.handle)))
```

At each call site an elaboration tactic reifies the predicate into a plan:
column/value comparisons (captured variables become bound SQL parameters),
joins, `&&`/`||`/`!`, `Option` null tests, `@[db]` helpers unfolded — and a
`match` on a closed world compiles to SQL by case-splitting it (the gpus
example's `Chip.vendor c == .amd`, a seven-constructor match, executes as
`chip IS 'mi300x' OR chip IS 'mi325x'`). Whatever the tactic can't
translate stays a *residual* conjunct: the lambda is **always** applied to
what comes back, so plans narrow fetches but can never change results.
`log` shows exactly what was pushed; `set_option leandb.explain true`
shows plans at compile time.

## Example bases

The hand-written bases are standalone packages with tests and a
`CLI_TRANSCRIPT.md`; `legacy` is the checked-in importer output:

| Base | Domain | Worth seeing |
|---|---|---|
| `examples/tickets` | issue tracker | SLA join, `@[db]` helpers, the reference base |
| `examples/crm` | companies/people/asks | pipeline join, keyword enum variant `«open»` |
| `examples/shop` | ecommerce | basket/revenue joins, Money/Sku/Qty scalars |
| `examples/gpus` | GPU SKUs & providers | match→CASE pushdown; `#check_failure LeanDb.delete (α := Chip) ⟨1⟩` — you can't delete a chip from the universe |
| `examples/gpumarket` | GPU rental market + models | providers as a *closed world* (deleting Lambda doesn't typecheck), total vocabulary functions, `query h100 onDemand` → cheapest first, `canServe <model>` joins models against listings |
| `examples/pricewatch` | ecommerce price comparison | typed hard constraints plus sorted, Pareto-front, and knee-point selection strategies |
| `examples/legacy` | generated by `import-sqlite` | what the importer emits |

```bash
cd examples/tickets && lake build tickets
./.lake/build/bin/tickets query seed
./.lake/build/bin/tickets query slaBreached 1700000000
./.lake/build/bin/tickets log 3
```

## Repo map

```text
LeanDb/Core.lean     Id/Ref/Stored, Col, ColCodec, ClosedEnum, ColumnSpec, DbError
LeanDb/Entity.lean   Entity class, TableSpec, DDL generation, fingerprint
LeanDb/Derive.lean   deriving LeanDb.Entity / LeanDb.ClosedEnum (incl. field defaults)
LeanDb/Select.lean   Rows ts, SortBy, RowsOf, selectSpec (the reference semantics)
LeanDb/Pred.lean     typed plan IR (Pred)  LeanDb/PlanElab.lean  the leandb_plan tactic, @[db]
LeanDb/Db.lean       DbM, the four verbs, joined executor, open checks, query log
LeanDb/Migrate.lean  schema diff → steps, transactional apply, journal
LeanDb/Json.lean     schema/row/error JSON, merge decode   LeanDb/Cli.lean  the CLI driver
LeanDb/CliQuery.lean query%                LeanDb/Import.lean  import-sqlite generator
Tests.lean           engine tests          Main.lean            the leandb executable
```

Design docs: [`plan.md`](plan.md) (interface spec),
[`plan-v2.md`](plan-v2.md) (milestones and status),
[`LEP-0001`](proposals/LEP-0001-database-derived-row-symbols.md)
(database-derived row symbols for query ergonomics),
[`LEP-0002`](proposals/LEP-0002-typed-predicate-ir.md)
(typed predicate IR: `Field` symbols, `Pred ts`, pushdown soundness by theorem — landed),
[`LEP-0003`](proposals/LEP-0003-nested-values.md)
(nested values: `EnumSet`, JSON columns with a declared shape, derived columns, inline flatten, child tables),
[`LEP-0004`](proposals/LEP-0004-child-table-quantifiers.md)
(`exists`/`forall` over a related table as one pushed `select`),
[`claude-discussion.md`](claude-discussion.md) (original design
discussion). Deferred, by name: MCP/HTTP serve, log replay,
`--output-lean`, migration source-file synthesis, `--infer-enums` on
import, column-arithmetic pushdown.
