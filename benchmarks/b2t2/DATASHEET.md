# LeanDB datasheet for B2T2 v1.2

Completed against the template at
[Datasheet.md](https://github.com/brownplt/B2T2/blob/fd227efadf532a20aefd25c7a8580978c2d684a2/Datasheet.md)
on 2026-09-14.

## Reference

> Q. Where can we learn about the programming medium covered by this datasheet?

[LeanDB](https://github.com/theoriclabs/LeanDB) — strongly typed SQL in Lean 4,
SQLite backend via [leansqlite](https://github.com/leanprover/leansqlite).
Version measured: **v0.3.1**, git SHA
`ad8d7f3de883176b7de0b6433cb8cd3fc25a8763`.
Toolchain: Lean 4.33.0 (`leanprover/lean4:v4.33.0`).
README and `docs/` in that commit.

> Q. What is the URL of the version of the benchmark being used?

https://github.com/brownplt/B2T2/tree/fd227efadf532a20aefd25c7a8580978c2d684a2
(tag `v1.2`).

> Q. On what date was this version of the datasheet last updated?

2026-09-14.

> Q. If you are not using the latest benchmark available on that date, please explain why not.

The plan pins **B2T2 v1.2**. On 2026-09-14, `main` was
`eeebf5db7a5c1dbf1893b622ff7fffd63d5c3286` (a `selectMany` signature typo
fix). This datasheet does not include that later commit.

## Example Tables

> Q. Do tables express heterogeneous data, or must data be homogenized?

Heterogeneous. Each column has its own Lean type (`String`, `Nat`,
`Bool`, `Option α`, `List Nat`, child lists). A row is a structure, not
a homogeneous array.

> Q. Do tables capture missing data and, if so, how? Do missing values affect the output constraints of any operations, for example `groupBy`?

Yes: `Option α` ↔ SQL NULL. LeanDB `select` output schema does not
change when cells are missing. Extra-Lean `groupByRetentive` treats
`none` as an ordinary key (Williams is his own group). Engine joins on
`departmentId == some d.departmentId` drop `none` (inner join).

> Q. Are mutable tables supported? Are there any limitations?

Yes, via `insert` / `update` / `delete` on a SQLite instance. `update` is
compare-and-swap on the stored row, not B2T2’s per-row function. One
writer per file. Schema change is a Lean type change plus migration, not
`addColumn` at runtime.

> Q. Which tables are inexpressible? Why?

A zero-column table (`emptyTable`). LeanDB entities always have an `id`
column and at least the fields of the structure.

> Q. Which tables are only partially expressible? Why, and what’s missing?

`gradebookTable`: encoded as a parent + child table, not as a cell whose
sort is `Table`. `gradebookSeq`: sequence cells are JSON TEXT, not a
native sequence sort. All tables lose first-class B2T2 display names
(spaces, `"Last Name"`).

> Q. Which tables’ expressibility is unknown? Why?

None of the published example tables.

> Q. Which tables can be expressed more precisely than in the benchmark? How?

Closed sorts can be inductives (`ClosedEnum`) with CHECK + drift scan
(not used in these fixtures; colors stay `String`). Duplicate column
names are unrepresentable. `Ref` / `Id` distinguish identity from value
(B2T2 has only position + values).

> Q. How direct is the mapping from the tables in the benchmark to representations in your system? How complex is the encoding?

One Lean structure per table, `deriving LeanDb.Entity`, fixtures as
`Array` literals, `insert` to seed. Mapping is direct for flat
heterogeneous tables. Name camelCasing, surrogate ids, JSON lists, and
child tables are the encoding cost. See `REPRESENTATION.md`.

## TableAPI

> Q. Are there consistent changes made to the way the operations are represented?

Yes. Column names become field projectors or a string boundary
(`Ops.getValue`). Same-schema filters/sorts/joins use LeanDB `select`.
Schema-changing ops become new Lean types or extra-Lean arrays. See
`INVENTORY.md`.

> Q. Which operations are entirely inexpressible? Why?

`emptyTable`, `bin`, `pivotTable`, `pivotLonger`, `pivotWider`,
`selectMany` (as specified: dynamic/nested schemas, histogram, names
from data). First-class `header` iteration that *indexes* typed columns
by computed strings is inexpressible without leaving the type.

> Q. Which operations are only partially expressible? Why, and what’s missing?

`addColumn` / `buildColumn` / `selectColumns` / `dropColumns` /
`renameColumns` / `hcat` / `transformColumn` / `select` / `update`:
expressible only by writing a new structure or mapping in Lean, not by
changing one table value’s schema. `leftJoin` is extra Lean; engine
`select [A,B]` is inner. `groupByRetentive` returns Lean arrays, not
`Table`-sorted cells. `getColumn`/`getValue` by `ColName` are extra
Lean.

> Q. Which operations’ expressibility is unknown? Why?

None is classified as unknown in the inventory, but classification is not
verification. `find`, `groupJoin`, `groupBySubtractive`, and `sortByColumns`
have no dedicated assertions; other entries share checks or use adaptations.
The 49 API entries comprise 31 direct/extra, 12 specialized, and 6 unsupported
classifications. See [INVENTORY.md](INVENTORY.md) for the evidence and gaps.

> Q. Which operations can be expressed more precisely than in the benchmark? How?

`tfilter` predicates that return non-`Bool` do not compile.
`select [Student]` rejects a `Stored Gradebook` predicate.
`SortBy.key` requires `Ord`. Wrong-table / wrong-field access is a
missing projection, not an empty result. `approx_sound` (engine) is out
of B2T2 scope but is how pushed filters stay conservative.

## Example Programs

> Q. Which examples are inexpressible? Why?

The *generic* `quizScoreSelect` / `quizScoreFilter` (computed or
`startsWith` names that determine numeric sort) and generic
`pHacking` (`for c in header(t)`). Specialized replacements exist.

> Q. Which examples’ expressibility is unknown? Why?

None is left unclassified. All eight have adaptations; seven have direct runtime
assertions. `groupBySubtractive` is implemented without its own runtime assertion.

> Q. Which examples, or aspects thereof, can be expressed especially precisely? How?

`dotProduct` with `Gradebook → Nat` projectors: both columns are
numeric by construction. `tfilter` / `SortBy` / inner join share that
precision. `sampleRows` can state `n ≤ nrows` as an `Except`.

> Q. How direct is the mapping from the pseudocode in the benchmark to representations in your system? How complex is the encoding?

Filters and typed sorts are close to the pseudocode (`select [α] pred
sortBy`). Anything that treats `ColName` or `header` as data is rewritten
as projectors or a static list. Fisher’s test and sampling are host Lean,
not the engine.

## Errors

> Q. Which error situations are known to be inexpressible? Why?

Plotting (`scatterPlot`, `pieChart`) — no Image. The mistaken *column
names* those plots would consume are still inexpressible as fields
(`"true"`, `"mid"`).

> Q. Which error situations are only partially expressible? Why, and what’s missing?

`err.getOnlyRow` is runtime, not a type-level `Fin nrows`.
`err.employeeToDepartment` is extra Lean; LeanDB does not type “this
helper returns a department name.” Tests cover a corrected lookup and missing
department data, not rejection of the original incorrect helper. String `getValue` can express the
`"mid"` bug at runtime; field access prevents constructing it.

> Q. Which error situations’ expressibility is unknown? Why?

None.

> Q. Which error situations can be expressed more precisely than in the benchmark? How?

Malformed table constants (missing schema/cell/row, swapped columns,
schema length) cannot be constructed as `Student` values. Wrong-table
`select` and non-`Bool` filters are type errors.

> Q. Which error situations are prevented from being constructed? How?

`err.missingSchema`, `err.missingRow`, `err.missingCell`,
`err.swappedColumns`, `err.schemaTooShort`, `err.schemaTooLong`,
`err.midFinal` (field form), `err.blackAndWhite`, `err.pieCount`,
`err.brownGetAcne`, `err.favoriteColor`, `err.brownJellybeans`.
Mechanism: structure fields + `select`’s `Rows ts → Bool`.

> Q. For each error situation that is at least partially expressible, what is the quality of feedback to the programmer?

Runtime `getValue "mid"`: `no such column "mid"; columns: [...]`.
`getRow 1` of a 1-row table: `row index 1 not in range(1)`.
`employeeToDepartment "Williams"`: `{name} has no department`.
These messages identify the bad column, row index, or missing department.
The column and row messages do not include the helper's function name.

> Q. For each error situation that is prevented from being constructed, what is the quality of feedback to the programmer?

Lean Infoview / compiler: missing field names (`favoriteColor`),
`OfNat String 12` + `String` vs `Nat` on swap, `Invalid field mid`,
`String` vs `Bool` for the favorite-color predicate, `Rows [Student]` vs
`Stored Gradebook`. These identify the field or the table list. They do
not mention B2T2 operation names (`buildColumn`, `scatterPlot`).
Controls in `B2T2Tests.lean` sit next to each `#check_failure`.
