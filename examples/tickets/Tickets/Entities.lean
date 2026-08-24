import LeanDb
import Tickets.Scalars
import Tickets.Enums

/-! # Entities

The tables, as flat structures. `deriving LeanDb.Entity` derives the schema
from these field types — nothing else defines it.
-/

namespace Tickets

open LeanDb

structure User where
  handle : Handle
  display : Title
  deriving Repr, LeanDb.Entity

structure Ticket where
  title : Title
  body : Body
  status : Status := .backlog
  priority : Priority := .p2
  reporter : Ref User
  assignee : Option (Ref User)
  estimate : Option Estimate
  createdAt : Timestamp
  deriving Repr, LeanDb.Entity

structure Comment where
  ticket : Ref Ticket
  author : Ref User
  body : Body
  «at» : Timestamp
  deriving Repr, LeanDb.Entity

/-- FK-dependency order: referenced tables first. -/
def schema : List TableSpec :=
  [Entity.spec User, Entity.spec Ticket, Entity.spec Comment]

end Tickets
