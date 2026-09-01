import LeanDb

/-! # Scalars

Validated newtypes, each with its own smart constructor and a `ColCodec`
built with `ColCodec.via` over its representation. Because every codec
*is* the projection (`(·.minutes)`, `(·.micro)`, …), the planner pushes
ordering through it: `h.val.opens.minutes ≤ t.minutes` becomes
`"opens" <= ?` in SQL. No `Float` anywhere — `Float` has no `SqlOrd`
(NaN breaks exact negation), so coordinates are integer microdegrees.
-/

namespace Eats

open LeanDb

/-- Trimmed, nonempty, bounded text — the shared rule behind the text
    newtypes below. Each type still has its own bound and its own `make`. -/
private def boundedText (what : String) (max : Nat) (s : String) : Except String String :=
  let t := s.trimAscii.toString
  if t.isEmpty then .error s!"{what} must be nonempty"
  else if t.length > max then .error s!"{what} too long ({t.length} > {max} chars)"
  else .ok t

/-- Stable key of a canonical dish: lowercase `a-z`, digits and `-`, 2–40
    characters — `chai-latte`, `tiramisu`. Queries name dishes by slug
    until LEP-0001 row symbols replace the string with a constant. -/
structure Slug where
  raw : String
  deriving Repr, DecidableEq, Ord

def Slug.make (s : String) : Except String Slug :=
  if s.length < 2 || s.length > 40 then
    .error s!"slug must be 2-40 chars, got {s.length}"
  else if !(s.toList.all fun c => c.isLower || c.isDigit || c == '-') then
    .error s!"slug may contain only a-z, 0-9 and '-': {String.quote s}"
  else .ok ⟨s⟩

instance : ColCodec Slug := ColCodec.via (·.raw) Slug.make

/-- The canonical dish's human name ("Chai latte"). -/
structure DisplayName where
  raw : String
  deriving Repr, DecidableEq, Ord

def DisplayName.make (s : String) : Except String DisplayName :=
  (⟨·⟩) <$> boundedText "display name" 80 s

instance : ColCodec DisplayName := ColCodec.via (·.raw) DisplayName.make

structure RestaurantName where
  raw : String
  deriving Repr, DecidableEq, Ord

def RestaurantName.make (s : String) : Except String RestaurantName :=
  (⟨·⟩) <$> boundedText "restaurant name" 80 s

instance : ColCodec RestaurantName := ColCodec.via (·.raw) RestaurantName.make

structure Neighborhood where
  raw : String
  deriving Repr, DecidableEq, Ord

def Neighborhood.make (s : String) : Except String Neighborhood :=
  (⟨·⟩) <$> boundedText "neighborhood" 60 s

instance : ColCodec Neighborhood := ColCodec.via (·.raw) Neighborhood.make

/-- The menu's own spelling of a dish ("Dirty Chai (oat)"). Free text by
    declaration: nothing is ever matched against it — the canonical
    reference carries the identity. -/
structure MenuName where
  raw : String
  deriving Repr, DecidableEq, Ord

def MenuName.make (s : String) : Except String MenuName :=
  (⟨·⟩) <$> boundedText "menu name" 120 s

instance : ColCodec MenuName := ColCodec.via (·.raw) MenuName.make

structure IngredientName where
  raw : String
  deriving Repr, DecidableEq, Ord

def IngredientName.make (s : String) : Except String IngredientName :=
  (⟨·⟩) <$> boundedText "ingredient name" 60 s

instance : ColCodec IngredientName := ColCodec.via (·.raw) IngredientName.make

/-- A modification as the menu words it ("oat milk", "no chashu"). -/
structure ModLabel where
  raw : String
  deriving Repr, DecidableEq, Ord

def ModLabel.make (s : String) : Except String ModLabel :=
  (⟨·⟩) <$> boundedText "modification label" 60 s

instance : ColCodec ModLabel := ColCodec.via (·.raw) ModLabel.make

/-- A time of day as minutes since midnight, 0–1439. Ordering pushes
    through `.minutes`. -/
structure Clock where
  minutes : Nat
  deriving Repr, DecidableEq, Ord

def Clock.make (m : Nat) : Except String Clock :=
  if m ≥ 1440 then .error s!"clock must be 0-1439 minutes since midnight, got {m}"
  else .ok ⟨m⟩

instance : ColCodec Clock := ColCodec.via (·.minutes) Clock.make

/-- `Clock.hm 21 30` is 21:30. -/
def Clock.hm (h m : Nat) : Clock := ⟨h * 60 + m⟩

def Clock.render (c : Clock) : String :=
  let h := c.minutes / 60
  let m := c.minutes % 60
  s!"{if h < 10 then "0" else ""}{h}:{if m < 10 then "0" else ""}{m}"

/-- A price in minor units (cents), non-negative by type. -/
structure Money where
  minor : Nat
  deriving Repr, DecidableEq, Ord

instance : ColCodec Money := ColCodec.via (·.minor) (fun n => .ok ⟨n⟩)

/-- A signed price delta ("oat milk +75", "no cheese −50"). `Int` has no
    codec; `Int64` does. -/
structure Delta where
  minor : Int64
  deriving Repr, DecidableEq

instance : ColCodec Delta := ColCodec.via (·.minor) (fun v => .ok ⟨v⟩)

/-- A latitude or longitude in microdegrees (37.785000° = 37785000).
    Integer, so a bounding box pushes as four ordered comparisons. -/
structure MicroDeg where
  micro : Int64
  deriving Repr, DecidableEq

def MicroDeg.make (v : Int64) : Except String MicroDeg :=
  if v < -180000000 || v > 180000000 then
    .error s!"microdegrees must be within ±180000000, got {v}"
  else .ok ⟨v⟩

instance : ColCodec MicroDeg := ColCodec.via (·.micro) MicroDeg.make

/-- Degrees as a `Float`, for the residual haversine only. -/
def MicroDeg.toDegrees (d : MicroDeg) : Float := d.micro.toFloat / 1000000.0

/-- A point in time, seconds since the Unix epoch. -/
structure Timestamp where
  epochSeconds : Nat
  deriving Repr, DecidableEq, Ord

instance : ColCodec Timestamp := ColCodec.via (·.epochSeconds) (fun n => .ok ⟨n⟩)

end Eats
