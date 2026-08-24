import PriceWatch.Choose

/-! # The decision queries

The shapes from the original design discussion, over ecommerce: hard
constraints (max price, min rating, max delivery, category, store) answered
in SQL, then `sorted` / `pareto` / `knee` selection over the feasible set.
Every constraint that can push, pushes — check `pricewatch log`. -/

namespace PriceWatch

open LeanDb

inductive Strategy where
  | sorted | pareto | knee
  deriving Repr, DecidableEq, Ord, LeanDb.ClosedEnum

instance : LeanDb.Cli.CliArg Strategy :=
  inferInstanceAs (LeanDb.Cli.CliArg Strategy)

private def byPrice : SortBy (Stored Product × Stored Listing) :=
  .key fun (_, l) => l.val.price

/-- Apply a selection strategy to the feasible rows. -/
def choose (s : Strategy) (rows : Array (Stored Product × Stored Listing)) :
    Array (Stored Product × Stored Listing) :=
  match s with
  | .sorted => rows
  | .pareto => paretoFront shoppingObjectives rows
  | .knee => match knee? shoppingObjectives rows with
      | some r => #[r]
      | none => #[]

/-- Buyable listings in a category at or under a budget (minor units),
    best tradeoff per `strategy` — "find electronics under ₹30,000". -/
def find (c : Category) (maxMinor : Nat) (strategy : Strategy) :
    DbM (Array (Stored Product × Stored Listing)) := do
  let rows ← select [Product, Listing]
    (fun (p, l) => l.val.product == p.ref
      && p.val.category == c
      && l.val.price.minor ≤ maxMinor
      && l.val.availability.buyable)
    byPrice
  return choose strategy rows

/-- Min-rating constraint on top: "well-reviewed, under budget, fast-ish" —
    the hotel-query shape, for products. -/
def wellRated (c : Category) (maxMinor : Nat) (minTenths : Nat) (strategy : Strategy) :
    DbM (Array (Stored Product × Stored Listing)) := do
  let rows ← select [Product, Listing]
    (fun (p, l) => l.val.product == p.ref
      && p.val.category == c
      && l.val.price.minor ≤ maxMinor
      && (l.val.rating.map (·.tenths)).getD 0 ≥ minTenths
      && l.val.availability.buyable)
    byPrice
  return choose strategy rows

/-- Every store's offer for one product, cheapest first — the
    price-comparison core. -/
def compare (p : Ref Product) : DbM (Array (Stored Product × Stored Listing)) :=
  select [Product, Listing]
    (fun (pr, l) => pr.id == p && l.val.product == p)
    byPrice

/-- The single cheapest buyable offer for a product. -/
def cheapest (p : Ref Product) : DbM (Option (Stored Product × Stored Listing)) := do
  let rows ← select [Product, Listing]
    (fun (pr, l) => pr.id == p && l.val.product == p && l.val.availability.buyable)
    byPrice
  return rows[0]?

/-- Discounted at least `pct` percent off the struck-through list price. -/
def deals (pct : Nat) : DbM (Array (Stored Product × Stored Listing)) :=
  select [Product, Listing]
    (fun (p, l) => l.val.product == p.ref
      && l.val.availability.buyable
      && (match l.val.listPrice with
          | some mrp => l.val.price.minor * 100 ≤ mrp.minor * (100 - pct)
          | none => false))
    byPrice

/-- Arrives within `maxDays` — the max-distance analogue. -/
def fastDelivery (c : Category) (maxDays : Nat) :
    DbM (Array (Stored Product × Stored Listing)) :=
  select [Product, Listing]
    (fun (p, l) => l.val.product == p.ref
      && p.val.category == c
      && l.val.deliveryDays.any (fun d => d ≤ maxDays)
      && l.val.availability.buyable)
    byPrice

/-- One store's catalog. -/
def atStore (s : Store) : DbM (Array (Stored Product × Stored Listing)) :=
  select [Product, Listing]
    (fun (p, l) => l.val.product == p.ref && l.val.store == s)
    byPrice

def products : DbM (Array (Stored Product)) :=
  select [Product] (fun _ => true) (.key (·.val.name.raw))

end PriceWatch
