import Crm.Queries

/-! # Seed data

All values pass through the smart constructors. `seedM` lifts an
`Except String` validation into `DbM` as a typed `.decode` error, so seed
stays total — no `panic!`, no `Option.get!`.
-/

namespace Crm

open LeanDb

/-- Lift a smart-constructor result into `DbM`. -/
def seedM (context : String) (r : Except String α) : DbM α :=
  match r with
  | .ok a => pure a
  | .error msg => throw (.decode "seed" context msg)

/-- The fixed "now" the seed data is laid out around; tests pass it to
    `staleAsks`. -/
def seedNow : Timestamp := ⟨1700000000⟩

/-- `d` days before `seedNow`. -/
def daysAgo (d : Nat) : Timestamp := seedNow.subDays d

private def company! (name : String) (segment : Segment) : DbM (Stored Company) := do
  insert Company {
    name := ← seedM s!"company {name}" (CompanyName.make name)
    segment }

private def person! (name email : String) (company : Option (Ref Company)) :
    DbM (Stored Person) := do
  insert Person {
    name := ← seedM s!"name {name}" (FullName.make name)
    email := ← seedM s!"email {email}" (Email.make email)
    company }

private def ask! (person : Ref Person) (title : String) (status : AskStatus)
    (value : Nat) (openedAt : Timestamp) : DbM (Stored Ask) := do
  insert Ask {
    person, status, value, openedAt
    title := ← seedM s!"ask title {title}" (Note.make title) }

private def interaction! (person : Ref Person) (channel : Channel)
    (note : String) (happenedAt : Timestamp) : DbM (Stored Interaction) := do
  insert Interaction {
    person, channel, happenedAt
    note := ← seedM "interaction note" (Note.make note) }

/-- Three companies, six people (one unaffiliated), eight asks in mixed
    statuses and values, four interactions. Laid out so that at `seedNow`
    exactly the live asks aged 45/40/35 days are stale (threshold 30). -/
def seed : DbM Unit := do
  let acme ← company! "Acme Analytics" .enterprise
  let bloom ← company! "Bloom Bakery" .smb
  let corex ← company! "Corex Systems" .midMarket
  let ada ← person! "Ada Lovelace" "ada@acme.example" (some acme.ref)
  let grace ← person! "Grace Hopper" "grace@acme.example" (some acme.ref)
  let alan ← person! "Alan Turing" "alan@bloom.example" (some bloom.ref)
  let edsger ← person! "Edsger Dijkstra" "edsger@corex.example" (some corex.ref)
  let barbara ← person! "Barbara Liskov" "barbara@corex.example" (some corex.ref)
  let donald ← person! "Donald Knuth" "donald@indie.example" none
  discard <| ask! ada.ref "Enterprise rollout" .«open» 50000 (daysAgo 40)
  discard <| ask! ada.ref "Training add-on" .won 8000 (daysAgo 60)
  discard <| ask! grace.ref "Security review" .waiting 20000 (daysAgo 10)
  discard <| ask! alan.ref "Starter plan" .«open» 1200 (daysAgo 5)
  discard <| ask! alan.ref "Analytics upsell" .lost 3000 (daysAgo 90)
  discard <| ask! edsger.ref "Platform migration" .waiting 45000 (daysAgo 35)
  discard <| ask! barbara.ref "Compliance module" .«open» 30000 (daysAgo 2)
  discard <| ask! donald.ref "Consulting retainer" .«open» 15000 (daysAgo 45)
  discard <| interaction! ada.ref .meeting "Kickoff demo went well." (daysAgo 41)
  discard <| interaction! ada.ref .email "Sent the rollout proposal." (daysAgo 39)
  discard <| interaction! grace.ref .call "Scoped the security review." (daysAgo 10)
  discard <| interaction! barbara.ref .chat "Pricing question on compliance." (daysAgo 2)

end Crm
