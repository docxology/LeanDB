import PriceWatch.Scalars
import PriceWatch.Enums

/-! # The open world

`Product` is the normalizer's output: one canonical row per real-world
product. `Listing` is the scraper's output: one row per (store, product)
offer observed. Empty until the scraper + normalizer land — the schema and
queries are the contract they must fill. -/

namespace PriceWatch

open LeanDb

structure Product where
  name     : ProductName
  brand    : Brand
  category : Category
  deriving Repr, LeanDb.Entity

structure Listing where
  product      : Ref Product
  store        : Store
  url          : Url
  price        : Money             -- current offer, minor units
  listPrice    : Option Money      -- struck-through MRP, when shown
  currency     : Currency := .inr
  rating       : Option Rating
  reviews      : Option Nat
  availability : Availability := .inStock
  deliveryDays : Option Nat
  observedAt   : Timestamp
  deriving Repr, LeanDb.Entity

def schema : List TableSpec := [Entity.spec Product, Entity.spec Listing]

end PriceWatch
