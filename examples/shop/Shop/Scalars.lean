import LeanDb

/-! # Scalars

Per-type validated newtypes. Each carries its own smart constructor and its
own `ColCodec` built with `ColCodec.via` — no shared "bounded text" wrapper:
the validation rule *is* the type.
-/

namespace Shop

open LeanDb

/-- A product's display name: trimmed, nonempty, at most 140 characters. -/
structure ProductName where
  raw : String
  deriving Repr, DecidableEq, Ord

def ProductName.make (s : String) : Except String ProductName :=
  let t := s.trimAscii.toString
  if t.isEmpty then .error "product name must be nonempty"
  else if t.length > 140 then .error s!"product name too long ({t.length} > 140 chars)"
  else .ok ⟨t⟩

instance : ColCodec ProductName := ColCodec.via (·.raw) ProductName.make

/-- A customer's display name: trimmed, nonempty, at most 100 characters.
    Deliberately not a `ProductName` — a customer never names a product row. -/
structure CustomerName where
  raw : String
  deriving Repr, DecidableEq, Ord

def CustomerName.make (s : String) : Except String CustomerName :=
  let t := s.trimAscii.toString
  if t.isEmpty then .error "customer name must be nonempty"
  else if t.length > 100 then .error s!"customer name too long ({t.length} > 100 chars)"
  else .ok ⟨t⟩

instance : ColCodec CustomerName := ColCodec.via (·.raw) CustomerName.make

/-- A stock-keeping unit: uppercase `A-Z`, digits, and `-` only; 4–20 chars. -/
structure Sku where
  raw : String
  deriving Repr, DecidableEq, Ord

def Sku.make (s : String) : Except String Sku :=
  if s.length < 4 || s.length > 20 then
    .error s!"sku must be 4-20 chars, got {s.length}"
  else if !(s.toList.all fun c => ('A' ≤ c && c ≤ 'Z') || c.isDigit || c == '-') then
    .error s!"sku may contain only A-Z, 0-9, and '-': {String.quote s}"
  else .ok ⟨s⟩

instance : ColCodec Sku := ColCodec.via (·.raw) Sku.make

/-- An amount of money in whole cents. Exact — never a Float. -/
structure Money where
  cents : Nat
  deriving Repr, DecidableEq, Ord

def Money.make (cents : Nat) : Except String Money := .ok ⟨cents⟩

instance : ColCodec Money := ColCodec.via (·.cents) Money.make

/-- `$12.34`-style rendering, for humans at the CLI boundary. -/
def Money.render (m : Money) : String :=
  let c := m.cents % 100
  s!"${m.cents / 100}.{if c < 10 then "0" else ""}{c}"

/-- A line-item quantity: 1–999. Zero of something is not a line item. -/
structure Qty where
  count : UInt16
  deriving Repr, DecidableEq, Ord

def Qty.make (n : Nat) : Except String Qty :=
  if n < 1 || n > 999 then .error s!"qty must be 1-999, got {n}"
  else .ok ⟨UInt16.ofNat n⟩

instance : ColCodec Qty :=
  ColCodec.via (·.count) (fun n =>
    if 1 ≤ n.toNat && n.toNat ≤ 999 then .ok ⟨n⟩
    else .error s!"qty must be 1-999, got {n.toNat}")

/-- An email address: exactly one `@`, nonempty local part, and a domain
    with an interior dot. -/
structure Email where
  raw : String
  deriving Repr, DecidableEq, Ord

def Email.make (s : String) : Except String Email :=
  match s.splitOn "@" with
  | [localPart, domain] =>
      if localPart.isEmpty then .error s!"email has empty local part: {String.quote s}"
      else if domain.isEmpty || !domain.contains '.'
          || domain.startsWith "." || domain.endsWith "." then
        .error s!"email has malformed domain: {String.quote s}"
      else .ok ⟨s⟩
  | _ => .error s!"email must contain exactly one '@': {String.quote s}"

instance : ColCodec Email := ColCodec.via (·.raw) Email.make

/-- A point in time, seconds since the Unix epoch. -/
structure Timestamp where
  epochSeconds : Nat
  deriving Repr, DecidableEq, Ord

instance : ColCodec Timestamp :=
  ColCodec.via (·.epochSeconds) (fun n => .ok ⟨n⟩)

end Shop
