import Eats.Queries

/-! # Seed data

Illustrative, not real: twelve Bay Area restaurants with plausible names,
coordinates, hours and prices, laid out so each query has a non-trivial
answer — three SF ramen kitchens (pork, removable pork, vegetable) plus
one whose ingredient list is incomplete and must never appear in a dietary
answer; five cafés with a chai latte at different prices, two outside SF;
three tiramisu places whose Friday hours close at 22:00, wrap past
midnight, and close at 20:00. Every value passes through its smart
constructor; `seedM` lifts a validation failure into a typed `.decode`
error, so seeding stays total. -/

namespace Eats

open LeanDb

/-- Lift a smart-constructor result into `DbM`. -/
def seedM (context : String) (r : Except String α) : DbM α :=
  match r with
  | .ok a => pure a
  | .error msg => throw (.decode "seed" context msg)

private def canonical! (slug display : String) (family : DishFamily) (course : Course) :
    DbM (Stored CanonicalDish) := do
  insert CanonicalDish {
    slug := ← seedM s!"slug {slug}" (Slug.make slug)
    display := ← seedM s!"display {display}" (DisplayName.make display)
    family, course }

private def restaurant! (name : String) (city : City) (hood : String)
    (lat lon : Int64) (cuisine : Cuisine) (tier : PriceTier) : DbM (Stored Restaurant) := do
  insert Restaurant {
    name := ← seedM s!"restaurant {name}" (RestaurantName.make name)
    city
    neighborhood := ← seedM s!"neighborhood {hood}" (Neighborhood.make hood)
    lat := ← seedM s!"lat {lat}" (MicroDeg.make lat)
    lon := ← seedM s!"lon {lon}" (MicroDeg.make lon)
    cuisine, priceTier := tier }

/-- One `Hours` row per listed day; days not listed are closed. -/
private def hours! (r : Ref Restaurant) (days : List Weekday)
    (opens lastOrder closes : Clock) : DbM Unit := do
  for day in days do
    discard <| insert Hours { restaurant := r, day, opens, lastOrder, closes }

private def everyDay : List Weekday := (ClosedEnum.all (α := Weekday)).toList

private def dish! (r : Ref Restaurant) (c : Ref CanonicalDish) (menuName : String)
    (minor : Nat) (complete : Bool) (size : Option Size := some .regular)
    (available : Bool := true) : DbM (Stored Dish) := do
  insert Dish {
    restaurant := r, canonical := c
    menuName := ← seedM s!"menu name {menuName}" (MenuName.make menuName)
    price := ⟨minor⟩, size, available, ingredientsComplete := complete }

private def ingredient! (name : String) (kind : IngredientKind) : DbM (Stored Ingredient) := do
  insert Ingredient { name := ← seedM s!"ingredient {name}" (IngredientName.make name), kind }

private def uses! (d : Ref Dish) (i : Ref Ingredient) (removable : Bool := false)
    (substitutable : Option (Ref Ingredient) := none) : DbM Unit :=
  discard <| insert DishIngredient { dish := d, ingredient := i, removable, substitutable }

private def mod! (d : Ref Dish) (label : String) (delta : Int64)
    (removes : Option IngredientKind := none) : DbM Unit := do
  discard <| insert Modification {
    dish := d, label := ← seedM s!"modification {label}" (ModLabel.make label)
    delta := ⟨delta⟩, removes }

private def obs! (d : Ref Dish) (minor : Nat) (at' : Nat) (source : Source) : DbM Unit :=
  discard <| insert PriceObs { dish := d, price := ⟨minor⟩, observedAt := ⟨at'⟩, source }

def seed : DbM Unit := do
  -- vocabulary rows: the canonical dishes
  let tonkotsu ← canonical! "tonkotsu-ramen" "Tonkotsu ramen" .ramen .main
  let shoyu ← canonical! "shoyu-ramen" "Shoyu ramen" .ramen .main
  let vegRamen ← canonical! "vegetable-ramen" "Vegetable ramen" .ramen .main
  let dashi ← canonical! "dashi-ramen" "Dashi ramen" .ramen .main
  let chai ← canonical! "chai-latte" "Chai latte" .latte .drink
  let tiramisu ← canonical! "tiramisu" "Tiramisu" .tiramisu .dessert
  -- ingredients, classified once
  let porkBelly ← ingredient! "pork belly chashu" .pork
  let chickenBroth ← ingredient! "chicken paitan broth" .chicken
  let noodles ← ingredient! "ramen noodles" .gluten
  let egg ← ingredient! "soft-boiled egg" .egg
  let scallion ← ingredient! "scallion" .allium
  let shiitake ← ingredient! "shiitake" .mushroom
  let bokChoy ← ingredient! "bok choy" .vegetable
  let soySauce ← ingredient! "soy sauce" .soy
  let blackTea ← ingredient! "black tea" .tea
  let spices ← ingredient! "chai spices" .spice
  let milk ← ingredient! "whole milk" .dairy
  let oatMilk ← ingredient! "oat milk" .grain
  let sugar ← ingredient! "cane sugar" .sugar
  let mascarpone ← ingredient! "mascarpone" .dairy
  let ladyfingers ← ingredient! "ladyfingers" .gluten
  let espresso ← ingredient! "espresso" .coffee
  let marsala ← ingredient! "marsala" .alcohol
  -- ramen, San Francisco
  let marufuku ← restaurant! "Marufuku Ramen" .sanFrancisco "Japantown"
    37785200 (-122431600) .japanese .mid
  hours! marufuku.ref everyDay (.hm 11 30) (.hm 21 30) (.hm 22 0)
  let dx ← dish! marufuku.ref tonkotsu.ref "Hakata Tonkotsu DX" 1850 (complete := true)
  uses! dx.ref porkBelly.ref
  uses! dx.ref noodles.ref
  uses! dx.ref egg.ref (removable := true)
  uses! dx.ref scallion.ref (removable := true)
  mod! dx.ref "extra chashu" 400
  mod! dx.ref "no egg" 0 (removes := some .egg)
  obs! dx.ref 1650 1704067200 .menu
  obs! dx.ref 1750 1725148800 .receipt
  obs! dx.ref 1850 1748736000 .deliveryApp
  let mensho ← restaurant! "Mensho Tokyo SF" .sanFrancisco "Tenderloin"
    37785900 (-122417200) .japanese .mid
  hours! mensho.ref everyDay (.hm 17 0) (.hm 22 0) (.hm 22 30)
  let paitan ← dish! mensho.ref shoyu.ref "Tori Paitan Shoyu" 1900 (complete := true)
  uses! paitan.ref chickenBroth.ref
  uses! paitan.ref porkBelly.ref (removable := true)
  uses! paitan.ref noodles.ref
  uses! paitan.ref egg.ref (removable := true)
  uses! paitan.ref scallion.ref (removable := true)
  mod! paitan.ref "no chashu" 0 (removes := some .pork)
  mod! paitan.ref "extra noodles" 300
  let shizen ← restaurant! "Shizen" .sanFrancisco "Mission"
    37762600 (-122421100) .japanese .mid
  hours! shizen.ref (everyDay.filter (· != .mon)) (.hm 17 0) (.hm 21 30) (.hm 22 0)
  let veg ← dish! shizen.ref vegRamen.ref "Shoyu Vegetable Ramen" 1700 (complete := true)
  uses! veg.ref shiitake.ref
  uses! veg.ref bokChoy.ref
  uses! veg.ref noodles.ref
  uses! veg.ref soySauce.ref
  uses! veg.ref scallion.ref (removable := true)
  mod! veg.ref "gluten-free noodles" 200 (removes := some .gluten)
  -- no ingredient rows recorded: looks vegan by absence of data, and must
  -- never be answered as anything
  let hinodeya ← restaurant! "Hinodeya Ramen Bar" .sanFrancisco "Japantown"
    37785000 (-122429900) .japanese .budget
  hours! hinodeya.ref everyDay (.hm 11 30) (.hm 20 30) (.hm 21 0)
  discard <| dish! hinodeya.ref dashi.ref "Dashi Ramen" 1600 (complete := false)
  -- cafés: chai latte at five prices, two outside San Francisco
  let chaiRecipe := fun (d : Ref Dish) => do
    uses! d blackTea.ref
    uses! d spices.ref
    uses! d milk.ref (substitutable := some oatMilk.ref)
    uses! d sugar.ref (removable := true)
  let blueBottle ← restaurant! "Blue Bottle Hayes Valley" .sanFrancisco "Hayes Valley"
    37776400 (-122423300) .cafe .mid
  hours! blueBottle.ref everyDay (.hm 6 30) (.hm 17 45) (.hm 18 0)
  let bbChai ← dish! blueBottle.ref chai.ref "Chai Latte" 550 (complete := true)
  chaiRecipe bbChai.ref
  mod! bbChai.ref "oat milk" 75 (removes := some .dairy)
  mod! bbChai.ref "extra shot" 100
  let sightglass ← restaurant! "Sightglass Coffee" .sanFrancisco "SoMa"
    37777000 (-122408600) .cafe .mid
  hours! sightglass.ref everyDay (.hm 7 0) (.hm 17 45) (.hm 18 0)
  let sgChai ← dish! sightglass.ref chai.ref "Masala Chai Latte" 600 (complete := true)
  chaiRecipe sgChai.ref
  mod! sgChai.ref "oat milk" 80 (removes := some .dairy)
  let samovar ← restaurant! "Samovar Tea Lounge" .sanFrancisco "Mission"
    37761800 (-122426000) .cafe .mid
  hours! samovar.ref everyDay (.hm 9 0) (.hm 19 30) (.hm 20 0)
  let svChai ← dish! samovar.ref chai.ref "Masala Chai (with milk)" 650 (complete := true)
  chaiRecipe svChai.ref
  -- listed, but off the menu right now: excluded from every answer
  discard <| dish! samovar.ref chai.ref "Iced Chai Latte (seasonal)" 700 (complete := true)
    (available := false)
  let highwire ← restaurant! "Highwire Coffee" .oakland "Rockridge"
    37844000 (-122252000) .cafe .budget
  hours! highwire.ref everyDay (.hm 6 30) (.hm 16 45) (.hm 17 0)
  let hwChai ← dish! highwire.ref chai.ref "Chai Latte" 525 (complete := true)
  chaiRecipe hwChai.ref
  mod! hwChai.ref "oat milk" 50 (removes := some .dairy)
  let strada ← restaurant! "Caffe Strada" .berkeley "Southside"
    37869200 (-122254700) .cafe .budget
  hours! strada.ref everyDay (.hm 6 30) (.hm 22 45) (.hm 23 0)
  let stChai ← dish! strada.ref chai.ref "Chai Latte" 475 (complete := true)
  chaiRecipe stChai.ref
  -- tiramisu: three sets of Friday hours
  let tiramisuRecipe := fun (d : Ref Dish) => do
    uses! d mascarpone.ref
    uses! d ladyfingers.ref
    uses! d espresso.ref
    uses! d egg.ref
    uses! d marsala.ref
  let stella ← restaurant! "Stella Pastry" .sanFrancisco "North Beach"
    37800400 (-122409300) .italian .mid
  hours! stella.ref everyDay (.hm 8 0) (.hm 21 45) (.hm 22 0)
  let stTira ← dish! stella.ref tiramisu.ref "Tiramisu" 700 (complete := true) (size := some .small)
  tiramisuRecipe stTira.ref
  let tosca ← restaurant! "Tosca Cafe" .sanFrancisco "North Beach"
    37797600 (-122406100) .italian .upscale
  -- 17:00 to 02:00: `closes < opens`, the interval wraps midnight
  hours! tosca.ref (everyDay.filter (· != .mon)) (.hm 17 0) (.hm 1 0) (.hm 2 0)
  let toTira ← dish! tosca.ref tiramisu.ref "Tiramisù" 1200 (complete := true)
  tiramisuRecipe toTira.ref
  let bellanico ← restaurant! "Bellanico" .oakland "Glenview"
    37807700 (-122223500) .italian .mid
  hours! bellanico.ref (everyDay.filter (· != .sun)) (.hm 11 30) (.hm 19 30) (.hm 20 0)
  let beTira ← dish! bellanico.ref tiramisu.ref "Tiramisu della casa" 900 (complete := true)
  tiramisuRecipe beTira.ref

end Eats
