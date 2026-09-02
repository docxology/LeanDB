import Eats.Entities
import Eats.Config

/-! # Configurable offers (LEP-0005 stage 1, by hand)

The three representations of a stored function over `EspressoConfig`,
all written by hand and kept coherent by one constructor:

* **Rule** — `EspressoOffer.rule`, one JSON column: the truth.
* **Bounds** — `minPrice`, `maxPrice`, `veganPossible`: scalar columns
  computed from the rule by `EspressoOffer.make`, so a fetch can narrow
  on them before the rule is ever read.
* **Tabulation** — `OfferPrice`, one row per valid configuration, the
  config hand-flattened into five columns so every option pushes. Written
  at seed time by `OfferSeed.tabulate!`; nothing regenerates it.

None of the coherence is engine-visible. `update` of `rule` alone, a raw
`UPDATE espresso_offer SET rule = …`, or a CLI `insert` with a `minPrice`
that disagrees with the rule are all accepted; `@[derived]` columns and
derived child rows (LEP-0003 B3 applied to D) are what would refuse them. -/

namespace Eats

open LeanDb

/-- The base ingredients of an offer as a canonical TEXT set — sorted
    constructor names, comma-separated — the same stand-in kernels uses
    for its `fuses` set until `EnumSet` (LEP-0003 A). Equality pushes;
    membership does not. -/
structure KindSet where
  kinds : List IngredientKind
  deriving Repr, DecidableEq

def KindSet.make (ks : List IngredientKind) : KindSet :=
  ⟨(ks.eraseDups.toArray.qsort fun a b => compare a b == .lt).toList⟩

def KindSet.render (s : KindSet) : String :=
  String.intercalate "," (s.kinds.map ClosedEnum.encodeName)

def KindSet.parse (t : String) : Except String KindSet := do
  if t.isEmpty then return ⟨[]⟩
  let ks ← (t.splitOn ",").mapM fun name =>
    match ClosedEnum.decodeName (α := IngredientKind) name with
    | some k => pure k
    | none => throw s!"{String.quote name} is not an ingredient kind"
  return KindSet.make ks

instance : ColCodec KindSet := ColCodec.via KindSet.render KindSet.parse

/-- A café's pricing of one espresso family (its `canonical` dish). The
    rule is the truth; the three summaries are *hand-maintained* copies of
    facts about it. The only place the invariant
    `minPrice = rule.minPrice ∧ maxPrice = rule.maxPrice ∧ veganPossible = …`
    is established is `EspressoOffer.make`; nothing checks it on read, and
    LEP-0003 B3 (`@[derived]` recomputed on encode, checked on decode) is
    what would. `baseKinds` is what the cup holds before any option is
    chosen (espresso itself comes from the configuration). -/
structure EspressoOffer where
  restaurant    : Ref Restaurant
  canonical     : Ref CanonicalDish
  rule          : PriceRule
  baseKinds     : KindSet
  minPrice      : Money
  maxPrice      : Money
  veganPossible : Bool
  available     : Bool := true
  deriving Repr, LeanDb.Entity

/-- Does the cup, with this configuration, suit the diet? -/
def EspressoOffer.suits (baseKinds : KindSet) (c : EspressoConfig) (d : Diet) : Bool :=
  (baseKinds.kinds ++ c.ingredients).all fun k => d.allows k

/-- The one constructor that establishes the bounds. `veganPossible` is
    "some valid configuration is allowed by `Diet.vegan`" — a latte on a
    dairy-free base is vegan with oat, almond or soy. -/
def EspressoOffer.make (restaurant : Ref Restaurant) (canonical : Ref CanonicalDish)
    (rule : PriceRule) (baseIngredients : List IngredientKind) (available : Bool := true) :
    EspressoOffer :=
  let baseKinds := KindSet.make baseIngredients
  { restaurant, canonical, rule, baseKinds
    minPrice := rule.minPrice
    maxPrice := rule.maxPrice
    veganPossible := EspressoConfig.allValid.any fun c => EspressoOffer.suits baseKinds c .vegan
    available }

/-- Do the stored summaries agree with the rule? A Lean check, the way
    kernels' `search_columns_agree` is — the engine does not run it. -/
def EspressoOffer.summariesAgree (o : EspressoOffer) : Bool :=
  o.minPrice == o.rule.minPrice && o.maxPrice == o.rule.maxPrice
    && o.veganPossible == EspressoConfig.allValid.any fun c => EspressoOffer.suits o.baseKinds c .vegan

/-- The tabulation: one row per configuration the offer sells, the
    config flattened into five columns (`kernels` did the same for
    `NumericProps`). Written at seed time from the rule; a configuration
    with no row is one the café does not sell — availability is *absence*
    in stage 1. -/
structure OfferPrice where
  offer : Ref EspressoOffer
  temp  : Temp
  size  : Size
  milk  : Milk
  shots : Shots
  decaf : Bool
  price : Money
  deriving Repr, LeanDb.Entity

def OfferPrice.ofConfig (offer : Ref EspressoOffer) (c : EspressoConfig) (price : Money) :
    OfferPrice :=
  { offer, temp := c.temp, size := c.size, milk := c.milk, shots := c.shots, decaf := c.decaf, price }

def OfferPrice.toConfig (p : OfferPrice) : EspressoConfig :=
  { temp := p.temp, size := p.size, milk := p.milk, shots := p.shots, decaf := p.decaf }

/-- An order: the configuration (flattened, as above), and `quoted`, the
    price the customer saw — a snapshot, deliberately not a `Ref` to an
    `OfferPrice` row that a re-tabulation would replace. Whether the offer
    *sells* this configuration is a cross-row fact (this café has no oat)
    checked by `placeOrder` against `OfferPrice`, not by the type.
    (`at` is a Lean keyword, hence `placedAt`.) -/
structure OrderLine where
  offer    : Ref EspressoOffer
  temp     : Temp
  size     : Size
  milk     : Milk
  shots    : Shots
  decaf    : Bool
  quoted   : Money
  placedAt : Timestamp
  deriving Repr, LeanDb.Entity

def OrderLine.toConfig (l : OrderLine) : EspressoConfig :=
  { temp := l.temp, size := l.size, milk := l.milk, shots := l.shots, decaf := l.decaf }

/-- Appended to `Eats.schema` by `Main`: `EspressoOffer` references
    `Restaurant` and `CanonicalDish` (already in `schema`); the two
    children reference it. -/
def offersSchema : List TableSpec :=
  [Entity.spec EspressoOffer, Entity.spec OfferPrice, Entity.spec OrderLine]

end Eats
