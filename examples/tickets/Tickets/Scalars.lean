import LeanDb

/-! # Scalars

Per-type validated newtypes. Each carries its own smart constructor and its
own `ColCodec` built with `ColCodec.via` — there is deliberately no shared
generic "bounded text" wrapper: the validation rule *is* the type.
-/

namespace Tickets

open LeanDb

/-- A ticket or display title: trimmed, nonempty, at most 200 characters. -/
structure Title where
  raw : String
  deriving Repr, DecidableEq, Ord

def Title.make (s : String) : Except String Title :=
  let t := s.trimAscii.toString
  if t.isEmpty then .error "title must be nonempty"
  else if t.length > 200 then .error s!"title too long ({t.length} > 200 chars)"
  else .ok ⟨t⟩

instance : ColCodec Title := ColCodec.via (·.raw) Title.make

/-- A user handle: lowercase `a-z`, digits, and `-` only; 3–30 characters. -/
structure Handle where
  raw : String
  deriving Repr, DecidableEq, Ord

def Handle.make (s : String) : Except String Handle :=
  if s.length < 3 || s.length > 30 then
    .error s!"handle must be 3-30 chars, got {s.length}"
  else if !(s.toList.all fun c => c.isLower || c.isDigit || c == '-') then
    .error s!"handle may contain only a-z, 0-9, and '-': {String.quote s}"
  else .ok ⟨s⟩

instance : ColCodec Handle := ColCodec.via (·.raw) Handle.make

/-- Free-form prose. Any string is valid — but it is still its own type, so
    a `Body` never wanders into a `Title` column. -/
structure Body where
  raw : String
  deriving Repr, DecidableEq

def Body.make (s : String) : Except String Body := .ok ⟨s⟩

instance : ColCodec Body := ColCodec.via (·.raw) Body.make

/-- A point in time, seconds since the Unix epoch. -/
structure Timestamp where
  epochSeconds : Nat
  deriving Repr, DecidableEq, Ord

instance : ColCodec Timestamp :=
  ColCodec.via (·.epochSeconds) (fun n => .ok ⟨n⟩)

/-- Whole hours between two instants, in either order. -/
def Timestamp.hoursBetween (a b : Timestamp) : Nat :=
  (max a.epochSeconds b.epochSeconds - min a.epochSeconds b.epochSeconds) / 3600

/-- `t.addHours h` is `h` hours later. -/
def Timestamp.addHours (t : Timestamp) (h : Nat) : Timestamp :=
  ⟨t.epochSeconds + h * 3600⟩

/-- An effort estimate in whole hours, at most 240 (six working weeks —
    anything larger is a plan, not a ticket). -/
structure Estimate where
  hours : UInt16
  deriving Repr, DecidableEq, Ord

def Estimate.make (h : Nat) : Except String Estimate :=
  if h > 240 then .error s!"estimate must be at most 240 hours, got {h}"
  else .ok ⟨UInt16.ofNat h⟩

instance : ColCodec Estimate :=
  ColCodec.via (·.hours) (fun h =>
    if h ≤ 240 then .ok ⟨h⟩
    else .error s!"estimate must be at most 240 hours, got {h}")

end Tickets
