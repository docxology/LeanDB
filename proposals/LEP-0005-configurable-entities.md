# LEP-0005: Configurable entities — stored functions over finite types

| Field | Value |
|---|---|
| Status | Draft |
| Number | LEP-0005 |
| Created | 2026-09-01 |
| Target | After LEP-0003 stages B–C |
| Primary goal | Modifiers, variants and options as a typed pattern, not a schema smell |
| Motivating case | A latte: hot or iced, five milks, three sizes, shots, decaf — and the price follows |

## Summary

A menu item is not a thing; it is a *family* of things indexed by
choices. A latte is `Temp × Size × Milk × Shots × Bool` — 180 drinks —
with a price, an ingredient list and an availability for each, some
combinations forbidden (no small iced), and all of it different at the
next café. Plain SQL has two ways to hold this and both are bad: one row
per drink (a tabulation that explodes and drifts from the rule that
generated it), or a "modifier groups" schema (five untyped tables whose
constraints, price interactions and dietary consequences all live in
application code). The awkwardness is not incidental. SQL has no finite
types and no functions as data, and a configurable item is exactly a
**function from a finite type to attributes**, under constraints.

LeanDB has finite types (closed worlds), derives their enumerations, and
after LEP-0002 has typed field symbols and after LEP-0003 has derived
columns and inline structures. This proposal names the pattern — a
**stored function over a finite configuration type** — and gives it
three coherent representations the engine keeps in sync:

| Representation | What it is | Who writes it | What it is for |
|---|---|---|---|
| **Rule** | compact, typed, first-order data (`PriceRule C`) | the author | truth; editing; audit |
| **Tabulation** | one child row per valid configuration | the engine, from the rule | pushed queries over configurations |
| **Bounds** | derived scalar columns (`minPrice`, `maxPrice`, `veganPossible`) | the engine, from the rule | narrowing a fetch before exact evaluation |

The same pattern is already in the repo twice without a name: gpumarket's
`Listing` rows are a tabulation of `(Gpu × Count × Pricing × Region) →
Price` per provider, written by hand; kernels' `Bench` rows are a
*sampled* tabulation of `DimBinding → Micros` — the infinite-domain
cousin, observed rather than derived. Naming the pattern is what lets the
engine do the tabulating.

## Why do this

### The SQL shape, and why it is awkward

Every point-of-sale schema (Square, Toast, Shopify's variants) converges
on the same thing:

```
item(id, name, base_price)
modifier_list(id, name, selection ∈ {single, multiple}, min, max)   -- "Milk", "Size", "Extras"
modifier(id, list_id, name, price_delta)                            -- "oat", +0.75
item_modifier_list(item_id, list_id)
variation(id, item_id, name, price)                                 -- sizes get their own table, because
                                                                    --   they are not a delta
order_line_modifier(line_id, modifier_id)
```

What it cannot say, so the application says it in every client:

- **Exclusivity and arity** are `selection`/`min`/`max` integers, checked
  by code, not by the schema. Nothing stops an order line with two milks.
- **Constraints between lists** — iced has no small; decaf is not offered
  on cold brew; an extra shot needs an espresso base — are not
  representable at all.
- **Price interactions** — a large iced oat latte is not `large + iced +
  oat`; the café prices it as a thing — are representable only by
  promoting the combination to a `variation`, which is the explosion the
  delta model was meant to avoid. Shopify caps variants at 100 per
  product for this reason.
- **Dietary consequences** of a choice (oat makes the latte vegan; extra
  chashu makes the ramen non-vegetarian) are disconnected from the
  modifier tables entirely.
- **Queries over configurations** — "where can I get an iced oat latte
  under $6 right now" — cannot be asked; the price of a configured item is
  computed by the client from deltas, so no index sees it.
- **Order lines** record modifier ids with no check that the combination
  was valid for that item at that time, and no snapshot of the price the
  customer saw.

Each of these is a *type-level* fact being carried by convention.

### The typed shape

```lean
inductive Temp  | hot | iced                       deriving …, LeanDb.ClosedEnum
inductive Size  | small | medium | large
inductive Milk  | whole | skim | oat | almond | soy
inductive Shots | single | double | triple

/-- The configuration space of an espresso drink: a product of closed
    worlds, so a finite type — 2·3·5·3·2 = 180 drinks — with a validity
    predicate that carves out the combinations no café offers. -/
structure EspressoConfig where
  temp  : Temp  := .hot
  size  : Size  := .medium
  milk  : Milk  := .whole
  shots : Shots := .double
  decaf : Bool  := false
  deriving Repr, DecidableEq, LeanDb.Config

instance : ConfigValid EspressoConfig where
  valid c := !(c.temp == .iced && c.size == .small)
```

Everything SQL could not say is now either a type or a total function:

- exclusivity and arity: a field *is* one value of a closed world;
  "multiple" is an `EnumSet` field (LEP-0003 A);
- constraints: `ConfigValid.valid`, and — because the space is finite —
  `Config.allValid` is a computed array and properties of the whole
  space are `decide`-able at compile time;
- dietary consequences: a total function at the vocabulary level,
  `EspressoConfig.ingredients : EspressoConfig → List IngredientKind`
  (`milk = .oat` contributes `.oat`, not `.dairy`); the compiler keeps it
  total when a milk is added;
- the price is a *stored function* — the subject of this proposal.

## Terminology

**Configuration type** `C`: a finite type — a structure whose fields are
closed enums, `Bool`, `EnumSet`s, or bounded newtypes — with a validity
predicate. `deriving LeanDb.Config` (proposed) gives it `all`, `allValid`,
a canonical index, and the `Inline` surface (LEP-0003 C): field symbols,
`fieldTy`, `get`, codecs, so it can be flattened into columns and named
in typed data.

**Configurable entity**: an entity with a field whose *meaning* is a
function `C → V` (price, availability, lead time, …), stored as a rule.

**Pattern** `Pattern C`: a partial configuration — some fields fixed,
the rest free — as typed data: `List (Σ f : Config.Field C,
Config.fieldTy f)`. `Pattern.matches : Pattern C → C → Bool`. This is
what "iced", "large oat", "any decaf" are as values, and it is typed by
LEP-0002's field symbols: `⟨.milk, .oat⟩` is checked, `⟨.milk, .large⟩`
does not elaborate.

**Rule**: first-order data whose evaluation is a total function `C → V`.

## Design

### The pricing rule

Functions cannot be stored; rules can. The smallest algebra that covers
what cafés actually do — a base, additive deltas, and explicit prices for
combinations — is:

```lean
structure PriceRule (C : Type) [Config C] where
  base      : Money
  /-- Additive. Every matching delta applies. `(milk = oat, +75)`, `(size = large, +100)`. -/
  deltas    : List (Pattern C × Delta)
  /-- Overriding. The first matching pattern *replaces* the computed price.
      `(temp = iced ∧ size = large ∧ milk = oat, 650)`. -/
  overrides : List (Pattern C × Money)
  deriving LeanDb.Json          -- stored as one column with a shape (LEP-0003 B)

def PriceRule.eval (r : PriceRule C) (c : C) : Money :=
  match r.overrides.find? (·.1.matches c) with
  | some (_, m) => m
  | none => r.base + (r.deltas.filter (·.1.matches c)).foldl (· + ·.2) 0

def PriceRule.tabulate (r : PriceRule C) : Array (C × Money) :=
  Config.allValid.map fun c => (c, r.eval c)
```

Two properties of a rule are worth stating because they are decidable
over the finite space and today live nowhere: **no two overrides match
the same configuration** (ambiguity), and **every valid configuration has
a non-negative price** (a delta cannot take it below zero). Both are
`decide`-able lints a base can run in tests or the engine can run on
insert through the codec's `validate`.

An `AvailabilityRule C` is the same shape with `Bool` values, or simply
`unavailable : List (Pattern C)` — "no oat milk here" is one pattern.

### The entity and its three representations

```lean
structure Offer where
  restaurant : Ref Restaurant
  canonical  : Ref CanonicalDish
  rule       : PriceRule EspressoConfig            -- truth: JSON column with a shape
  @[derived] minPrice : Money := rule.tabulate.map (·.2) |>.min      -- bounds: push
  @[derived] maxPrice : Money := …
  @[derived] veganPossible : Bool :=                                  -- a dietary bound
    Config.allValid.any fun c => Diet.vegan.allowsAll (baseIngredients ++ c.ingredients)
  @[derived] prices : List OfferPrice := rule.tabulate.map …          -- tabulation: child rows
  deriving Repr, LeanDb.Entity

/-- One row per valid configuration: the rule, materialized. Config
    fields flatten to columns (LEP-0003 C), so every option is pushable. -/
structure OfferPrice where
  offer  : Ref Offer
  config : EspressoConfig      -- → offer_price.config_temp, config_size, config_milk, …
  price  : Money
  deriving Repr, LeanDb.Inline-record-for-a-child-table (LEP-0003 D)
```

The `@[derived]` mechanism of LEP-0003 B3 does the coherence: `encode`
recomputes the bounds and the child rows from the rule on every write
through LeanDB, `decode` checks the stored values against the
recomputation, and a raw-SQL edit that desynchronizes them is refused on
read. **Derived child rows** are the one extension beyond LEP-0003 as
written: B3 covers derived *scalar* columns; D covers child tables; this
proposal needs a derived child table — B3 applied to D — which is
regenerated (delete-and-insert within the write's transaction) when its
source changes. That is a materialized view over a finite domain, and
because the domain is finite the materialization is total and cheap:
180 rows per offer, a few thousand per café.

### What each representation is for

- **"Cheapest iced oat latte in San Francisco, open now."** A join on
  the tabulation: `Offer × OfferPrice × Restaurant × Hours` with
  `config_temp IS 'iced' ∧ config_milk IS 'oat' ∧ …`, sorted by price.
  Everything pushes; nothing is evaluated in Lean; the rule is never
  read.
- **"Espresso drinks under $6 for a vegan."** `minPrice ≤ 600 ∧
  veganPossible` pushes as a prefilter on `Offer`; the exact
  configurations that satisfy both are then enumerated in Lean over the
  survivors — bounds narrow, evaluation is exact, the honest split.
- **"Who offers oat milk?"** `exists` over `OfferPrice` with
  `config_milk IS 'oat'` (LEP-0004), or a derived `hasOat : Bool` if it is
  asked often enough to earn a column.
- **A price change.** Edit the rule; the engine re-tabulates; history is
  the rule's history, one JSON value per edit, not 180 row updates.
- **An order line.** `OrderLine (offer, config : EspressoConfig, quoted :
  Money, at : Timestamp)` — config inline-flattened, the quoted price a
  snapshot. Validity of the configuration *for that offer* is a
  cross-row fact (this café has no oat), checked at insert by a query
  against `OfferPrice`, not by the type. Say so in the docstring; it is
  the same boundary as `Kernel.make`'s search columns before B3.

### Families with different configuration types

A latte, a ramen and a cookie do not share a configuration type. The
dependent version — `structure Dish where family : DishFamily; config :
ConfigOf family` — is a dependent field, which `deriving Entity` refuses
and SQL cannot hold except as forty nullable columns. The typed answer is
**one offer table per configuration type**: `EspressoOffer`, `RamenOffer`,
`PlainOffer` (config `Unit`), each an ordinary entity, with
`CanonicalDish.family` saying which. A cross-family listing is a fold
over `DishFamily.all` dispatching to the right query — a `Query`
constructor per family, in the query-universe sense (study §5). This is
the relational normal form the modifier-groups schema was avoiding by
being untyped, and it is not awkward once the dispatch is code.

### What is pattern and what is engine

Everything above can be built **today** by hand, and the restaurant base
should build it that way first: config as a structure of closed enums
hand-flattened into columns (kernels did this for `NumericProps`), a
hand-maintained `OfferPrice` child table, hand-written `all`/`allValid`,
the rule as a JSON codec'd newtype with hand-maintained `minPrice`. The
cost is the same cost the kernel base measured — the invariants live in
`make` and not in the engine — and the point of building it first is to
measure it.

The engine pieces, each motivated by a specific line above:

1. **`deriving LeanDb.Config`** — product-of-finite-types enumeration
   (`all`, `allValid`, canonical index), plus the `Inline` surface, so
   `Pattern C` is typed by field symbols and `decide` works over the
   space. Small; sits on LEP-0003 C.
2. **`Pattern C` and `PriceRule C`** as library types with `Json`, shape,
   and the two lints. Small; sits on LEP-0002 symbols and LEP-0003 B.
3. **Derived child rows** — `@[derived]` on a `List` field of a child
   record type, regenerated transactionally on write, checked on read.
   The one genuinely new mechanism; sits on LEP-0003 B3 + D.
4. **`EnumSet`** for multi-select option groups ("extras"). LEP-0003 A,
   already scheduled.

## Vocabulary growth: what the compiler sees, what the migration sees

The reason to put queries, data and migrations in one universe is that an
edit to the vocabulary has an *impact you can see* — not only on stored
data, but on how the data is used. Add `Milk.pistachio` and:

1. **Facts that are functions in code** — `EspressoConfig.ingredients`,
   `Diet.forbids`, gpumarket's `Gpu.spec` — are `match`es over the closed
   world. The build fails until each one says what pistachio is. The
   compiler walks you to every table of facts that must learn about it.
   This is what LeanDB already does.

2. **Facts that are rows** — a café's `PriceRule` — are data, and data
   has no `match`. A rule that never mentions pistachio does not fail; it
   prices pistachio at `base + size`, silently — the modifier-groups bug
   wearing a type. What saves it is that the configuration space is
   finite *and typed*: growing `Milk` changes the CHECK on every milk
   column, which is already a fingerprint mismatch and a rebuild in
   `migrate status`, and that same step can evaluate every stored rule
   over the new configurations and report **"3 offers price `pistachio`
   by omission; 1 declares it unavailable"**. That is impact-on-usage at
   migrate time, possible only because the rule is a typed value over the
   same `Milk` the column is checked against, not a JSON blob of strings.
   This is the **rule-coverage check**, engine stage 2 of this proposal:
   `planMigration` learns that a closed-world growth on a configuration
   type touches every `PriceRule` column over that type, and the report
   names the rows that price the new variant by omission.

3. **The tabulation** has the safe default for free: no `OfferPrice` row
   for pistachio means `quote` refuses with a typed error. Absence is a
   refusal, never an invented price. Regenerating the tabulation after the
   rule is edited (derived child rows, engine stage 3) is what makes the
   new variant sellable — deliberately, per offer.

4. **Queries**, once they are data too (R5, study §5): `migrate status`
   can say the third thing — "these four queries case-split on `Milk`;
   their plans change" — and replay them before `apply`.

One edit, three reports, one universe. The compiler covers what is code;
the migration covers what is rows; the finite, typed configuration space
is what lets the second be as total as the first.

## The general pattern, stated once

> **Stored function over a finite type.** A field whose value means
> `C → V` for a finite `C`. Store the *rule* as typed first-order data
> (truth); derive the *tabulation* as child rows (queryable, pushable);
> derive *bounds* as scalar columns (narrowing). The engine owns the
> coherence of the three. Properties of the function are decidable over
> `C` and belong in tests or the codec's validator.

Where it shows up, beyond menus: product variants (size × colour →
SKU, price, stock); SaaS pricing (plan × seats × region × term); cloud
listings (gpumarket: gpu × count × pricing × region → price, per
provider — today a hand-written tabulation with no rule behind it);
shipping rates (zone × weight band × speed); insurance (a rating table);
any configurator. The infinite-domain cousin — kernels' `Bench` over
`DimBinding` — is *observed*, not derived: rows are samples of an unknown
function, and nothing should regenerate them. The distinction is whether
the engine can compute the table from a rule; keep the two apart in
docstrings and never put `@[derived]` on a sampled table.

## Staging

1. **eats, by hand** (after LEP-0004 lands there): `EspressoConfig`,
   hand-flattened; `EspressoOffer` with a JSON rule and hand-maintained
   `minPrice`/`maxPrice`; `OfferPrice` tabulated by a `seed`-time
   function; `OrderLine`. Queries: `priceOf`, `cheapestConfigured`
   (pattern → cheapest matching offer in a city, pushed),
   `configurationsFor (offer) (diet)`, `offersWith (pattern)`. Measure
   what is residual and what the hand-maintenance costs; write it up as
   this LEP's evidence section, the way kernels did for LEP-0003.
2. **Engine 1–2** once LEP-0003 C exists: `deriving Config`, `Pattern`,
   `PriceRule`, lints by `decide`; eats switches.
3. **Engine 3** once LEP-0003 D exists: derived child rows; eats'
   `OfferPrice` becomes `@[derived]`; the seed-time tabulation is deleted.
4. gpumarket: a `Provider`-level rule from which its `Listing` rows could
   be derived — as a demonstration that the pattern was already there.

## Alternatives considered

### Tabulation only (Shopify variants)

Store the 180 rows and nothing else. Queryable, but the rule that
generated them is gone: a price change is 180 updates with no audit of
*why*, and the constraint that generated the set (no small iced) is not
recorded anywhere. This is the representation to *derive*, not to
author.

### Rule only, evaluate in Lean

Store the rule, compute prices on read. Honest and small, but every
configuration query is a full fetch plus evaluation, and "cheapest iced
oat latte in the city" is exactly the query a menu database exists for.
Bounds help; they do not make the query pushable.

### Modifier groups as entities (the SQL schema, typed)

`ModifierGroup`, `Modifier (group, delta)`, `OfferGroup`, with closed
enums for the names. Better than SQL — the names are typed — but it
keeps the shape that cannot express interactions or constraints, and it
puts `min`/`max`/`selection` back as data the type system cannot check.
The configuration *type* is the point.

### Dependent configuration types

`inductive EspressoConfig | hot (size : HotSize) … | iced (size : IcedSize) …`
for options whose *type* depends on other options. Correct, and the
flattening (a tag column plus per-variant nullable columns with a CHECK
tying them) is known; but for menus the product-plus-validity form is
enough, and every dependent case seen so far is a forbidden combination,
not a different field set. Reserve the sum form for when a base needs a
variant with genuinely different fields.

## Acceptance criteria

For stage 1 (by hand, in eats):

1. `cheapestConfigured ⟨[⟨.temp, .iced⟩, ⟨.milk, .oat⟩]⟩ .sanFrancisco` is one
   `select` with residual 0 over `Offer × OfferPrice × Restaurant`, and
   its answer equals the fold over rules evaluated in Lean.
2. `#check_failure` for a `Pattern` fixing `.milk` to a `Size` (typed by
   field symbols — requires LEP-0002's `Field`, which exists).
3. `decide` proves, for the seed rules, that no two overrides overlap and
   no price is negative; a deliberately ambiguous rule fails the check.
4. Choosing `milk = .oat` on a latte whose base ingredients contain no
   dairy makes `dietsFor` include `.vegan`; choosing `.whole` does not.
5. An `OrderLine` with a configuration the offer does not sell is refused
   at insert with a named reason.
6. The evidence section records the hand-maintenance cost (which
   invariants live only in `make`, what a raw-SQL edit can desynchronize),
   so engine stages 2–3 are written from measurement.
