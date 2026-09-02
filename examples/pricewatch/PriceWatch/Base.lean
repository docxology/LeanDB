import PriceWatch.Entities
import PriceWatch.Queries

/-! The pricewatch base as a value. NO seed by design: rows arrive only
through the (separate) scraper + normalizer, whose contract is this
base's smart constructors — `insert listing '{"price":0,…}'` and friends
fail typed today, on an empty instance, exactly as they will fail on a
full one. -/

namespace PriceWatch

open LeanDb LeanDb.Cli

def base : LeanDb.Base := {
  name := "pricewatch"
  tables := [.of Product, .of Listing]
  queries := [
    query% find,
    query% wellRated,
    query% PriceWatch.compare,
    query% cheapest,
    query% deals,
    query% fastDelivery,
    query% atStore,
    query% products]
}

end PriceWatch
