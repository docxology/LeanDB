import GpuMarket.Entities
import GpuMarket.Models
import GpuMarket.Queries
import GpuMarket.Seed

/-! The gpumarket base as a value. Query names and arities are
`query%`-derived from the defs in `GpuMarket/Queries.lean`; closed-world
arguments (gpu, pricing, provider) parse by variant name and refuse
unknown ones typed. The seed loads listings and models. -/

namespace GpuMarket

open LeanDb LeanDb.Cli

def base : LeanDb.Base := {
  name := "gpumarket"
  tables := [.of Listing, .of Model]
  queries := [
    query% cheapest,
    query% h100,
    query% under,
    query% amd,
    query% bigVram,
    query% catalog,
    query% providerInfo,
    query% chipInfo,
    query% byArch,
    query% minBandwidth,
    query% valueRank,
    query% models,
    query% canServe]
  seed := some (do seed; seedModels)
}

end GpuMarket
