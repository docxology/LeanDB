import Legacy

/-! Legacy tests: the imported base, tightened by hand at V1, carries its
own adopted file forward through the typed migration in
`Legacy/Migrations/V1.lean`, and back. -/

open LeanDb Legacy

private def check (condition : Bool) (message : String) : IO Unit :=
  unless condition do throw <| IO.userError s!"FAIL: {message}"

-- The build is red until the code's schema is the chain's head: edit an
-- entity, `lake build legacy && legacy migrate freeze`, fill the holes.
leandb_check_head Legacy.Migrations.chain Legacy.base.specs

private def fixture : System.FilePath := ".." / "import-fixture" / "legacy.db"
private def dbPath : System.FilePath := ".lake" / "legacy_test.db"

private def code (j : Lean.Json) : String := (j.getObjValAs? String "code").toOption.getD ""

private def sizes : IO (Array (Int64 × String)) := do
  let st ← (← SQLite.open dbPath).prepare "SELECT id, size FROM orders ORDER BY id"
  let mut out := #[]
  repeat
    if ← st.step then out := out.push (← st.columnInt64 0, ← st.columnText 1) else break
  return out

def main : IO UInt32 := do
  -- a raw copy of the imported file: no `_leandb_meta`, V0 columns
  for suffix in ["", "-wal", "-shm"] do
    let f : System.FilePath := dbPath.toString ++ suffix
    if ← f.pathExists then IO.FS.removeFile f
  let backups : System.FilePath := ".lake" / "backups"
  if ← backups.pathExists then IO.FS.removeDirAll backups
  IO.FS.writeBinFile dbPath (← IO.FS.readBinFile fixture)
  let inst := Instance.ofPath dbPath
  let sess ← match ← Cli.Session.open base inst with
    | .ok s => pure s
    | .error e => throw <| IO.userError s!"FAIL: open: {e}"
  -- adopted at the version whose columns it has, not mislabeled as the head
  let v ← base.handle inst sess ["version"]
  check ((v.getObjValAs? Nat "schema_version").toOption == some 0
    && (v.getObjValAs? Bool "in_sync").toOption == some false) s!"adopted at V0: {v}"
  check (code (← base.handle inst sess ["rows", "orders"]) == "schema_mismatch") "gated at V0"
  -- status: one pending migration, its transform provided, three rows, destructive (drops qty)
  let st ← base.handle inst sess ["migrate", "status"]
  check ((st.getObjValAs? String "mode").toOption == some "chain"
    && (st.getObjValAs? Nat "instance_version").toOption == some 0
    && (st.getObjValAs? Nat "head_version").toOption == some 1) s!"status versions: {st}"
  let pending := (st.getObjValAs? (Array Lean.Json) "pending").toOption.getD #[]
  check (pending.size == 1) "one pending migration"
  let steps := (pending[0]!.getObjValAs? (Array Lean.Json) "steps").toOption.getD #[]
  check (steps.any fun s => (s.getObjValAs? String "transform").toOption == some "provided"
      && (s.getObjValAs? Nat "rows").toOption == some 3) s!"transform provided over 3 rows: {steps}"
  check ((pending[0]!.getObjValAs? Bool "destructive").toOption == some true) "dropping qty is destructive"
  check (code (← base.handle inst sess ["migrate", "apply"]) == "migrate") "destructive apply needs the flag"
  -- apply: the transform decides every row's size; a backup precedes it
  let ap ← base.handle inst sess ["migrate", "apply", "--allow-destructive"]
  check ((ap.getObjValAs? Bool "ok").toOption == some true
    && (ap.getObjValAs? Nat "instance_version").toOption == some 1) s!"applied to V1: {ap}"
  let applied := (ap.getObjValAs? (Array Lean.Json) "applied").toOption.getD #[]
  let backup := (applied[0]!.getObjValAs? String "backup").toOption.getD ""
  check (← (System.FilePath.mk backup).pathExists) s!"backup taken: {backup}"
  check ((← sizes) == #[(1, "bulk"), (2, "small"), (3, "bulk")]) s!"sizes decided by the transform: {← sizes}"
  let rows ← base.handle inst sess ["rows", "orders"]
  check ((rows.getObjValAs? Nat "count").toOption == some 3) "typed rows readable at V1"
  let v ← base.handle inst sess ["version"]
  check ((v.getObjValAs? Bool "in_sync").toOption == some true
    && (v.getObjValAs? Nat "schema_version").toOption == some 1) "in sync at V1"
  -- and back: the backup restores V0, gated again, qty intact
  let rb ← base.handle inst sess ["migrate", "rollback"]
  check ((rb.getObjValAs? Nat "schema_version").toOption == some 0) s!"rolled back to V0: {rb}"
  check (code (← base.handle inst sess ["rows", "orders"]) == "schema_mismatch") "gated again at V0"
  let st ← (← SQLite.open dbPath).prepare "SELECT qty FROM orders WHERE id = 3"
  discard <| st.step
  check ((← st.columnInt64 0) == 42) "qty back after rollback"
  -- forward again, without a backup this time
  let ap ← base.handle inst sess ["migrate", "apply", "--allow-destructive", "--no-backup"]
  check ((ap.getObjValAs? Nat "instance_version").toOption == some 1) "re-applied"
  check ((← sizes).size == 3) "rows carried again"
  IO.println "legacy base: all tests passed"
  return 0
