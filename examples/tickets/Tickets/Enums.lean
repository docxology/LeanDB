import LeanDb

/-! # Closed worlds

Payload-free inductives stored as TEXT constructor names, guarded by a
CHECK constraint and an open-time drift scan. `Ord` derives constructor
order, which is exactly the domain order (p0 before p3, backlog before
done), so these are usable directly as `SortBy` keys.
-/

namespace Tickets

/-- Workflow state of a ticket. -/
inductive Status where
  | backlog | inProgress | blocked | inReview | done
  deriving Repr, DecidableEq, Ord, LeanDb.ClosedEnum

/-- Urgency. `p0` is highest. -/
inductive Priority where
  | p0 | p1 | p2 | p3
  deriving Repr, DecidableEq, Ord, LeanDb.ClosedEnum

/-- Hours a ticket of this priority may stay open before it breaches SLA.
    Total by `match` — a new priority cannot be added without answering. -/
def Priority.slaHours : Priority → Nat
  | .p0 => 4
  | .p1 => 24
  | .p2 => 72
  | .p3 => 168

end Tickets
