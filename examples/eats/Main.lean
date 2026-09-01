import Eats

/-! The eats CLI. Query names and arities are `query%`-derived from the
defs in `Eats/Queries.lean`; closed-world arguments (city, weekday, diet,
family) parse by variant name, and the newtypes below get their own
`CliArg` so `openFor tiramisu fri 21:30` reads as written. -/

open Lean (Json)
open LeanDb LeanDb.Cli Eats

/-- A slug, validated exactly as at insert. -/
instance : CliArg Slug := ⟨Slug.make⟩

/-- `HH:MM`, or plain minutes since midnight. -/
instance : CliArg Clock := ⟨fun s =>
  match s.splitOn ":" with
  | [h, m] =>
      match h.toNat?, m.toNat? with
      | some h, some m =>
          if h < 24 && m < 60 then .ok (Clock.hm h m)
          else .error s!"expected HH:MM with H < 24 and M < 60, got {String.quote s}"
      | _, _ => .error s!"expected HH:MM or minutes since midnight, got {String.quote s}"
  | [n] =>
      match n.toNat? with
      | some n => Clock.make n
      | none => .error s!"expected HH:MM or minutes since midnight, got {String.quote s}"
  | _ => .error s!"expected HH:MM or minutes since midnight, got {String.quote s}"⟩

/-- Decimal degrees (`37.7852`, `-122.4316`) or integer microdegrees. -/
instance : CliArg MicroDeg := ⟨fun s =>
  let (neg, body) := if s.startsWith "-" then (true, (s.drop 1).toString) else (false, s)
  let micro? : Option Int64 :=
    match body.splitOn "." with
    | [whole] => whole.toNat?.map fun w => Int64.ofNat (w * 1000000)
    | [whole, frac] =>
        if frac.isEmpty || frac.length > 6 || !(frac.all Char.isDigit) then none
        else
          (whole.toNat?.bind fun w => frac.toNat?.map fun f =>
            Int64.ofNat (w * 1000000 + f * 10 ^ (6 - frac.length)))
    | _ => none
  match micro? with
  | some m => MicroDeg.make (if neg then -m else m)
  | none => .error s!"expected decimal degrees or integer microdegrees, got {String.quote s}"⟩

/-- Comma-separated values, each parsed by its own `CliArg`; `""` is the
    empty list. -/
instance [CliArg α] : CliArg (List α) := ⟨fun s =>
  if s.isEmpty then .ok []
  else (s.splitOn ",").mapM CliArg.parse⟩

/-- `pork,beef,shellfish`. -/
instance : CliArg AdHocDiet := ⟨fun s => (⟨·⟩) <$> CliArg.parse s⟩

instance : QueryOut Money := ⟨fun m => Lean.toJson m.minor⟩
instance : QueryOut Diet := ⟨fun d => Json.str (ClosedEnum.encodeName d)⟩

def main (args : List String) : IO UInt32 := do
  Cli.run {
    name := "eats"
    dbPath := "data" / "eats.sqlite"
    specs := schema
    tables := [.of CanonicalDish, .of Restaurant, .of Ingredient, .of Hours, .of Dish,
      .of DishIngredient, .of Modification, .of PriceObs]
    queries := [
      ("seed", fun _ => do
        seed
        return Json.mkObj [("ok", Json.bool true), ("seeded", Json.bool true)]),
      query% avgPrice,
      query% openFor,
      query% suitable,
      query% suitableAdHoc,
      query% dietsFor,
      query% priceWith,
      query% nearby,
      query% history]
  } args
