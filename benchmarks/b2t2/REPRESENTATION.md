# Table representations

B2T2 tables are encoded as LeanDB entities. Expected cell values live in
`B2T2/Fixtures.lean`, transcribed from ExampleTables.md at
`fd227efadf532a20aefd25c7a8580978c2d684a2`. Tests compare decoded `val`
fields to those fixtures; they do not treat LeanDB ids as part of the
benchmark row.

## Identifier mapping

B2T2 column names are first-class strings and may contain spaces. LeanDB
columns are Lean structure fields. The mapping is:

| B2T2 | Lean field | SQLite column |
|---|---|---|
| `name` | `name` | `name` |
| `age` | `age` | `age` |
| `favorite color` | `favoriteColor` | `favoriteColor` |
| `Last Name` | `lastName` | `lastName` |
| `Department ID` | `departmentId` | `departmentId` |
| `Department Name` | `departmentName` | `departmentName` |
| `get acne` | `getAcne` | `getAcne` |
| `final` | `«final»` | `final` |

This is a representation gap: programs that *compute* a column name
(`concat("quiz", …)`) cannot feed that string into a typed field
accessor without an extra string-boundary helper (`Ops.getValue`).

## Row identity and order

LeanDB stores a surrogate `Id α` on every row. B2T2 rows are value tuples
plus a positional index. Consequences:

- Two B2T2-identical rows become two LeanDB rows with distinct ids.
- `distinct` on values is extra Lean (`distinctBy`); the engine’s rows
  are already unique by id.
- Insertion order is recovered by `SortBy .key (·.id)` after seed
  (`Ops.loadOrdered`). B2T2 positional `getRow n` is extra Lean on that
  ordered array, not an engine primitive.

## Missing values

`Option α` columns store SQL NULL (`ColCodec` nullable). Representable:

- `studentsMissing.age` / `favoriteColor`
- `employees.departmentId` (Williams)
- `gradebookMissing.quiz1` / `quiz3`

Missing values do not change output schemas of LeanDB `select`. Extra
Lean helpers implement `dropna`, `fillna`, and `completeCases`.

## Empty, zero-column, duplicate-column tables

| Feature | Status |
|---|---|
| Empty row set | Representable (`Array` empty / `select` that matches nothing) |
| Zero-column table (`emptyTable`) | **Unsupported.** An entity needs columns; LeanDB always adds `id`. |
| Duplicate column names | **Rejected at compile time** (duplicate structure fields). More precise than B2T2’s runtime constraint. |
| Duplicate row values | Representable as distinct ids |

## Sequences and nested tables

- `gradebookSeq.quizzes : List Nat` uses an extra-Lean JSON TEXT codec.
  Not a first-class sequence sort; SQLite sees TEXT.
- `gradebookTable` is encoded as `GradebookNested` with
  `quizzes : List Quiz` (`deriving LeanDb.Inline`). That is a **child
  table** (`gradebook_nested_quizzes` with `parent` + `position`), not a
  table-valued cell. Group-by operations that need `Table` as a cell
  sort remain extra Lean arrays, not stored nested tables.

## Normalization and codecs

Scalars use engine codecs: `String`, `Nat`, `Bool`, `Option`. No
trimming or case-folding. Boolean jelly columns are `Bool` (INTEGER
0/1), not strings `"true"`/`"false"`.

## SQL vs Lean

| Work | Where |
|---|---|
| `insert` of fixtures | SQL |
| `select [α] pred sortBy` (`tfilter`, typed sort, inner join) | SQL plan + Lean residual (`finishRows`) |
| Child-list attach for `GradebookNested` | SQL + engine attach |
| `getColumn` / `getRow` / `head` / `leftJoin` / `count` / `dropna` / `flatten` / Fisher / sample | Lean on decoded rows |
| Schema-changing ops (`buildColumn`, `pivot*`, generic `header` iteration) | Extra Lean or unsupported |

## Fixture tests

`B2T2Tests` reloads each table in id order and checks names, optionality,
sequence contents, and nested quiz rows against `B2T2/Fixtures.lean`.
