import Eats

/-! Tests for the eats base: seed, then assert on each query's *results*
(never on its plan — pushdown is an optimization the reference semantics
define away), check that wrong-world programs are rejected at compile
time, and finally print the logged plans for `openFor` and the
ingredient-side fetch of `suitable` so the report shows what pushed. -/

open LeanDb Eats

private def check (c : Bool) (m : String) : IO Unit :=
  unless c do throw <| IO.userError s!"FAIL: {m}"

private def checkD (c : Bool) (m : String) : DbM Unit :=
  unless c do throw (.sqlite s!"FAIL: {m}")

private def expectOk (r : Except DbError α) (ctx : String) : IO α :=
  match r with
  | .ok a => pure a
  | .error e => throw <| IO.userError s!"FAIL: {ctx}: {e}"

private def dbPath : System.FilePath := ".lake" / "eats_test.sqlite"

/-! ## Negative compile checks -/

-- A diet is vocabulary, not a row: there is no table to insert it into.
#check_failure LeanDb.insert Diet Diet.vegetarian

-- A predicate over the wrong table does not typecheck: `select [Dish]`
-- forces `Stored Dish → Bool`.
#check_failure LeanDb.select [Dish] (fun (r : Stored Restaurant) => r.val.city == City.oakland)

-- Cities are closed: you cannot delete one from the universe.
#check_failure LeanDb.delete (α := City) ⟨1⟩

/-! ## Vocabulary -/

private def vocabulary : IO Unit := do
  check (Diet.allows .vegetarian .dairy && !(Diet.allows .vegan .dairy)) "allows derives from forbids"
  check (Diet.allows .omnivore .pork) "omnivore forbids nothing"
  for d in ClosedEnum.all (α := Diet) do
    check ((d.forbids.all fun k => !(d.allows k))) s!"forbids and allows agree for {repr d}"
  check (Hours.servesAt ⟨⟨1⟩, .fri, .hm 17 0, .hm 1 0, .hm 2 0⟩ (.hm 0 30)) "wrap: 00:30 is served"
  check (!Hours.servesAt ⟨⟨1⟩, .fri, .hm 17 0, .hm 1 0, .hm 2 0⟩ (.hm 1 30)) "wrap: past last order"
  check (!Hours.servesAt ⟨⟨1⟩, .fri, .hm 17 0, .hm 1 0, .hm 2 0⟩ (.hm 16 0)) "wrap: before opening"
  check ((Slug.make "Chai Latte").isOk == false && (Slug.make "chai-latte").isOk) "slug validation"
  check ((Clock.make 1440).isOk == false) "clock upper bound"

/-! ## Runtime tests -/

private def slug! (s : String) : Slug := ⟨s⟩

private def restaurantNames (rows : Array (Stored Dish × Stored Restaurant)) : Array String :=
  rows.map (·.2.val.name.raw)

private def menuNames (rows : Array (Stored Dish × Stored Restaurant)) : Array String :=
  rows.map (·.1.val.menuName.raw)

private def dishByMenuName (name : String) : DbM (Stored Dish) := do
  let rows ← select [Dish] (fun d => d.val.menuName.raw == name)
  match rows[0]? with
  | some d => pure d
  | none => throw (.sqlite s!"FAIL: seeded dish {name} not found")

private def runQueries : DbM Unit := do
  seed
  checkD ((← fetchAll Restaurant).size == 12) "twelve restaurants seeded"
  -- avgPrice: SF cafés only (550 + 600 + 650) / 3; the unavailable 700
  -- and the Oakland/Berkeley chais are excluded
  checkD ((← avgPrice (slug! "chai-latte") .sanFrancisco) == some ⟨600⟩) "avgPrice chai-latte SF"
  checkD ((← avgPrice (slug! "chai-latte") .oakland) == some ⟨525⟩) "avgPrice chai-latte Oakland"
  checkD ((← avgPrice (slug! "tiramisu") .paloAlto) == none) "avgPrice with no rows is none"
  -- openFor: Friday 21:30 → Stella (closes 22:00) and Tosca (wraps past
  -- midnight); Bellanico's last order was 19:30
  let late ← openFor (slug! "tiramisu") .fri (.hm 21 30)
  checkD (late.map (·.1.val.name.raw) == #["Stella Pastry", "Tosca Cafe"])
    s!"openFor tiramisu fri 21:30, got {late.map (·.1.val.name.raw)}"
  let early ← openFor (slug! "tiramisu") .fri (.hm 19 0)
  checkD (early.map (·.1.val.name.raw) == #["Bellanico", "Stella Pastry", "Tosca Cafe"])
    s!"openFor tiramisu fri 19:00, got {early.map (·.1.val.name.raw)}"
  let small ← openFor (slug! "tiramisu") .fri (.hm 0 30)
  checkD (small.map (·.1.val.name.raw) == #["Tosca Cafe"]) "openFor tiramisu fri 00:30: only the wrap"
  let monday ← openFor (slug! "tiramisu") .mon (.hm 21 30)
  checkD (monday.map (·.1.val.name.raw) == #["Stella Pastry"]) "openFor mon: Tosca has no Monday row"
  -- suitable: vegetarian → only the vegetable ramen; noPorkBeef → also the
  -- removable-chashu paitan; tonkotsu never; the incomplete dashi never
  let vegOk ← suitable .ramen .vegetarian .sanFrancisco
  checkD (menuNames vegOk == #["Shoyu Vegetable Ramen"]) s!"suitable vegetarian, got {menuNames vegOk}"
  let npb ← suitable .ramen .noPorkBeef .sanFrancisco
  checkD (menuNames npb == #["Tori Paitan Shoyu", "Shoyu Vegetable Ramen"])
    s!"suitable noPorkBeef, got {menuNames npb}"
  checkD (restaurantNames npb == #["Mensho Tokyo SF", "Shizen"]) "suitable pairs dishes with restaurants"
  let omni ← suitable .ramen .omnivore .sanFrancisco
  checkD (menuNames omni == #["Hakata Tonkotsu DX", "Tori Paitan Shoyu", "Shoyu Vegetable Ramen"])
    "omnivore: every complete ramen, never the incomplete one"
  checkD ((← suitable .ramen .vegan .sanFrancisco).size == 1) "vegan: the vegetable ramen"
  checkD ((← suitable .ramen .jain .sanFrancisco).size == 0) "jain: shiitake and chicken rule out all"
  checkD ((← suitable .ramen .vegetarian .oakland).size == 0) "no ramen in Oakland"
  -- the same through an ad-hoc list of kinds
  let adHoc ← suitableAdHoc .ramen ⟨[.pork, .beef]⟩ .sanFrancisco
  checkD (menuNames adHoc == menuNames npb) "ad-hoc pork,beef agrees with noPorkBeef"
  -- dietsFor
  let veg ← dishByMenuName "Shoyu Vegetable Ramen"
  let vegDiets ← dietsFor veg.ref
  checkD (vegDiets.contains .vegetarian && vegDiets.contains .noPorkBeef && vegDiets.contains .vegan)
    "veg ramen suits vegetarian, noPorkBeef, vegan"
  checkD (!vegDiets.contains .jain && !vegDiets.contains .glutenFree) "veg ramen: not jain, not gluten-free"
  let paitan ← dishByMenuName "Tori Paitan Shoyu"
  let paitanDiets ← dietsFor paitan.ref
  checkD (paitanDiets.contains .noPorkBeef && !paitanDiets.contains .vegetarian)
    "paitan: noPorkBeef (chashu removable) but not vegetarian (chicken broth)"
  let dashi ← dishByMenuName "Dashi Ramen"
  checkD ((← dietsFor dashi.ref) == []) "incomplete ingredient list: no diet at all, not even omnivore"
  -- priceWith
  let bbChai ← dishByMenuName "Chai Latte"
  let mods ← select [Modification] (fun m => m.val.dish == bbChai.ref)
  checkD ((← priceWith bbChai.ref []) == ⟨550⟩) "priceWith no mods is the list price"
  checkD ((← priceWith bbChai.ref (mods.map (·.ref)).toList) == ⟨725⟩) "priceWith oat milk + extra shot"
  -- nearby: the pushed box around Marufuku admits Mensho and Blue Bottle
  -- too; the residual haversine cuts them
  let near ← nearby ⟨37785200⟩ ⟨-122431600⟩ 1000
  checkD (near.map (·.val.name.raw) == #["Hinodeya Ramen Bar", "Marufuku Ramen"])
    s!"nearby 1 km of Japantown, got {near.map (·.val.name.raw)}"
  checkD ((← nearby ⟨37785200⟩ ⟨-122431600⟩ 1300).size == 4) "nearby 1.3 km admits Mensho and Blue Bottle"
  -- history, newest first
  let dx ← dishByMenuName "Hakata Tonkotsu DX"
  let hist ← history dx.ref
  checkD (hist.map (·.val.price.minor) == #[1850, 1750, 1650]) "history newest first"
  checkD (hist.map (·.val.source) == #[.deliveryApp, .receipt, .menu]) "history sources"

/-- The logged plans this base is about: `openFor` (three tables incl.
    hours) and the ingredient-side fetch of `suitable`. Printed, not
    asserted. -/
private def showPlans : DbM Unit := do
  let entries ← readLog 200
  let mut seen : Array String := #[]
  for e in entries.reverse do
    let detail := (e.getObjValAs? String "detail").toOption.getD ""
    if (detail.startsWith "restaurant×dish×hours" || detail.startsWith "dish_ingredient×ingredient")
        && !seen.contains detail then
      seen := seen.push detail
  for d in seen do IO.println s!"plan: {d}"

def main : IO UInt32 := do
  vocabulary
  if ← dbPath.pathExists then IO.FS.removeFile dbPath
  expectOk (← withDb dbPath schema runQueries) "seed + queries"
  -- results identical to the unplanned reference semantics
  let (planned, reference) ← expectOk (← withDb dbPath schema do
      let planned ← select [Restaurant, Dish, Hours] (fun (r, d, h) =>
        d.val.restaurant == r.ref && h.val.restaurant == r.ref && d.val.available
          && h.val.day == Weekday.fri && h.val.servesAt (.hm 21 30))
        (.key fun (r, _, _) => r.val.name)
      let reference ← selectUnplanned [Restaurant, Dish, Hours] (fun (r, d, h) =>
        d.val.restaurant == r.ref && h.val.restaurant == r.ref && d.val.available
          && h.val.day == Weekday.fri && h.val.servesAt (.hm 21 30))
        (.key fun (r, _, _) => r.val.name)
      return (planned.map fun (r, d, h) => (r.id.toInt64, d.id.toInt64, h.id.toInt64),
              reference.map fun (r, d, h) => (r.id.toInt64, d.id.toInt64, h.id.toInt64)))
    "differential"
  check (planned == reference && planned.size > 0) "planned select equals selectUnplanned"
  -- a slug that names nothing is a typed error, not an empty answer
  match ← withDb dbPath schema (avgPrice ⟨"pho-bo"⟩ .sanFrancisco) with
  | .error (.decode ..) => pure ()
  | _ => throw <| IO.userError "FAIL: unknown slug must be a typed error"
  expectOk (← withDb dbPath schema showPlans) "log"
  IO.println "eats base: all tests passed"
  return 0
