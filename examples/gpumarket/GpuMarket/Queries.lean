import GpuMarket.Entities

/-! # Queries — domain logic as plain Lean over `select`

Every predicate below compiles to SQL (check `gpumarket log`): closed-enum
equality pushes as `IS`, the `@[db]` vocabulary functions case-split into
disjunctions, prices compare as integers. -/

namespace GpuMarket

open LeanDb

private def byPrice : SortBy (Stored Listing) := .key (·.val.usdHr)

/-- Cheapest first for one SKU under one pricing model —
    `query cheapest h100Sxm onDemand`. -/
def cheapest (g : Gpu) (p : Pricing) : DbM (Array (Stored Listing)) :=
  select [Listing]
    (fun l => l.val.gpu == g && l.val.pricing == p && l.val.available)
    byPrice

/-- The whole H100 family (SXM and PCIe), cheapest first — the row on top
    answers "cheapest on-demand H100". -/
def h100 (p : Pricing) : DbM (Array (Stored Listing)) :=
  select [Listing]
    (fun l => l.val.gpu.isH100 && l.val.pricing == p && l.val.available)
    byPrice

/-- Everything at or under a price (millidollars/GPU-hr), any silicon. -/
def under (milli : Nat) (p : Pricing) : DbM (Array (Stored Listing)) :=
  select [Listing]
    (fun l => l.val.usdHr.milli ≤ milli && l.val.pricing == p && l.val.available)
    byPrice

/-- AMD silicon only — `Gpu.vendor` is a match over the closed world; the
    plan compiles it to `gpu IS 'mi300x' OR gpu IS 'mi325x'`. -/
def amd : DbM (Array (Stored Listing)) :=
  select [Listing] (fun l => l.val.gpu.vendor == .amd && l.val.available) byPrice

/-- Listings with at least `minGb` of VRAM per GPU (via the total
    `Gpu.vramGb` table — also a case-split at the SQL layer). -/
def bigVram (minGb : Nat) : DbM (Array (Stored Listing)) :=
  select [Listing]
    (fun l => l.val.gpu.vramGb ≥ minGb && l.val.available)
    byPrice

/-- One provider's whole catalog, cheapest first. -/
def catalog (pr : Provider) : DbM (Array (Stored Listing)) :=
  select [Listing] (fun l => l.val.provider == pr) byPrice

open Lean (Json) in
/-- Vocabulary lookup: the closed world answers from code, the open world
    from rows. -/
def providerInfo (pr : Provider) : DbM Json := do
  let rows ← catalog pr
  return Json.mkObj [
    ("name", Json.str pr.displayName),
    ("website", Json.str pr.website),
    ("listings", Lean.toJson rows.size),
    ("cheapest_milli", match rows[0]? with
      | some l => Lean.toJson l.val.usdHr.milli
      | none => Json.null)]

end GpuMarket
