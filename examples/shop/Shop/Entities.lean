import LeanDb
import Shop.Scalars
import Shop.Enums

/-! # Entities

The tables, as flat structures. `deriving LeanDb.Entity` derives the schema
from these field types — nothing else defines it.

The order entity is named `Purchase`: Lean core already owns the name
`Order` (the `Lean.Order` fixpoint machinery), and a base should not shadow
its host language.
-/

namespace Shop

open LeanDb

structure Customer where
  name : CustomerName
  email : Email
  deriving Repr, LeanDb.Entity

structure Product where
  name : ProductName
  sku : Sku
  category : Category
  price : Money
  stock : Nat
  deriving Repr, LeanDb.Entity

structure Purchase where
  customer : Ref Customer
  status : OrderStatus := .cart
  placedAt : Timestamp
  deriving Repr, LeanDb.Entity

structure LineItem where
  order : Ref Purchase
  product : Ref Product
  qty : Qty
  unitPrice : Money
  deriving Repr, LeanDb.Entity

/-- FK-dependency order: referenced tables first. -/
def schema : List TableSpec :=
  [Entity.spec Customer, Entity.spec Product, Entity.spec Purchase, Entity.spec LineItem]

end Shop
