import Eats.Seed
import Eats.OfferQueries

/-! # Seed: espresso offers at five of the seeded cafés

Illustrative, not real. Five rules, chosen so each query has a
non-trivial answer:

* Blue Bottle (SF) — the plain shape: base plus milk, size, temperature
  and shot deltas, no overrides.
* Sightglass (SF) — the same shape plus one override: iced large oat is
  priced as a thing, not as a sum.
* Samovar (SF) — cheaper everywhere; the answer to "cheapest".
* Highwire (Oakland) — **does not offer oat**: the rule is override-free
  and prices oat like any milk; the *tabulation* simply omits every oat
  configuration. Availability is absence in stage 1.
* Caffe Strada (Berkeley) — the cheapest base of all, outside SF.

The rules are top-level defs so the tests can `decide` their lints.
`seedOffers` looks the restaurants up by name from `Eats.seed`, inserts
the two espresso canonical dishes (`latte`, `cappuccino`) that the base
seed does not have, and tabulates each rule into `OfferPrice` rows. -/

namespace Eats

open LeanDb

/-! ## The rules -/

/-- Blue Bottle: $5.00 base; oat/almond +75, soy +50; large +100, small
    −50; iced +50; triple +100. -/
def ruleBlueBottle : PriceRule :=
  { base := ⟨500⟩
    deltas := [([.milk .oat], ⟨75⟩), ([.milk .almond], ⟨75⟩), ([.milk .soy], ⟨50⟩),
               ([.size .large], ⟨100⟩), ([.size .small], ⟨-50⟩),
               ([.temp .iced], ⟨50⟩), ([.shots .triple], ⟨100⟩)] }

/-- Sightglass: $5.25 base, the same deltas a little higher, and iced
    large oat is $7.25 whatever the deltas say. -/
def ruleSightglass : PriceRule :=
  { base := ⟨525⟩
    deltas := [([.milk .oat], ⟨80⟩), ([.milk .almond], ⟨80⟩), ([.milk .soy], ⟨60⟩),
               ([.size .large], ⟨100⟩), ([.size .small], ⟨-50⟩),
               ([.temp .iced], ⟨50⟩), ([.shots .triple], ⟨100⟩)]
    overrides := [([.temp .iced, .size .large, .milk .oat], ⟨725⟩)] }

/-- Samovar: $4.50 base, non-dairy +50, large +75, small −50, iced +25,
    triple +75. -/
def ruleSamovar : PriceRule :=
  { base := ⟨450⟩
    deltas := [([.milk .oat], ⟨50⟩), ([.milk .almond], ⟨50⟩), ([.milk .soy], ⟨50⟩),
               ([.size .large], ⟨75⟩), ([.size .small], ⟨-50⟩), ([.temp .iced], ⟨25⟩),
               ([.shots .triple], ⟨75⟩)] }

/-- Highwire: $4.75 base, almond +60, soy +50, large +75, small −25, iced
    +25. No oat delta because there is no oat: `unavailableHighwire`
    keeps those configurations out of the tabulation. -/
def ruleHighwire : PriceRule :=
  { base := ⟨475⟩
    deltas := [([.milk .almond], ⟨60⟩), ([.milk .soy], ⟨50⟩),
               ([.size .large], ⟨75⟩), ([.size .small], ⟨-25⟩), ([.temp .iced], ⟨25⟩),
               ([.shots .triple], ⟨75⟩)] }

def unavailableHighwire : List Pattern := [[.milk .oat]]

/-- Caffe Strada: $4.00 base, non-dairy +50, large +50, small −25, triple +50. -/
def ruleStrada : PriceRule :=
  { base := ⟨400⟩
    deltas := [([.milk .oat], ⟨50⟩), ([.milk .almond], ⟨50⟩), ([.milk .soy], ⟨50⟩),
               ([.size .large], ⟨50⟩), ([.size .small], ⟨-25⟩), ([.shots .triple], ⟨50⟩)] }

/-- A rule the codec must refuse: both overrides match iced oat. -/
def ruleAmbiguous : PriceRule :=
  { base := ⟨500⟩
    overrides := [([.milk .oat], ⟨600⟩), ([.temp .iced], ⟨550⟩)] }

/-- A rule the codec must refuse: a small decaf prices below zero. -/
def ruleNegative : PriceRule :=
  { base := ⟨100⟩
    deltas := [([.size .small], ⟨-75⟩), ([.decaf true], ⟨-50⟩)] }

/-! ## Seeding -/

private def restaurantNamed (name : String) : DbM (Stored Restaurant) := do
  let rows ← select [Restaurant] (fun r => r.val.name.raw == name)
  match rows[0]? with
  | some r => pure r
  | none => throw (.decode "seed" "restaurant" s!"no seeded restaurant named {String.quote name}")

/-- The canonical dish behind a slug, inserted if `Eats.seed` did not. -/
private def canonicalOrInsert (slug display : String) : DbM (Stored CanonicalDish) := do
  let s ← seedM s!"slug {slug}" (Slug.make slug)
  let rows ← select [CanonicalDish] (fun c => c.val.slug == s)
  match rows[0]? with
  | some c => pure c
  | none => insert CanonicalDish {
      slug := s, display := ← seedM s!"display {display}" (DisplayName.make display)
      family := .latte, course := .drink }

/-- The tabulation, by hand: one `OfferPrice` per valid configuration the
    café sells — every valid one, minus those matching an `unavailable`
    pattern. This is the function `@[derived] prices` would replace. -/
def tabulate! (offer : Ref EspressoOffer) (rule : PriceRule) (unavailable : List Pattern := []) :
    DbM Nat := do
  let mut n := 0
  for (c, price) in rule.tabulate do
    unless unavailable.any (Pattern.matches · c) do
      discard <| insert OfferPrice (OfferPrice.ofConfig offer c price)
      n := n + 1
  return n

private def offer! (r : Stored Restaurant) (cd : Stored CanonicalDish) (rule : PriceRule)
    (base : List IngredientKind) (unavailable : List Pattern := []) :
    DbM (Stored EspressoOffer) := do
  let o ← insert EspressoOffer (EspressoOffer.make r.ref cd.ref rule base)
  discard <| tabulate! o.ref rule unavailable
  return o

/-- Runs after `Eats.seed` (it looks the cafés up by name). Five latte
    offers and one cappuccino; a latte's base is nothing but what the
    configuration adds, the cappuccino here carries cocoa dusting (sugar). -/
def seedOffers : DbM Unit := do
  let latte ← canonicalOrInsert "latte" "Latte"
  let cappuccino ← canonicalOrInsert "cappuccino" "Cappuccino"
  let blueBottle ← restaurantNamed "Blue Bottle Hayes Valley"
  let sightglass ← restaurantNamed "Sightglass Coffee"
  let samovar ← restaurantNamed "Samovar Tea Lounge"
  let highwire ← restaurantNamed "Highwire Coffee"
  let strada ← restaurantNamed "Caffe Strada"
  discard <| offer! blueBottle latte ruleBlueBottle []
  discard <| offer! blueBottle cappuccino ruleBlueBottle [.sugar]
  discard <| offer! sightglass latte ruleSightglass []
  discard <| offer! samovar latte ruleSamovar []
  discard <| offer! highwire latte ruleHighwire [] unavailableHighwire
  discard <| offer! strada latte ruleStrada []

end Eats
