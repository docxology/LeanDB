import LeanDb
import Kernels.Enums

/-! # Scalars — no anonymous primitives

Validated newtypes, each with its own smart constructor and a
`ColCodec.via` through its projection, so that ordering on `Micros`,
`Timestamp`, … pushes to SQL through the projection (`m.val.latency.us`)
and equality pushes on every one of them.

Two of these are *encodings of structure into one TEXT column*:
`DimBinding` (a sorted assignment, order-independent, so equality is
`TEXT IS`) and `FusedOps` (a sorted set of a closed world — the `EnumSet`
gap named in plan-v2 M3). Both push equality and nothing else. -/

namespace Kernels

open LeanDb

/-- Microseconds of wall-clock latency; positive. -/
structure Micros where
  us : Nat
  deriving Repr, DecidableEq, Ord

def Micros.make (us : Nat) : Except String Micros :=
  if us == 0 then .error "latency must be positive" else .ok ⟨us⟩

instance : ColCodec Micros := ColCodec.via (·.us) Micros.make

/-- Achieved throughput in milli-TFLOPS (1 TFLOPS = 1000). -/
structure MilliTflops where
  milli : Nat
  deriving Repr, DecidableEq, Ord

instance : ColCodec MilliTflops := ColCodec.via (·.milli) (.ok ⟨·⟩)

/-- Parts per thousand, 0–1000. -/
structure Permille where
  n : Nat
  deriving Repr, DecidableEq, Ord

def Permille.make (n : Nat) : Except String Permille :=
  if n > 1000 then .error s!"permille must be at most 1000, got {n}" else .ok ⟨n⟩

instance : ColCodec Permille := ColCodec.via (·.n) Permille.make

/-- A kernel's stable name: a slug, `a-z`, `0-9`, `-`; 3–64 chars. -/
structure KernelName where
  raw : String
  deriving Repr, DecidableEq, Ord

def KernelName.make (s : String) : Except String KernelName :=
  if s.length < 3 || s.length > 64 then
    .error s!"kernel name must be 3-64 chars, got {s.length}"
  else if !(s.toList.all fun c => c.isLower || c.isDigit || c == '-') then
    .error s!"kernel name may contain only a-z, 0-9 and '-': {String.quote s}"
  else .ok ⟨s⟩

instance : ColCodec KernelName := ColCodec.via (·.raw) KernelName.make

/-- Same slug rule for programs. -/
structure ProgramName where
  raw : String
  deriving Repr, DecidableEq, Ord

def ProgramName.make (s : String) : Except String ProgramName :=
  (KernelName.make s).map fun k => ⟨k.raw⟩

instance : ColCodec ProgramName := ColCodec.via (·.raw) ProgramName.make

/-- A free-text tag distinguishing builds of one op (`splitk-4`,
    `flash-v2-causal`); trimmed, nonempty, at most 64 chars. -/
structure Variant where
  raw : String
  deriving Repr, DecidableEq

def Variant.make (s : String) : Except String Variant :=
  let t := s.trimAscii.toString
  if t.isEmpty then .error "variant must be nonempty"
  else if t.length > 64 then .error s!"variant too long ({t.length} > 64 chars)"
  else .ok ⟨t⟩

instance : ColCodec Variant := ColCodec.via (·.raw) Variant.make

/-- sha256 of the kernel source: 64 lowercase hex digits. The source text
    itself is an artifact, not a column. -/
structure SourceHash where
  hex : String
  deriving Repr, DecidableEq

def SourceHash.make (s : String) : Except String SourceHash :=
  if s.length != 64 then .error s!"source hash must be 64 hex chars, got {s.length}"
  else if !(s.toList.all fun c => c.isDigit || ('a' ≤ c && c ≤ 'f')) then
    .error "source hash must be lowercase hex"
  else .ok ⟨s⟩

instance : ColCodec SourceHash := ColCodec.via (·.hex) SourceHash.make

private def shortText (what : String) (max : Nat) (s : String) : Except String String :=
  let t := s.trimAscii.toString
  if t.isEmpty then .error s!"{what} must be nonempty"
  else if t.length > max then .error s!"{what} too long ({t.length} > {max} chars)"
  else .ok t

structure DriverVersion where
  raw : String
  deriving Repr, DecidableEq

def DriverVersion.make (s : String) : Except String DriverVersion :=
  (shortText "driver version" 32 s).map (⟨·⟩)

instance : ColCodec DriverVersion := ColCodec.via (·.raw) DriverVersion.make

structure ToolchainVersion where
  raw : String
  deriving Repr, DecidableEq

def ToolchainVersion.make (s : String) : Except String ToolchainVersion :=
  (shortText "toolchain version" 32 s).map (⟨·⟩)

instance : ColCodec ToolchainVersion := ColCodec.via (·.raw) ToolchainVersion.make

structure HostId where
  raw : String
  deriving Repr, DecidableEq

def HostId.make (s : String) : Except String HostId :=
  (shortText "host id" 64 s).map (⟨·⟩)

instance : ColCodec HostId := ColCodec.via (·.raw) HostId.make

/-- Seconds since the Unix epoch. Ordering pushes through `.epochSeconds`. -/
structure Timestamp where
  epochSeconds : Nat
  deriving Repr, DecidableEq, Ord

instance : ColCodec Timestamp := ColCodec.via (·.epochSeconds) (.ok ⟨·⟩)

/-- A shape variable (`M`, `N`, `K`, `S`, `H`): an uppercase letter followed
    by up to 7 alphanumerics. Inside `KernelSig` it is a JSON string, and
    decoding there goes through this same constructor. -/
structure DimVar where
  name : String
  deriving Repr, DecidableEq, Ord

def DimVar.make (s : String) : Except String DimVar :=
  if s.isEmpty || s.length > 8 then .error s!"shape variable must be 1-8 chars, got {String.quote s}"
  else if !s.front.isUpper then .error s!"shape variable must start with an uppercase letter: {String.quote s}"
  else if !(s.toList.all Char.isAlphanum) then .error s!"shape variable must be alphanumeric: {String.quote s}"
  else .ok ⟨s⟩

instance : ColCodec DimVar := ColCodec.via (·.name) DimVar.make
instance : Lean.ToJson DimVar := ⟨fun v => .str v.name⟩
instance : Lean.FromJson DimVar := ⟨fun j => j.getStr? >>= DimVar.make⟩

/-- A concrete assignment of shape variables, `M=4096,N=4096,K=4096`.
    `make` sorts by variable and refuses duplicates, so the encoding is
    canonical: two bindings are equal iff their TEXT is, and
    `m.val.binding == b` pushes as `binding IS ?`. Nothing *inside* the
    text is addressable from SQL — "bindings with M ≥ 8192" is residual. -/
structure DimBinding where
  assign : List (DimVar × Nat)
  deriving Repr, DecidableEq

def DimBinding.make (xs : List (DimVar × Nat)) : Except String DimBinding :=
  let sorted := (xs.toArray.qsort fun a b => a.1.name < b.1.name).toList
  let names := sorted.map (·.1)
  if names.eraseDups.length != names.length then
    .error "binding assigns a variable twice"
  else .ok ⟨sorted⟩

def DimBinding.lookup (b : DimBinding) (v : DimVar) : Option Nat :=
  (b.assign.find? (·.1 == v)).map (·.2)

def DimBinding.encode (b : DimBinding) : String :=
  String.intercalate "," (b.assign.map fun (v, n) => s!"{v.name}={n}")

def DimBinding.decode (s : String) : Except String DimBinding := do
  if s.isEmpty then return ⟨[]⟩
  let pairs ← (s.splitOn ",").mapM fun kv => do
    match kv.splitOn "=" with
    | [k, v] =>
        let var ← DimVar.make k
        match v.toNat? with
        | some n => pure (var, n)
        | none => throw s!"binding {String.quote kv}: expected VAR=nat"
    | _ => throw s!"binding {String.quote kv}: expected VAR=nat"
  DimBinding.make pairs

instance : ColCodec DimBinding := ColCodec.via DimBinding.encode DimBinding.decode
instance : ToString DimBinding := ⟨DimBinding.encode⟩

/-- A set of ops a kernel fuses into its epilogue, as a sorted, deduplicated
    comma-separated TEXT of variant names. Equality pushes; membership
    ("fuses silu") does not — that is the `EnumSet` gap. -/
structure FusedOps where
  ops : List OpKind
  deriving Repr, DecidableEq

def FusedOps.make (ops : List OpKind) : FusedOps :=
  ⟨(ops.eraseDups.toArray.qsort fun a b => compare a b == .lt).toList⟩

def FusedOps.encode (f : FusedOps) : String :=
  String.intercalate "," (f.ops.map LeanDb.ClosedEnum.encodeName)

def FusedOps.decode (s : String) : Except String FusedOps := do
  if s.isEmpty then return ⟨[]⟩
  let ops ← (s.splitOn ",").mapM fun name =>
    match LeanDb.ClosedEnum.decodeName (α := OpKind) name with
    | some op => pure op
    | none => throw s!"fused op {String.quote name} is not in the closed world"
  return FusedOps.make ops

instance : ColCodec FusedOps := ColCodec.via FusedOps.encode FusedOps.decode

def FusedOps.contains (f : FusedOps) (op : OpKind) : Bool := f.ops.contains op

end Kernels
