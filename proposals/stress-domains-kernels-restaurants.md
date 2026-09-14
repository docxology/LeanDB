# Design study: two stress domains for LeanDB

| Field | Value |
|---|---|
| Status | Study (not a LEP) |
| Created | 2026-09-01 |
| Feeds | LEP-0001 (row symbols), LEP-0002 (typed predicate IR), and two LEPs this study motivates |

Two bases chosen to break things: a **kernel database** (GPU compute
kernels, their typed signatures, composition into programs, and per-SKU
performance logs) and a **restaurant database** (dishes, ingredients,
modifications, hours, prices — with dietary reasoning). For each, this
document writes the *ideal* Lean types and query universe first, ignoring
what the engine can do today, then evaluates the 0.2 engine against them.
Every sketch is annotated: `✓` works today, `~` works with a workaround,
`✗` needs an engine change (named).

The evaluation is at the end, followed by a recommended order of work.

---

## 1. Kernel database

### 1.1 What "strongly typed kernel" has to mean

A kernel is shape-polymorphic: a GEMM is `∀ M N K, T[M,K] → T[K,N] → T[M,N]`
with divisibility constraints on `K` and a tile. That is a Π-type, and a
database row cannot *be* a Π-type. What a row can hold is the **code** of
the signature — a small DSL value — from which Lean computes the type. This
is the same move LeanDB already makes for schemas (`ColumnSpec` is a code;
`Entity.decode` interprets it) and that LEP-0002 makes for predicates.

So the design has three layers, and the database is only the first:

1. **Rows**: kernel metadata, a signature *as data*, performance samples.
2. **Denotation** (pure Lean): `KernelSig.denote : KernelSig → Type`.
3. **Programs** (pure Lean): `Prog ins outs`, a DAG whose edges are tensor
   types, built from fetched rows and checked by the compiler.

"Mechanically combine them and produce full programs" is layer 3 over layer
1 — queries narrow the candidate set, Lean does unification and codegen.

### 1.2 Vocabulary (closed worlds)

```lean
namespace Kernels

inductive DType where                                                   -- ✓ ClosedEnum
  | f64 | f32 | tf32 | bf16 | f16 | fp8e4m3 | fp8e5m2 | fp4e2m1
  | int8 | int4 | int32 | uint8 | bool
  deriving Repr, DecidableEq, Ord, LeanDb.ClosedEnum

def DType.bits : DType → Nat                                            -- total; @[db] if ever filtered on
def DType.isFloat : DType → Bool

inductive OpKind where                                                  -- ✓
  | gemm | gemv | batchedGemm | attention | flashAttention | pagedAttention
  | softmax | layerNorm | rmsNorm | rope | silu | gelu | reduce | scan
  | embedding | allReduce | allGather | conv2d | topK | sort
  deriving Repr, DecidableEq, Ord, LeanDb.ClosedEnum

inductive Lang where | cuda | hip | triton | cutlass | ck | ptx | mlir  -- ✓
  deriving Repr, DecidableEq, Ord, LeanDb.ClosedEnum

/-- Target architectures. Ordered by capability *within a vendor*; the
    order across vendors is meaningless, which is exactly why this must
    not be `SqlOrd` and why `supports` is a total function, not `≤`. -/
inductive Arch where                                                    -- ✓
  | sm80 | sm86 | sm89 | sm90 | sm100 | gfx90a | gfx942 | gfx950
  deriving Repr, DecidableEq, Ord, LeanDb.ClosedEnum

@[db] def Arch.supports (target minimum : Arch) : Bool := …            -- ~ two-column case split; see §3.4

inductive MemSpace where | global | shared | register | constant       -- ✓
  deriving Repr, DecidableEq, Ord, LeanDb.ClosedEnum

/-- The SKU vocabulary is *gpumarket's* `Gpu`, imported as a Lake
    dependency. First cross-base type reuse; `Gpu.spec` (VRAM, bandwidth,
    dense TFLOPS per precision) comes with it for roofline arithmetic. -/
-- open GpuMarket (Gpu)                                                  -- ✓ types cross bases; instances do not (§3.7)
```

### 1.3 Signatures as data, and their denotation

```lean
/-- A validated identifier for a shape variable (`M`, `N`, `K`, `H`, `S`). -/
structure DimVar where name : String                                    -- ✓ newtype, smart constructor
instance : ColCodec DimVar := ColCodec.via (·.name) DimVar.make

/-- A symbolic dimension: literal, bound variable, or a small affine
    expression in bound variables (`K / 2`, `2 * S + 1`). -/
inductive Dim where                                                     -- ✗ payload-carrying sum: not a ClosedEnum,
  | lit (n : Nat)                                                       --   not a flat structure; needs a codec (§3.1)
  | var (v : DimVar)
  | mul (k : Nat) (d : Dim)
  | add (a b : Dim)
  | div (d : Dim) (k : Nat)
  deriving Repr, DecidableEq

inductive Layout where                                                  -- ✗ same
  | rowMajor | colMajor
  | strided (strides : List Dim)
  | tiled (tile : List Nat) (inner : Layout)
  deriving Repr, DecidableEq

structure TensorTy where                                                -- ✗ nested value (§3.1)
  dtype  : DType
  shape  : List Dim
  layout : Layout := .rowMajor
  mem    : MemSpace := .global
  align  : Nat := 16
  deriving Repr, DecidableEq

inductive DimConstraint where                                           -- ✗ same
  | divides (k : Nat) (d : Dim)
  | le (a b : Dim)
  | eq (a b : Dim)

/-- The signature. Invariants belong to `KernelSig.make`, not to the
    fields: every variable in `ins`/`outs`/`constraints` is bound in
    `vars`, and every variable that appears in an output appears in some
    input (outputs are determined). Validation as inhabitation — a
    `KernelSig` that exists is well-formed. -/
structure KernelSig where                                               -- ✗ nested value; stored as one codec'd column today (§3.1)
  vars        : List DimVar
  ins         : List TensorTy
  outs        : List TensorTy
  scalars     : List (ScalarName × DType)       -- alpha, beta, eps, causal
  constraints : List DimConstraint
  deriving Repr, DecidableEq

def KernelSig.make : … → Except String KernelSig

/-- A concrete binding of the shape variables: `{M := 4096, N := 4096, K := 4096}`. -/
structure DimBinding where                                              -- ~ canonical text encoding; equality pushes as TEXT IS
  assign : List (DimVar × Nat)                  -- sorted by var; `make` enforces
instance : ColCodec DimBinding := …             -- canonical string, order-independent

/-! ### Denotation — from data to a Lean type. Pure; never stored. -/

def Dim.eval (env : DimVar → Nat) : Dim → Nat
def DType.denote : DType → Type                 -- f32 ↦ Float, int32 ↦ Int32, …
def TensorTy.denote (env : DimVar → Nat) (t : TensorTy) : Type :=
  { a : Array t.dtype.denote // a.size = (t.shape.map (Dim.eval env)).foldl (· * ·) 1 }
def KernelSig.denote (s : KernelSig) : Type :=
  (env : DimVar → Nat) → s.constraints.all (·.holds env) = true →
    HList (s.ins.map (TensorTy.denote env)) → HList (s.outs.map (TensorTy.denote env))

/-- Instantiate at a binding: the monomorphic in/out types, or a named
    reason (unbound var, violated constraint). -/
def KernelSig.instantiate (s : KernelSig) (b : DimBinding) :
    Except String (List TensorTy × List TensorTy)
```

### 1.4 Entities

```lean
structure Kernel where
  name      : KernelName            -- ✓ validated slug newtype
  op        : OpKind                -- ✓
  lang      : Lang                  -- ✓
  variant   : Variant               -- ✓ newtype ("flash-v2-causal", "splitk-4")
  sig       : KernelSig             -- ✗ nested (§3.1)
  minArch   : Arch                  -- ✓
  maxArch   : Option Arch           -- ✓
  launch    : LaunchConfig          -- ✗ nested, but *small and fixed* → inline-flatten candidate (§3.1)
  numeric   : NumericProps          -- ✗ nested: {deterministic : Bool, accum : DType, errBound : Option Micro}
  fuses     : List OpKind           -- ✗ set of a closed world → EnumSet bitmask (plan-v2 M3, deferred) or child table
  source    : SourceHash            -- ✓ sha256 newtype; source text is an artifact, not a column
  license   : License               -- ✓ ClosedEnum
  /-- Denormalized *search* columns, filled by `Kernel.make` from `sig`
      so the common filters push to SQL. The invariant that they agree
      with `sig` is cross-field — see §3.2. -/
  inDtype0  : DType                 -- ✓ pushable
  outDtype0 : DType                 -- ✓
  rank0     : Nat                   -- ✓
  deriving Repr, LeanDb.Entity

/-- One measurement. `sku` is gpumarket's closed world, so "log their
    performance (separate table with specific SKU)" is a column, and SKU
    facts (`Gpu.spec`) are total functions with no lookup. -/
structure Bench where
  kernel     : Ref Kernel           -- ✓
  sku        : Gpu                  -- ✓ cross-base *type*
  binding    : DimBinding           -- ~ TEXT equality only
  precision  : DType                -- ✓
  latency    : Micros               -- ✓ Nat newtype; ordering pushes through `.us` (projection fix)
  tflops     : MilliTflops          -- ✓
  bwGBs      : Nat                  -- ✓
  occupancy  : Permille             -- ✓
  warmup     : Nat ; iters : Nat    -- ✓
  driver     : DriverVersion        -- ✓ newtype
  toolchain  : ToolchainVersion     -- ✓
  host       : HostId               -- ✓
  measuredAt : Timestamp            -- ✓
  deriving Repr, LeanDb.Entity

/-- A stored program: the DAG relationally, re-typed on read. -/
structure Program where
  name : ProgramName ; sku : Gpu ; binding : DimBinding
  deriving Repr, LeanDb.Entity

structure ProgramNode where
  program  : Ref Program
  position : Nat
  kernel   : Ref Kernel
  /-- Which earlier node's output feeds each input; `none` = program input. -/
  feeds    : List (Option (Nat × Nat))    -- ✗ list → child table `ProgramEdge` in practice
  deriving Repr, LeanDb.Entity
```

### 1.5 Programs — the typed layer, entirely in Lean

```lean
/-- A typed DAG. Edges are tensor types; a node is a *stored* kernel plus a
    proof that its signature instantiates to the node's edge types. The
    compiler checks composition; the database never sees this type. -/
inductive Prog : List TensorTy → List TensorTy → Type where
  | kernel (k : Stored Kernel) (b : DimBinding)
      (h : k.val.sig.instantiate b = .ok (ins, outs)) : Prog ins outs
  | seq  : Prog a b → Prog b c → Prog a c
  | par  : Prog a b → Prog c d → Prog (a ++ c) (b ++ d)
  | swap : Prog [x, y] [y, x]
  | dup  : Prog [x] [x, x]

/-- The gate: relational rows back into a typed program, or a named reason. -/
def Prog.ofRows (nodes : Array (Stored ProgramNode)) (kernels : Ref Kernel → Stored Kernel) :
    Except String (Σ ins outs, Prog ins outs)

/-- "Produce full programs": emit a host program that launches each node
    in topological order with the right buffers. Needs source text from
    the artifact store keyed by `Kernel.source`. -/
def Prog.emit (lang : Lang) : Prog ins outs → (SourceHash → IO String) → IO String

/-- Sum of per-node latencies on a SKU at a binding, from `Bench`. -/
def Prog.estimate (lookup : Ref Kernel → DimBinding → Option Micros) : Prog ins outs → Option Micros
```

### 1.6 Query universe

```lean
/-- Candidates for an op on an arch at a dtype. -/
def candidates (op : OpKind) (arch : Arch) (dt : DType) : DbM (Array (Stored Kernel)) :=
  select [Kernel] (fun k =>
    k.val.op == op && k.val.inDtype0 == dt                            -- ✓ pushes
      && arch.supports k.val.minArch                                   -- ~ case split over `minArch` (8 branches),
      && (k.val.maxArch.isNone || k.val.maxArch == some arch))         --   each branch a `cmpVV` on captured `arch` — see §3.4
    (.key (·.val.name))

/-- Fastest measured kernel for an op on a SKU at a binding. -/
def fastest (op : OpKind) (sku : Gpu) (b : DimBinding) :
    DbM (Option (Stored Kernel × Stored Bench)) := do
  let rows ← select [Kernel, Bench] (fun (k, m) =>
    m.val.kernel == k.ref && k.val.op == op                            -- ✓ join + enum push
      && m.val.sku == sku && m.val.binding == b)                       -- ✓ TEXT IS on the canonical binding
    (.key fun (_, m) => m.val.latency)                                 -- ~ sort is client-side; no LIMIT (§3.5)
  return rows[0]?

/-- Kernels whose first input unifies with `k`'s first output. -/
def composable (k : Stored Kernel) : DbM (Array (Stored Kernel)) := do
  let cands ← select [Kernel] (fun c => c.val.inDtype0 == k.val.outDtype0)   -- ✓ narrows on the search column
  return cands.filter fun c => (unify k.val.sig.outs[0]? c.val.sig.ins[0]?).isSome  -- residual by nature: unification is Lean

/-- Synthesize a program for a chain of ops: search over candidates,
    threading edge types; return the first that typechecks. -/
def synthesize (ops : List OpKind) (sku : Gpu) (b : DimBinding) :
    DbM (Option (Σ ins outs, Prog ins outs))                          -- ✓ pure Lean over `candidates`

/-- Performance regressions: later sample slower than an earlier one by
    more than 10% for the same kernel/SKU/binding. A self-join. -/
def regressions (sku : Gpu) : DbM (Array (Stored Bench × Stored Bench)) :=
  select [Bench, Bench] (fun (a, c) =>
    a.val.kernel == c.val.kernel && a.val.sku == sku && c.val.sku == sku   -- ✓ self-join, cmp2 across t0/t1
      && a.val.binding == c.val.binding
      && a.val.measuredAt < c.val.measuredAt                              -- ✓ cmp2 ordering (Timestamp newtype → via)
      && c.val.latency.us * 10 > a.val.latency.us * 11)                    -- residual: column arithmetic (README names it deferred)

/-- Roofline position of every measured kernel on a SKU: arithmetic
    intensity vs achieved, against `Gpu.spec`. -/
def roofline (sku : Gpu) : DbM Json                                    -- ✓ Lean arithmetic over a pushed fetch

/-- $/TFLOP-hour of the fastest kernel per op, using gpumarket *listings*. -/
def perDollar (op : OpKind) (b : DimBinding) : DbM Json               -- ✗ needs gpumarket's *instance* (§3.7)
```

---

## 2. Restaurant database

### 2.1 The vocabulary problem is the whole problem

"Chai latte" on one menu is "Masala Chai Latte" on the next and "Dirty
Chai (oat)" on a third. "Average cost of chai latte in San Francisco" is
meaningless over free text and trivial over a canonical dish key. The
canonical dish set is open (thousands, grows weekly) but is *queried by
name in code* — which is precisely LEP-0001's row-symbol case. Menus keep
their own spelling in a `MenuName` newtype and point at the canonical row.

Dietary reasoning is the second vocabulary, and it is **never stored**.
No table carries a "vegetarian" tag. Ingredients have a *kind* (closed —
pork *is* pork, a fact about the ingredient, not a dietary opinion); a
diet is a named set of forbidden kinds; whether a dish suits a diet is
computed from its ingredient rows at query time. "Ramen without pork or
beef" is the filter `suitable .ramen .noPorkBeef`, "veg ramen" is
`suitable .ramen .vegetarian`, and there is nothing to keep in sync when a
recipe changes. Adding `.jain` is a compile-time refactor that walks you
to the one list that defines it.

### 2.2 Vocabulary

```lean
namespace Eats

inductive City where | sanFrancisco | oakland | berkeley | paloAlto | sanJose   -- ✓ closed for the test base
  deriving Repr, DecidableEq, Ord, LeanDb.ClosedEnum                              --   (a `City` table + Ref in production)

inductive Weekday where | mon | tue | wed | thu | fri | sat | sun               -- ✓
  deriving Repr, DecidableEq, Ord, LeanDb.ClosedEnum

/-- Minutes since midnight, 0–1439. -/
structure Clock where minutes : Nat                                              -- ✓ ordering pushes through `.minutes`
instance : ColCodec Clock := ColCodec.via (·.minutes) Clock.make

/-- Minor units, non-negative. -/
structure Money where minor : Nat                                                -- ✓
/-- A signed price delta ("oat milk +75", "no cheese −50"). `Int` has no
    codec; store via `Int64`. -/
structure Delta where minor : Int64                                              -- ~ `Int` is not a codec; `Int64` is

inductive Course where | drink | starter | main | dessert | side                -- ✓
inductive DishFamily where                                                       -- ✓ the *shape* of a dish, closed
  | ramen | pho | curry | pizza | burger | salad | latte | tea | tiramisu | gelato | dosa | biryani | …

inductive IngredientKind where                                                   -- ✓
  | pork | beef | lamb | chicken | fish | shellfish | egg | dairy
  | gluten | soy | peanut | treeNut | sesame | allium | mushroom | vegetable | grain | sugar | alcohol
  deriving Repr, DecidableEq, Ord, LeanDb.ClosedEnum

inductive Diet where                                                             -- ✓
  | omnivore | noPorkBeef | noBeef | noPork | pescatarian | vegetarian | vegan
  | jain | halal | kosher | glutenFree | nutFree
  deriving Repr, DecidableEq, Ord, LeanDb.ClosedEnum

/-- A diet is the set of kinds it forbids. One list per profile; `allows`
    is derived, and "which diets does this dish satisfy" is a fold over
    `ClosedEnum.all`. -/
def Diet.forbids : Diet → List IngredientKind
  | .omnivore    => []
  | .noPork      => [.pork]
  | .noBeef      => [.beef]
  | .noPorkBeef  => [.pork, .beef]
  | .pescatarian => [.pork, .beef, .lamb, .chicken]
  | .vegetarian  => [.pork, .beef, .lamb, .chicken, .fish, .shellfish]
  | .vegan       => [.pork, .beef, .lamb, .chicken, .fish, .shellfish, .egg, .dairy]
  | .jain        => [.pork, .beef, .lamb, .chicken, .fish, .shellfish, .egg, .allium, .mushroom]
  | .halal       => [.pork, .alcohol]
  | .kosher      => [.pork, .shellfish]
  | .glutenFree  => [.gluten]
  | .nutFree     => [.peanut, .treeNut]

@[db] def Diet.allows (d : Diet) (k : IngredientKind) : Bool := !(d.forbids.contains k)
  -- ~ pushes only with the captured-parameter case split (§3.4): after
  --   `d := .vegetarian` each branch is a closed `List.contains` on a
  --   literal, which `whnf` should reduce — confirm with a golden.

/-- Every diet a dish satisfies, given its ingredient rows. Total over the
    vocabulary; no table, no tag. -/
def dietsOk (ings : Array (Stored DishIngredient × Stored Ingredient)) : List Diet :=
  (ClosedEnum.all (α := Diet)).toList.filter fun d =>
    ings.all fun (di, i) => d.allows i.val.kind || di.val.removable
```

### 2.3 Entities

```lean
/-- Canonical dishes: open world, queried by name → LEP-0001 row symbols
    (`KnownDish.tiramisu : KnownDish`, resolving to this row by `slug`). -/
structure CanonicalDish where
  slug    : Slug                    -- ✓ stable key
  display : DisplayName
  family  : DishFamily              -- ✓
  course  : Course                  -- ✓
  deriving Repr, LeanDb.Entity

structure Restaurant where
  name         : RestaurantName
  city         : City               -- ✓
  neighborhood : Neighborhood
  /-- Microdegrees, not `Float`: `Float` has no `SqlOrd` (NaN breaks exact
      negation) and bounding-box queries want ordering to push. -/
  lat          : MicroDeg           -- ✓ Int64 newtype; ordering pushes
  lon          : MicroDeg           -- ✓
  cuisine      : Cuisine            -- ✓ closed
  priceTier    : PriceTier          -- ✓ closed
  deriving Repr, LeanDb.Entity

/-- One row per (restaurant, weekday). `closes < opens` means the interval
    wraps midnight. `lastOrder` is what "can I get it after 9 PM" asks. -/
structure Hours where
  restaurant : Ref Restaurant
  day        : Weekday
  opens      : Clock
  lastOrder  : Clock
  closes     : Clock
  deriving Repr, LeanDb.Entity

structure Dish where
  restaurant : Ref Restaurant
  canonical  : Ref CanonicalDish    -- ✓ the vocabulary FK
  menuName   : MenuName             -- ✓ the menu's own spelling, free text by declaration
  price      : Money                -- ✓
  size       : Option Size
  available  : Bool := true
  /-- Suitability is `∀` over ingredient rows, which is vacuously true for
      a dish with none recorded. An unlisted ramen must read as *unknown*,
      never as vegan: every dietary query requires this flag. -/
  ingredientsComplete : Bool := false
  deriving Repr, LeanDb.Entity

structure Ingredient where
  name : IngredientName
  kind : IngredientKind             -- ✓
  deriving Repr, LeanDb.Entity

/-- The child table dietary questions quantify over. -/
structure DishIngredient where
  dish          : Ref Dish
  ingredient    : Ref Ingredient
  removable     : Bool              -- "hold the chashu" is a real option
  substitutable : Option (Ref Ingredient)   -- ✓ Option Ref
  deriving Repr, LeanDb.Entity

structure Modification where
  dish  : Ref Dish
  label : ModLabel                  -- "oat milk", "extra shot", "no pork"
  delta : Delta
  /-- What the modification removes, if anything — lets "ramen, no pork"
      be answered from data rather than by string-matching labels. -/
  removes : Option IngredientKind
  deriving Repr, LeanDb.Entity

/-- Observed prices over time; `Dish.price` is the current one. -/
structure PriceObs where
  dish       : Ref Dish
  price      : Money
  observedAt : Timestamp
  source     : Source               -- ✓ closed: menu | receipt | delivery-app | crowd
  deriving Repr, LeanDb.Entity
```

### 2.4 Query universe

```lean
/-- "Average cost of a chai latte in San Francisco." -/
def avgPrice (dish : KnownDish) (city : City) : DbM (Option Money) := do    -- LEP-0001 symbol; today a `Ref CanonicalDish`
  let cd ← dish.resolve
  let rows ← select [Dish, Restaurant] (fun (d, r) =>
    d.val.restaurant == r.ref && d.val.canonical == cd.ref && r.val.city == city && d.val.available)   -- ✓ all pushes
  return mean (rows.map (·.1.val.price))                                                              -- ~ aggregate in Lean (§3.5)

/-- "Where can I get tiramisu after 9 PM?" — the time predicate is a
    `@[db]` helper; the midnight wrap is a disjunction, which pushes. -/
@[db] def Hours.servesAt (h : Hours) (t : Clock) : Bool :=
  if h.closes.minutes < h.opens.minutes
  then t.minutes ≥ h.opens.minutes || t.minutes < h.lastOrder.minutes
  else h.opens.minutes ≤ t.minutes && t.minutes < h.lastOrder.minutes

def openFor (dish : KnownDish) (day : Weekday) (t : Clock) :
    DbM (Array (Stored Restaurant × Stored Dish × Stored Hours)) := do
  let cd ← dish.resolve
  select [Restaurant, Dish, Hours] (fun (r, d, h) =>
    d.val.restaurant == r.ref && h.val.restaurant == r.ref             -- ✓ two joins
      && d.val.canonical == cd.ref && h.val.day == day                 -- ✓
      && h.servesAt t)                                                 -- ✓ `if` on columns → (c ∧ t) ∨ (¬c ∧ e), through `.minutes` (tactic case added in R1)
    (.key fun (r, _, _) => r.val.name)

/-- "Places that serve ramen I can eat" — vegetarian, or no pork/beef.
    The question is ∀ over a child table: every ingredient is allowed by
    the diet, or removable. There is no single `select` for a universal
    quantifier; today it is two fetches and a set difference (§3.3). -/
def suitable (fam : DishFamily) (diet : Diet) (city : City) :
    DbM (Array (Stored Dish × Stored Restaurant)) := do
  let dishes ← select [Dish, Restaurant, CanonicalDish] (fun (d, r, c) =>
    d.val.restaurant == r.ref && d.val.canonical == c.ref
      && c.val.family == fam && r.val.city == city && d.val.available
      && d.val.ingredientsComplete)                                              -- ✓ absence of data is not a guarantee
  let offending ← select [DishIngredient, Ingredient] (fun (di, i) =>
    di.val.ingredient == i.ref && !di.val.removable
      && !(diet.allows i.val.kind))                                             -- ~ pushes iff `allows` matches on the column first (§3.4)
  let bad := offending.map (·.1.val.dish)
  return dishes.filterMap fun (d, r, _) => if bad.contains d.ref then none else some (d, r)   -- the anti-join, in Lean

/-- The same question with a diet typed on the command line
    (`--avoid pork,beef,shellfish`). Works today, but the ingredient
    conjunct is residual by nature: the tactic cannot emit a disjunction
    whose length it does not know at compile time. Closed profiles push;
    ad-hoc ones do not. Offer both. -/
structure AdHocDiet where avoid : List IngredientKind
def suitableAdHoc (fam : DishFamily) (diet : AdHocDiet) (city : City) : DbM (Array (Stored Dish × Stored Restaurant))

/-- With LEP-0004 (§3.3), `suitable` is one `select`: the universal
    quantifier over the child table renders as `NOT EXISTS`. -/
-- select [Dish, Restaurant, CanonicalDish] (fun (d, r, c) =>
--   … && d.ingredients.all fun (di, i) => diet.allows i.val.kind || di.val.removable)

/-- Price of a dish with modifications applied. -/
def priceWith (dish : Ref Dish) (mods : List (Ref Modification)) : DbM Money   -- ✓ trivial

/-- Restaurants within a bounding box, then exact distance in Lean. -/
def nearby (lat lon : MicroDeg) (radiusM : Nat) : DbM (Array (Stored Restaurant)) := do
  let box ← select [Restaurant] (fun r =>
    r.val.lat.micro ≥ lat.micro - dLat && r.val.lat.micro ≤ lat.micro + dLat && …)   -- ✓ ordering on Int64 through `.micro`
  return box.filter (haversine · ≤ radiusM)                                          -- residual, correctly

/-- Price history for one dish, newest first. -/
def history (dish : Ref Dish) : DbM (Array (Stored PriceObs)) :=
  select [PriceObs] (fun p => p.val.dish == dish) (.desc (.key (·.val.observedAt)))   -- ✓
```

---

## 3. Evaluation of the 0.2 engine

What the two bases *validate* first, because it is most of the engine:
closed worlds with total functions (`Diet.allows`, `Arch.supports`,
`Gpu.spec`) push as case splits; validated newtypes over `Nat`/`Int64`
push ordering through their projection (`Clock`, `Micros`, `MicroDeg`);
`||` and `if` on columns push (the midnight wrap); multi-table joins and
self-joins push; `Option (Ref _)`, defaults, CAS updates, and closed-world
growth migrations all apply directly. `Bench.sku : Gpu` shows a base
importing another base's vocabulary as a Lake dependency, and it just
works.

Then the gaps, ranked by how hard each domain hits them.

### 3.1 Nested values — `✗`, kernel-critical

`KernelSig`, `TensorTy`, `Dim`, `Layout`, `LaunchConfig`, `NumericProps`,
`List OpKind`. The engine's entity model is first-order: every field needs
a `ColCodec`, and there are codecs for scalars, `Option`, `Id`, and closed
enums — not for structures, lists, or payload-carrying sums. `deriving
LeanDb.ClosedEnum` explicitly refuses constructors with data ("stored sums
are planned separately").

The original design (transcript §4) named three encodings, none built:

| Encoding | Fits | Pushdown | Migration sees inside? |
|---|---|---|---|
| `@[dbJson]` — derive `ToJson`/`FromJson`, store TEXT | any type; `KernelSig` | none (opaque column) | no — inner schema changes are invisible to `migrate` |
| inline flatten — `launch.grid`, `launch.block`, … as sibling columns | small fixed structures; `LaunchConfig`, `NumericProps` | full | yes |
| child table — `KernelInput (kernel, position, dtype, rank)` | lists; `ins`, `outs`, `fuses`, `ProgramNode.feeds` | full, via joins | yes |

**R2 built this and wrote up what it could not do** — see
[Kernels design notes](../examples/kernels/DESIGN.md), "Evidence for LEP-0003". The short version:
every predicate that reads inside `sig` is a full-table fetch; the search
columns cannot describe a list; `migrate`, the fingerprint and the
enum-drift scan all stop at the JSON boundary (adding a field to `TensorTy`
is invisible to `version` and then fails per-row on read); inline
flattening was right for `NumericProps`; child tables are the only
encoding under which per-input questions push. The recommendation below
stands, with those specifics.

Recommendation for the base: **`KernelSig` as a JSON-codec'd newtype
column** (`ColCodec.via Json.compress Json.parse` through derived
instances — this is writable today with no engine change, as one
`instance`), **plus denormalized search columns** (`inDtype0`,
`outDtype0`, `rank0`) so the common filters push. `Prog.ofRows` re-types on
read. This is the honest first cut and it will show, on real queries,
whether opaque-plus-search-columns is acceptable or whether inline
flattening and child tables must be derived. That decision should come from
the base, not from this document. It becomes **LEP-0003: nested values**.

Note on lists of a closed world (`fuses : List OpKind`): this is the
`EnumSet` bitmask deferred in plan-v2 M3, and it is the cheapest of the
three to add (one codec, one `CHECK`).

### 3.2 Cross-field invariants — `✗`, kernel-medium

The search columns must agree with `sig`. That is a cross-field invariant;
the engine's answer (transcript §4.3) is a proof field, and
`deriving LeanDb.Entity` refuses dependent fields today ("proof/dependent
fields are not supported yet"). Until then the invariant lives in
`Kernel.make` and is not enforced on `update`. For the base this is
acceptable and should be stated in the module docstring. The engine change
— skip `Prop`-typed fields in the derive, reconstruct the proof by `decide`
in `decode` — is small and was always planned.

### 3.3 Quantifiers over child tables — `✗`, restaurant-critical

"Every ingredient is allowed or removable" is `∀` over `DishIngredient`.
`select` computes a filtered *product*; it can find dishes that *have* an
offending ingredient, never dishes that have *none*. The anti-join happens
in Lean over two fetches. Correct, and O(dishes + offending), but it is the
domain's central query and it is not one `select`.

This is the transcript's `t.power.chargeInputs.any (·.path == …) →
EXISTS on child table` (line 382), unbuilt. In LEP-0002's IR it is one
constructor:

```lean
| exists (child : Type) [Entity child] (fk : Col [child] (Ref α)) (body : Pred (child :: ts)) : Pred ts
```

rendering as `EXISTS (SELECT 1 FROM child WHERE child.fk = tN.id AND …)`,
with `∀` as `¬∃¬`. `denote` is a nested fetch in the reference semantics.
**LEP-0002 should reserve this constructor now** so the IR's shape is not
closed prematurely; implementing it is **LEP-0004: child-table
quantifiers**. The restaurant base is its acceptance test.

### 3.4 Case splits on captured parameters — `~`, both domains, small

`Diet.allows diet i.val.kind` with `diet` a *captured parameter*: the
tactic case-splits on the column (`kind`) and substitutes each constructor,
leaving `Diet.allows diet .pork`. If `allows` matches on `kind` first, that
reduces to comparisons of the closed value `diet` against constants —
`cmpVV`, pushable. If `allows` matches on `diet` first, `whnf` is stuck on
the variable, `findEnumCol` finds no *column* to split, and the conjunct
goes residual. The same applies to `Arch.supports arch k.val.minArch`.

**Landed in R1** (confirmed by golden first). The tactic now splits on a
captured `ClosedEnum` parameter — `⋁_c (param IS 'c' ∧ branch)` — when no
column is left to split, and because both sides of each guard are known
when the plan is built, `cmpVVS` folds every guard but one away: the
derived `Diet.allows d k := !(d.forbids.contains k)` with `d :=
.noPorkBeef` renders as `(kind IS ? OR kind IS ?)`, and both match orders
produce the same plan. One refinement to the reading above: a `match` on
the parameter hides the column under the alternatives' binders, where
`findEnumCol` does not look, so the parameter is split *first* there —
sound, and the folded result is identical.

Fuel is the other limit: `caseSplit` is bounded at depth 2 and each level
is `|enum|` branches. `Arch.supports` over 8×8 and `Diet.allows` over 12×19
sit inside it; a third enum column in one conjunct would not.

### 3.5 Aggregates, sort and limit — `~`, both domains, deferred by design

`avgPrice`'s mean, `fastest`'s minimum, and every `count` are Lean folds
over a full pushed fetch. `SortBy` is applied client-side after the fetch
(the plan-v2 M4 note that `.key` sorts push down was not implemented), and
there is no `LIMIT` except the CLI's post-fetch `take`. All correct, all
O(n) in the matching rows. For these bases n is thousands and it does not
matter. Aggregation is a different verb from `select` (it returns a scalar
over a group, not rows) and should be designed as one — after LEP-0002,
since it wants `Pred` for its `WHERE`. Not blocking.

### 3.6 Row symbols — LEP-0001, restaurant-strong

`avgPrice .chaiLatte .sanFrancisco` and `openFor .tiramisu .fri ⟨21*60⟩` are
the ergonomic target, and `CanonicalDish` keyed by `slug` is exactly
LEP-0001's shape. Until it lands, the queries take `Ref CanonicalDish` and
the CLI takes a slug parsed through `CliArg`. The restaurant base is the
example LEP-0001's acceptance criteria ask for; build it with slugs now and
let LEP-0001 swap in the symbols.

### 3.7 Cross-instance queries — `✗`, kernel-low

`perDollar` joins kernel benches against gpumarket *listings*. Types cross
bases via Lake; instances do not — `Conn` is one SQLite handle over one
file, and `openDb` checks one fingerprint. SQLite's `ATTACH DATABASE` is
the physical answer; the typed layer would need `select` over tables from
two `Base`s and an open-time check per attached file. Interesting, not
urgent; note it and move on.

### 3.8 Things that turned out fine

- `Float` coordinates: **do not** give `Float` an `SqlOrd`. SQLite stores
  NaN as NULL, so `!(x < 5)` is `true` in Lean and excluded in SQL —
  `neg` would over-narrow. The engine is right to refuse; the base uses
  integer microdegrees, which is better modelling anyway.
- `Int` has no codec; `Int64` does. Fine — `Delta` is `Int64`.
- Self-joins (`select [Bench, Bench]`) work: `Rows` is a product, aliases
  are positional, and `colOf?` distinguishes the two components by fvar.
- Importing gpumarket's `Gpu` brings its `ClosedEnum` instance and
  `Gpu.spec`; the `Bench` table gets a `CHECK` over gpumarket's vocabulary
  for free, and adding a GPU to gpumarket is a migration in the kernel base
  too — which is correct.

### 3.9 Summary

| Gap | Kernel | Restaurant | Resolution |
|---|---|---|---|
| Nested values (structures, lists, payload sums) | critical | mild | JSON-codec + search columns now; **LEP-0003** from what the base shows |
| Quantifiers over child tables | mild (`composable`) | critical (`suitable`) | two fetches now; reserve in LEP-0002; **LEP-0004** |
| Cross-field invariants / proof fields | medium | — | `make` now; small derive change later |
| Case split on captured enum params | medium | medium | ~20-line tactic extension, during the restaurant base |
| Aggregates / pushed sort / limit | low | low | Lean folds now; an `aggregate` verb after LEP-0002 |
| Row symbols | low | strong | slugs now; LEP-0001 |
| Cross-instance join | low | — | note; `ATTACH` later |
| `EnumSet` for `fuses` | medium | — | cheapest add; plan-v2 M3 item |

---

## 4. Recommended order of work

1. **Commit what is verified.** The four fixes and LEP-0002 are green under
   `release_check.sh`; land them before starting bases so the bases are
   measured against a known engine.

2. **Restaurant base first** (`examples/eats`), against the engine as it
   is. It exercises the largest share of what exists, needs no engine
   change to be useful, and exposes exactly one missing thing — child-table
   quantifiers — in its central query. Build `suitable` as two fetches and
   say so in the docstring; that becomes LEP-0004's golden. Do the captured-
   parameter case split (§3.4) during this base, with a golden proving
   `Diet.allows` pushes in either match order. Use slugs where LEP-0001
   will use symbols.

3. **Kernel base second** (`examples/kernels`). Decide nested values up
   front as §3.1 recommends — JSON-codec'd `KernelSig`, denormalized search
   columns, `Prog` in Lean, `Bench.sku` from gpumarket. This base is where
   the engine is weakest, and its job is to make the nested-values decision
   concrete: after building `composable` and `synthesize` against opaque
   columns, LEP-0003 can be written from evidence.

4. **LEP-0002 implementation**, with both bases as acceptance goldens and
   the `exists` constructor reserved in the IR (amend the LEP now — a
   two-line note in §"The plan"). LEP-0004 follows directly on the new IR;
   LEP-0003 is independent of it and can go earlier if the kernel base makes
   the case.

The order is chosen so that each base is built against a stable engine and
each engine change is justified by a base that already exists and already
has the query that needs it — the same discipline plan-v2 set:
*correctness machinery first, optimization machinery only when a test
demands it.*

5. **The query universe** (§5) is tried in both bases once LEP-0002 has
   made the log store data; it is a base-level pattern first and an
   engine feature only where deriving makes it cheap.

---

## 5. The query universe

Queries are typed, so a base does not merely *contain* queries — it
maintains a **universe** of them, and the compiler keeps the universe
consistent with the vocabulary. There are two levels; the engine is at the
first.

### 5.1 Level one — already true

Queries are `def`s compiled with the schema. Rename a field, shrink a
closed world, retarget a `Ref`: every query that touched it fails to build,
which is the "compiler walks you through" property applied to questions
instead of values. `query%` then makes the set finite and enumerable —
`Cli.Base.queries` is a list, `usageJson` prints it, and each entry's
arity and argument types are read off the def's signature. An agent driving
a base picks from that list; it cannot invent a query.

The universe compounds when the *arguments* are closed too. gpumarket's
`cheapest : Gpu → Pricing → …` is not one query but 14 × 4 = 56 concrete
ones; with LEP-0001, `avgPrice : KnownDish → City → …` is likewise a finite
product. The **instantiated** universe is enumerable — exhaustively
testable, precomputable, cacheable, and documentable by generation rather
than by hand.

### 5.2 Level two — the universe as a type

```lean
inductive Query : Type → Type where
  | avgPrice : KnownDish → City → Query (Option Money)
  | openFor  : KnownDish → Weekday → Clock → Query (Array (Stored Restaurant × Stored Dish))
  | suitable : DishFamily → Diet → City → Query (Array (Stored Dish))

def Query.run : Query ρ → DbM ρ          -- dispatches to the ordinary defs
```

A query is now a *value*: comparable, serializable, storable. What that
changes:

- **The CLI derives from constructors** rather than from `query%` on defs —
  same `CliArg`/`QueryOut` machinery, one source.
- **The log stores the `Query` value**, not a description string. Replay is
  `log.map Query.run`. This is plan.md §4.4's "regression suite for
  migrations": run the universe against a candidate schema before `apply`.
- **The served wire carries `Query` values.** No SQL, no predicate, no
  text on the wire; injection is unrepresentable at the outermost layer,
  not just at `Pred`.
- **Composition is structural.** Once LEP-0002 makes `Pred` data, a `Query`
  can be assembled from reusable conjuncts (`inCity c`, `inFamily f`,
  `dietOk d`) at runtime — the `p₁.and p₂` across modules the original
  discussion wanted.
- **Total questions over the universe** become folds: which `Diet`
  variants, which `Gpu`s, appear in no query's tests (`ClosedEnum.all ×
  Query`); which queries stopped pushing after a change (a static residual
  report rather than a per-run `log` line); which queries break under a
  proposed migration.
- **The agent's tool list is derived.** An MCP layer is `Query`'s
  constructors with their argument types — plan.md §4.5's "thin later
  layer," with nothing to write by hand.

### 5.3 The boundary

Level two *indexes* the defs; it does not replace them. `Query.run` is
ordinary Lean, and a query that exists only as a `def` never entered the
universe — the same "captured at the boundary" rule LEP-0002 applies to
predicates. It is a base-level pattern: the engine's contribution is that
`Pred`, `Rows ts`, `CliArg` and `QueryOut` make the inductive cheap to write
and to derive from. Whether deriving `Query` from a list of defs (the
inverse of `query%`) earns engine machinery is a question the two bases
should answer.

Ordering: after LEP-0002 — log-as-data is the first thing level two needs —
and tried in both stress bases, where the instantiated universe is small
enough to enumerate in a test.
