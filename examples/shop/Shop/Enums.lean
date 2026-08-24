import LeanDb

/-! # Closed worlds

Payload-free inductives stored as TEXT constructor names, guarded by a
CHECK constraint and an open-time drift scan. `Ord` derives constructor
order — `cart` before `delivered` is exactly lifecycle order.
-/

namespace Shop

/-- Lifecycle of a purchase. -/
inductive OrderStatus where
  | cart | placed | paid | shipped | delivered | cancelled
  deriving Repr, DecidableEq, Ord, LeanDb.ClosedEnum

/-- A purchase the shop still owes work on: committed but not yet
    delivered (and not abandoned in a cart or cancelled). `@[db]` lets
    query plans unfold this into predicates. -/
@[db] def OrderStatus.isActive : OrderStatus → Bool
  | .placed | .paid | .shipped => true
  | _ => false

/-- Product taxonomy. -/
inductive Category where
  | electronics | grocery | apparel | toys
  deriving Repr, DecidableEq, Ord, LeanDb.ClosedEnum

end Shop
