import Eats.Scalars
import Eats.Enums

/-! # The espresso configuration space (LEP-0005 stage 1, by hand)

A latte is not a dish; it is a *family* of dishes indexed by choices:
`Temp × Size × Milk × Shots × Bool`, 2·3·5·3·2 = 180 drinks, some of
which no café sells (no small iced; no decaf triple). This file is the
vocabulary for that space and the pricing *rule* over it, written by
hand — every piece of it is what `deriving LeanDb.Config` (LEP-0005
engine stage 2) would generate:

* the closed worlds `Temp`, `Milk`, `Shots` (`Size` is reused from
  `Enums.lean`, whose middle size is `regular`, not `medium`);
* `EspressoConfig` with defaults, `all` (the cartesian product),
  `valid`, `allValid` (125 of 180), a canonical text form;
* `EspressoOption` — a typed (field, value) pair standing in for the
  LEP-0002 field symbols an entity gets and a plain structure does not;
* `PriceRule` — base, additive deltas, overriding prices — with `eval`,
  `tabulate`, bounds, the two lints, and a JSON column codec whose
  decoder refuses a rule that fails either lint.

Nothing here is an entity. The config is hand-flattened into columns in
`Offers.lean`; the rule is one compressed-JSON TEXT column. -/

namespace Eats

open LeanDb

/-! ## Closed worlds -/

inductive Temp where
  | hot | iced
  deriving Repr, DecidableEq, Ord, LeanDb.ClosedEnum

inductive Milk where
  | whole | skim | oat | almond | soy
  deriving Repr, DecidableEq, Ord, LeanDb.ClosedEnum

inductive Shots where
  | single | double | triple
  deriving Repr, DecidableEq, Ord, LeanDb.ClosedEnum

/-- JSON for a closed world is its constructor name — the same spelling
    the column CHECK and the CLI use. Written per type rather than as a
    blanket `[ClosedEnum α]` instance so it cannot shadow a derived one. -/
private def enumToJson [ClosedEnum α] (a : α) : Lean.Json := .str (ClosedEnum.encodeName a)
private def enumFromJson [ClosedEnum α] (j : Lean.Json) : Except String α := do
  let s ← j.getStr?
  match ClosedEnum.decodeName (α := α) s with
  | some a => .ok a
  | none => .error s!"{String.quote s} is not in the closed world"

/-- Decode a closed-world name at a boundary, naming the field. -/
private def decodeEnum [ClosedEnum α] (what : String) (t : String) : Except String α :=
  match ClosedEnum.decodeName (α := α) t with
  | some a => .ok a
  | none => .error s!"{what}: {String.quote t} is not one of {ClosedEnum.variants α}"

instance : Lean.ToJson Temp := ⟨enumToJson⟩
instance : Lean.FromJson Temp := ⟨enumFromJson⟩
instance : Lean.ToJson Size := ⟨enumToJson⟩
instance : Lean.FromJson Size := ⟨enumFromJson⟩
instance : Lean.ToJson Milk := ⟨enumToJson⟩
instance : Lean.FromJson Milk := ⟨enumFromJson⟩
instance : Lean.ToJson Shots := ⟨enumToJson⟩
instance : Lean.FromJson Shots := ⟨enumFromJson⟩

instance : Lean.ToJson Money := ⟨fun m => Lean.toJson m.minor⟩
instance : Lean.FromJson Money := ⟨fun j => (⟨·⟩) <$> Lean.fromJson? (α := Nat) j⟩
instance : Lean.ToJson Delta := ⟨fun d => Lean.toJson d.minor.toInt⟩
instance : Lean.FromJson Delta := ⟨fun j => (⟨Int64.ofInt ·⟩) <$> Lean.fromJson? (α := Int) j⟩

/-- What choosing a milk puts in the cup. Total by `match`: adding a milk
    walks you here. Whole and skim are `.dairy`; oat is `.grain` (the
    seed's "oat milk" ingredient is classified the same way); almond is
    `.treeNut`; soy is `.soy`. -/
def Milk.kind : Milk → IngredientKind
  | .whole | .skim => .dairy
  | .oat => .grain
  | .almond => .treeNut
  | .soy => .soy

/-! ## The configuration type -/

/-- One drink of the family. Defaults are the plain order: hot, regular,
    whole milk, double shot, caffeinated. -/
structure EspressoConfig where
  temp  : Temp  := .hot
  size  : Size  := .regular
  milk  : Milk  := .whole
  shots : Shots := .double
  decaf : Bool  := false
  deriving Repr, DecidableEq, Lean.ToJson, Lean.FromJson

namespace EspressoConfig

/-- The whole space, declaration order of each world, `false` before
    `true` — 180 drinks. Written as list comprehension (not an `Id.run`
    loop) so the kernel can unfold it under `decide`. -/
def all : Array EspressoConfig :=
  ((ClosedEnum.all (α := Temp)).toList.flatMap fun temp =>
    (ClosedEnum.all (α := Size)).toList.flatMap fun size =>
      (ClosedEnum.all (α := Milk)).toList.flatMap fun milk =>
        (ClosedEnum.all (α := Shots)).toList.flatMap fun shots =>
          [false, true].map fun decaf => { temp, size, milk, shots, decaf }).toArray

/-- The combinations no café offers: no small iced drink (the cup is
    the ice), and decaf is pulled as at most a double. -/
def valid (c : EspressoConfig) : Bool :=
  !(c.temp == .iced && c.size == .small) && !(c.decaf && c.shots == .triple)

/-- The 125 valid drinks. Every "for all configurations" below quantifies
    over this. -/
def allValid : Array EspressoConfig := all.filter valid

/-- Canonical text, for logs, errors and the CLI: `iced/large/oat/double/decaf`
    (or `regular` for the caffeinated default). Parsed by `parse`. -/
def render (c : EspressoConfig) : String :=
  s!"{ClosedEnum.encodeName c.temp}/{ClosedEnum.encodeName c.size}/{ClosedEnum.encodeName c.milk}/{ClosedEnum.encodeName c.shots}/{if c.decaf then "decaf" else "regular"}"

def parse (s : String) : Except String EspressoConfig := do
  match s.splitOn "/" with
  | [t, sz, m, sh, d] =>
      let decaf ← match d with
        | "decaf" => pure true
        | "regular" => pure false
        | _ => throw s!"expected decaf|regular, got {String.quote d}"
      return { temp := ← decodeEnum "temp" t, size := ← decodeEnum "size" sz
               milk := ← decodeEnum "milk" m, shots := ← decodeEnum "shots" sh, decaf }
  | _ => throw s!"expected temp/size/milk/shots/decaf|regular, got {String.quote s}"

/-- What a configuration adds to the base ingredients of the offer:
    espresso, and the milk's kind. Total — the compiler keeps it so when
    a milk is added. -/
def ingredients (c : EspressoConfig) : List IngredientKind :=
  [.coffee, c.milk.kind]

end EspressoConfig

/-! ## Typed options and patterns -/

/-- A (field, value) pair of `EspressoConfig`, typed: `.milk .oat` is a
    value, `.milk .large` does not elaborate. This is what LEP-0002's
    field symbols give an *entity* for free (`Ticket.Field.title` with
    `fieldTy`) and what a plain structure has to write by hand until
    `deriving LeanDb.Config` (LEP-0005 engine stage 1) generates it. -/
inductive EspressoOption where
  | temp  (t : Temp)
  | size  (s : Size)
  | milk  (m : Milk)
  | shots (n : Shots)
  | decaf (b : Bool)
  deriving Repr, DecidableEq, Lean.ToJson, Lean.FromJson

def EspressoOption.matches : EspressoOption → EspressoConfig → Bool
  | .temp t, c => c.temp == t
  | .size s, c => c.size == s
  | .milk m, c => c.milk == m
  | .shots n, c => c.shots == n
  | .decaf b, c => c.decaf == b

def EspressoOption.render : EspressoOption → String
  | .temp t => s!"temp={ClosedEnum.encodeName t}"
  | .size s => s!"size={ClosedEnum.encodeName s}"
  | .milk m => s!"milk={ClosedEnum.encodeName m}"
  | .shots n => s!"shots={ClosedEnum.encodeName n}"
  | .decaf b => s!"decaf={b}"

/-- `key=value`, the CLI spelling of one option. -/
def EspressoOption.parse (s : String) : Except String EspressoOption := do
  match s.splitOn "=" with
  | ["temp", v] => .temp <$> decodeEnum "temp" v
  | ["size", v] => .size <$> decodeEnum "size" v
  | ["milk", v] => .milk <$> decodeEnum "milk" v
  | ["shots", v] => .shots <$> decodeEnum "shots" v
  | ["decaf", "true"] => pure (.decaf true)
  | ["decaf", "false"] => pure (.decaf false)
  | ["decaf", v] => throw s!"decaf must be true or false, got {String.quote v}"
  | [k, _] => throw s!"unknown option {String.quote k}; options: temp, size, milk, shots, decaf"
  | _ => throw s!"expected key=value, got {String.quote s}"

/-- A partial configuration: some fields fixed, the rest free. `[]`
    matches everything; `[.temp .iced, .milk .oat]` is "iced oat". -/
abbrev Pattern := List EspressoOption

def Pattern.matches (p : Pattern) (c : EspressoConfig) : Bool :=
  p.all (·.matches c)

def Pattern.render (p : Pattern) : String :=
  if p.isEmpty then "*" else String.intercalate "," (p.map EspressoOption.render)

/-! ## The pricing rule -/

/-- A café's pricing of the family: a base, additive deltas (every match
    applies), and overriding prices (the first match *replaces* the
    computed price — "iced large oat is $7.25, full stop"). First-order
    data; `eval` is the function it denotes. -/
structure PriceRule where
  base      : Money
  deltas    : List (Pattern × Delta) := []
  overrides : List (Pattern × Money) := []
  deriving Repr, DecidableEq, Lean.ToJson, Lean.FromJson

namespace PriceRule

/-- The price before clamping, as an `Int`: an override, or base plus
    every matching delta. `Money` is `Nat` and `Delta` is `Int64`, so the
    sum is signed; `nonNegative` is the lint that keeps it honest. -/
def evalRaw (r : PriceRule) (c : EspressoConfig) : Int :=
  match r.overrides.find? (fun (p, _) => Pattern.matches p c) with
  | some (_, m) => Int.ofNat m.minor
  | none =>
      (r.deltas.filter (fun (p, _) => Pattern.matches p c)).foldl
        (fun acc (_, d) => acc + d.minor.toInt) (Int.ofNat r.base.minor)

/-- The price of a configuration. A negative sum floors at zero — a rule
    that can reach it fails `nonNegative` and never enters a column. -/
def eval (r : PriceRule) (c : EspressoConfig) : Money :=
  ⟨(r.evalRaw c).toNat⟩

/-- The rule, materialized over the valid space: 125 prices. -/
def tabulate (r : PriceRule) : Array (EspressoConfig × Money) :=
  EspressoConfig.allValid.map fun c => (c, r.eval c)

def minPrice (r : PriceRule) : Money :=
  r.tabulate.foldl (fun acc (_, m) => if m.minor < acc.minor then m else acc) r.base

def maxPrice (r : PriceRule) : Money :=
  r.tabulate.foldl (fun acc (_, m) => if m.minor > acc.minor then m else acc) r.base

/-- Lint: no two overrides match the same valid configuration, so "first
    match" is never an accident of list order. Decidable over the finite
    space. -/
def overridesDisjoint (r : PriceRule) : Bool :=
  EspressoConfig.allValid.all fun c =>
    (r.overrides.filter fun (p, _) => Pattern.matches p c).length ≤ 1

/-- Lint: no valid configuration prices below zero. -/
def nonNegative (r : PriceRule) : Bool :=
  EspressoConfig.allValid.all fun c => r.evalRaw c ≥ 0

/-- Both lints, as the boundary check: a rule that fails either is refused
    by the codec (`insert`, the CLI's JSON, a row written by hand). -/
def validate (r : PriceRule) : Except String PriceRule := do
  unless r.overridesDisjoint do
    let bad := EspressoConfig.allValid.find? fun c =>
      (r.overrides.filter fun (p, _) => Pattern.matches p c).length > 1
    throw s!"ambiguous rule: two overrides match {(bad.map (·.render)).getD "?"}"
  unless r.nonNegative do
    let bad := EspressoConfig.allValid.find? fun c => r.evalRaw c < 0
    throw s!"negative price at {(bad.map (·.render)).getD "?"}"
  return r

end PriceRule

/-- The one nested column: compressed JSON TEXT, decoded through
    `validate`. SQL sees a string — equality and nothing else pushes. -/
instance : ColCodec PriceRule :=
  ColCodec.via (fun r => (Lean.toJson r).compress)
    (fun t => Lean.Json.parse t >>= Lean.fromJson? >>= PriceRule.validate)

end Eats
