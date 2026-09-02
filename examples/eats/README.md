# eats — restaurants, dishes, diets computed not stored, and configurable offers

See `CLI_TRANSCRIPT.md` for the base's own transcript. This file is the
evidence section for LEP-0005 stage 1, which was built here by hand.

## Evidence for LEP-0005 stage 1: a stored function over a finite type, by hand

Everything below was measured on this base (`eats_offers_tests`, `eats
log`, `set_option leandb.explain true`); residual counts are from the
tactic. The code is `Eats/Config.lean` (the space and the rule),
`Eats/Offers.lean` (the entities), `Eats/OfferQueries.lean`,
`Eats/OfferSeed.lean`, `EatsOffersTests.lean` — 674 lines of library
and seed for one configurable family, about a third of which is what
`deriving LeanDb.Config` and derived child rows would generate.

**The space, and what `decide` can do with it.** `EspressoConfig` is
`Temp × Size × Milk × Shots × Bool` (`Size` is the base's existing
`small | regular | large`), 180 drinks, 125 valid after two rules (no
small iced, no decaf triple). `all`/`allValid` are hand-written list
comprehensions over `ClosedEnum.all`. The two lints — `overridesDisjoint`
(no configuration matched by two overrides) and `nonNegative` (no
configuration priced below zero) — are `Bool` folds over `allValid`, and
they *are* provable at compile time for the seed rules, with one caveat:
plain `decide` hits `maxRecDepth` in the elaborator's evaluator, and
`decide +kernel` (the kernel reduces the closed term directly) proves
each in about a second — eleven such `example`s in the test file, two of
them proving the deliberately bad rules `= false`. No `native_decide`.
The same lints run in the codec's `validate`, so the CLI refuses the
ambiguous rule too:

```
$ eats insert espresso_offer {"restaurant":1,"canonical":7,"rule":"{\"base\":500,\"deltas\":[],\"overrides\":[[[{\"milk\":{\"m\":\"oat\"}}],600],[[{\"temp\":{\"t\":\"iced\"}}],550]]}",…}
{"code":"decode","message":"espresso_offer.rule: ambiguous rule: two overrides match iced/regular/oat/single/regular","ok":false}
```

**Typed options without field symbols.** A structure gets no
`Field`/`fieldTy` from LEP-0002, so `Pattern` is typed by a hand-written
`inductive EspressoOption | temp (t : Temp) | size (s : Size) | …`:
`#check_failure (EspressoOption.milk .large)` fails with `Unknown
constant Eats.Milk.large`, and `EspressoOption.milk Size.large` with the
type mismatch. It is 40 lines (`matches`, `render`, `parse`) per
configuration type, and it is exactly `Σ f, fieldTy f` written out.

**Which invariants live only in `make`.** `EspressoOffer.make` is the
one place that establishes `minPrice = rule.minPrice`, `maxPrice =
rule.maxPrice` and `veganPossible = ∃ c ∈ allValid, vegan allows
(baseKinds ++ c.ingredients)`. Nothing checks them on read.
`EspressoOffer.summariesAgree` is a Lean check the tests run, the way
kernels' `search_columns_agree` is. The tabulation has no constructor at
all: `OfferSeed.tabulate!` writes it once, from the rule, at seed time,
and nothing links it to the `rule` column afterwards.

**What a write can desynchronize.** Three ways, all accepted by the
engine:

- `update` of the rule alone (test `desynchronize`): Samovar's base goes
  450 → 900 and the row is accepted; afterwards
  `minPrice=400 rule.minPrice=850 tabulated=(some 600) rule.eval=1050`
  — the bound says 400, the rule 850; the tabulation quotes 600 for a
  drink the rule now prices at 1050; `placeOrder` would sell it at 600.
- CLI `insert` with summaries that contradict the rule is accepted with
  exit 0 (`minPrice:1, maxPrice:99999, veganPossible:false` on a
  `base 500` rule → `{"ok":true,"row":{…"id":7,"maxPrice":99999,"minPrice":1…}}`),
  and it has no `OfferPrice` rows at all: `cheapestConfigured` will
  never find it, `quote` refuses every configuration, and no query
  notices that the offer is unsellable.
- A raw `UPDATE espresso_offer SET rule = …` is the first case without
  even the Lean-side `update`; a raw `DELETE FROM offer_price` is the
  second.

A fourth, subtler one is *availability as absence*: Highwire's "no oat"
is a seed-time filter (`unavailableHighwire`) applied to the tabulation
only, so its `minPrice`/`maxPrice`/`veganPossible` are computed over all
125 configurations including the 25 oat ones it does not sell. Here it
is harmless (oat is not its cheapest milk; almond and soy keep it vegan-
possible) but that is luck, not a check. The rule is the truth *and* the
tabulation is the truth, and stage 1 has no single thing that is.

**What stayed residual and why.** The plans, verbatim from `eats log`:

```
priceOf              offer_price | pushed: (((((t0."offer" IS ? AND t0."temp" IS ?) AND t0."size" IS ?) AND t0."milk" IS ?) AND t0."shots" IS ?) AND t0."decaf" IS ?), residual conjuncts: 0
cheapestConfigured   espresso_offer×offer_price×restaurant | pushed: ((((((((t1."offer" IS t0."id" AND t0."restaurant" IS t2."id") AND t0."available" IS ?) AND t2."city" IS ?) AND t1."temp" IS ?) AND t1."size" IS ?) AND t1."milk" IS ?) AND t1."shots" IS ?) AND t1."decaf" IS ?), residual conjuncts: 0
offersWith           espresso_offer×offer_price×restaurant | pushed: ((((t1."offer" IS t0."id" AND t0."restaurant" IS t2."id") AND t0."available" IS ?) AND t2."city" IS ?) AND t1."milk" IS ?), residual conjuncts: 0
cheapestMatching     espresso_offer×offer_price×restaurant | pushed: (((t1."offer" IS t0."id" AND t0."restaurant" IS t2."id") AND t0."available" IS ?) AND t2."city" IS ?), residual conjuncts: 1
cheapestOptional     espresso_offer×offer_price×restaurant | pushed: (((t1."offer" IS t0."id" AND t0."restaurant" IS t2."id") AND t0."available" IS ?) AND t2."city" IS ?), residual conjuncts: 2
```

- *A fully specified configuration pushes entirely.* Hand-flattening the
  config into five columns is what makes `cheapestConfigured` residual 0
  over three tables: the LEP's acceptance 1 holds, and the answer equals
  the fold over every SF rule evaluated in Lean (`[600, 725, 725, 725]`
  both ways; Samovar wins; the planned select equals `selectUnplanned`).
- *A runtime pattern is residual by nature.* `cheapestMatching (p :
  Pattern)` keeps `Pattern.matches p op.val.toConfig` in Lean (residual
  1): the tactic case-splits closed-enum columns and closed-enum
  parameters, and a `List EspressoOption` typed at the CLI is neither —
  it cannot emit a conjunction whose length it does not know at compile
  time. Same reason as `suitableAdHoc`'s `avoid.contains`. The joins and
  the city still push, so the fetch is the city's rows, not the table.
- *The `Option`-parameter probe: does not push.* `cheapestOptional (temp?
  : Option Temp) (milk? : Option Milk)` with
  `(temp?.isNone || some op.val.temp == temp?)` is residual 2 — each
  option conjunct is opaque. With `leandb.explain` the reflected plan is
  `… .andS (Pred.opaque fun row => temp?.isNone || some row.2.1.val.temp == temp?)`;
  the `match temp? with | none => true | some t => op.val.temp == t`
  spelling is opaque the same way; and the closed-parameter control
  (`temp : Temp`, `op.val.temp == temp`) is `Pred.eq (Col.here
  OfferPrice.Field.temp).there EqOp.eq temp`, pushed. The captured-
  parameter split (`findEnumParam`) asks `ClosedEnum (Option Temp)` and
  gets nothing. **Engine finding:** case-splitting a captured `Option α`
  parameter for closed `α` — `none` guard ∧ `true`, plus `⋁_c (param IS
  some c ∧ col IS c)` — would make every optional filter pushable in one
  step; it is the same `splitWorld` with `none` as an extra constructor
  and a value/value guard on the parameter. Until then an optional
  filter is a runtime pattern, and residual.

**What the tabulation costs.** 125 rows per offer (the 125 valid drinks
of 180), 725 `offer_price` rows for the six seeded offers (Highwire's
100 = 125 − 25 oat configurations); 725 single-row inserts at seed time,
one `withLog` entry each. `OrderLine` carries the same five columns
again as a snapshot. A price change is a rule edit plus a delete-and-
reinsert of 125 rows that nothing in stage 1 performs — `update` of the
rule leaves the 125 rows as they were (above). At 5 cafés this is
nothing; at 5,000 offers it is 625,000 rows that are *entirely*
determined by 5,000 JSON values, and the only place that knows how to
regenerate them is a seed function.

**What `deriving Config` and `@[derived]` child rows would remove.**
- `deriving LeanDb.Config` on `EspressoConfig`: `all`, `allValid`,
  `render`/`parse`, the `EspressoOption` inductive with `matches`/
  `render`/`parse`, `Pattern`, and the per-enum `ToJson`/`FromJson`
  instances — about 120 of `Config.lean`'s 263 lines, plus the
  `CliArg`s for a config and a pattern. `PriceRule` and its two lints
  are 60 lines that are already generic over the config type and belong
  in the library (engine stage 2 of the LEP).
- Inline flattening (LEP-0003 C): `OfferPrice` and `OrderLine` each
  spell the five config columns by hand, plus `ofConfig`/`toConfig`;
  `config : EspressoConfig` would replace both and keep `priceOf`'s six
  pushed equalities.
- `@[derived] minPrice/maxPrice/veganPossible` (LEP-0003 B3): `make`
  and `summariesAgree` go, and the `update`/CLI/raw-SQL desynchronizations
  above become decode-time refusals.
- `@[derived] prices : List OfferPrice` (B3 applied to D): `tabulate!`
  goes, the seed-time filter becomes an `unavailable : List Pattern`
  field of the offer that the tabulation respects *and* the bounds see,
  and `update` of the rule regenerates the 125 rows in the same
  transaction. This is the one mechanism that makes "the rule is the
  truth" a fact rather than a docstring.

**Deviations from the LEP as written.** `Size` is reused from
`Enums.lean` (`regular`, not `medium`), so the vocabulary stays one
closed world per notion. `at` is a Lean keyword; the order-line column is
`placedAt`. `Delta` is `Int64` and `Money` is `Nat`: `PriceRule.evalRaw`
sums in `Int` and `eval` floors at zero, with `nonNegative` guarding the
floor from ever mattering. `configurationsFor` needs the base ingredients
at query time, so `EspressoOffer` carries one extra column, `baseKinds`,
a canonical-TEXT set of `IngredientKind` (kernels' `fuses` idiom; the
`EnumSet` of LEP-0003 A). Acceptance 4 is met through it: on a
dairy-free latte `configurationsFor … .vegan` returns 75 configurations
(3 non-dairy milks × 25), every one with `milk ∈ {oat, almond, soy}` and
none with `whole`.

Transcript excerpts (the seed's ids; offer 4 is Samovar, offer 5 is
Highwire):

```
$ eats query cheapestConfigured iced large oat double false sanFrancisco
{"ok":true,"result":[[{…"id":4,"maxPrice":675,"minPrice":400,"restaurant":7…},[{"decaf":0,"id":488,"milk":"oat","offer":4,"price":600,"shots":"double","size":"large","temp":"iced"},{…"name":"Samovar Tea Lounge"…}]],…
$ eats query cheapestMatching milk=large sanFrancisco
{"code":"decode","message":"cli.p: milk: \"large\" is not one of #[whole, skim, oat, almond, soy]","ok":false}
$ eats query offersWith oat oakland
{"ok":true,"result":[]}
$ eats query quote 5 iced/large/oat/double/regular
{"code":"decode","message":"offer_price.config: offer 5 does not sell iced/large/oat/double/regular: this café does not sell that configuration","ok":false}
$ eats query placeOrder 4 iced/large/oat/double/regular 1756684800
{"ok":true,"result":{"decaf":0,"id":1,"milk":"oat","offer":4,"placedAt":1756684800,"quoted":600,"shots":"double","size":"large","temp":"iced"}}
$ eats query placeOrder 1 iced/small/whole/double/regular 1756684800
{"code":"decode","message":"offer_price.config: offer 1 does not sell iced/small/whole/double/regular: this café does not sell that configuration","ok":false}
```
