import Tickets.Queries

/-! # Seed data

All values pass through the smart constructors. `seedM` lifts an
`Except String` validation into `DbM` as a typed `.decode` error, so seed
stays total — no `panic!`, no `Option.get!`.
-/

namespace Tickets

open LeanDb

/-- Lift a smart-constructor result into `DbM`. -/
def seedM (context : String) (r : Except String α) : DbM α :=
  match r with
  | .ok a => pure a
  | .error msg => throw (.decode "seed" context msg)

/-- The fixed "now" the seed data is laid out around; tests pass it to
    `slaBreached`. -/
def seedNow : Timestamp := ⟨1700000000⟩

/-- `h` hours before `seedNow`. -/
def hoursAgo (h : Nat) : Timestamp := ⟨seedNow.epochSeconds - h * 3600⟩

private def user! (handle display : String) : DbM (Stored User) := do
  insert User {
    handle := ← seedM s!"handle {handle}" (Handle.make handle)
    display := ← seedM s!"display {display}" (Title.make display) }

private def ticket! (title : String) (priority : Priority) (status : Status)
    (reporter : Ref User) (assignee : Option (Ref User))
    (estimateHours : Option Nat) (createdAt : Timestamp) : DbM (Stored Ticket) := do
  let estimate ← match estimateHours with
    | none => pure none
    | some h => some <$> seedM s!"estimate {h}" (Estimate.make h)
  insert Ticket {
    title := ← seedM s!"title {title}" (Title.make title)
    body := ← seedM "body" (Body.make s!"Details for: {title}")
    status, priority, reporter, assignee, estimate, createdAt }

private def comment! (ticket : Ref Ticket) (author : Ref User)
    (body : String) (at' : Timestamp) : DbM (Stored Comment) := do
  insert Comment {
    ticket, author
    body := ← seedM "comment body" (Body.make body)
    «at» := at' }

/-- Three users, eight tickets across statuses/priorities/assignees, three
    comments. Laid out so that at `seedNow` exactly the p0/p1/p2/p3 tickets
    aged 6h/30h/80h/200h have breached their 4h/24h/72h/168h SLAs. -/
def seed : DbM Unit := do
  let ada ← user! "ada" "Ada Lovelace"
  let bob ← user! "bob" "Bob Harris"
  let cara ← user! "cara" "Cara Chen"
  let t1 ← ticket! "Login crashes on empty password" .p0 .inProgress
    ada.ref (some bob.ref) (some 3) (hoursAgo 6)
  discard <| ticket! "Data export corrupts unicode" .p0 .backlog
    bob.ref none none (hoursAgo 2)
  let t3 ← ticket! "Search results stale" .p1 .blocked
    cara.ref (some ada.ref) (some 8) (hoursAgo 30)
  discard <| ticket! "Dark mode flickers" .p1 .done
    ada.ref (some cara.ref) (some 2) (hoursAgo 100)
  discard <| ticket! "Onboarding email typo" .p2 .inReview
    bob.ref (some bob.ref) (some 1) (hoursAgo 80)
  discard <| ticket! "Refactor billing module" .p2 .backlog
    cara.ref none (some 40) (hoursAgo 10)
  discard <| ticket! "Update dependencies" .p3 .backlog
    ada.ref none none (hoursAgo 200)
  discard <| ticket! "Improve docs" .p3 .inProgress
    bob.ref (some ada.ref) (some 5) (hoursAgo 12)
  discard <| comment! t1.ref bob.ref "Reproduced on staging." (hoursAgo 5)
  discard <| comment! t1.ref ada.ref "Fix is in review." (hoursAgo 4)
  discard <| comment! t3.ref ada.ref "Blocked on cache invalidation." (hoursAgo 20)

end Tickets
