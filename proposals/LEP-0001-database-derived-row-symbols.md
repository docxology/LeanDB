# LEP-0001: Database-derived row symbols

| Field | Value |
|---|---|
| Status | Draft |
| Number | LEP-0001 |
| Created | 2026-08-26 |
| Target | Post-0.2 |
| Primary goal | Query ergonomics |

## Summary

LeanDB should be able to derive a finite set of typed symbols from selected
rows in the database bound to a base. A base with organizations named
Facebook, Google, and OpenAI could generate a type such as:

```lean
inductive KnownOrganization where
  | Facebook
  | Google
  | OpenAI
  deriving Repr, DecidableEq
```

Base queries and operations could then accept `KnownOrganization`:

```lean
addEmployment person.ref .Facebook 2018 2022
currentlyAt .OpenAI
```

The organization remains an ordinary entity row. The generated constructor
is a compiler-known handle that resolves to that row through a stable key.
Adding or removing a participating row changes the generated type and causes
affected Lean code to recompile.

The database is part of the base by convention. A SQLite base names a fixed
file. A future PostgreSQL base names an environment variable containing its
connection string. A Lake target reads that configured database, generates a
Lean module deterministically, and detects drift before compiling code that
imports it.

## Why do this

Opaque row IDs make small queries harder to write and harder to read:

```lean
currentlyAt ⟨11⟩
```

The number carries no meaning at the call site. A string lookup is clearer,
but gives up compiler assistance and has to define what happens when names
are missing or duplicated:

```lean
currentlyAtName "Facebook"
```

Database-derived symbols retain the readability of names while giving Lean a
real type to check. The immediate benefit is query ergonomics:

- editors can complete `.Facebook` after seeing the expected type;
- misspelled or deleted symbols fail during compilation;
- query definitions no longer repeat lookup code;
- logs and reviewed source show a meaningful handle instead of an integer;
- agents can choose from a finite vocabulary exposed by the type.

This also provides a controlled form of data-as-code. Some rows act as a
base's working vocabulary even though they still need normal entity features
such as descriptions, relationships, migrations, and administration through
SQL tools. Today a base must choose between a hand-written closed enum and a
dynamic table. Row symbols cover the useful middle case.

## Terminology

A **row symbol** is a generated Lean constructor associated with one entity
row through an immutable key.

A **symbol set** is the generated inductive plus its key mapping and resolver.

A **bound database** is the database instance named by the base configuration
and used as an input to symbol generation.

Row symbols differ from `LeanDb.ClosedEnum`. A closed enum declares the whole
world in Lean and stores its constructor names as values. A symbol set takes
a snapshot of selected rows from an open entity table. Those rows retain IDs,
columns, foreign keys, and an ordinary CRUD lifecycle.

## Proposed base configuration

The configuration belongs to the base rather than the engine package. The
exact manifest format may change during implementation; the proposed shape
is:

```toml
[database]
backend = "sqlite"
path = "data/people.sqlite"

[[symbols]]
entity = "People.Organization"
type = "KnownOrganization"
module = "People.Generated.Organizations"
table = "organization"
key = "slug"
label = "name"
constructorStyle = "pascal"
mode = "bound"
```

A PostgreSQL-backed base would keep the secret outside version control:

```toml
[database]
backend = "postgres"
connectionEnv = "PEOPLE_DATABASE_URL"
```

The base commits the environment-variable name. Local setup and CI provide
the value. LeanDB must never print the connection string in generated files,
logs, diagnostics, or fingerprints.

SQLite is the first implementation target because it is LeanDB's current
backend. The configuration and generator interface should leave room for
PostgreSQL without claiming PostgreSQL runtime support in this proposal.

## Stable keys

Symbols must derive from a unique, immutable key such as an organization
slug:

```text
facebook  -> Facebook
openai    -> OpenAI
```

Display names are unsuitable as identity because users edit them and two rows
may share one. Primary-key integers are stable in one live instance but can
differ in a copied or rebuilt instance. Generated code therefore contains the
stable key, not a numeric row ID.

Generation fails if the configured key column contains `NULL`, duplicate
values, values that cannot become Lean constructors, or normalization
collisions such as `foo-bar` and `foo_bar`. LeanDB reports every conflicting
row and writes no partial module.

Changing a key is an API-breaking database migration. Changing a label is an
ordinary data edit unless the base elects to generate documentation or
display functions from labels.

## Generated API

For the configuration above, LeanDB writes a normal source module owned by
the base:

```lean
namespace People

inductive KnownOrganization where
  | Facebook
  | Google
  | OpenAI
  deriving Repr, DecidableEq, Ord

def KnownOrganization.key : KnownOrganization → OrgSlug
  | .Facebook => ⟨"facebook"⟩
  | .Google   => ⟨"google"⟩
  | .OpenAI   => ⟨"openai"⟩

def KnownOrganization.resolve
    (symbol : KnownOrganization) : DbM (Stored Organization) :=
  resolveUnique Organization "slug" (toCol symbol.key)

end People
```

The generator should also emit `CliArg`, JSON, and display instances when the
required underlying codecs exist. The precise common interface can be small:

```lean
class DbSymbol (symbol entity : Type) where
  key : symbol → Col
  resolve : symbol → DbM (Stored entity)
```

`resolve` checks the database at runtime. Generated code does not embed the
row's numeric ID, so it remains valid for a faithful copy of the base
database. Resolution returns a typed error if drift leaves the key missing or
ambiguous.

## Query surface

An operation opts into the generated symbol type in its signature:

```lean
def addEmployment
    (person : Ref Person)
    (organization : KnownOrganization)
    (started ended : Year) : DbM (Stored Employment) := do
  let org ← organization.resolve
  insert Employment {
    person
    organization := org.ref
    title := ← defaultTitleFor organization
    startedAt := some started
    endedAt := some ended
  }
```

The call site is short and checked:

```lean
addEmployment person.ref .Facebook 2018 2022
```

The intended base-level surface extends across relationships that share the
same entity identity:

```lean
addEmployment person.ref .Stanford 2018 2020
addEducation person.ref .Stanford .masters .computerScience
```

Here `.Stanford` is a database-derived `KnownOrganization`. The degree level
is a code-owned closed enum. A field-of-study taxonomy may be a closed enum or
another database-derived symbol set, depending on whether code or rows own
that vocabulary. The function signatures keep those choices visible and
prevent values from crossing argument positions.

These calls are the ergonomic target for LEP-0001. Normalized tables, foreign
keys, and runtime symbol resolution remain below the domain operation.

A base may add syntax such as `!addEmployment(...)`, but special punctuation
is outside the engine proposal. The ergonomic gain comes from the expected
symbol type and dot-constructor completion.

`query%` should derive CLI parsing from the generated type, allowing:

```bash
people query currentlyAt Facebook
```

Unknown values fail during argument decoding and list the accepted symbols.

## Build and synchronization contract

The database is a declared input to the base. LeanDB adds two commands:

```bash
lake leandb-symbols sync
lake leandb-symbols check
```

`sync` performs the following work:

1. Connect to the configured database with read-only permissions.
2. Read each symbol query in stable key order.
3. Validate keys and constructor names.
4. Compute a canonical fingerprint over the generator version,
   configuration, keys, and emitted metadata.
5. Replace a generated module only when its content changes.

`check` computes the same fingerprint and fails if the generated source is
stale. It never edits files.

Two modes support different base conventions:

| Mode | Behavior |
|---|---|
| `bound` | The default Lake target runs `sync` before compiling. The configured database must be available for every clean build. |
| `snapshot` | Generated modules are committed. Ordinary builds use the snapshot; CI and release checks run `check` against the configured database. |

The `bound` mode matches bases whose fixed database is part of project setup.
It also handles remote databases because the Lake target probes the database
instead of relying on file modification times. Existing `.olean` files do
not suppress the probe. Rewriting happens only after a fingerprint change,
which avoids needless recompilation.

The `snapshot` mode supports distributable packages and offline work. A
checkout can compile from committed generated modules, while CI still detects
database drift.

## Failure behavior

Symbol generation is atomic. Any failure preserves the last complete
generated module and exits nonzero with a machine-readable error. Named error
cases should include:

- configured database unavailable;
- missing table or key column;
- null or duplicate key;
- invalid or colliding constructor names;
- stale generated fingerprint;
- generated key missing or ambiguous during runtime resolution.

Removing a participating row and running `sync` removes its constructor.
Queries that mention it then fail to compile. This is a desired result: the
compiler points to every source location that relied on the removed row.

## Security and operational boundaries

Generation requires read-only database access. PostgreSQL deployments should
use a dedicated role limited to the configured tables or views. Queries in
the manifest must be static; values from the database are data and are never
spliced into executable SQL.

Connection strings stay in environment variables. Fingerprints include query
results and public configuration, never credentials. Diagnostics identify the
environment-variable name and backend without revealing its value.

Because `bound` mode makes compilation depend on external state, its output
must record the database schema fingerprint and symbol fingerprint in the
generated header. Build logs can then state exactly which snapshot was used.

## Scope

The first implementation includes:

- SQLite symbol generation from one entity table and one scalar key column;
- deterministic generated inductives, key functions, and resolvers;
- `sync` and `check` commands;
- `bound` and `snapshot` modes;
- `CliArg` generation;
- tests for drift, deletion, collisions, and copied databases with different
  numeric IDs.

PostgreSQL connectivity, arbitrary joins in symbol queries, generated syntax
macros, and automatic uniqueness migrations are later work. The backend
interface should make PostgreSQL possible without delaying the SQLite path.

## Alternatives considered

### Raw IDs

Raw IDs already work and remain the universal interface. They are poor query
literals because readers must inspect the database to learn what `11` means.

### Runtime strings

Strings avoid generation and work with any backend. They move spelling,
existence, and ambiguity errors to runtime and provide no editor completion.
They remain useful for ad hoc input.

### Hand-written closed enums

A hand-written enum gives excellent Lean ergonomics. It duplicates the row
set and can drift from the database. Closed enums are still the right model
when Lean source owns the vocabulary.

### Querying the database directly from a command elaborator

A command elaborator can perform the database query and emit declarations.
Lake may reuse a cached module without rerunning that elaborator when only a
remote database changed. A dedicated generation target makes the dependency
and fingerprint check explicit, while the output remains ordinary Lean code.

## Acceptance criteria

LEP-0001 is ready for implementation when one example base can demonstrate
all of the following:

```lean
#check (KnownOrganization.Facebook : KnownOrganization)
#check addEmployment person.ref .Facebook 2018 2022
#check addEmployment person.ref .Stanford 2018 2020
#check addEducation person.ref .Stanford .masters .computerScience
#check_failure addEmployment person.ref .Facebok 2018 2022
#check_failure addEducation person.ref .Stanford .softwareEngineer .computerScience
```

The example must also prove that:

1. adding a configured organization creates a constructor after `sync`;
2. deleting one removes the constructor and breaks dependent source;
3. a display-name edit leaves the constructor stable;
4. a copied database with different numeric IDs resolves the same symbol;
5. duplicate or colliding keys fail without changing generated files;
6. `check` detects drift for both a local SQLite file and a mocked remote
   backend fingerprint.
