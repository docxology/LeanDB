# Releasing LeanDB

LeanDB uses the version in `lakefile.toml` as its package version. The Lean toolchain and the pinned `leansqlite` revision must move together; every example package must use the same `lean-toolchain` file as the repository root.

Before tagging a release:

1. Add the release date and final notes to `CHANGELOG.md`.
2. Run `./scripts/release_check.sh` from the repository root.
3. Review `git diff --check` and `git status --short`. The release commit should contain only intended source, documentation, and lockfile changes.
4. Confirm that the repository's MIT `LICENSE` file is present and carries the intended copyright holder and year.
5. Commit the release, then create an annotated tag matching the Lake version, for example `v0.2.0`.

The release check builds the engine and importer, runs the engine suite, builds and runs every example suite, builds the generated legacy example, and exercises fresh SQLite import generation plus overwrite refusal.

Bases pulled out of this repository require the engine by git tag
(`leandb new … --leandb-git <url> --rev v0.3.0`); a tag therefore fixes
the engine's `Base`/`Cli`/`Client` surface and the wire (JSON-lines argv,
row JSON, error codes, `X-LeanDb-Fingerprint`). Bump the version in
`lakefile.toml`, in `LeanDb/Mcp.lean`'s `serverInfo`, and in the README's
`--rev` example together.
