import LeanDb
import Crm.Scalars
import Crm.Enums

/-! # Entities

The tables, as flat structures. `deriving LeanDb.Entity` derives the schema
from these field types — nothing else defines it.
-/

namespace Crm

open LeanDb

structure Company where
  name : CompanyName
  segment : Segment
  deriving Repr, LeanDb.Entity

structure Person where
  name : FullName
  email : Email
  company : Option (Ref Company)
  deriving Repr, LeanDb.Entity

structure Interaction where
  person : Ref Person
  channel : Channel
  note : Note
  happenedAt : Timestamp
  deriving Repr, LeanDb.Entity

structure Ask where
  person : Ref Person
  title : Note
  status : AskStatus := .«open»
  value : Nat
  openedAt : Timestamp
  deriving Repr, LeanDb.Entity

/-- FK-dependency order: referenced tables first. -/
def schema : List TableSpec :=
  [Entity.spec Company, Entity.spec Person, Entity.spec Interaction, Entity.spec Ask]

end Crm
