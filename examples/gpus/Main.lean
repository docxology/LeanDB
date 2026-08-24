import Gpus

/-! The gpus CLI: tables, schema, and row JSON derived from the entity
declarations; queries `query%`-derived from the query defs' signatures
(chip/region arguments parse by closed-world variant name through the
generic `CliArg` instance — an unknown name is a typed `.decode` error,
never a silent empty result). Only the imperative `seed` verb is
hand-written. -/

open Lean (Json) in
open LeanDb LeanDb.Cli Gpus in
def main (args : List String) : IO UInt32 := do
  Cli.run {
    name := "gpus"
    dbPath := "data" / "gpus.sqlite"
    specs := schema
    tables := [.of Provider, .of Offering]
    queries := [
      ("seed", fun _ => do
        seed
        return Json.mkObj [("ok", Json.bool true), ("seeded", Json.bool true)]),
      query% availableChip,
      query% cheapestIn,
      query% amdOfferings,
      query% bigVram]
  } args
