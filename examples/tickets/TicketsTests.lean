import Tickets

/-! Tests for the tickets base: seed through smart constructors, assert on
each query, exercise CAS + `.stale`, FK `.restricted`, and check that the
type system rejects wrong-world programs (`#check_failure`). -/

open LeanDb Tickets

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

private def dbPath : System.FilePath := ".lake" / "tickets_test.sqlite"

/-! ## Negative compile checks -/

-- Closed worlds are not entities: a Status has no table to insert into.
#check_failure insert Status Status.backlog

-- A predicate over the wrong table does not typecheck: `select [User]`
-- forces `Stored User → Bool`.
#check_failure select [User] (fun (t : Stored Ticket) => t.val.status == Status.done)

/-! ## Runtime tests -/

private def titlesOf (ts : Array (Stored Ticket)) : Array String :=
  ts.map (·.val.title.raw)

private def runQueries : DbM (Stored User × Stored Ticket) := do
  seed
  -- fetchAll + get
  let users ← fetchAll User
  checkD (users.size == 3) "three users seeded"
  let some ada := users.find? (fun u => u.val.handle.raw == "ada")
    | throw (.sqlite "FAIL: seeded user ada not found")
  let got ← get ada.id
  checkD (got.map (·.val.display.raw) == some "Ada Lovelace") "get returns ada"
  -- openTickets: everything but the done ticket, priority then age
  let opened ← openTickets
  checkD (opened.size == 7) "seven open tickets"
  checkD (titlesOf opened == #[
    "Login crashes on empty password", "Data export corrupts unicode",
    "Search results stale",
    "Onboarding email typo", "Refactor billing module",
    "Update dependencies", "Improve docs"]) "openTickets triage order"
  -- queueOf: assigned + open, triage order
  let adaQueue ← queueOf ada.ref
  checkD (titlesOf adaQueue == #["Search results stale", "Improve docs"])
    "ada's queue"
  -- unassigned: open, no assignee
  let free ← unassigned
  checkD (titlesOf free == #[
    "Data export corrupts unicode", "Refactor billing module",
    "Update dependencies"]) "unassigned triage order"
  -- slaBreached: join with reporter; one breach per priority by construction
  let breached ← slaBreached seedNow
  checkD (breached.map (fun (t, u) => (t.val.title.raw, u.val.handle.raw)) == #[
    ("Login crashes on empty password", "ada"),
    ("Search results stale", "cara"),
    ("Onboarding email typo", "bob"),
    ("Update dependencies", "ada")]) "slaBreached join + order"
  -- CAS update: claim the billing refactor
  let some billing := (← select [Ticket]
      (fun t => t.val.title.raw == "Refactor billing module"))[0]?
    | throw (.sqlite "FAIL: billing ticket not found")
  let billing' ← update billing
    { billing.val with status := .inProgress, assignee := some ada.ref }
  checkD (billing'.val.status == Status.inProgress) "CAS update applies"
  checkD ((← unassigned).size == 2) "claimed ticket left the unassigned pool"
  -- return pre-update snapshot (now stale) and a referenced user
  return (ada, billing)

def main : IO UInt32 := do
  -- The base value's derived schema is the hand-written one, table for
  -- table: `Base.specs` (dedup + dependency order) must not reorder a
  -- list that is already in dependency order, or the fingerprint moves.
  unless base.specs == schema do
    throw <| IO.userError "FAIL: Base.specs must equal the hand-written schema"
  if ← dbPath.pathExists then IO.FS.removeFile dbPath
  let (ada, staleBilling) ← expectOk (← withDb dbPath schema runQueries) "seed + queries"
  -- the snapshot from before the CAS update no longer matches the row
  expectErr (← withDb dbPath schema do
      discard <| update staleBilling { staleBilling.val with status := Status.blocked })
    "stale" "CAS with stale snapshot"
  -- ada reports tickets and wrote comments: delete must refuse loudly
  expectErr (← withDb dbPath schema do delete ada.id)
    "restricted" "delete referenced user"
  -- data persisted across reopens
  let opened ← expectOk (← withDb dbPath schema openTickets) "reopen"
  check (opened.size == 7) "open tickets persist across reopen"
  IO.println "tickets base: all tests passed"
  return 0
