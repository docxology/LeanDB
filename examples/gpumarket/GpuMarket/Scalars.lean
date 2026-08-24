import LeanDb

/-! # Scalars — no anonymous primitives -/

namespace GpuMarket

open LeanDb

/-- USD per GPU-hour in **millidollars** ($2.49/hr = 2490). Integer money:
    exact comparisons, no float drift in ORDER BY. -/
structure Price where
  milli : Nat
  deriving Repr, DecidableEq, Ord

def Price.make (milli : Nat) : Except String Price :=
  if milli == 0 then .error "price must be positive"
  else if milli > 1000000 then .error "price above $1000/hr is surely a typo"
  else .ok ⟨milli⟩

instance : ColCodec Price := ColCodec.via (·.milli) Price.make

/-- GPUs per node in the listing: 1, 2, 4 or 8. -/
structure GpuCount where
  n : Nat
  deriving Repr, DecidableEq, Ord

def GpuCount.make (n : Nat) : Except String GpuCount :=
  if [1, 2, 4, 8].contains n then .ok ⟨n⟩
  else .error s!"GPU count must be 1, 2, 4 or 8, got {n}"

instance : ColCodec GpuCount := ColCodec.via (·.n) GpuCount.make

structure Timestamp where
  epochSeconds : Nat
  deriving Repr, DecidableEq, Ord

instance : ColCodec Timestamp := ColCodec.via (·.epochSeconds) (.ok ⟨·⟩)

end GpuMarket
