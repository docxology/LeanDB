import Kernels

/-! The kernels CLI: `LeanDb.Cli.run` over the base value in `Kernels/Base.lean`. -/

def main (args : List String) : IO UInt32 :=
  LeanDb.Cli.run Kernels.base args
