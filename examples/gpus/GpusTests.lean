import Gpus

/-! Tests for the gpus base: seed through smart constructors, assert on
each query, exercise CAS + `.stale`, FK `.restricted`, and check that the
type system rejects wrong-world programs (`#check_failure`). -/

open LeanDb Gpus

private def check (condition : Bool) (message : String) : IO Unit :=
  unless condition do throw <| IO.userError s!"FAIL: {message}"

private def checkD (condition : Bool) (message : String) : DbM Unit :=
  unless condition do throw (.sqlite s!"FAIL: {message}")

private def expectOk (r : Except DbError α) (context : String) : IO α :=
  match r with
  | .ok a => pure a
  | .error e => throw <| IO.userError s!"FAIL: {context}: {e}"

private def expectErr (r : Except DbError α) (code : String) (context : String) : IO Unit :=
  match r with
  | .ok _ => throw <| IO.userError s!"FAIL: {context}: expected [{code}], got success"
  | .error e =>
      unless e.code == code do
        throw <| IO.userError s!"FAIL: {context}: expected [{code}], got {e}"

private def dbPath : System.FilePath := ".lake" / "gpus_test.sqlite"

/-! ## Negative compile checks -/

-- The flagship demo: chips live in a closed world, not a table. There is
-- no `chip` table, no `Id Chip` row, nothing to delete — so "remove the
-- h100 from the catalog" is not a query that can lose data at 2am; it is
-- a program that does not typecheck.
#check_failure LeanDb.delete (α := Chip) ⟨1⟩

-- Same closed world on the way in: you cannot insert a chip either.
#check_failure insert Chip Chip.h100

-- A predicate over the wrong table does not typecheck: `select [Provider]`
-- forces `Stored Provider → Bool`.
#check_failure select [Provider] (fun (o : Stored Offering) => o.val.available)

/-! ## Runtime tests -/

private def prices (os : Array (Stored Offering)) : Array Nat :=
  os.map (·.val.hourly.tenthsOfCent)

private def runQueries : DbM (Stored Provider × Stored Offering) := do
  seed
  -- fetchAll: everything landed
  checkD ((← fetchAll Provider).size == 4) "four providers seeded"
  checkD ((← fetchAll Offering).size == 12) "twelve offerings seeded"
  let some hotaisle := (← fetchAll Provider).find? (fun p => p.val.name.raw == "Hot Aisle")
    | throw (.sqlite "FAIL: seeded provider Hot Aisle not found")
  -- availableChip: only listed h100s, cheapest first (eu h100 is delisted)
  let h100s ← availableChip .h100
  checkD (prices h100s == #[2390, 2490, 3290]) "availableChip h100 prices + order"
  checkD (h100s.all (fun o => o.val.chip == Chip.h100 && o.val.available))
    "availableChip returns only available h100s"
  -- cheapestIn: the head is the cheapest GPU-hour in the region
  let usEast ← cheapestIn .usEast
  checkD (prices usEast == #[440, 1990, 2490, 2790]) "cheapestIn usEast prices + order"
  checkD (usEast[0]?.map (·.val.chip) == some Chip.rtx4090) "cheapest in usEast is the rtx4090"
  checkD ((← cheapestIn .eu).map (·.val.chip) == #[Chip.l40s])
    "eu: only the l40s is listed (both other eu rows are delisted)"
  -- amdOfferings: chip facts as predicates (residual conjunct, same rows)
  let amd ← amdOfferings
  checkD (prices amd == #[1990, 2190, 2790]) "amdOfferings prices + order"
  checkD (amd.all (fun o => o.val.chip.vendor == Vendor.amd)) "amdOfferings all AMD"
  checkD (amd.all (fun o => o.val.provider == hotaisle.ref)) "only Hot Aisle sells AMD here"
  -- bigVram: Chip.vramGb as a predicate
  checkD (prices (← bigVram 80) == #[1290, 1990, 2390, 2490, 2790, 3290])
    "bigVram 80: every available 80GB+ card"
  let huge ← bigVram 100
  checkD (huge.map (·.val.chip) == #[Chip.mi300x, Chip.mi325x])
    "bigVram 100: only the big AMD parts"
  checkD (huge.all (fun o => o.val.chip.vramGb ≥ 100)) "bigVram respects the bound"
  -- CAS update: reprice the rtx3090
  let some cheap := (← select [Offering] (fun o => o.val.chip == Chip.rtx3090))[0]?
    | throw (.sqlite "FAIL: rtx3090 offering not found")
  let cheap' ← update cheap { cheap.val with hourly := ⟨190⟩ }
  checkD (cheap'.val.hourly.tenthsOfCent == 190) "CAS update applies"
  checkD (prices (← cheapestIn .usWest) == #[190, 1290, 2390]) "usWest repriced"
  -- return a referenced provider and the pre-update (now stale) snapshot
  return (hotaisle, cheap)

def main : IO UInt32 := do
  -- The base value's derived schema is the hand-written one, table for
  -- table: `Base.specs` (dedup + dependency order) must not reorder a
  -- list that is already in dependency order, or the fingerprint moves.
  unless base.specs == schema do
    throw <| IO.userError "FAIL: Base.specs must equal the hand-written schema"
  if ← dbPath.pathExists then IO.FS.removeFile dbPath
  let (hotaisle, staleOffering) ← expectOk (← withDb dbPath schema runQueries) "seed + queries"
  -- the snapshot from before the CAS update no longer matches the row
  expectErr (← withDb dbPath schema do
      discard <| update staleOffering { staleOffering.val with available := false })
    "stale" "CAS with stale snapshot"
  -- Hot Aisle has offerings: delete must refuse loudly
  expectErr (← withDb dbPath schema do delete hotaisle.id)
    "restricted" "delete referenced provider"
  -- data persisted across reopens
  let amd ← expectOk (← withDb dbPath schema amdOfferings) "reopen"
  check (amd.size == 3) "amd offerings persist across reopen"
  IO.println "gpus base: all tests passed"
  return 0
