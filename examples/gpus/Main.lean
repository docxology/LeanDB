import Gpus

/-! The gpus CLI: `LeanDb.Cli.run` over this base's entities and queries.
Chip and region arguments are parsed with `ClosedEnum.decodeName` — an
unknown name is a typed `.decode` error, never a silent empty result. -/

open Lean (Json)
open LeanDb LeanDb.Cli Gpus

private def offeringRows (rows : Array (Stored Offering)) : Json :=
  Json.mkObj [("ok", Json.bool true), ("count", Lean.toJson rows.size),
    ("rows", Json.arr (rows.map (rowJson Offering)))]

private def argOne (args : List String) (name : String) : DbM String :=
  match args with
  | [v] => pure v
  | _ => throw (DbError.decode "cli" name "exactly one argument expected")

/-- Parse one argv word into a closed world, or fail typed. -/
private def argEnum (β : Type) [ClosedEnum β] (args : List String) (name : String) : DbM β := do
  let v ← argOne args name
  match ClosedEnum.decodeName (α := β) v with
  | some b => pure b
  | none => throw (DbError.decode "cli" name
      s!"unknown {name} {String.quote v}; known: {ClosedEnum.variants β}")

def main (args : List String) : IO UInt32 :=
  Cli.run {
    name := "gpus"
    dbPath := "data" / "gpus.sqlite"
    specs := schema
    tables := [.of Provider, .of Offering]
    queries := [
      ("seed", fun _ => do
        seed
        return Json.mkObj [("ok", Json.bool true), ("seeded", Json.bool true)]),
      ("chip", fun args => do
        offeringRows <$> availableChip (← argEnum Chip args "chip")),
      ("cheapest", fun args => do
        offeringRows <$> cheapestIn (← argEnum Region args "region")),
      ("amd", fun _ => offeringRows <$> amdOfferings),
      ("vram", fun args => do
        let v ← argOne args "min-gb"
        let some n := v.toNat?
          | throw (DbError.decode "cli" "min-gb" s!"expected a natural number, got {v}")
        let minGb ← match VramGb.make n with
          | .ok g => pure g
          | .error msg => throw (DbError.decode "cli" "min-gb" msg)
        offeringRows <$> bigVram minGb.gb)]
  } args
