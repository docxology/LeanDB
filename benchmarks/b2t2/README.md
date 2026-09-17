# LeanDB on B2T2

## TL;DR

**LeanDB provides useful compile-time checks for tables with known schemas. Its
biggest gap is working with tables whose columns are computed at runtime.**

In our evaluation of **LeanDB v0.3.1** against **B2T2 v1.2**:

- All **10 example datasets** can be stored and read back, with some encoding changes.
- **12 of 14 error situations** are prevented in their typed Lean adaptations.
  The other two remain expressible and need runtime checks or application logic.
- The API has a mix of engine support, extra Lean helpers, and substantial gaps.
  The example programs need adaptations; matching their sample output does not
  mean supporting their full interface.

This is evidence about **what you can express and which mistakes types catch**.
It gives no query-speed or throughput score. The recorded run passed on
September 14, 2026; the [report](REPORT.md) explains the evidence and limitations.

## What is B2T2?

B2T2 is the **Brown Benchmark for Table Types**, created by Kuang-Chen Lu,
Ben Greenman, and Shriram Krishnamurthi. It gives languages and libraries a common
set of table operations, programs, and mistakes to evaluate. The aim is to make
claims about “typed tables” concrete and comparable.
See the [paper](https://cs.brown.edu/people/sk/Publications/Papers/Published/lgk-b2t2/)
and [upstream benchmark](https://github.com/brownplt/B2T2/tree/fd227efadf532a20aefd25c7a8580978c2d684a2).

The examples look like ordinary data work: student records, employee departments,
gradebooks, filtering, joining, grouping, and calculating averages. Some ask harder
questions: can a program discover every column beginning with `quiz`, establish
that those columns contain numbers, and calculate an average safely?

This evaluation inventories **10 example tables, 49 API operations and overloads,
8 example programs, and 14 error situations**. It examines three separate things:

1. **Correctness:** does the adapted program produce the expected result?
2. **Expressiveness:** can it handle the general operation, or just a known schema?
3. **Error handling:** when is a mistake caught, and does the message help locate it?

## How are we doing?

| Area | Result | How to read it |
|---|---|---|
| Example data | **10 / 10 encoded and loaded** | Missing values work. Sequences use a local JSON codec; nested tables become child tables. Column names and row identity also need adaptation. |
| Table API | **31 direct/helper adaptations, 12 schema-specific adaptations, 6 unsupported** | These classify the 49 inventory entries. Many run in Lean after fetching rows; they are not 43 built-in database operations or 43 fully verified implementations. |
| Example programs | **8 adaptations; 0 / 8 claimed in the original B2T2 interface** | Typed field access and Lean arrays replace parts of the table/column-name API. Seven adaptations have runtime assertions; subtractive grouping is implemented without its own assertion. |
| Error situations | **12 / 14 prevented in typed form; 2 remain expressible** | Structures reject missing or wrong fields and incorrect cell types. Row bounds need runtime checks; types alone do not identify an incorrect lookup helper. |

The [coverage matrix](INVENTORY.md) lists every case. These counts describe our
port and its limitations; they are not an overall B2T2 pass percentage.

### Where the types help

A gradebook has a `midterm` field. Accidentally asking for `mid` fails during
compilation:

```lean
import B2T2

open B2T2

#check fun (g : Gradebook) => g.midterm
#check_failure fun (g : Gradebook) => g.mid
```

The suite also checks that a string cannot be used as a filter's Boolean result,
and that a query for students cannot receive a predicate for gradebook rows.
These checks help when application code and database schemas evolve: a stale
typed field reference becomes a compiler error.

The guarantee depends on using the typed interface. The evaluation's helper for
looking up a column by a string accepts `"mid"` as input, then returns an error
listing the available columns at runtime. Plotting itself is outside this port;
for B2T2's plotting errors, we test the invalid field access the plot would use.

### Where the flexibility runs out

The quiz-average adaptation explicitly reads `quiz1`, `quiz2`, `quiz3`, and
`quiz4`. It returns the expected **8.25, 7.25, and 8.0**. B2T2 also asks for a
program that discovers or constructs the quiz column names. Adding `quiz5`
would require changing our adaptation; it would not be picked up automatically.

Similarly, filtering, sorting, and inner joins have engine support, while adding
or renaming columns generally requires declaring a new Lean type. Operations such
as `pivotWider`, which turns cell values into new column names, remain unsupported
in this evaluation. See the [representation notes](REPRESENTATION.md) for the
underlying choices.

## Head-to-head: how does LeanDB compare?

**TypeScript and Rotella's Lean tables cover more of B2T2's schema-changing
operations. LeanDB combines checks on declared schemas with SQLite persistence.**
Empirical shares more of LeanDB's restrictions on dynamic column names, and its
published port cannot represent sequence or nested-table cells.

This compares our **v0.3.1 run** with the **published TypeScript reference,
Empirical 0.6.9, and Rotella's 2024 thesis implementation**. The other candidates
were reviewed through their datasheets and source, not re-run. Their reports use
different benchmark revisions, so the cells describe capabilities rather than a
common pass rate.

| Capability | LeanDB v0.3.1 | TypeScript reference | Empirical 0.6.9 | Rotella's Lean tables |
|---|---|---|---|---|
| Represent example data | All 10, with encodings | All, per datasheet | No sequence/nested cells | Sequence/nested cells supported |
| Add, drop, or rename columns generically | Requires a new type or specialized projection | Implemented; some constraints escape types | Limited; schema changes missing | Implemented with schema proofs; some semantic differences |
| `pivotLonger` / `pivotWider` | Unsupported | Implemented | Unsupported | Implemented |
| Discover quiz columns by name | Hardcoded fields | Name filtering plus casts | Limited; computed-name example not established | Prefix proofs; quiz examples still specialized |
| Reject an unknown field / string filter | Compile-time with typed access | Compile-time diagnostics | Compile-time diagnostics | Compile-time type/proof checks |
| Reject row 1 of a one-row result | Runtime bounds check | Datasheet reports no detection | Runtime array bounds check | Bounds proof rejects the example |
| Sampling example | Seeded generator; size and membership checked | Example hardcodes row indices | Reported unavailable | Seeded generator; size bounded by type |

Sources and qualifications: [TypeScript datasheet][ts-datasheet] and
[programs][ts-programs], [Empirical datasheet][emp-datasheet] and
[errors][emp-errors], [Rotella's thesis][rotella-thesis] and
[programs][rotella-programs]. The [detailed comparison](COMPARISON.md) links the
individual APIs and error cases, explains the different scoring conventions,
and includes pandas as a familiar reference point.

Our reading: **LeanDB has substantial ground to cover on generic table
transformations.** Its error checks are useful, but compile-time field checks
are also present in the other typed candidates. Rotella's library goes further
on row-bound proofs. LeanDB's persistence, references, and migrations address
application storage; this evaluation does not rank those features against the
other systems.

## Why this matters for LeanDB

LeanDB's promise is to connect Lean types to stored SQL data. B2T2 tests that
promise against examples chosen outside this project, including awkward cases
that a short demo can easily miss.

For applications with declared tables—tickets, customers, orders—the results
give concrete examples of the checks that typed queries provide. For exploratory
data analysis with columns discovered from input data, the gaps are substantial.
Supporting those programs would require a more flexible table abstraction.

The findings also suggest practical improvements: clearer errors for string-based
column lookup, an engine left join, and built-in sequence storage. Supporting
computed column names is a larger design decision. These are proposals, not
features included in the measured release.

B2T2 does not assess LeanDB's overall database suitability: this run does not
measure throughput, memory use, planner quality, concurrent writers, or migration
safety. The [report's comparison](REPORT.md#comparison-with-other-table-systems)
puts the results alongside other approaches to typed tables.

## Run it yourself

Install [elan](https://github.com/leanprover/elan), then run from the repository root:

```bash
cd benchmarks/b2t2
./scripts/run.sh
```

The first build compiles bundled SQLite and can take several minutes. A successful
run ends with:

```text
b2t2: fixture, operation, program, and error tests passed
```

This means the implemented checks passed, including expected compilation failures.
Unsupported operations are recorded in the inventory, not exercised by that command.

The script **overwrites `results/run.log`** and records the current repository
revision. The package uses the engine in this checkout, so a later checkout may
produce different results. For a fresh checkout of the evaluated code, use the
[baseline instructions](BASELINE.md#setup-from-a-fresh-checkout).

## Go deeper

| File | Read it for |
|---|---|
| [Report](REPORT.md) | Detailed results, comparisons, and limits of the evidence |
| [Head-to-head comparison](COMPARISON.md) | The same capabilities and error cases across four candidates |
| [Coverage matrix](INVENTORY.md) | The status of every benchmark case |
| [Table representations](REPRESENTATION.md) | Column names, missing values, row IDs, sequences, and child tables |
| [Datasheet](DATASHEET.md) | Answers in B2T2's standard reporting format |
| [Baseline](BASELINE.md) | Exact versions and reproduction instructions |
| [Tests](B2T2Tests.lean) and [implementation](B2T2/) | The runnable evidence and helper code |
| [Recorded log](results/run.log) | The original build, diagnostics, and test result |
| [Evaluation plan](PLAN.md) | Scope and original work items |

Example tables and case names are adapted from B2T2, copyright Brown University
PLT, under the [MIT license](LICENSE-B2T2.txt).

[ts-datasheet]: https://github.com/brownplt/B2T2/blob/fd227efadf532a20aefd25c7a8580978c2d684a2/Media/TypeScript/Datasheet.md
[ts-programs]: https://github.com/brownplt/B2T2/blob/fd227efadf532a20aefd25c7a8580978c2d684a2/Media/TypeScript/ExamplePrograms.ts
[emp-datasheet]: https://github.com/brownplt/B2T2/blob/fd227efadf532a20aefd25c7a8580978c2d684a2/Media/Empirical/Datasheet.md
[emp-errors]: https://github.com/brownplt/B2T2/blob/fd227efadf532a20aefd25c7a8580978c2d684a2/Media/Empirical/Errors.md
[rotella-thesis]: https://cs.brown.edu/media/filer_public/b8/d7/b8d70bb1-9c0e-467f-aec6-aaf42019f169/rotellajoseph.pdf
[rotella-programs]: https://github.com/jrr6/lean-tables/blob/7dfa8308e13cb7b15296cc63fa2cbd26c0d0f712/Table/ExamplePrograms.lean
