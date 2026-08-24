import LeanDb

/-! # Closed worlds: the stores we scrape, and fixed vocabulary

A new store = a new constructor + a scraper — a compiler-refereed refactor,
not a row. -/

namespace PriceWatch

inductive Store where
  | amazon | flipkart | walmart | bestbuy | newegg | ebay | target | croma
  deriving Repr, DecidableEq, Ord, LeanDb.ClosedEnum

def Store.displayName : Store → String
  | .amazon => "Amazon" | .flipkart => "Flipkart" | .walmart => "Walmart"
  | .bestbuy => "Best Buy" | .newegg => "Newegg" | .ebay => "eBay"
  | .target => "Target" | .croma => "Croma"

inductive Category where
  | electronics | appliances | fashion | grocery | homeKitchen
  | beauty | toys | sports | books
  deriving Repr, DecidableEq, Ord, LeanDb.ClosedEnum

inductive Currency where
  | inr | usd | eur
  deriving Repr, DecidableEq, Ord, LeanDb.ClosedEnum

inductive Availability where
  | inStock | limited | outOfStock | preorder
  deriving Repr, DecidableEq, Ord, LeanDb.ClosedEnum

/-- Buyable now? Total over the closed world; `@[db]`: compiles into the
    WHERE clause as a disjunction. -/
@[db] def Availability.buyable : Availability → Bool
  | .inStock | .limited => true
  | .outOfStock | .preorder => false

end PriceWatch
