import Shop.Entities
import Shop.Queries
import Shop.Seed

/-! The shop base as a value: tables (the schema is derived from them),
`query%`-derived queries, and the seed. -/

namespace Shop

open LeanDb LeanDb.Cli

def base : LeanDb.Base := {
  name := "shop"
  tables := [.of Customer, .of Product, .of Purchase, .of LineItem]
  queries := [
    query% activeOrders,
    query% lowStock,
    query% basketOf,
    query% revenueRows]
  seed := some seed
}

end Shop
