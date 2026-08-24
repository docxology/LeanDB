import LeanDb
import Gpus.Scalars
import Gpus.Enums

/-! # Entities

Two tables: who sells, and what they sell where for how much. The chips
themselves are deliberately *not* an entity — see `Enums`.
-/

namespace Gpus

open LeanDb

structure Provider where
  name : ProviderName
  console : Url
  deriving Repr, LeanDb.Entity

structure Offering where
  provider : Ref Provider
  chip : Chip
  region : Region
  hourly : PricePerHour
  available : Bool
  deriving Repr, LeanDb.Entity

/-- FK-dependency order: referenced tables first. -/
def schema : List TableSpec :=
  [Entity.spec Provider, Entity.spec Offering]

end Gpus
