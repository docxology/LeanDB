import Gpus.Entities
import Gpus.Queries
import Gpus.Seed

/-! The gpus base as a value. Chip/region arguments parse by closed-world
variant name through the generic `CliArg` instance — an unknown name is
a typed `.decode` error, never a silent empty result. -/

namespace Gpus

open LeanDb LeanDb.Cli

def base : LeanDb.Base := {
  name := "gpus"
  tables := [.of Provider, .of Offering]
  queries := [
    query% availableChip,
    query% cheapestIn,
    query% amdOfferings,
    query% bigVram]
  seed := some seed
}

end Gpus
