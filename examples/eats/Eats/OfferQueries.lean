import Eats.Queries
import Eats.Offers

/-! # Queries over configurable offers

Each docstring says what pushes and what stays residual; `README.md`
records the measurements. The pattern to notice: a *fully specified*
configuration is five closed-enum/Bool equalities and pushes entirely;
a *runtime pattern* (a list of options the CLI typed) is a value the
tactic cannot split on and stays residual; an `Option`-typed optional
filter pushes too, one `IS ?` per argument given (the last query). -/

namespace Eats

open LeanDb LeanDb.Cli

/-! ## CLI boundary -/

instance : CliArg Bool := ⟨fun
  | "true" => .ok true
  | "false" => .ok false
  | s => .error s!"expected true or false, got {String.quote s}"⟩

/-- `iced/large/oat/double/regular` — the canonical text of a configuration. -/
instance : CliArg EspressoConfig := ⟨EspressoConfig.parse⟩

/-- `milk=oat`. -/
instance : CliArg EspressoOption := ⟨EspressoOption.parse⟩

/-- `temp=iced,milk=oat`; `""` is the empty pattern (matches everything). -/
instance : CliArg Pattern := ⟨fun s =>
  if s.isEmpty then .ok [] else (s.splitOn ",").mapM EspressoOption.parse⟩

/-- Seconds since the epoch. -/
instance : CliArg Timestamp := ⟨fun s => (⟨·⟩) <$> CliArg.parse s⟩

instance : QueryOut EspressoConfig := ⟨fun c => Lean.toJson c⟩

/-! ## Reading the tabulation -/

/-- The price of one configuration at one offer, from the tabulation —
    the offer and the five flattened config columns are six equalities,
    all pushed, residual 0. `none` is "not sold here". -/
def priceOf (offer : Ref EspressoOffer) (c : EspressoConfig) : DbM (Option Money) := do
  let rows ← select [OfferPrice] (fun op =>
    op.val.offer == offer && op.val.temp == c.temp && op.val.size == c.size
      && op.val.milk == c.milk && op.val.shots == c.shots && op.val.decaf == c.decaf)
  return rows[0]?.map (·.val.price)

/-- "Cheapest iced large oat double in San Francisco": the whole
    configuration as five arguments, a three-table join, sorted by price.
    Two join conditions, `available`, the city and the five config
    columns all push — residual 0; the rule is never read. -/
def cheapestConfigured (temp : Temp) (size : Size) (milk : Milk) (shots : Shots) (decaf : Bool)
    (city : City) :
    DbM (Array (Stored EspressoOffer × Stored OfferPrice × Stored Restaurant)) :=
  select [EspressoOffer, OfferPrice, Restaurant] (fun (o, op, r) =>
    op.val.offer == o.ref && o.val.restaurant == r.ref && o.val.available
      && r.val.city == city && op.val.temp == temp && op.val.size == size
      && op.val.milk == milk && op.val.shots == shots && op.val.decaf == decaf)
    (.key fun (_, op, _) => op.val.price)

/-- The same question for a *pattern* typed at runtime ("iced oat, any
    size"). The joins, `available` and the city push; `p.matches` is
    residual — a runtime list is not something the tactic can split on
    (it splits closed-enum columns and closed-enum parameters; a `List
    EspressoOption` is neither), so the config columns are fetched for
    the city and filtered in Lean. -/
def cheapestMatching (p : Pattern) (city : City) :
    DbM (Array (Stored EspressoOffer × Stored OfferPrice × Stored Restaurant)) :=
  select [EspressoOffer, OfferPrice, Restaurant] (fun (o, op, r) =>
    op.val.offer == o.ref && o.val.restaurant == r.ref && o.val.available
      && r.val.city == city && Pattern.matches p op.val.toConfig)
    (.key fun (_, op, _) => op.val.price)

/-- Optional filters as `Option` parameters — "iced if asked, oat if
    asked". `temp?`/`milk?` are captured `Option Temp`/`Option Milk`; the
    tactic case-splits each on its closed world `none :: all.map some`
    with value/value guards on the parameter, which fold at plan build:
    a `none` argument folds its conjunct to `tt`, a `some c` argument to
    `t1."temp" IS ?`. Every combination pushes with residual 0 (asserted
    in `EatsOffersTests.lean`; the logged plans are in the README). -/
def cheapestOptional (temp? : Option Temp) (milk? : Option Milk) (city : City) :
    DbM (Array (Stored EspressoOffer × Stored OfferPrice × Stored Restaurant)) :=
  select [EspressoOffer, OfferPrice, Restaurant] (fun (o, op, r) =>
    op.val.offer == o.ref && o.val.restaurant == r.ref && o.val.available
      && r.val.city == city
      && (temp?.isNone || some op.val.temp == temp?)
      && (milk?.isNone || some op.val.milk == milk?))
    (.key fun (_, op, _) => op.val.price)

/-- "Who offers oat milk?" A join on the tabulation with `milk IS ?`,
    pushed; one row per configuration comes back, so the offers are
    deduplicated in Lean (LEP-0004's `exists` is the one-row answer). -/
def offersWith (milk : Milk) (city : City) :
    DbM (Array (Stored EspressoOffer × Stored Restaurant)) := do
  let rows ← select [EspressoOffer, OfferPrice, Restaurant] (fun (o, op, r) =>
    op.val.offer == o.ref && o.val.restaurant == r.ref && o.val.available
      && r.val.city == city && op.val.milk == milk)
    (.key fun (_, _, r) => r.val.name)
  let mut out : Array (Stored EspressoOffer × Stored Restaurant) := #[]
  for (o, _, r) in rows do
    unless out.any (·.1.ref == o.ref) do out := out.push (o, r)
  return out

/-- "Espresso offers in a city with no `k` in the base" — nut-free
    cappuccinos, dairy-free bases. `baseKinds` is an `EnumSet`
    (LEP-0003 A), so `!(o.val.baseKinds.contains k)` pushes as a bit test
    on the INTEGER mask, `((t0."baseKinds" & ?) = 0)`, the bound value the
    kind's bit — one `Pred.bit` leaf whose negation flips a flag. With the
    join, `available` and the city, residual 0 (asserted in
    `EatsOffersTests.lean`). The canonical-TEXT set this column replaced
    could push equality only. -/
def offersFreeOf (k : IngredientKind) (city : City) :
    DbM (Array (Stored EspressoOffer × Stored Restaurant)) :=
  select [EspressoOffer, Restaurant] (fun (o, r) =>
    o.val.restaurant == r.ref && o.val.available && r.val.city == city
      && !(o.val.baseKinds.contains k))
    (.key fun (o, _) => o.id.toInt64)

/-! ## Reading the rule -/

/-- Every configuration of an offer that suits a diet, with its price —
    enumerated in Lean over `allValid` and priced by the rule (not the
    tabulation): the dietary question is a fold over the closed world,
    and only the offer row is fetched. -/
def configurationsFor (offer : Ref EspressoOffer) (diet : Diet) :
    DbM (Array (EspressoConfig × Money)) := do
  let some o ← get offer | throw (.notFound "espresso_offer" offer.toInt64)
  return EspressoConfig.allValid.filterMap fun c =>
    if EspressoOffer.suits o.val.baseKinds c diet then some (c, o.val.rule.eval c) else none

/-! ## Ordering -/

/-- The tabulation's price, or a typed refusal naming the offer and the
    configuration: a configuration with no `OfferPrice` row is one this
    café does not sell (no oat here; no small iced anywhere). -/
def quote (offer : Ref EspressoOffer) (c : EspressoConfig) : DbM Money := do
  match ← priceOf offer c with
  | some m => pure m
  | none => throw (.decode "offer_price" "config"
      s!"offer {offer.toInt64} does not sell {c.render}: this café does not sell that configuration")

/-- `quote`, then the order line with the quoted price as its snapshot.
    Refused exactly when `quote` refuses. -/
def placeOrder (offer : Ref EspressoOffer) (c : EspressoConfig) (placedAt : Timestamp) :
    DbM (Stored OrderLine) := do
  let quoted ← quote offer c
  insert OrderLine { offer, temp := c.temp, size := c.size, milk := c.milk, shots := c.shots
                     decaf := c.decaf, quoted, placedAt }

end Eats
