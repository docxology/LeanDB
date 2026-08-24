import Gpus.Entities

/-! # Queries

Domain logic as plain defs over `select`. Chip *facts* (`Chip.vendor`,
`Chip.vramGb`) participate in predicates directly — they unfold via `@[db]`
but their `match` bodies stay residual conjuncts today, which narrows
nothing and changes nothing: the lambda is always applied.
-/

namespace Gpus

open LeanDb

/-- Cheapest-first: hourly price, provider id as a stable tiebreak. -/
private def byPrice : SortBy (Stored Offering) :=
  .andThen (.key (·.val.hourly)) (.key (·.val.provider.toInt64))

/-- Where can you rent chip `c` right now, cheapest first? -/
def availableChip (c : Chip) : DbM (Array (Stored Offering)) :=
  select [Offering] (fun o => o.val.available && o.val.chip == c) byPrice

/-- Everything rentable in region `r`, cheapest first — the head of the
    result is the cheapest GPU-hour in the region. -/
def cheapestIn (r : Region) : DbM (Array (Stored Offering)) :=
  select [Offering] (fun o => o.val.available && o.val.region == r) byPrice

/-- Every AMD offering, listed or not. `Chip.vendor` is a chip fact, not a
    column — the conjunct is residual today, and still typed. -/
def amdOfferings : DbM (Array (Stored Offering)) :=
  select [Offering] (fun o => o.val.chip.vendor == Vendor.amd) byPrice

/-- Available offerings whose chip carries at least `minGb` of VRAM,
    cheapest first. -/
def bigVram (minGb : Nat) : DbM (Array (Stored Offering)) :=
  select [Offering] (fun o => o.val.available && o.val.chip.vramGb ≥ minGb) byPrice

end Gpus
