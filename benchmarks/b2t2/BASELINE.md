# Pinned baseline

Evaluation of **LeanDB v0.3.1** against **B2T2 v1.2**.
No engine changes are in scope; this package only imports the released library.

## Revisions

| Artifact | Version | Pin |
|---|---|---|
| LeanDB engine | v0.3.1 | `ad8d7f3de883176b7de0b6433cb8cd3fc25a8763` |
| B2T2 benchmark | v1.2 tag | `fd227efadf532a20aefd25c7a8580978c2d684a2` |
| Lean toolchain | Lean 4 | `leanprover/lean4:v4.33.0` |
| leansqlite | Lakefile pin | `0be4df908d1a8e75b58961041e2b4973692623df` |

LeanDB v0.3.1 is commit `ad8d7f3` (`Complete documentation and release v0.3.1`).
The package depends on it via `path = "../.."` while this repository is at
that commit, or any later commit that does not change `LeanDb/` relative to
it. The report records the exact `git rev-parse HEAD` of the tree that
was measured.

B2T2 v1.2 is the annotated tag `v1.2`. `main` later moved to
`eeebf5db7a5c1dbf1893b622ff7fffd63d5c3286` (a `selectMany` signature typo
fix in `TableAPI.md`). This evaluation does not use that later commit.

Upstream sources at the pin:

- https://github.com/brownplt/B2T2/tree/fd227efadf532a20aefd25c7a8580978c2d684a2
- [WhatIsATable.md](https://github.com/brownplt/B2T2/blob/fd227efadf532a20aefd25c7a8580978c2d684a2/WhatIsATable.md)
- [ExampleTables.md](https://github.com/brownplt/B2T2/blob/fd227efadf532a20aefd25c7a8580978c2d684a2/ExampleTables.md)
- [TableAPI.md](https://github.com/brownplt/B2T2/blob/fd227efadf532a20aefd25c7a8580978c2d684a2/TableAPI.md)
- [ExamplePrograms.md](https://github.com/brownplt/B2T2/blob/fd227efadf532a20aefd25c7a8580978c2d684a2/ExamplePrograms.md)
- [Errors.md](https://github.com/brownplt/B2T2/blob/fd227efadf532a20aefd25c7a8580978c2d684a2/Errors.md)
- [Datasheet.md](https://github.com/brownplt/B2T2/blob/fd227efadf532a20aefd25c7a8580978c2d684a2/Datasheet.md)

## License

B2T2 is MIT (Copyright 2022 Brown University PLT). Attribution and the
license text are in `LICENSE-B2T2.txt`. Fixtures and case names are
adapted from that pin; they are not copied as a git submodule.

## Setup from a fresh checkout

```bash
git clone https://github.com/theoriclabs/LeanDB.git leandb
cd leandb
# engine pin (v0.3.1):
git checkout ad8d7f3de883176b7de0b6433cb8cd3fc25a8763
# then use the benchmarks/b2t2 tree from the evaluation commit
cd benchmarks/b2t2
./scripts/run.sh
```

The first `lake build` compiles bundled SQLite (several minutes).

One-command reproduction from this directory: `./scripts/run.sh`.
That command writes `results/run.log` with the measured engine SHA.
