# LeanDB evaluation on B2T2

Status: executed. Isolated package, inventory, fixtures, suite, datasheet,
and report are under this directory. Measured engine:
`ad8d7f3de883176b7de0b6433cb8cd3fc25a8763` (v0.3.1). B2T2 pin:
`fd227efadf532a20aefd25c7a8580978c2d684a2` (v1.2). See REPORT.md.

Evaluate LeanDB v0.3.1 against the Brown Benchmark for Table Types (B2T2).
B2T2 evaluates table operations, type constraints, and error feedback.
Its upstream repository currently identifies the benchmark as version 1.2.

Sources:

- [B2T2 repository](https://github.com/brownplt/B2T2)
- [Table definition](https://github.com/brownplt/B2T2/blob/main/WhatIsATable.md)
- [Example tables](https://github.com/brownplt/B2T2/blob/main/ExampleTables.md)
- [Table API](https://github.com/brownplt/B2T2/blob/main/TableAPI.md)
- [Example programs](https://github.com/brownplt/B2T2/blob/main/ExamplePrograms.md)
- [Error cases](https://github.com/brownplt/B2T2/blob/main/Errors.md)
- [Datasheet template](https://github.com/brownplt/B2T2/blob/main/Datasheet.md)

## Scope

Use an isolated package under `benchmarks/b2t2/`. Test the released engine
before proposing changes to it. Keep engine improvements in separate work.

Record every upstream case, including unsupported cases. Distinguish direct
LeanDB support from operations implemented with extra Lean code. For each
constraint, record whether it is enforced during compilation, checked at
runtime, assumed by the programmer, or not enforced.

Preserve the benchmark's semantics and the generality of its programs.
Hardcoding sample answers or a fixed list of columns does not demonstrate
support for a program that computes column names. Correct sample output
and enforcement of the program's typing constraints are separate results.

Record which work runs in SQL and which runs on decoded rows in Lean.
The evaluation focuses on correctness and expressiveness. It does not
claim an engine throughput score.

## 1. Pin the baseline

- Resolve LeanDB v0.3.1 to its commit and pin it as the package dependency.
- Choose and record the exact B2T2 commit for version 1.2.
- Record the Lean toolchain, dependency revisions, and local environment.
- Provide setup commands that work from a fresh checkout.
- Preserve upstream attribution and check its license before copying fixtures.

Done when the baseline is reproducible and all source references identify
the pinned revision.

## 2. Map the full benchmark

- Inventory the table definition, example tables, API operations and overloads,
  example programs, and error cases.
- Give each case a stable ID and a source reference.
- List each operation's required and ensured constraints.
- Classify support as direct, extra Lean code, or unsupported. Mark tentative
  classifications as unverified until there is evidence.
- Keep omissions and semantic differences visible in the matrix.

Done when every upstream item is accounted for. The matrix defines the
denominator for coverage reports.

## 3. Define faithful table representations

- Encode the upstream sample tables as fixtures.
- Document missing values, duplicate rows, row and column order, empty tables,
  zero-column tables, sequences, and nested tables.
- Explain how LeanDB row IDs relate to the benchmark's row values and positions.
- Record normalization, codec choices, and any representation gaps.
- Test fixture loading and decoding where representable. Check ordered rows,
  values, and missing cells against the source fixtures.

Done when fixtures have independent expected values and every representation
choice or limitation is documented.

## 4. Build the runnable operations and programs

- Add the isolated Lake package and a command to run its tests.
- Start with loading, field access, filtering, and joins.
- Attempt the remaining API operations and example programs from the inventory.
- Include numeric column calculations and computed column names.
- Preserve generic inputs and constraints. Label specialized adaptations clearly.
- Compare outputs with the upstream examples. Use independent expected results
  or a reference implementation when the examples do not fully specify an output.
- Test meaningful edge cases. Use fixed seeds and invariant checks for sampling.
- Record SQL execution, Lean processing, helper code, failures, and unsupported cases.

Done when each inventory item has runnable evidence or an explicit gap entry.
Successful tests must distinguish behavioral correctness from type guarantees.

## 5. Test type errors and runtime validation

- Port upstream error cases to the available operations.
- Add compilation tests for rejected programs and capture the diagnostics.
- Pair negative cases with valid controls so missing imports or unrelated
  compilation failures cannot count as successful rejection.
- Exercise runtime validation where the relevant check happens during execution.
- Record errors that are accepted, detected late, or cannot yet be expressed.
- Assess whether each diagnostic identifies the relevant operation or field.

Done when each required constraint and error case has a recorded enforcement
stage and evidence, or a clear explanation of why it is untested.

## 6. Produce the report and datasheet

- Run the suite from a clean setup using the pinned baseline.
- Save results and logs with the tested revisions and reproduction commands.
- Summarize coverage using the full inventory, including unsupported items.
- Report output correctness, constraint enforcement, and diagnostic quality separately.
- Complete the upstream datasheet and document helper code and adaptations.
- List proposed engine improvements separately from measured baseline results.

Done when one command reproduces the evaluation and the report links every
claim to a test, diagnostic, or documented limitation.

## Order and deliverables

Step 1 pins the baseline. Step 2 inventories that revision. Step 3 uses both
to define the fixtures. Step 4 implements the operations and programs.
Step 5 checks their errors and constraints. Step 6 combines the evidence.

Deliver an isolated test package, a coverage matrix, recorded results, a
completed datasheet, and a concise report under `benchmarks/b2t2/`.

## Tickets

1. [#10: Pin the benchmark and LeanDB baseline](https://github.com/theoriclabs/LeanDB/issues/10)
2. [#11: Inventory benchmark cases and constraints](https://github.com/theoriclabs/LeanDB/issues/11)
3. [#12: Define table representations and fixtures](https://github.com/theoriclabs/LeanDB/issues/12)
4. [#13: Implement operation and example program tests](https://github.com/theoriclabs/LeanDB/issues/13)
5. [#14: Test type errors and runtime validation](https://github.com/theoriclabs/LeanDB/issues/14)
6. [#15: Publish the evaluation report and datasheet](https://github.com/theoriclabs/LeanDB/issues/15)
