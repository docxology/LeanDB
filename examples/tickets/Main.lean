import Tickets

/-! The tickets CLI: `LeanDb.Cli.run` over the base value in `Tickets/Base.lean`. -/

def main (args : List String) : IO UInt32 :=
  LeanDb.Cli.run Tickets.base args
