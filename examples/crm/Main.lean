import Crm

/-! The crm CLI: `LeanDb.Cli.run` over the base value in `Crm/Base.lean`. -/

def main (args : List String) : IO UInt32 :=
  LeanDb.Cli.run Crm.base args
