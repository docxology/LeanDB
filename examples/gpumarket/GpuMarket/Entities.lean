import GpuMarket.Scalars
import GpuMarket.Enums

/-! # The open world

One entity: a priced listing. Everything vocabulary-shaped (provider,
silicon, pricing model, region) is a closed-world column — TEXT with a
CHECK at rest, an inductive in code. Rows are what actually changes daily:
who charges what. -/

namespace GpuMarket

open LeanDb

structure Listing where
  provider   : Provider
  gpu        : Gpu
  count      : GpuCount
  pricing    : Pricing := .onDemand
  region     : Region := .northAmerica
  usdHr      : Price              -- per GPU-hour, millidollars
  available  : Bool := true
  observedAt : Timestamp
  deriving Repr, LeanDb.Entity



end GpuMarket
