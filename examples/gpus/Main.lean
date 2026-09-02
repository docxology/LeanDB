import Gpus

/-! The gpus CLI: `LeanDb.Cli.run` over the base value in `Gpus/Base.lean`. -/

def main (args : List String) : IO UInt32 :=
  LeanDb.Cli.run Gpus.base args
