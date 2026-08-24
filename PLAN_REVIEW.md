# Plan review — 2026-08-23

## Verdict

`plan.md` is a useful interface specification but not yet a directly executable
implementation plan. It spans a type universe, deriving framework, SQLite
adapter, migration synthesizer, importer, planner, runtime, CLI generator,
server, four templates, and test strategy. Building those simultaneously would
hide the highest-risk semantics behind scaffolding.

The repository also does not contain the Architecture document that the plan
normatively references. Those references are therefore context, not acceptance
criteria for this milestone.

## Decisions made for the first slice

1. **Start with the semantic seam.** Implement typed values, constraints,
   objectives, feasibility, dominance, Pareto selection, and one deterministic
   compromise selector before persistence or code generation.
2. **Make “complex satisfiability” concrete.** A request is feasible when every
   named constraint accepts it. Domain constraints compose as conjunctions and
   remain inspectable values.
3. **Define “knee.”** For any number of objectives, normalize each objective's
   Pareto-front utility to `[0, 1_000_000]`, account for minimize/maximize
   direction, and select the row maximizing its worst utility. This is the
   normalized max–min compromise. Constant objectives contribute full utility.
   Ties retain input order.
4. **Use exact storage units.** Money is cents, ratings are integer tenths, and
   distance is tenths of a kilometer. Filters and ranking avoid floating-point
   instability.
5. **Treat the Lean CLI as the primary endpoint.** It provides the complete
   machine-readable request and response surface for this milestone.
6. **Use the three examples requested at the end of the plan.** GPU, hotel, and
   restaurant schemas each provide realistic constraints and competing
   objectives. The tickets template remains later roadmap work.

## Risks found

- The plan calls itself a companion to an absent Architecture v0.14; decisions
  such as row codecs, proof erasure, SQL lowering, and migration laws cannot be
  verified yet.
- “Create the endpoint” is underspecified (local process, HTTP, MCP, or hosted
  service). This slice supplies a JSON process endpoint without prematurely
  committing to distributed runtime semantics.
- Query logging claims replayability of reified predicates, which depends on a
  stable serialization format and vocabulary-version policy not yet specified.
- SQL import and schema adoption are data-affecting features and need fixture
  databases plus golden unsupported-feature reports before implementation.
- The SQLite file is described as an implementation detail, but backup,
  recovery, concurrency, and forward-compatibility guarantees still need
  explicit acceptance tests.

## Recommended next milestone

Introduce SQLite behind the already-tested query semantics:

1. define table and column descriptors for the three example row types;
2. add codecs and round-trip tests for each named primitive;
3. create a versioned local instance with `_leandb_meta`;
4. lower conjunctive constraints and primary sorting to parameterized SQL;
5. compare SQL results against the pure reference interpreter;
6. preserve residual evaluation for objectives that cannot be pushed down.

That milestone should not add migration synthesis or SQL import until the
differential spec-vs-engine suite is green.
