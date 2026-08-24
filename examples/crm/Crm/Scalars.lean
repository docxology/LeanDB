import LeanDb

/-! # Scalars

Per-type validated newtypes. Each carries its own smart constructor and its
own `ColCodec` built with `ColCodec.via` — there is deliberately no shared
generic "bounded text" wrapper: the validation rule *is* the type.
-/

namespace Crm

open LeanDb

/-- A person's display name: trimmed, nonempty, at most 120 characters. -/
structure FullName where
  raw : String
  deriving Repr, DecidableEq, Ord

def FullName.make (s : String) : Except String FullName :=
  let t := s.trimAscii.toString
  if t.isEmpty then .error "name must be nonempty"
  else if t.length > 120 then .error s!"name too long ({t.length} > 120 chars)"
  else .ok ⟨t⟩

instance : ColCodec FullName := ColCodec.via (·.raw) FullName.make

/-- An email address: exactly one `@`, with a nonempty local part and a
    nonempty domain. Deliberately no more than that — real validation is
    delivery, not regex archaeology. -/
structure Email where
  raw : String
  deriving Repr, DecidableEq, Ord

def Email.make (s : String) : Except String Email :=
  match s.splitOn "@" with
  | [localPart, domain] =>
      if localPart.isEmpty then .error s!"email has empty local part: {String.quote s}"
      else if domain.isEmpty then .error s!"email has empty domain: {String.quote s}"
      else .ok ⟨s⟩
  | _ => .error s!"email must contain exactly one '@': {String.quote s}"

instance : ColCodec Email := ColCodec.via (·.raw) Email.make

/-- A company's legal or trading name: trimmed, nonempty, at most 160
    characters. -/
structure CompanyName where
  raw : String
  deriving Repr, DecidableEq, Ord

def CompanyName.make (s : String) : Except String CompanyName :=
  let t := s.trimAscii.toString
  if t.isEmpty then .error "company name must be nonempty"
  else if t.length > 160 then .error s!"company name too long ({t.length} > 160 chars)"
  else .ok ⟨t⟩

instance : ColCodec CompanyName := ColCodec.via (·.raw) CompanyName.make

/-- Free-form prose. Any string is valid — but it is still its own type, so
    a `Note` never wanders into a name or email column. -/
structure Note where
  raw : String
  deriving Repr, DecidableEq, Ord

def Note.make (s : String) : Except String Note := .ok ⟨s⟩

instance : ColCodec Note := ColCodec.via (·.raw) Note.make

/-- A point in time, seconds since the Unix epoch. -/
structure Timestamp where
  epochSeconds : Nat
  deriving Repr, DecidableEq, Ord

instance : ColCodec Timestamp :=
  ColCodec.via (·.epochSeconds) (fun n => .ok ⟨n⟩)

/-- `t.olderThanDays now d` — is `t` strictly more than `d` whole days
    before `now`? -/
def Timestamp.olderThanDays (t now : Timestamp) (days : Nat) : Bool :=
  t.epochSeconds + days * 86400 < now.epochSeconds

/-- `t.subDays d` is `d` days earlier (clamped at the epoch). -/
def Timestamp.subDays (t : Timestamp) (d : Nat) : Timestamp :=
  ⟨t.epochSeconds - d * 86400⟩

end Crm
