import Tickets.Entities

/-! # Queries

Domain logic as plain defs over `select`. Predicates and sort keys are
ordinary Lean — the compiler checks them against the row types.
-/

namespace Tickets

open LeanDb

/-- Priority first (p0 highest), oldest first within a priority. -/
private def triage : SortBy (Stored Ticket) :=
  .andThen (.key (·.val.priority)) (.key (·.val.createdAt))

@[db] private def isOpen (t : Stored Ticket) : Bool :=
  !(t.val.status == Status.done)

/-- Every ticket not yet done, in triage order. -/
def openTickets : DbM (Array (Stored Ticket)) :=
  select [Ticket] isOpen triage

/-- The open tickets assigned to `u`, in triage order. -/
def queueOf (u : Ref User) : DbM (Array (Stored Ticket)) :=
  select [Ticket] (fun t => t.val.assignee == some u && isOpen t) triage

/-- Open tickets older than their priority's SLA at `now`, joined with the
    user who reported them. -/
def slaBreached (now : Timestamp) : DbM (Array (Stored Ticket × Stored User)) :=
  select [Ticket, User]
    (fun (t, u) =>
      t.val.reporter == u.ref
        && isOpen t
        && t.val.createdAt.hoursBetween now > t.val.priority.slaHours)
    (.andThen (.key fun (t, _) => t.val.priority) (.key fun (t, _) => t.val.createdAt))

/-- Open tickets nobody owns, most urgent first. -/
def unassigned : DbM (Array (Stored Ticket)) :=
  select [Ticket] (fun t => t.val.assignee.isNone && isOpen t) triage

end Tickets
