import Eats

/-! The eats CLI: `LeanDb.Cli.run` over the base value in `Eats/Base.lean`. -/

def main (args : List String) : IO UInt32 :=
  LeanDb.Cli.run Eats.base args
