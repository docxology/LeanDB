import PriceWatch

/-! The pricewatch CLI: `LeanDb.Cli.run` over the base value in `PriceWatch/Base.lean`. -/

def main (args : List String) : IO UInt32 :=
  LeanDb.Cli.run PriceWatch.base args
