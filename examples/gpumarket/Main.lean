import GpuMarket

/-! The gpumarket CLI: `LeanDb.Cli.run` over the base value in `GpuMarket/Base.lean`. -/

def main (args : List String) : IO UInt32 :=
  LeanDb.Cli.run GpuMarket.base args
