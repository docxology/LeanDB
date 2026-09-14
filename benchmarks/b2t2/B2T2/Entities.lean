import LeanDb
import Lean.Data.Json

/-! B2T2 example tables as LeanDB entities.

Column names are Lean identifiers (see REPRESENTATION.md). B2T2's
`"favorite color"` is `favoriteColor`; `"get acne"` is `getAcne`;
`"Last Name"` is `lastName`. `final` is a Lean keyword, so the field is
`«final»`. LeanDB adds a surrogate `Id` that is not part of the
benchmark row.
-/

namespace B2T2

open LeanDb

/-- Sequence cells (`gradebookSeq.quizzes`) as one TEXT JSON column.
    Extra Lean: not a first-class LeanDB sequence sort. -/
instance : ColCodec (List Nat) where
  sqlType := .text
  toCol xs := .text (Lean.toJson xs).compress
  fromCol
    | .text s =>
        match Lean.Json.parse s with
        | .error e => .error e
        | .ok j =>
            match Lean.fromJson? (α := List Nat) j with
            | .ok xs => .ok xs
            | .error e => .error e
    | c => .error s!"expected TEXT JSON list, found {c.describe}"

instance [Inhabited α] : Inhabited (Stored α) := ⟨⟨⟨0⟩, default⟩⟩

structure Student where
  name : String
  age : Nat
  favoriteColor : String
  deriving Repr, Inhabited, LeanDb.Entity

structure StudentMissing where
  name : String
  age : Option Nat
  favoriteColor : Option String
  deriving Repr, Inhabited, LeanDb.Entity

structure Employee where
  lastName : String
  departmentId : Option Nat
  deriving Repr, Inhabited, LeanDb.Entity

structure Department where
  departmentId : Nat
  departmentName : String
  deriving Repr, Inhabited, LeanDb.Entity

structure JellyAnon where
  getAcne : Bool
  red : Bool
  black : Bool
  white : Bool
  green : Bool
  yellow : Bool
  brown : Bool
  orange : Bool
  pink : Bool
  purple : Bool
  deriving Repr, Inhabited, LeanDb.Entity

structure JellyNamed where
  name : String
  getAcne : Bool
  red : Bool
  black : Bool
  white : Bool
  green : Bool
  yellow : Bool
  brown : Bool
  orange : Bool
  pink : Bool
  purple : Bool
  deriving Repr, Inhabited, LeanDb.Entity

structure Gradebook where
  name : String
  age : Nat
  quiz1 : Nat
  quiz2 : Nat
  midterm : Nat
  quiz3 : Nat
  quiz4 : Nat
  «final» : Nat
  deriving Repr, Inhabited, LeanDb.Entity

structure GradebookMissing where
  name : String
  age : Nat
  quiz1 : Option Nat
  quiz2 : Nat
  midterm : Nat
  quiz3 : Option Nat
  quiz4 : Nat
  «final» : Nat
  deriving Repr, Inhabited, LeanDb.Entity

structure GradebookSeq where
  name : String
  age : Nat
  quizzes : List Nat
  midterm : Nat
  «final» : Nat
  deriving Repr, Inhabited, LeanDb.Entity

/-- Nested quiz table (`gradebookTable`): child rows, not a table-valued cell. -/
structure Quiz where
  quizNum : Nat
  grade : Nat
  deriving Repr, Inhabited, LeanDb.Inline

structure GradebookNested where
  name : String
  age : Nat
  quizzes : List Quiz
  midterm : Nat
  «final» : Nat
  deriving Repr, Inhabited, LeanDb.Entity

def schema : List TableSpec :=
  orderSpecs (
    Entity.specs Student ++
    Entity.specs StudentMissing ++
    Entity.specs Employee ++
    Entity.specs Department ++
    Entity.specs JellyAnon ++
    Entity.specs JellyNamed ++
    Entity.specs Gradebook ++
    Entity.specs GradebookMissing ++
    Entity.specs GradebookSeq ++
    Entity.specs GradebookNested)

end B2T2
