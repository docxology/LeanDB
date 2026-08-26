import GpuMarket.Entities
import GpuMarket.Arch

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

/-- Listings on one architecture generation — `Gpu.arch` reads the spec
    table; the plan case-splits it into `gpu IS …` disjunctions. -/
def byArch (a : Arch) : DbM (Array (Stored Listing)) :=
  select [Listing] (fun l => l.val.gpu.arch == a && l.val.available) byPrice

/-- Memory-bandwidth floor (GB/s), from the spec table. -/
def minBandwidth (gbs : Nat) : DbM (Array (Stored Listing)) :=
  select [Listing] (fun l => l.val.gpu.memBwGBs ≥ gbs && l.val.available) byPrice

open Lean (Json) in
/-- The full datasheet for one SKU — pure vocabulary, no rows touched. -/
def chipInfo (g : Gpu) : DbM Json :=
  pure (g.spec.toJson g)

open Lean (Json) in
/-- On-demand $/TFLOP ranking at a precision: listings on silicon that
    supports it, scored microdollars per dense TFLOP-hour, best first.
    The arithmetic is client-side; the fetch narrowing is SQL. -/
def valueRank (p : Precision) : DbM Json := do
  let rows ← select [Listing] (fun l => l.val.available && l.val.pricing == .onDemand)
  let scored := (rows.filterMap fun l =>
      (l.val.gpu.tflops p).map fun t => (l, t, l.val.usdHr.milli * 1000 / t))
    |>.qsort (fun a b => a.2.2 < b.2.2)
  return Json.mkObj [("ok", Json.bool true),
    ("precision", Json.str (LeanDb.ClosedEnum.encodeName p)),
    ("rows", Json.arr <| scored.map fun (l, t, score) => Json.mkObj [
      ("provider", Json.str (LeanDb.ClosedEnum.encodeName l.val.provider)),
      ("gpu", Json.str (LeanDb.ClosedEnum.encodeName l.val.gpu)),
      ("usd_hr_milli", Lean.toJson l.val.usdHr.milli),
      ("dense_tflops", Lean.toJson t),
      ("micro_usd_per_tflop_hr", Lean.toJson score)])]

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
