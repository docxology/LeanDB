# B2T2 inventory and coverage matrix

Denominator for all coverage claims. Upstream pin:
[fd227efadf532a20aefd25c7a8580978c2d684a2](https://github.com/brownplt/B2T2/tree/fd227efadf532a20aefd25c7a8580978c2d684a2)
(B2T2 v1.2). LeanDB pin: `ad8d7f3de883176b7de0b6433cb8cd3fc25a8763` (v0.3.1).

Support:

- **direct** — LeanDB type or verb, no helper beyond fixtures
- **extra** — extra Lean on decoded rows or `Entity.spec`
- **specialized** — extra Lean that hardcodes fields or a static header (not the generic program)
- **unsupported** — cannot express the generic operation / table

Enforcement of required constraints:

- **compile** — rejected by Lean / `deriving Entity`
- **runtime** — `Except` / `DbError` when the program is expressible
- **assumed** — caller must uphold; not checked
- **n/a** — operation unsupported, so the constraint is not tested as an API check

Evidence is `B2T2Tests.lean` unless a gap is named.

## Definition (`WhatIsATable.md`)

| ID | Item | Support | Enforcement | Notes |
|---|---|---|---|---|
| def.schema | ordered distinct names + sorts | specialized | compile | Names are Lean fields, not first-class strings |
| def.rect | rectangular cells | direct | compile | Structure rows; arity is the type |
| def.missing | missing cells | direct | runtime decode | `Option` / SQL NULL |
| def.header | header = names without sorts | extra | compile | `Ops.header` reads `Entity.spec` |
| def.colname | column name is a first-class string | unsupported | n/a | `Ops.getValue` is a string boundary only |

## Example tables

| ID | Table | Support | Evidence |
|---|---|---|---|
| tbl.students | `students` | direct | load + cell checks |
| tbl.studentsMissing | `studentsMissing` | direct | Option age/color |
| tbl.employees | `employees` | direct | Williams `none` |
| tbl.departments | `departments` | direct | 4 rows |
| tbl.jellyAnon | `jellyAnon` | direct | 10 bool columns |
| tbl.jellyNamed | `jellyNamed` | direct | name + bools |
| tbl.gradebook | `gradebook` | direct | `«final»` |
| tbl.gradebookMissing | `gradebookMissing` | direct | Option quizzes |
| tbl.gradebookSeq | `gradebookSeq` | extra | JSON `List Nat` codec |
| tbl.gradebookTable | `gradebookTable` | specialized | child table, not table-valued cells |
| tbl.emptyTable | zero-column empty | unsupported | LeanDB always has `id`; entities need columns |
| tbl.dupRows | duplicate value rows | extra | distinct ids; `distinctBy` on values |
| tbl.zeroRows | empty row set | direct | `select` may return `#[]` |

## Table API (49 overloads)

Required/ensured constraints are those in TableAPI.md. Classification is for a *generic* implementation (first-class names, dynamic schema).

| ID | Support | Constraints | SQL / Lean | Evidence / gap |
|---|---|---|---|---|
| api.emptyTable | unsupported | n/a | — | zero-column + no id |
| api.addRows | extra | compile (row type) | SQL `insert` | `Ops.addRows` / seed |
| api.addColumn | specialized | compile on a new entity type | Lean | not generic; new structure |
| api.buildColumn | specialized | compile on a new type | Lean | `quizScoreFilter` |
| api.vcat | extra | compile (same `α`) | Lean | `vcat` test |
| api.hcat | specialized | compile on a pair type | Lean | not a dynamic header concat |
| api.values | extra | compile | SQL `insert` | fixtures |
| api.crossJoin | extra / direct | compile (disjoint types) | Lean product / `select [A,B]` | `crossJoin` 3×4 |
| api.leftJoin | extra | runtime key match | Lean | Williams unmatched |
| api.nrows | extra | n/a | Lean (`COUNT` unused) | fixture sizes |
| api.ncols | extra | n/a | Lean `Entity.spec` | students=3 |
| api.header | extra | n/a | Lean identifiers | `favoriteColor` ≠ `"favorite color"` |
| api.getRow | extra | runtime range | Lean | Alice 0; index 1 errors |
| api.getValue | extra | compile (field) / runtime (string) | Lean | `favoriteColor`; `"mid"` errors |
| api.getColumn.n | extra | runtime range | Lean encode | column 0 = names |
| api.getColumn.c | extra | compile (projector) / runtime (string) | Lean | `getColumn (·.age)` |
| api.selectRows.ns | extra | runtime range | Lean | `[2,0]` → Eve, Bob |
| api.selectRows.bs | extra | runtime length | Lean | mask Alice+Eve |
| api.selectColumns.bs | specialized | compile | Lean | new type; not a mask |
| api.selectColumns.ns | specialized | compile | Lean | field projectors |
| api.selectColumns.cs | specialized | compile | Lean | not computed names |
| api.head | extra | runtime range | Lean | `2` and `-1` |
| api.distinct | extra | n/a | Lean values | `distinctBy` |
| api.dropColumn | specialized | compile | Lean | new type |
| api.dropColumns | specialized | compile | Lean | `dropName` |
| api.tfilter | direct | compile (`Bool`) | SQL+Lean | green students |
| api.tsort | direct | compile (`Ord`) | SQL `SortBy` + Lean | age order |
| api.sortByColumns | extra | compile | Lean / `.andThen` | not string names |
| api.orderBy | extra | compile | `SortBy.key` / `.cmp` | typed keys |
| api.count | extra | compile | Lean | acne 5/5 |
| api.bin | unsupported | n/a | — | no histogram op |
| api.pivotTable | unsupported | n/a | — | dynamic agg schema |
| api.groupBy | extra | assumed | Lean | `groupByRetentive` |
| api.completeCases | extra | compile | Lean | age mask |
| api.dropna | extra | assumed | Lean | Alice only |
| api.fillna | extra | compile | Lean | Bob age 0 |
| api.pivotLonger | unsupported | n/a | — | manufactured name column |
| api.pivotWider | unsupported | n/a | — | names from cell values |
| api.flatten | extra | assumed | Lean | 12 quiz rows |
| api.transformColumn | specialized | compile | Lean | new field type |
| api.renameColumns | specialized | compile | Lean | new field names |
| api.find | extra | runtime | Lean `find?` | unused in suite |
| api.groupByRetentive | extra | compile | Lean arrays | 4 keys |
| api.groupBySubtractive | extra | compile | Lean | implemented; not separately asserted |
| api.update | specialized | compile / runtime CAS | SQL `update` | engine verb ≠ B2T2 row map |
| api.select | specialized | compile | Lean map | not `Row → Row` schema inference |
| api.selectMany | unsupported | n/a | — | nested table project |
| api.groupJoin | extra | assumed | Lean | not in suite |
| api.join | extra / direct | compile | SQL inner `select` + Lean | 5 matches; drops Williams |

**Counts:** 49 ops. Direct or extra with evidence: 27. Specialized (schema-static): 12. Unsupported: 8. Unrun extra (`find`, `groupJoin`): 2, implemented or trivial, marked extra without a dedicated assert.

## Example programs

| ID | Program | Support | Notes |
|---|---|---|---|
| prog.dotProduct | `dotProduct` | specialized | Projectors `Gradebook → Nat`; output 183 |
| prog.sampleRows | `sampleRows` | extra | Fixed LCG seed; subset + `n` invariants, not the spec’s Eve/Alice sample |
| prog.pHackingHomogeneous | `pHacking` | specialized | Static `jellyColors`; Fisher extra Lean; hits `orange` |
| prog.pHackingHeterogeneous | drop name then pHacking | specialized | `dropName` projection, not generic `dropColumns` |
| prog.quizScoreFilter | `startsWith "quiz"` | specialized | Hardcoded quiz1–4; averages 8.25/7.25/8 |
| prog.quizScoreSelect | computed `quizN` names | specialized | Same as filter; does **not** type `concat("quiz", i)` |
| prog.groupByRetentive | user-defined | extra | Lean groups, not table cells |
| prog.groupBySubtractive | user-defined | extra | implemented |

## Errors

| ID | Case | Expressible? | Stage | Diagnostic quality | Control |
|---|---|---|---|---|---|
| err.missingSchema | no schema | prevented | compile | `insert` expects `Student`, not a tuple | typed `insert Student` |
| err.missingRow | empty last row | prevented | compile | missing fields named | full constructor |
| err.missingCell | short row | prevented | compile | `Fields missing: favoriteColor` | full constructor |
| err.swappedColumns | 12 / `"Bob"` | prevented | compile | `OfNat String` / `String` vs `Nat` | valid Student |
| err.schemaTooShort | 2 columns | prevented | compile | missing `favoriteColor` | valid Student |
| err.schemaTooLong | extra field | prevented | compile | `` `extra` is not a field `` | valid Student |
| err.midFinal | `"mid"` | prevented + runtime | compile field / runtime string | `Gradebook.mid` missing; `getValue` quotes `mid` and lists columns | `g.midterm` / `"midterm"` |
| err.blackAndWhite | `"black and white"` | prevented | compile | `blackAndWhite` not a field | `black && white` |
| err.pieCount | wrong count columns | prevented | compile | `CountRow.true` / `.getAcne` missing | `.value` / `.count` |
| err.brownGetAcne | name mismatch | prevented | compile | unknown field | consistent field name |
| err.getOnlyRow | index 1 of 1 | expressible | runtime | `row index 1 not in range(1)` | index 0 |
| err.favoriteColor | String as pred | prevented | compile | `String` vs `Bool` | `== "green"` |
| err.brownJellybeans | `"color"` | prevented | compile | `JellyAnon.color` missing | `j.brown` |
| err.employeeToDepartment | wrong helper | extra | runtime | Williams: no department; Rafferty → Sales | corrected program |

`scatterPlot` / `pieChart` (assumed in Errors.md) are **unsupported** (no Image type). The table-shaped mistakes they wrap are still tested.

## Omissions kept visible

- First-class / computed column names (`quizScoreSelect` generic form).
- Zero-column tables.
- Table-valued cells (`groupByRetentive` as stored `Table` sort).
- `pivotLonger` / `pivotWider` / `pivotTable` / `bin` / `selectMany`.
- B2T2 display names with spaces vs Lean camelCase.
- Sampling uses a local LCG, not the upstream RNG or the printed sample.
