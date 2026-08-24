import LeanDb.Api

def main (args : List String) : IO UInt32 := do
  match LeanDb.Api.run args with
  | .ok output =>
      IO.println output
      pure 0
  | .error error =>
      IO.eprintln error.toJson
      pure 2
