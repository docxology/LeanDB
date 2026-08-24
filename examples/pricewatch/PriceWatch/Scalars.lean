import LeanDb

/-! # Scalars — no anonymous primitives

Everything a scraper hands the normalizer arrives as strings and floats;
everything the normalizer hands THIS base must already have passed these
smart constructors. The types are the normalizer's spec. -/

namespace PriceWatch

open LeanDb

/-- Canonical product title: trimmed, nonempty, ≤ 300 chars. -/
structure ProductName where
  raw : String
  deriving Repr, DecidableEq

def ProductName.make (s : String) : Except String ProductName :=
  let t := s.trimAscii.toString
  if t.isEmpty then .error "product name must be nonempty"
  else if t.length > 300 then .error "product name over 300 chars — normalizer should truncate"
  else .ok ⟨t⟩

instance : ColCodec ProductName := ColCodec.via (·.raw) ProductName.make

/-- Brand is open-world (scrapers meet new brands daily) but named:
    trimmed, nonempty. -/
structure Brand where
  raw : String
  deriving Repr, DecidableEq

def Brand.make (s : String) : Except String Brand :=
  let t := s.trimAscii.toString
  if t.isEmpty then .error "brand must be nonempty" else .ok ⟨t⟩

instance : ColCodec Brand := ColCodec.via (·.raw) Brand.make

/-- A listing URL: http(s) only. -/
structure Url where
  raw : String
  deriving Repr, DecidableEq

def Url.make (s : String) : Except String Url :=
  if s.startsWith "https://" || s.startsWith "http://" then .ok ⟨s⟩
  else .error s!"not an http(s) url: {s}"

instance : ColCodec Url := ColCodec.via (·.raw) Url.make

/-- Money in minor units (paise/cents). Integer, exact, positive. -/
structure Money where
  minor : Nat
  deriving Repr, DecidableEq, Ord

def Money.make (minor : Nat) : Except String Money :=
  if minor == 0 then .error "price must be positive" else .ok ⟨minor⟩

instance : ColCodec Money := ColCodec.via (·.minor) Money.make

/-- Star rating in tenths, 0–50 ("4.4 stars" = 44). -/
structure Rating where
  tenths : Nat
  deriving Repr, DecidableEq, Ord

def Rating.make (tenths : Nat) : Except String Rating :=
  if tenths ≤ 50 then .ok ⟨tenths⟩ else .error s!"rating {tenths}/10 exceeds 5.0 stars"

instance : ColCodec Rating := ColCodec.via (·.tenths) Rating.make

structure Timestamp where
  epochSeconds : Nat
  deriving Repr, DecidableEq, Ord

instance : ColCodec Timestamp := ColCodec.via (·.epochSeconds) (.ok ⟨·⟩)

end PriceWatch
