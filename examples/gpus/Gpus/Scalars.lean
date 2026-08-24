import LeanDb

/-! # Scalars

Per-type validated newtypes. Each carries its own smart constructor and its
own `ColCodec` built with `ColCodec.via`. Regions are *not* a scalar — a
region is a closed world (`Gpus.Region` in `Enums`), not free text.
-/

namespace Gpus

open LeanDb

/-- A provider's display name: trimmed, nonempty, at most 100 characters. -/
structure ProviderName where
  raw : String
  deriving Repr, DecidableEq, Ord

def ProviderName.make (s : String) : Except String ProviderName :=
  let t := s.trimAscii.toString
  if t.isEmpty then .error "provider name must be nonempty"
  else if t.length > 100 then .error s!"provider name too long ({t.length} > 100 chars)"
  else .ok ⟨t⟩

instance : ColCodec ProviderName := ColCodec.via (·.raw) ProviderName.make

/-- An hourly price in tenths of a cent — $2.49/hr is `⟨2490⟩`. Exact
    integer arithmetic; GPU markets quote sub-cent differences. -/
structure PricePerHour where
  tenthsOfCent : Nat
  deriving Repr, DecidableEq, Ord

def PricePerHour.make (tenthsOfCent : Nat) : Except String PricePerHour :=
  .ok ⟨tenthsOfCent⟩

instance : ColCodec PricePerHour := ColCodec.via (·.tenthsOfCent) PricePerHour.make

/-- `$2.490/hr`-style rendering, for humans at the CLI boundary. -/
def PricePerHour.render (p : PricePerHour) : String :=
  let sub := p.tenthsOfCent % 1000
  let pad := if sub < 10 then "00" else if sub < 100 then "0" else ""
  s!"${p.tenthsOfCent / 1000}.{pad}{sub}/hr"

/-- A VRAM size in whole gigabytes, at most 512 — anything larger is a
    typo, not a card. -/
structure VramGb where
  gb : Nat
  deriving Repr, DecidableEq, Ord

def VramGb.make (gb : Nat) : Except String VramGb :=
  if gb > 512 then .error s!"vram must be at most 512 GB, got {gb}"
  else .ok ⟨gb⟩

instance : ColCodec VramGb :=
  ColCodec.via (·.gb) VramGb.make

/-- An http(s) URL. -/
structure Url where
  raw : String
  deriving Repr, DecidableEq, Ord

def Url.make (s : String) : Except String Url :=
  if s.startsWith "http://" || s.startsWith "https://" then .ok ⟨s⟩
  else .error s!"url must start with http:// or https://: {String.quote s}"

instance : ColCodec Url := ColCodec.via (·.raw) Url.make

end Gpus
