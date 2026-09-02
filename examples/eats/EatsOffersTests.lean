import Eats

/-! Tests for LEP-0005 stage 1 (configurable offers, by hand): the LEP's
acceptance criteria 1–5, plus the hand-maintenance evidence the README
reports — what the codec refuses, what `update` does not, how many rows
the tabulation costs, and the logged plans of every offer query
(printed, never asserted). Runs against its own database under `.lake/`
so `eats_tests` is untouched. -/

open LeanDb Eats

private def check (c : Bool) (m : String) : IO Unit :=
  unless c do throw <| IO.userError s!"FAIL: {m}"

private def checkD (c : Bool) (m : String) : DbM Unit :=
  unless c do throw (.sqlite s!"FAIL: {m}")

private def expectOk (r : Except DbError α) (ctx : String) : IO α :=
  match r with
  | .ok a => pure a
  | .error e => throw <| IO.userError s!"FAIL: {ctx}: {e}"

private def dbPath : System.FilePath := ".lake" / "eats_offers_test.sqlite"

/-- The base schema plus the offer tables, in FK order. -/
private def fullSchema : List TableSpec := schema ++ offersSchema

/-! ## 2. Typed options: a pattern fixing `milk` to a `Size` does not elaborate -/

#check_failure (EspressoOption.milk .large)
#check_failure (EspressoOption.milk Size.large)
#check_failure (EspressoOption.temp Milk.oat)
#check_failure ([EspressoOption.temp .iced, EspressoOption.size .oat] : Pattern)

-- and the entity side: the tabulation's config columns are typed too
#check_failure LeanDb.select [OfferPrice] (fun op => op.val.milk == Size.large)

/-! ## 3. Lints, decided over the finite space at compile time

Plain `decide` hits `maxRecDepth` in the elaborator's evaluator (125
configurations × pattern matching is too deep for `whnf`); `decide
+kernel` hands the closed term straight to the kernel, which reduces it
in about a second per lint. No `native_decide` needed. -/

example : ruleBlueBottle.overridesDisjoint = true := by decide +kernel
example : ruleBlueBottle.nonNegative = true := by decide +kernel
example : ruleSightglass.overridesDisjoint = true := by decide +kernel
example : ruleSightglass.nonNegative = true := by decide +kernel
example : ruleSamovar.nonNegative = true := by decide +kernel
example : ruleHighwire.nonNegative = true := by decide +kernel
example : ruleStrada.nonNegative = true := by decide +kernel
-- the deliberately bad rules fail the same lints
example : ruleAmbiguous.overridesDisjoint = false := by decide +kernel
example : ruleNegative.nonNegative = false := by decide +kernel
-- and the space is what the docstrings say
example : EspressoConfig.all.size = 180 := by decide +kernel
example : EspressoConfig.allValid.size = 125 := by decide +kernel

/-! ## Vocabulary, in Lean -/

private def icedLargeOat : EspressoConfig := { temp := .iced, size := .large, milk := .oat }

private def vocabulary : IO Unit := do
  check (EspressoConfig.all.size == 180) "180 configurations"
  check (EspressoConfig.allValid.size == 125) "125 valid configurations"
  check (!EspressoConfig.valid { temp := .iced, size := .small }) "no small iced"
  check (!EspressoConfig.valid { shots := .triple, decaf := true }) "no decaf triple"
  for c in EspressoConfig.all do
    check (match EspressoConfig.parse c.render with | .ok c' => c' == c | .error _ => false)
      s!"render/parse round trip {c.render}"
  check (icedLargeOat.render == "iced/large/oat/double/regular") "canonical text"
  check (Pattern.matches [.temp .iced, .milk .oat] icedLargeOat) "pattern matches"
  check (!Pattern.matches [.temp .iced, .milk .whole] icedLargeOat) "pattern rejects"
  check (Pattern.matches [] icedLargeOat) "empty pattern matches everything"
  check (icedLargeOat.ingredients == [.coffee, .grain]) "oat contributes grain, not dairy"
  check (EspressoConfig.ingredients {} == [.coffee, .dairy]) "whole milk contributes dairy"
  -- evaluation: sums, and the override that replaces the sum
  check (ruleBlueBottle.eval icedLargeOat == ⟨725⟩) "Blue Bottle iced large oat = 500+75+100+50"
  check (ruleSightglass.eval icedLargeOat == ⟨725⟩) "Sightglass override, not 525+80+100+50"
  check (ruleSightglass.eval { icedLargeOat with milk := .almond } == ⟨755⟩) "Sightglass almond sums"
  check (ruleSamovar.eval icedLargeOat == ⟨600⟩) "Samovar iced large oat"
  check (ruleStrada.minPrice == ⟨375⟩ && ruleStrada.maxPrice == ⟨550⟩) "Strada bounds"
  check (ruleNegative.eval { size := .small, decaf := true } == ⟨0⟩) "eval floors at zero"
  check (ruleNegative.evalRaw { size := .small, decaf := true } == -25) "evalRaw does not"
  -- the codec: round trip, and refusal of the two bad rules
  let col := toCol ruleSightglass
  check (match fromCol (α := PriceRule) col with | .ok r => r == ruleSightglass | .error _ => false)
    "PriceRule codec round trip"
  match fromCol (α := PriceRule) (toCol ruleAmbiguous) with
  | .error m => check (m.startsWith "ambiguous rule") s!"ambiguous rule refused: {m}"; IO.println s!"codec: {m}"
  | .ok _ => throw <| IO.userError "FAIL: ambiguous rule accepted by the codec"
  match fromCol (α := PriceRule) (toCol ruleNegative) with
  | .error m => check (m.startsWith "negative price") s!"negative rule refused: {m}"; IO.println s!"codec: {m}"
  | .ok _ => throw <| IO.userError "FAIL: negative rule accepted by the codec"
  -- the same refusal through the CLI's JSON path: `insert espresso_offer <json>`
  let bad := Lean.Json.mkObj [("restaurant", 1), ("canonical", 1), ("rule", Lean.Json.str (Lean.toJson ruleAmbiguous).compress),
    ("baseKinds", ""), ("minPrice", 500), ("maxPrice", 600), ("veganPossible", true)]
  match rowOfJson EspressoOffer bad with
  | .error (.decode "espresso_offer" "rule" m) => IO.println s!"rowOfJson: espresso_offer.rule: {m}"
  | .error e => throw <| IO.userError s!"FAIL: wrong error for ambiguous rule via JSON: {e}"
  | .ok _ => throw <| IO.userError "FAIL: ambiguous rule accepted via rowOfJson"

/-! ## Runtime -/

private def offerAt (name : String) (slug : String) : DbM (Stored EspressoOffer) := do
  let rows ← select [EspressoOffer, Restaurant, CanonicalDish] (fun (o, r, c) =>
    o.val.restaurant == r.ref && o.val.canonical == c.ref
      && r.val.name.raw == name && c.val.slug.raw == slug)
  match rows[0]? with
  | some (o, _, _) => pure o
  | none => throw (.sqlite s!"FAIL: no offer for {slug} at {name}")

private def runQueries : DbM Unit := do
  seed
  seedOffers
  let offers ← fetchAll EspressoOffer
  checkD (offers.size == 6) "six offers seeded"
  for o in offers do
    checkD o.val.summariesAgree s!"summaries agree with the rule for offer {o.id.toInt64}"
  let prices ← fetchAll OfferPrice
  -- 5 × 125 valid, plus Highwire's 125 − 25 oat configurations
  checkD (prices.size == 725) s!"tabulation: 725 rows, got {prices.size}"
  IO.println s!"tabulation: {prices.size} offer_price rows for {offers.size} offers ({EspressoConfig.allValid.size} valid configurations of {EspressoConfig.all.size})"
  let highwire ← offerAt "Highwire Coffee" "latte"
  checkD ((prices.filter (·.val.offer == highwire.ref)).size == 100) "Highwire: 100 rows (no oat)"
  -- 1. cheapestConfigured equals the fold over rules evaluated in Lean
  let cheapest ← cheapestConfigured .iced .large .oat .double false .sanFrancisco
  let sfOffers ← select [EspressoOffer, Restaurant] (fun (o, r) =>
    o.val.restaurant == r.ref && o.val.available && r.val.city == .sanFrancisco)
  let evaluated := (sfOffers.map fun (o, _) => (o.val.rule.eval icedLargeOat).minor).qsort (· < ·)
  checkD (cheapest.map (·.2.1.val.price.minor) == evaluated)
    s!"cheapestConfigured agrees with the fold: {cheapest.map (·.2.1.val.price.minor)} vs {evaluated}"
  checkD (evaluated[0]? == some 600) "the fold's minimum is 600"
  checkD (cheapest[0]?.map (·.2.2.val.name.raw) == some "Samovar Tea Lounge") "Samovar is cheapest"
  checkD ((← cheapestConfigured .iced .large .oat .double false .oakland).isEmpty) "no oat in Oakland"
  checkD ((← cheapestConfigured .iced .large .almond .double false .oakland).size == 1) "almond in Oakland"
  checkD ((← cheapestConfigured .iced .small .whole .double false .sanFrancisco).isEmpty) "no small iced anywhere"
  -- the runtime-pattern and Option-parameter forms give the same answer
  let matching ← cheapestMatching [.temp .iced, .milk .oat] .sanFrancisco
  checkD (matching[0]?.map (·.2.1.val.price.minor) == some 525) "cheapest iced oat: Samovar regular single 525"
  checkD (matching.all fun (_, op, _) => op.val.temp == .iced && op.val.milk == .oat) "pattern filter holds"
  let optional ← cheapestOptional (some .iced) (some .oat) .sanFrancisco
  checkD (optional.map (·.2.1.id.toInt64) == matching.map (·.2.1.id.toInt64)) "Option form agrees with the pattern"
  checkD ((← cheapestOptional none none .sanFrancisco).size == 4 * 125) "no filter: every SF row"
  -- offersWith: pushed `milk IS ?`, deduplicated to offers
  let oatSF ← offersWith .oat .sanFrancisco
  checkD (oatSF.size == 4) s!"four SF offers with oat, got {oatSF.size}"
  checkD ((← offersWith .oat .oakland).isEmpty) "Highwire has no oat"
  checkD ((← offersWith .almond .oakland).map (·.2.val.name.raw) == #["Highwire Coffee"]) "Highwire has almond"
  -- 4. configurationsFor: a dairy-free base is vegan with oat, never with whole
  let bbLatte ← offerAt "Blue Bottle Hayes Valley" "latte"
  let vegan ← configurationsFor bbLatte.ref .vegan
  checkD (vegan.any fun (c, _) => c.milk == .oat) "vegan: an oat configuration"
  checkD (vegan.all fun (c, _) => c.milk != .whole && c.milk != .skim) "vegan: no dairy milk"
  checkD (vegan.size == 75) s!"vegan: 3 milks × 25 configurations, got {vegan.size}"
  checkD ((← configurationsFor bbLatte.ref .vegetarian).size == 125) "vegetarian: everything"
  checkD ((← configurationsFor bbLatte.ref .nutFree).all fun (c, _) => c.milk != .almond) "nut-free: no almond"
  checkD (vegan.all fun (c, m) => m == ruleBlueBottle.eval c) "configurationsFor prices from the rule"
  checkD (bbLatte.val.veganPossible) "veganPossible on the latte"
  -- 5. placeOrder: refused for a configuration the offer does not sell
  let refused ← tryCatch (do discard <| placeOrder highwire.ref icedLargeOat ⟨1756684800⟩; pure none)
    (fun e => pure (some e))
  match refused with
  | some (.decode "offer_price" "config" m) => IO.println s!"placeOrder refused: {m}"
  | some e => throw (.sqlite s!"FAIL: wrong error for oat at Highwire: {e}")
  | none => throw (.sqlite "FAIL: oat at Highwire was accepted")
  let refused2 ← tryCatch
    (do discard <| placeOrder bbLatte.ref { temp := .iced, size := .small } ⟨1756684800⟩; pure none)
    (fun e => pure (some e))
  checkD (refused2 matches some (.decode ..)) "small iced is refused everywhere"
  checkD ((← fetchAll OrderLine).isEmpty) "a refused order inserts nothing"
  let samovar ← offerAt "Samovar Tea Lounge" "latte"
  let line ← placeOrder samovar.ref icedLargeOat ⟨1756684800⟩
  checkD (some line.val.quoted == (← priceOf samovar.ref icedLargeOat)) "quoted equals priceOf"
  checkD (line.val.quoted == ⟨600⟩ && line.val.toConfig == icedLargeOat) "the order line snapshot"
  checkD ((← quote highwire.ref { milk := .almond }) == ⟨535⟩) "quote almond at Highwire"

/-- The hand-maintenance cost, demonstrated: `update` of the rule alone
    is accepted, and the stored summaries and tabulation are now wrong. A
    Lean check (`summariesAgree`) is the only thing that notices. -/
private def desynchronize : DbM Unit := do
  let samovar ← offerAt "Samovar Tea Lounge" "latte"
  let pricier : PriceRule := { ruleSamovar with base := ⟨900⟩ }
  let updated ← update samovar { samovar.val with rule := pricier }
  checkD (!updated.val.summariesAgree) "after `update` of the rule alone, the summaries disagree"
  checkD (updated.val.minPrice == ruleSamovar.minPrice) "minPrice still says the old rule's minimum"
  checkD ((← priceOf samovar.ref icedLargeOat) == some ⟨600⟩) "the tabulation still says 600"
  checkD (updated.val.rule.eval icedLargeOat == ⟨1050⟩) "the rule says 1050"
  IO.println s!"desync: update rule alone accepted; minPrice={updated.val.minPrice.minor} rule.minPrice={pricier.minPrice.minor} tabulated={(← priceOf samovar.ref icedLargeOat).map (·.minor)} rule.eval={(updated.val.rule.eval icedLargeOat).minor}"

/-- The logged plans of every offer query, printed once each. -/
private def showPlans : DbM Unit := do
  let entries ← readLog 2000
  let mut seen : Array String := #[]
  for e in entries.reverse do
    let detail := (e.getObjValAs? String "detail").toOption.getD ""
    if (detail.startsWith "espresso_offer×" || detail.startsWith "offer_price |")
        && !seen.contains detail then
      seen := seen.push detail
  for d in seen do IO.println s!"plan: {d}"

def main : IO UInt32 := do
  vocabulary
  if ← dbPath.pathExists then IO.FS.removeFile dbPath
  expectOk (validateSchema fullSchema) "schema"
  expectOk (← withDb dbPath fullSchema runQueries) "seed + queries"
  -- results identical to the unplanned reference semantics
  let (planned, reference) ← expectOk (← withDb dbPath fullSchema do
      let planned ← cheapestConfigured .iced .large .oat .double false .sanFrancisco
      let reference ← selectUnplanned [EspressoOffer, OfferPrice, Restaurant] (fun (o, op, r) =>
        op.val.offer == o.ref && o.val.restaurant == r.ref && o.val.available
          && r.val.city == .sanFrancisco && op.val.temp == .iced && op.val.size == .large
          && op.val.milk == .oat && op.val.shots == .double && op.val.decaf == false)
        (.key fun (_, op, _) => op.val.price)
      return (planned.map fun (o, op, r) => (o.id.toInt64, op.id.toInt64, r.id.toInt64),
              reference.map fun (o, op, r) => (o.id.toInt64, op.id.toInt64, r.id.toInt64)))
    "differential"
  check (planned == reference && planned.size == 4) "planned select equals selectUnplanned"
  expectOk (← withDb dbPath fullSchema desynchronize) "desync"
  expectOk (← withDb dbPath fullSchema showPlans) "log"
  IO.println "eats offers (LEP-0005 stage 1): all tests passed"
  return 0
