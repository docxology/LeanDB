# B2T2 head-to-head comparison

**LeanDB trails the TypeScript reference and Rotella's Lean tables on generic
table transformations. Its declared schemas provide useful checks alongside
SQLite storage.** Empirical's published implementation also favors fixed schemas
and has substantial gaps in this benchmark.

The [README](README.md#head-to-head-how-does-leandb-compare) has the quick table.
This page records the evidence behind it. Source review: September 16, 2026.

## Which versions are being compared?

Only LeanDB was executed in our evaluation. The other columns describe published
results and inspected code, not fresh test runs. A feature being implemented does
not establish that every B2T2 constraint is enforced.

| Candidate | Evidence | Version boundary |
|---|---|---|
| LeanDB v0.3.1 | [Tests](B2T2Tests.lean), [inventory](INVENTORY.md), and [recorded run](results/run.log) | Engine `ad8d7f3`; B2T2 v1.2 at `fd227ef` |
| TypeScript reference | [Datasheet][ts-d], [API][ts-api], [programs][ts-p], [errors][ts-e] | Files inspected at B2T2 `fd227ef`; datasheet dated May 28, 2021, targets benchmark `8636f63` |
| Empirical 0.6.9 | [Datasheet][emp-d] and [error transcript][emp-e] | Files inspected at B2T2 `fd227ef`; datasheet dated December 15, 2021, targets benchmark `74c604d` |
| Rotella's Lean tables | [2024 thesis][lt-thesis], [API][lt-api], [programs][lt-p], [errors][lt-e] | Thesis implementation at `7dfa8308e13cb7b15296cc63fa2cbd26c0d0f712` |

These are historical snapshots. Reading an older datasheet from the v1.2 tree
does not turn its results into a v1.2 evaluation. We therefore do not assign the
other implementations a synthetic score out of our 49 API entries or 14 errors.

## The same table operations

Read each column against its linked API, programs, or datasheet. “Implemented”
describes source coverage; limitations follow below.

| Task | [LeanDB](INVENTORY.md) | [TypeScript][ts-api] | [Empirical][emp-d] | [Rotella Lean][lt-api] |
|---|---|---|---|---|
| Filter, sort, and join declared tables | Engine queries; left join is a Lean helper | Table operations implemented | Native `from`, `sort`, and `join`; not every B2T2 join variant | Table operations implemented |
| Store missing cells | `Option` / SQL NULL | `null` | Type-specific sentinels such as `nil` / `nan` | Explicit empty cells |
| Represent sequences and nested tables | JSON codec and child-table encoding | Supported | Both example forms unsupported | Lists and table-valued cells |
| Add, drop, or rename columns generically | New types or specialized projections | Implemented; output types depend on precise column-name types | Missing or partial operations | Implemented; proofs and schema transformations |
| Pivot values into new column names | Unsupported | `pivotWider` implemented | Unsupported | `pivotWider` implemented |
| Group into table-valued cells | Helpers return Lean arrays | Implemented | Unsupported | Implemented |

TypeScript's datasheet reports all API operations as at least partially
expressible, but cannot enforce all size, ordering, and uniqueness constraints.
It also warns that using a general string or a union of names can produce an
incorrect output type. This is broader coverage than our LeanDB port, with
explicit gaps in the guarantees. [TypeScript datasheet][ts-d]

Rotella represents the schema in the table's type and provides proofs for many
API specifications. Its thesis also documents differences: column-name uniqueness
is optional, and sequential renaming/flattening differs from B2T2's semantics.
Broader API coverage is not complete conformance. [Thesis, §§7–8][lt-thesis]

## The same example programs

| Task | [LeanDB](B2T2/Programs.lean) | [TypeScript][ts-p] | [Empirical][emp-d] | [Rotella Lean][lt-p] |
|---|---|---|---|---|
| Dot product of named numeric columns | Typed `Gradebook → Nat` functions; checks 183 | Named columns constrained to numbers; source test expects 183 | Not individually classified as inexpressible; no comparable result established here | Named columns with numeric membership proofs; source test expects 183 |
| Sample rows | Seeded generator; runtime size check and subset assertions | Published example fixes indices to `[2, 1]` | Sampling routines reported missing | Seeded generator; sample count has a bounded type |
| Iterate columns for pHacking | Fixed list of color accessors | Iterates a table header | Both pHacking examples reported inexpressible | Iterates certified schema entries with a Boolean homogeneity proof |
| Select quiz columns by prefix | Explicit `quiz1`–`quiz4` fields | Prefix filtering, followed by a numeric cast | No comparable generic implementation established here | Prefix test plus a proof about the gradebook schema |
| Construct `quizN` column names | Specialized alias of the fixed-field calculation | Constructs strings, then casts to a fixed tuple of names | Listed under unknown expressibility | Constructs names with proofs specialized to four quiz columns |
| Return groups as tables | Arrays; subtractive version lacks a dedicated assertion | Both grouping programs implemented | Both reported inexpressible | Both grouping programs implemented with table-valued results |

Two details prevent an “8/8 versus 0/8” leaderboard:

- **TypeScript's datasheet says all examples are expressible**, while its source
  uses casts for both quiz programs and a fixed answer for the sampling example.
  Those are material qualifications under the standard used for our own port.
  [Datasheet][ts-d], [programs][ts-p]
- **Rotella's quiz examples are also adapted.** The computed-name proof is tied
  to four columns, and its tests use natural-number division, expecting averages
  of 8, 7, and 8. Our port and the TypeScript example check 8.25, 7.25, and 8.0.
  The source demonstrates schema reasoning, but those results are not identical.
  [Rotella programs][lt-p], [LeanDB tests](B2T2Tests.lean), [TypeScript programs][ts-p]

## The same mistakes

“Compile-time” below refers to each implementation's adapted example. LeanDB's
tests exercise field-access analogues of plotting errors; this port does not
implement plots. Rotella uses placeholder plotting signatures in its error file.

| Mistake | [LeanDB](B2T2Tests.lean) | [TypeScript][ts-e] | [Empirical][emp-e] | [Rotella Lean][lt-e] |
|---|---|---|---|---|
| Ask for `mid` instead of `midterm` | Compile-time field error; string helper errors at runtime | Static type diagnostic in the example | Compile-time unknown member | Compile-time schema-membership proof failure |
| Return a string from a filter predicate | Compile-time type mismatch | Static type diagnostic | Compile-time `where` type error | Compile-time type mismatch |
| Read row 1 after filtering to one row | Runtime bounds error | Datasheet reports no detection | Runtime array bounds error | Bounds proof rejects the concrete example |
| Pass the wrong table to the employee helper | General wrong-table predicates rejected; this case only tests a corrected helper | Wrong-table/schema diagnostic | Compile-time unknown field | Schema-membership proof failure |
| Malformed input rows | Typed constructors reject missing/wrong fields | Typed record examples produce diagnostics | CSV examples may skip rows or substitute missing values | Typed row constructors reject invalid shape/types |

LeanDB's **12/14** is a classification of its typed adaptations. TypeScript's
datasheet answer “None” to *prevented from being constructed* is **not a claim of
zero compile-time errors**: its error source explicitly demonstrates static
diagnostics. Empirical's CSV-loading examples also differ from constructing
typed constants. Counts using those different meanings would be misleading.
[LeanDB report](REPORT.md#errors-14), [TypeScript datasheet][ts-d] and
[error source][ts-e], [Empirical transcript][emp-e]

Rotella's bounded row access is a stronger guarantee than our runtime helper.
Its thesis notes that the resulting proof failure can be hard to understand:
stronger enforcement and clearer diagnostics are separate dimensions.
[Thesis, §6.3][lt-thesis]

## What this means for LeanDB

Our interpretation of this evidence:

- **Generic table transformations are the clearest gap.** TypeScript and
  Rotella's library offer operations that currently require new types, fixed
  projections, or unsupported entries in our port.
- **Compile-time field checks are a shared strength.** LeanDB demonstrates useful
  checks, but this evidence does not establish a safety win over every candidate.
  Row-bound proofs are a concrete area where Rotella goes further.
- **LeanDB encodes more of the example data than Empirical's published port**, at
  the cost of custom sequence codecs and child-table representations.
- **SQLite-backed application storage is LeanDB's distinct scope.** Typed
  references, persistence, compare-and-swap updates, and migrations matter there.
  This B2T2 run does not compare those features or database performance.

### Where do pandas and other candidates fit?

pandas provides familiar examples of the flexibility at issue: it can select
columns by a regular expression and pivot cell values into column labels. Those
capabilities are documented in its [filter][pandas-filter] and [pivot][pandas-pivot]
APIs. We have not run a pandas B2T2 port or assigned it a type-safety score here.

The pinned [B2T2 catalog][catalog] also lists Idris2-Table, Dex, Ruby, and an OCaml
branch as work in progress. They are related candidates, but this review does
not establish comparable results for them. Their catalog status describes that
snapshot, not their current development status.

[ts-d]: https://github.com/brownplt/B2T2/blob/fd227efadf532a20aefd25c7a8580978c2d684a2/Media/TypeScript/Datasheet.md
[ts-api]: https://github.com/brownplt/B2T2/blob/fd227efadf532a20aefd25c7a8580978c2d684a2/Media/TypeScript/TableAPI.ts
[ts-p]: https://github.com/brownplt/B2T2/blob/fd227efadf532a20aefd25c7a8580978c2d684a2/Media/TypeScript/ExamplePrograms.ts
[ts-e]: https://github.com/brownplt/B2T2/blob/fd227efadf532a20aefd25c7a8580978c2d684a2/Media/TypeScript/Errors.ts
[emp-d]: https://github.com/brownplt/B2T2/blob/fd227efadf532a20aefd25c7a8580978c2d684a2/Media/Empirical/Datasheet.md
[emp-e]: https://github.com/brownplt/B2T2/blob/fd227efadf532a20aefd25c7a8580978c2d684a2/Media/Empirical/Errors.md
[lt-thesis]: https://cs.brown.edu/media/filer_public/b8/d7/b8d70bb1-9c0e-467f-aec6-aaf42019f169/rotellajoseph.pdf
[lt-api]: https://github.com/jrr6/lean-tables/blob/7dfa8308e13cb7b15296cc63fa2cbd26c0d0f712/Table/API.lean
[lt-p]: https://github.com/jrr6/lean-tables/blob/7dfa8308e13cb7b15296cc63fa2cbd26c0d0f712/Table/ExamplePrograms.lean
[lt-e]: https://github.com/jrr6/lean-tables/blob/7dfa8308e13cb7b15296cc63fa2cbd26c0d0f712/Table/Errors.lean
[pandas-filter]: https://pandas.pydata.org/docs/reference/api/pandas.DataFrame.filter.html
[pandas-pivot]: https://pandas.pydata.org/docs/reference/api/pandas.DataFrame.pivot.html
[catalog]: https://github.com/brownplt/B2T2/blob/fd227efadf532a20aefd25c7a8580978c2d684a2/Media/README.md
