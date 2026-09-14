# LeanDB v0.3.1 on B2T2 v1.2

Measured engine: `ad8d7f3de883176b7de0b6433cb8cd3fc25a8763` (tag v0.3.1).  
B2T2: `fd227efadf532a20aefd25c7a8580978c2d684a2` (tag v1.2).  
Lean 4.33.0 (`d8b18978322de05a8f3dba51ef03cf5461676c17`), Darwin arm64.  
Run: 2026-09-14T19:09:06Z. Log: `results/run.log`.  
Reproduce: `cd benchmarks/b2t2 && ./scripts/run.sh`.

The package under `benchmarks/b2t2/` imports the released library and does not edit `LeanDb/`. Every coverage claim uses the inventory in `INVENTORY.md` as the denominator. A specialized rewrite that hardcodes fields is recorded as specialized, not as support for the generic program.

## What B2T2 asks

Lu, Greenman, and Krishnamurthi published B2T2 as a language-design benchmark for table types ([Programming 6.2](https://cs.brown.edu/~sk/Publications/Papers/Published/lgk-b2t2/)). It is not a throughput test. The v1.2 suite has a table definition, ten example tables, 49 API overloads with required and ensured constraints, eight example programs, and fourteen error situations taken from student code.

The programs that separate implementations are the ones that treat column names as data: iterate `header(t)`, build `"quiz" ++ i`, or pivot cell values into new headers. The error cases ask whether `"mid"` is refused, and whether the message names the field.

This evaluation scores three things separately: output correctness against the transcribed fixtures and published numbers; where each constraint is enforced (compile, runtime, assumed, or not applicable); and whether a diagnostic names the field, index, or table.

## Method

Each published table is a Lean structure with `deriving LeanDb.Entity`. Fixtures in `B2T2/Fixtures.lean` match ExampleTables.md at the B2T2 pin. Tests compare decoded `val` fields. LeanDB's surrogate `Id` is not part of a B2T2 row; insertion order is recovered with `SortBy .key (·.id)`.

Operations fall into four bins:

- *direct*: an engine verb or type does the work (`select`, `SortBy`, `Option`, `insert`).
- *extra*: host Lean on decoded rows or `Entity.spec` (`getRow`, `leftJoin`, `count`).
- *specialized*: extra Lean that names fields or a static header (quiz averages, pHacking over a fixed color list).
- *unsupported*: the generic operation cannot be expressed (`emptyTable`, `pivotWider`, `selectMany`).

`B2T2Tests.lean` is the evidence. Each `#check_failure` sits next to a valid control so a missing import cannot count as a rejection. `./scripts/run.sh` passed on `ad8d7f3`.

## Findings

### Tables

All ten published example tables load and round-trip.

Missing cells are `Option` columns (SQL NULL): Bob's age, Eve's color, Williams's department, Alice's quiz3. Sequence cells (`gradebookSeq.quizzes`) use a package-local JSON TEXT codec. Nested quizzes (`gradebookTable`) are a child table (`List Quiz` with `deriving LeanDb.Inline`), not a cell whose sort is `Table`.

B2T2 display names with spaces become Lean fields: `"favorite color"` is `favoriteColor`, `"Last Name"` is `lastName`, `final` is `«final»`. That mapping is the main representation gap. A program that computes a column name cannot feed the string into a typed accessor without `Ops.getValue`.

A zero-column table is unsupported. Every entity has an `id` and the fields of its structure. Duplicate column names are unrepresentable (duplicate structure fields). Duplicate *values* are two rows with distinct ids.

### API (49 overloads)

| Bin | Count | Reading |
|---|---|---|
| Direct or extra, with a test | 27 | Same-schema algebra |
| Specialized | 12 | New Lean type, not a runtime schema change |
| Unsupported | 8 | `emptyTable`, `bin`, `pivotTable`, `pivotLonger`, `pivotWider`, `selectMany`, and the generic forms of nested-table projectors that require those |
| Extra, no dedicated assert | 2 | `find`, `groupJoin` |

Same-schema work is where LeanDB is a database. `select [Student] (fun r => r.val.favoriteColor == "green")` is an engine query: `leandb_plan` emitted `Pred.eq` on `Student.Field.favoriteColor`, SQLite ran the plan, and `finishRows` still applied the Lean predicate. Age sort used `SortBy .key (·.val.age)` and returned Bob, Eve, Alice. `select [Employee, Department]` with a key equality is an inner join (five rows; Williams is dropped). The left join that keeps Williams is extra Lean.

Schema-changing operations (`addColumn`, `buildColumn`, `dropColumns`, `renameColumns`, `hcat`) require a new structure or a Lean pair type. The result you write by hand is checked. B2T2 wants one table value whose header is a function of the input.

### Programs (8)

None of the eight example programs are supported in their generic form. All eight have a specialized or extra-Lean stand-in with a check.

`dotProduct` on `quiz1` and `quiz2` returned 183, the number in ExamplePrograms.md. Both arguments are `Gradebook → Nat`, so both columns are numeric by construction. That is tighter than a `ColName` that the type system hopes is numeric.

Quiz averages were 8.25, 7.25, and 8.0. The code names `quiz1` through `quiz4`. It does not type `startsWith(c, "quiz")` or `concat("quiz", colNameOfNumber i)`.

pHacking walks a static list of color projectors, runs a two-sided Fisher's exact test in Lean, and reports `orange` (p < 0.05), matching the published line. The loop is not `for c in header(t)`.

`sampleRows` uses a local LCG. Tests check `n ≤ nrows` and that the sample is a subset of the input. They do not check the Eve-then-Alice sample in the spec, which depends on an unspecified RNG.

`groupByRetentive` returns Lean arrays keyed by `departmentId` (four keys, including `none`). The groups are not stored nested tables.

### Errors (14)

Twelve of the fourteen buggy programs cannot be constructed. Two are expressible and fail at runtime.

Prevented at compile time, each with a control that typechecks:

- Malformed constants: missing field, extra field, swapped `12` / `"Bob"`, untyped tuple passed to `insert`.
- Unknown fields: `g.mid`, `j.blackAndWhite`, `j.color`, `CountRow.true`.
- Wrong predicate sort: `favoriteColor` used as a `Bool`.
- Wrong table: `select [Student]` given a `Stored Gradebook` predicate.

Runtime:

- `getValue` with `"mid"`: `no such column "mid"; columns: [...]`. The control `"midterm"` succeeds.
- `getRow 1` on the one-row Alice filter: `row index 1 not in range(1)`. Index 0 returns Alice's color.
- `employeeToDepartment "Williams"`: no department. `"Rafferty"` returns `Sales`.

Compiler messages name the Lean field or the `Rows [Student]` type. They do not say `buildColumn` or `scatterPlot`. `scatterPlot` and `pieChart` themselves are unsupported (no `Image`). The column-name mistakes those plots would consume are still refused as missing fields.

## Comparison

B2T2's own [Media catalog](https://github.com/brownplt/B2T2/blob/fd227efadf532a20aefd25c7a8580978c2d684a2/Media/README.md) lists a TypeScript reference and Empirical as complete implementations. In-progress or related work includes Idris2-Table, Dex, an OCaml branch, and Joseph Rotella's 2024 Brown thesis, *Dependently Typed Tables*, a Lean dataframe library verified against B2T2. The numbers below for TypeScript and Empirical are those projects' datasheets, not a re-run. TypeScript's datasheet is more generous than this report: "partially expressible" still counts.

| | LeanDB v0.3.1 | TypeScript reference | Empirical 0.6.9 | pandas / R / SQL | Rotella Lean tables |
|---|---|---|---|---|---|
| Kind | Typed SQL, SQLite | In-memory tables, `keyof` | Dataframe language | Dynamic table APIs | Dependently typed dataframe |
| Ten example tables | All, with name/id/encoding gaps | All, as specified | No sequences or nested cells | All | All, B2T2-shaped |
| Generic schema-changing API | Weak | Almost all ops, many partial | Many ops absent | Complete | Nearly complete, with proofs |
| Generic example programs | 0 / 8 | Claims all; some casts | Several inexpressible | Run; types do not help | Close to TypeScript |
| Errors prevented | 12 / 14 | 0 / 14 | Several (static identifiers) | Almost none | Aimed at prevention |
| Column names | Lean fields | First-class strings | Identifiers | Strings | Strings plus schema proofs |
| Persistence | File, `Id`, CAS, FKs | None | Mutable cells, fixed schema | Varies | In-memory |

TypeScript is the B2T2-shaped system. A table is a header plus maps from names to cells. `addColumn` and `pivotWider` exist. `"favorite color"` stays a string. The datasheet is explicit that *no* error situation is prevented: `"mid"` is some column name and fails later; `getOnlyRow` is undetectable; `swappedColumns` cannot even be stated, because cells are keyed by name rather than position. Output types break if a `ColName` is `string` instead of a string literal. Feedback is often long and does not suggest `midterm`.

Empirical is the closer relative. Column names are identifiers (`Department ID` becomes `department_id`). The schema does not change at runtime. Their datasheet already rules out pHacking (no `header` as data), nested tables, and a long list of API operations. LeanDB encodes more of the example tables (JSON lists, child quizzes) and implements more same-schema helpers. Empirical is a dataframe language (`from`, `join`, vector expressions). LeanDB is a database.

pandas, R, and SQL are the sources B2T2 was mined from. They implement the API and the example programs. `"mid"` is an empty plot or a runtime exception. Raw SQL is LeanDB's backend; without the Lean layer you get the same empty-result failure the rest of this repository is written to refuse.

Rotella's library is the Lean work that *is* a B2T2 table type: schema as type-level data, `tsort students "age" true` with a synthesized proof that `age` is numeric, `pivotWider`, action lists, and proofs of most API constraints. On this benchmark that library wins. LeanDB would win on persist, `Ref`, compare-and-swap `update`, and migrations. Scoring LeanDB as a dataframe makes it look unfinished. Scoring the dataframe as a database does the same in reverse.

## What this run does not measure

Throughput, memory, or planner quality. Multi-writer behavior. How good a diagnostic is for someone who does not already know Lean. Whether a later LeanDB commit still matches these numbers (re-run `./scripts/run.sh` and compare `engine_sha` in the log).

## Engine work suggested by the gaps

These items are not part of the v0.3.1 score.

1. A string-boundary `getValue` that suggests `midterm` for `"mid"`.
2. An engine left join. Today's `select [A, B]` is inner.
3. A built-in sequence or JSON column sort, so `gradebookSeq` does not need a package-local codec.
4. First-class column symbols that can be computed and then used, if LeanDB ever wants the generic B2T2 programs. That is a dataframe feature, not a small patch.

## Evidence

| File | Contents |
|---|---|
| `INVENTORY.md` | Every upstream case and its bin |
| `REPRESENTATION.md` | Name mapping, ids, missing values, child tables |
| `DATASHEET.md` | Completed upstream template |
| `B2T2Tests.lean` | Runnable checks and `#check_failure` controls |
| `B2T2/Ops.lean`, `B2T2/Programs.lean` | Extra and specialized Lean |
| `results/run.log` | This run, `engine_sha: ad8d7f3…` |
| `LICENSE-B2T2.txt` | Upstream MIT (Brown PLT) |
| `BASELINE.md` | Pins and checkout commands |
