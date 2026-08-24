import LeanDb

/-! # Closed worlds

The chip catalog *is* the closed world — LeanDB's motivating example.
A chip is not a row in some `chips` table that anyone can insert into or
delete from; it is a constructor. Adding `b200` is a code change that every
total `match` below must answer, and the drift scan refuses instances whose
stored chips the code no longer knows.
-/

namespace Gpus

/-- The GPU SKUs this base knows. -/
inductive Chip where
  | h100 | a100 | l40s | rtx4090 | rtx3090 | mi300x | mi325x
  deriving Repr, DecidableEq, Ord, LeanDb.ClosedEnum

/-- Who makes the silicon. -/
inductive Vendor where
  | nvidia | amd
  deriving Repr, DecidableEq, Ord, LeanDb.ClosedEnum

/-- Coarse geography an offering is served from. -/
inductive Region where
  | usEast | usWest | eu | apac
  deriving Repr, DecidableEq, Ord, LeanDb.ClosedEnum

/-- Facts about a chip live on the type, not in a table. `@[db]` lets
    query plans unfold these into predicates (a `match` stays a residual
    conjunct today — correct, just not pushed to SQL). -/
@[db] def Chip.vendor : Chip → Vendor
  | .mi300x | .mi325x => .amd
  | _ => .nvidia

/-- On-card memory in GB — total by `match`, so a new chip cannot be added
    without answering. -/
@[db] def Chip.vramGb : Chip → Nat
  | .h100 => 80
  | .a100 => 80
  | .l40s => 48
  | .rtx4090 => 24
  | .rtx3090 => 24
  | .mi300x => 192
  | .mi325x => 256

end Gpus
