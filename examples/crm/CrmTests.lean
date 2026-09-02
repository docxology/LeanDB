import Crm

/-! Tests for the crm base: seed through smart constructors, assert on each
query (counts, ordering, one join result), exercise CAS + `.stale`, FK
`.restricted`, and check that the type system rejects wrong-world programs
(`#check_failure`). -/

open LeanDb Crm

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

private def dbPath : System.FilePath := ".lake" / "crm_test.sqlite"

/-! ## Negative compile checks -/

-- Closed worlds are not entities: a Channel has no table to insert into.
#check_failure insert Channel Channel.email

-- A predicate over the wrong table does not typecheck: `select [Person]`
-- forces `Stored Person → Bool`.
#check_failure select [Person] (fun (a : Stored Ask) => a.val.status == AskStatus.won)

/-! ## Runtime tests -/

private def titlesOf (asks : Array (Stored Ask)) : Array String :=
  asks.map (·.val.title.raw)

private def runQueries : DbM (Stored Person × Stored Ask) := do
  seed
  -- fetchAll + get: seed counts
  let companies ← fetchAll Company
  checkD (companies.size == 3) "three companies seeded"
  checkD ((← fetchAll Person).size == 6) "six people seeded"
  checkD ((← fetchAll Ask).size == 8) "eight asks seeded"
  checkD ((← fetchAll Interaction).size == 4) "four interactions seeded"
  let some acme := companies.find? (fun c => c.val.name.raw == "Acme Analytics")
    | throw (.sqlite "FAIL: seeded company Acme Analytics not found")
  let some corex := companies.find? (fun c => c.val.name.raw == "Corex Systems")
    | throw (.sqlite "FAIL: seeded company Corex Systems not found")
  let got ← get acme.id
  checkD (got.map (·.val.segment == Segment.enterprise) == some true) "get returns acme"
  -- liveAsks: open/waiting only, biggest value first
  let live ← liveAsks
  checkD (live.size == 6) "six live asks"
  checkD (titlesOf live == #[
    "Enterprise rollout", "Platform migration", "Compliance module",
    "Security review", "Consulting retainer", "Starter plan"])
    "liveAsks value-desc order"
  -- pipelineFor: join Ask × Person restricted to acme, live only
  let pipeline ← pipelineFor acme.ref
  checkD (pipeline.map (fun (a, p) => (a.val.title.raw, p.val.name.raw)) == #[
    ("Enterprise rollout", "Ada Lovelace"),
    ("Security review", "Grace Hopper")]) "pipelineFor acme join + order"
  -- staleAsks: live and older than 30 days at seedNow, oldest first
  let stale ← staleAsks seedNow
  checkD (titlesOf stale == #[
    "Consulting retainer", "Enterprise rollout", "Platform migration"])
    "staleAsks order (won/lost and fresh asks excluded)"
  -- contactsOf: everyone at corex, alphabetical
  let contacts ← contactsOf corex.ref
  checkD (contacts.map (·.val.name.raw) == #["Barbara Liskov", "Edsger Dijkstra"])
    "contactsOf corex alphabetical"
  -- CAS update: close the starter-plan deal
  let some starter := (← select [Ask]
      (fun a => a.val.title.raw == "Starter plan"))[0]?
    | throw (.sqlite "FAIL: starter plan ask not found")
  let starter' ← update starter { starter.val with status := .won }
  checkD (starter'.val.status == AskStatus.won) "CAS update applies"
  checkD ((← liveAsks).size == 5) "won ask left the live pipeline"
  -- ada, to test FK RESTRICT (she has asks and interactions), and the
  -- pre-update snapshot (now stale)
  let people ← fetchAll Person
  let some ada := people.find? (fun p => p.val.name.raw == "Ada Lovelace")
    | throw (.sqlite "FAIL: seeded person Ada Lovelace not found")
  return (ada, starter)

def main : IO UInt32 := do
  -- The base value's derived schema is the hand-written one, table for
  -- table: `Base.specs` (dedup + dependency order) must not reorder a
  -- list that is already in dependency order, or the fingerprint moves.
  unless base.specs == schema do
    throw <| IO.userError "FAIL: Base.specs must equal the hand-written schema"
  if ← dbPath.pathExists then IO.FS.removeFile dbPath
  let (ada, staleStarter) ← expectOk (← withDb dbPath schema runQueries) "seed + queries"
  -- the snapshot from before the CAS update no longer matches the row
  expectErr (← withDb dbPath schema do
      discard <| update staleStarter { staleStarter.val with status := AskStatus.lost })
    "stale" "CAS with stale snapshot"
  -- ada has asks and interactions pointing at her: delete must refuse loudly
  expectErr (← withDb dbPath schema do delete ada.id)
    "restricted" "delete referenced person"
  -- data persisted across reopens
  let live ← expectOk (← withDb dbPath schema liveAsks) "reopen"
  check (live.size == 5) "live asks persist across reopen"
  IO.println "crm base: all tests passed"
  return 0
