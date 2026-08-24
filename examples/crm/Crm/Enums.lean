import LeanDb

/-! # Closed worlds

Payload-free inductives stored as TEXT constructor names, guarded by a
CHECK constraint and an open-time drift scan. `Ord` derives constructor
order, which is exactly the domain order (open before lost, smb before
enterprise), so these are usable directly as `SortBy` keys.
-/

namespace Crm

/-- How an interaction happened. -/
inductive Channel where
  | email | call | meeting | chat
  deriving Repr, DecidableEq, Ord, LeanDb.ClosedEnum

/-- Lifecycle of an ask. `open` is a Lean keyword, hence the guillemets —
    the stored variant name is still plain `open`. -/
inductive AskStatus where
  | «open» | waiting | won | lost
  deriving Repr, DecidableEq, Ord, LeanDb.ClosedEnum

/-- An ask still in play: not yet won or lost. `@[db]` lets the planner
    unfold this into the pushable fragment of a predicate. -/
@[db] def AskStatus.isLive (s : AskStatus) : Bool :=
  s == .«open» || s == .waiting

/-- Company size band. -/
inductive Segment where
  | smb | midMarket | enterprise
  deriving Repr, DecidableEq, Ord, LeanDb.ClosedEnum

end Crm
