# LeanDB v0.1 vertical slice

LeanDB is a typed decision-query prototype written in Lean 4. This repository
implements the first executable slice of [`plan.md`](plan.md): named data
types, composable constraints and objectives, deterministic sorting, Pareto
frontiers, a defined knee selector, and a machine-readable CLI for GPU, hotel,
and restaurant examples.

## Build and test

```bash
lake build
lake build leandb_tests
.lake/build/bin/leandb_tests
```

No third-party package is required beyond Lean 4.31.0. The test executable
covers validation, dominance/Pareto behavior, knee selection, typed filters,
and all three example domains.

## Query interface

Every successful command writes one JSON value to stdout. Typed usage errors
write JSON to stderr and exit with status 2.

```bash
.lake/build/bin/leandb schema

.lake/build/bin/leandb query gpus \
  --min-vram 16 --max-price 1000 --max-power 350 --strategy pareto

.lake/build/bin/leandb query hotels \
  --max-nightly 250 --min-rating 44 --max-distance 20 --strategy knee

.lake/build/bin/leandb query restaurants \
  --cuisine Japanese --max-price-level 3 --min-rating 45 --strategy sorted
```

Strategies:

- `sorted` orders feasible rows by the domain's headline quality metric.
- `pareto` returns rows not dominated across all declared objectives.
- `knee` returns one Pareto row maximizing its worst normalized objective
  utility. Equal scores retain seed order, making output deterministic.

Ratings and distances use exact integer units: ratings are tenths out of 50,
and distances are tenths of a kilometer. Money is stored as cents.

## Code map

```text
LeanDb/Core.lean                 named validated primitives and JSON encoding
LeanDb/Query.lean                constraints, objectives, Pareto, knee, sorting
LeanDb/Examples/*.lean           typed schemas, seeds, and domain queries
LeanDb/Api.lean                  strict machine-readable command surface
Main.lean                        CLI executable
Tests.lean                       executable semantic tests
```

## Scope

This is deliberately a vertical slice, not a claim that the entire product
specification is complete. SQLite persistence, schema derivation, migration
chains, query reification/pushdown, imports, logs/replay, code generation,
transactions, and served multi-user operation remain roadmap work. The sample
rows are currently immutable Lean values so the query semantics can be tested
before persistence is introduced. See [`PLAN_REVIEW.md`](PLAN_REVIEW.md) for
the review decisions and recommended next milestone.
