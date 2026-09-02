import Shop

/-! The shop CLI: `LeanDb.Cli.run` over the base value in `Shop/Base.lean`. -/

def main (args : List String) : IO UInt32 :=
  LeanDb.Cli.run Shop.base args
