namespace LeanDb

/-- A named, validated string. Domain modules expose constructors rather than
    accepting anonymous strings as rows. -/
structure TextValue where
  raw : String
  deriving Repr, DecidableEq, Inhabited

inductive ValidationError where
  | empty (field : String)
  | invalid (field message : String)
  deriving Repr, DecidableEq

def TextValue.create (field value : String) : Except ValidationError TextValue :=
  if value.trimAscii.isEmpty then
    .error (.empty field)
  else
    .ok ⟨value.trimAscii.toString⟩

structure Money where
  cents : Nat
  deriving Repr, DecidableEq, Ord

def Money.dollars (amount : Nat) : Money := ⟨amount * 100⟩

structure DistanceKm where
  tenths : Nat
  deriving Repr, DecidableEq, Ord

/-- Ratings are represented in tenths, avoiding unstable floating-point
    comparisons in filters and output. -/
structure Rating where
  tenths : Nat
  valid : tenths ≤ 50 := by omega

instance : Repr Rating where
  reprPrec r _ := repr r.tenths

instance : Inhabited Rating := ⟨⟨0, by omega⟩⟩

def jsonString (value : String) : String :=
  let value := value.replace "\\" "\\\\"
  let value := value.replace "\"" "\\\""
  let value := value.replace "\n" "\\n"
  let value := value.replace "\r" "\\r"
  let value := value.replace "\t" "\\t"
  let value := value.replace "\u0008" "\\b"
  let value := value.replace "\u000c" "\\f"
  "\"" ++ value ++ "\""

def jsonBool (value : Bool) : String := if value then "true" else "false"

def jsonArray (items : List String) : String :=
  "[" ++ String.intercalate "," items ++ "]"

def jsonObject (fields : List (String × String)) : String :=
  let encoded := fields.map fun (key, value) => jsonString key ++ ":" ++ value
  "{" ++ String.intercalate "," encoded ++ "}"

end LeanDb
