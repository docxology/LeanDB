# LeanDB × B2T2

Isolated evaluation of LeanDB **v0.3.1**
(`ad8d7f3de883176b7de0b6433cb8cd3fc25a8763`) against the Brown Benchmark
for Table Types **v1.2**
(`fd227efadf532a20aefd25c7a8580978c2d684a2`).

The engine is not modified. The write-up is [REPORT.md](REPORT.md): pins, scores, comparison with TypeScript, Empirical, pandas, and Rotella's Lean tables.

## Reproduce

From this directory, with [elan](https://github.com/leanprover/elan) installed:

```bash
./scripts/run.sh
```

That writes `results/run.log` including `git rev-parse HEAD` of the
engine tree. First build compiles bundled SQLite.

Manual:

```bash
lake build b2t2_tests
./.lake/build/bin/b2t2_tests
```

Fresh checkout: see [BASELINE.md](BASELINE.md).

## Layout

| Path | Role |
|---|---|
| `PLAN.md` | Evaluation plan and tickets |
| `BASELINE.md` | Pinned revisions |
| `INVENTORY.md` | Every upstream case |
| `REPRESENTATION.md` | How tables are encoded |
| `DATASHEET.md` | Completed B2T2 datasheet |
| `REPORT.md` | Results pinned to `ad8d7f3` |
| `B2T2/` | Entities, fixtures, ops, programs |
| `B2T2Tests.lean` | Suite |
| `LICENSE-B2T2.txt` | Upstream MIT notice |

Example tables and case names are adapted from B2T2 (MIT, Brown PLT).
