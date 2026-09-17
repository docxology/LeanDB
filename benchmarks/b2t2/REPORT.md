# LeanDB v0.3.1 on B2T2 v1.2

LeanDB's strongest results are checks on known row types: malformed records,
unknown fields, and incorrectly typed predicates are rejected during compilation.
Its largest gaps involve computing column names and changing a table's schema
from data. The [README](README.md) gives a short introduction; this report records
the methods, results, and limits behind that conclusion.

| Evaluation detail | Value |
|---|---|
| LeanDB engine | v0.3.1, `ad8d7f3de883176b7de0b6433cb8cd3fc25a8763` |
| B2T2 | v1.2, `fd227efadf532a20aefd25c7a8580978c2d684a2` |
| Toolchain | Lean 4.33.0, `d8b18978322de05a8f3dba51ef03cf5461676c17` |
| Platform | Darwin arm64 |
| Recorded run | September 14, 2026, 19:09:06 UTC; [log](results/run.log) |
| Reproduction | [Baseline and setup](BASELINE.md) |

The package under `benchmarks/b2t2/` imports the released library and does not edit
`LeanDb/`. The [inventory](INVENTORY.md) supplies the denominator for coverage
claims. A rewrite that hardcodes fields is classified as specialized. Support
classifications, passing example checks, and enforcement of every B2T2 constraint
are separate claims.

## What B2T2 asks

Lu, Greenman, and Krishnamurthi published B2T2 as a language-design benchmark for table types ([Programming 6.2](https://cs.brown.edu/~sk/Publications/Papers/Published/lgk-b2t2/)). It is not a throughput test. The v1.2 suite has a table definition, ten example tables, 49 API overloads with required and ensured constraints, eight example programs, and fourteen error situations taken from student code.

The programs that separate implementations are the ones that treat column names as data: iterate `header(t)`, build `"quiz" ++ i`, or pivot cell values into new headers. The error cases ask whether `"mid"` is refused, and whether the message names the field.

This evaluation scores three things separately: output correctness against the transcribed fixtures and published numbers; where each constraint is enforced (compile, runtime, assumed, or not applicable); and whether a diagnostic names the field, index, or table.

## Method

Each published table is a Lean structure with `deriving LeanDb.Entity`. Fixtures
in [B2T2/Fixtures.lean](B2T2/Fixtures.lean) are transcribed from ExampleTables.md
at the B2T2 pin. Tests check row counts and selected decoded `val` fields, rather
than comparing every cell of every table. LeanDB's generated `Id` is not part of a
B2T2 row; insertion order is recovered by sorting on that ID.

Operations have four support categories:

- *direct*: an engine verb or type does the work (`select`, `SortBy`, `Option`, `insert`).
- *extra*: host Lean on decoded rows or `Entity.spec` (`getRow`, `leftJoin`, `count`).
- *specialized*: extra Lean that names fields or a static header (quiz averages, pHacking over a fixed color list).
- *unsupported*: the generic operation cannot be expressed (`emptyTable`, `pivotWider`, `selectMany`).

[B2T2Tests.lean](B2T2Tests.lean) is the runnable evidence. Negative compilation
checks use `#check_failure`, alongside valid examples; some inventory cases share
a check. `./scripts/run.sh` passed on `ad8d7f3`. Passing means the implemented
assertions succeeded, including expected compilation failures. Unsupported cases
and entries without assertions do not contribute passing tests.

## Findings

### Tables

All ten published example tables are encoded, inserted, and loaded successfully.
The suite checks representative values and reopens the database to confirm that
the three student rows persist.

Missing cells are `Option` columns (SQL NULL): Bob's age, Eve's color, Williams's department, Alice's quiz3. Sequence cells (`gradebookSeq.quizzes`) use a package-local JSON TEXT codec. Nested quizzes (`gradebookTable`) are a child table (`List Quiz` with `deriving LeanDb.Inline`), not a cell whose sort is `Table`.

B2T2 display names with spaces become Lean fields: `"favorite color"` is `favoriteColor`, `"Last Name"` is `lastName`, `final` is `«final»`. That mapping is the main representation gap. A program that computes a column name cannot feed the string into a typed accessor without `Ops.getValue`.

A zero-column table is unsupported. Every entity has an `id` and the fields of its structure. Duplicate column names are unrepresentable (duplicate structure fields). Duplicate *values* are two rows with distinct ids.

### API (49 overloads)

| Classification | Count | Reading |
|---|---|---|
| Direct or extra Lean | 31 | Engine operations, typed adaptations, or helpers over decoded rows |
| Specialized | 12 | Requires known fields, a new Lean type, or a fixed output shape |
| Unsupported | 6 | `emptyTable`, `bin`, `pivotTable`, `pivotLonger`, `pivotWider`, `selectMany` |

These totals count the 49 inventory rows, not independently tested API
implementations. In particular, `find`, `groupJoin`, `groupBySubtractive`, and
`sortByColumns` have no dedicated assertions. Other entries share fixture or
query checks. Helpers may implement only the behavior needed by the fixtures:
for example, `leftJoin` keeps the first matching right row and does not cover
multiple right-side matches.

The suite exercises engine-backed filtering, sorting, and inner joins. Filtering
students by green returns Alice; sorting by age returns Bob, Eve, Alice. Joining
employees to departments returns five rows, dropping Williams, whose department
is missing. The extra-Lean left join keeps all six employees.

The build log also shows that an inline green-student predicate can produce a
`Pred.eq` SQL plan. This is compiler evidence; the suite does not independently
audit SQL pushdown for each runtime query. LeanDB applies the original Lean
predicate to decoded rows as well.

Schema-changing operations (`addColumn`, `buildColumn`, `dropColumns`, `renameColumns`, `hcat`) require a new structure or a Lean pair type. The result you write by hand is checked. B2T2 wants one table value whose header is a function of the input.

### Programs (8)

All eight programs have specialized or extra-Lean adaptations. Seven have direct
runtime assertions; `groupBySubtractive` is implemented but not separately
asserted. None is claimed as a full implementation of the original B2T2
table/column-name interface. Some helpers are generic over Lean row types, but
use typed functions and arrays in place of parts of that interface.

`dotProduct` on `quiz1` and `quiz2` returned 183, the number in ExamplePrograms.md.
Both column arguments have type `Gradebook → Nat`, which guarantees numeric
inputs. The adaptation gets this guarantee from typed field functions; it does
not establish that an arbitrary column name refers to numeric data.

Quiz averages were 8.25, 7.25, and 8.0. The code names `quiz1` through `quiz4`. It does not type `startsWith(c, "quiz")` or `concat("quiz", colNameOfNumber i)`.

pHacking walks a static list of color projectors, runs a two-sided Fisher's exact test in Lean, and reports `orange` (p < 0.05), matching the published line. The loop is not `for c in header(t)`.

`sampleRows` uses a local pseudorandom number generator with a fixed seed. Tests
check the requested sample size, membership in the input, and rejection of a
sample larger than the table. They do not check randomness quality or the
Eve-then-Alice sample in the specification, whose generator is unspecified.

`groupByRetentive` returns Lean arrays keyed by `departmentId` (four keys, including `none`). The groups are not stored nested tables.

### Errors (14)

The inventory classifies twelve of the fourteen error situations as prevented
in their typed adaptations. Two remain expressible: an out-of-range row access
and the incorrect employee-to-department helper. This classification concerns
the adapted representations; it is not a claim that all original buggy programs
were ported unchanged.

Prevented at compile time, each with a control that typechecks:

- Malformed constants: missing field, extra field, swapped `12` / `"Bob"`, untyped tuple passed to `insert`.
- Unknown fields: `g.mid`, `j.blackAndWhite`, `j.color`, `CountRow.true`.
- Wrong predicate type: `favoriteColor` used as a `Bool`.
- Wrong table: `select [Student]` given a `Stored Gradebook` predicate.

Runtime checks:

- `getValue` with `"mid"`: `no such column "mid"; columns: [...]`. The control `"midterm"` succeeds.
- `getRow 1` on the one-row Alice filter: `row index 1 not in range(1)`. Index 0 returns Alice's color.
- `employeeToDepartment "Williams"`: no department. `"Rafferty"` returns `Sales`.

The string lookup is an additional runtime form of the `midFinal` case, which is
already counted as prevented under typed field access. The employee tests exercise
the **corrected** helper and its missing-data behavior. They do not show that Lean
can reject a helper returning the wrong kind of name when both names are strings.

Compiler messages name the Lean field or the `Rows [Student]` type. They do not say `buildColumn` or `scatterPlot`. `scatterPlot` and `pieChart` themselves are unsupported (no `Image`). The column-name mistakes those plots would consume are still refused as missing fields.

## Comparison with other table systems

B2T2's [Media catalog](https://github.com/brownplt/B2T2/blob/fd227efadf532a20aefd25c7a8580978c2d684a2/Media/README.md)
lists TypeScript and Empirical implementations, with other projects in progress.
Being listed does not establish complete conformance. The comparison below is
about design choices, using those projects' documentation and Rotella's thesis;
we did not run a comparative evaluation.

| System | Approach | Relevant tradeoff |
|---|---|---|
| LeanDB v0.3.1 | Lean structures stored in SQLite | Typed fields and predicates work well with declared schemas; computed names and runtime schema changes need a different abstraction. |
| [TypeScript reference](https://github.com/brownplt/B2T2/blob/fd227efadf532a20aefd25c7a8580978c2d684a2/Media/TypeScript/README.md) | Tables with named cells and type-level column information | Supports schema-transforming operations, but documents limitations around duplicate column names and using general strings instead of string-literal types. |
| [Empirical implementation](https://github.com/brownplt/B2T2/blob/fd227efadf532a20aefd25c7a8580978c2d684a2/Media/Empirical/README.md) | A language for data analysis | Documents built-in-only cell types, missing table-management operations, and limited generic higher-order functions. |
| [Rotella's Lean tables](https://cs.brown.edu/media/filer_public/b8/d7/b8d70bb1-9c0e-467f-aec6-aaf42019f169/rotellajoseph.pdf) | Table schemas represented in dependent types | Implements every B2T2 function or a close approximation, with proofs for the specifications it satisfies. Some schema-uniqueness and multi-step operation semantics diverge from B2T2. |

Our interpretation is that Rotella's work demonstrates a route to more flexible,
typed table transformations in Lean. LeanDB's current structure-based model
instead connects declared application types to persistent data. Persistence,
typed references, compare-and-swap updates, and migrations matter to that use
case, but this benchmark does not compare their quality across systems.

The [B2T2 paper](https://cs.brown.edu/people/sk/Publications/Papers/Published/lgk-b2t2/)
draws on established tabular tools to define a shared target. That does not make
this run a head-to-head result against pandas, R, or SQL, nor establish that one
system is the best choice for every kind of table work.

## What this run does not measure

This run does not measure throughput, memory use, planner quality, concurrent
writers, or migration safety. Diagnostic quality has not been evaluated with
people unfamiliar with Lean. Results apply to the recorded release; a later
checkout needs a new run and an updated report. See [BASELINE.md](BASELINE.md)
for how the script records the repository revision.

## Engine work suggested by the gaps

These are proposed improvements, outside the measured v0.3.1 results.

1. A string-boundary `getValue` that suggests `midterm` for `"mid"`.
2. An engine left join. Today's `select [A, B]` is inner.
3. A built-in sequence or JSON column type, so `gradebookSeq` does not need a package-local codec.
4. First-class column symbols that can be computed and then used, if LeanDB ever wants the generic B2T2 programs. That is a dataframe feature, not a small patch.

## Evidence

| File | Contents |
|---|---|
| [INVENTORY.md](INVENTORY.md) | Every upstream case and its classification |
| [REPRESENTATION.md](REPRESENTATION.md) | Name mapping, IDs, missing values, child tables |
| [DATASHEET.md](DATASHEET.md) | Completed upstream template |
| [B2T2Tests.lean](B2T2Tests.lean) | Runnable checks and `#check_failure` controls |
| [B2T2/Ops.lean](B2T2/Ops.lean), [B2T2/Programs.lean](B2T2/Programs.lean) | Extra and specialized Lean |
| [results/run.log](results/run.log) | This run, `engine_sha: ad8d7f3…` |
| [LICENSE-B2T2.txt](LICENSE-B2T2.txt) | Upstream MIT (Brown PLT) |
| [BASELINE.md](BASELINE.md) | Pins and checkout commands |
