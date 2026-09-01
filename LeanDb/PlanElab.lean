import Lean
import LeanDb.Plan

/-! # `leandb_plan`: reifying the select predicate

`select`'s trailing argument `plan : PlanFor where' := by leandb_plan` makes
this tactic run at every call site with the *elaborated* predicate visible
in its goal type. It reifies what it recognizes into a `PushPred` tree:

- `row.val.field OP value` (both orders) via `==`/`!=`/`BEq` and
  `decide`-coerced `<`/`≤`/`>`/`≥`; captured variables and literals become
  embedded `toCol` terms, bound as SQL parameters at run time;
- the same through a validated newtype's projection — `row.val.field.rep`
  — but only when that projection *is* the column's encoding, i.e.
  `toCol a` and `toCol a.rep` are definitionally equal (which is what
  `ColCodec.via (·.rep) _` gives). The comparison then happens on the
  representation type, so ordering is pushed whenever *it* is `SqlOrd`;
- column-vs-column comparisons — across tables these are join conditions
  (`t.val.ref == u.ref`, also through `some`), routed to the joined executor;
- `&&`, `||`, `!` (negation is exact — see `PushPred.neg`), and
  `if c then t else e` on `Bool` as `(c ∧ t) ∨ (¬c ∧ e)`;
- `Option` tests (`== none`, `.isNone`, `.isSome`) as null-safe SQL;
- bare `Bool` columns; `@[db]`-tagged defs unfolded;
- `match` on a closed-enum column (directly or via an unfolded `@[db]`
  function like an SLA table) by *case-splitting on the closed world*:
  `⋁_c (col IS 'c' ∧ reify (conjunct[col := c]))` — total because the
  world is closed; branches that reduce to `false` drop out;
- the same split on a *captured parameter* of closed-enum type when the
  conjunct is stuck on it and no column is left to split (a `@[db]`
  function that matches on its parameter before its column argument, or
  a derived form like `!(d.forbids.contains k)`):
  `⋁_c (param IS 'c' ∧ reify (conjunct[param := c]))` — the guard is a
  value/value test, bound as parameters at run time.

Everything else is counted residual and left to the client-side lambda,
which is always applied. The tactic never fails: on any surprise it emits
`tt` for that conjunct (no narrowing) — correct, just unoptimized.
-/

namespace LeanDb.PlanElab

open Lean Meta Elab Tactic

/-- Marks a definition as unfoldable during select-plan reification: a
    `@[db]` helper whose body is in the pushable fragment compiles to SQL
    at its call sites instead of going residual. -/
initialize dbAttr : TagAttribute ←
  registerTagAttribute `db
    "LeanDB: allow unfolding this def while reifying select plans"

register_option leandb.explain : Bool := {
  defValue := false
  descr := "log the reified SelectPlan (pushed vs residual conjuncts) at each select call site"
}

/-- Walk a `Rows ts` product type, introducing one local per component, and
    hand the continuation the components plus the nested-pair value. -/
private partial def withComps (ρ : Expr) (k : Array Expr → Expr → MetaM α) : MetaM α := do
  let ρ ← whnfR ρ
  if ρ.isAppOfArity ``Prod 2 then
    withLocalDeclD `row (ρ.getArg! 0) fun a =>
      withComps (ρ.getArg! 1) fun comps rest => do
        k (#[a] ++ comps) (← mkAppM ``Prod.mk #[a, rest])
  else
    withLocalDeclD `row ρ fun a => k #[a] a

/-- If `e` is a column access on one of the row components, return
    (component index, column name). Recognizes `Stored.val c |>.field`
    (as projection-fn application or `Expr.proj`), `Stored.id`/`.ref`, and
    a projection *through* a column whose codec is that very projection —
    `col.field` on a validated newtype (see `throughCodec?`). `fuel`
    bounds how many such projections are unwrapped. -/
private partial def colOf? (comps : Array Expr) (e : Expr) (fuel : Nat := 8) :
    MetaM (Option (Nat × String)) := do
  let e ← whnfR e
  match e with
  | .proj s i x =>
      if s == ``Stored && i == 0 then
        return (← compIdx? x).map ((·, "id"))
      if let some ci ← storedValComp? x then
        let some info := getStructureInfo? (← getEnv) s | return none
        let some fname := info.fieldNames[i]? | return none
        return some (ci, fname.toString)
      throughCodec? x e fun a => .proj s i a
  | _ =>
      let .const declName _ := e.getAppFn | return none
      if (declName == ``Stored.id || declName == ``Stored.ref) && e.getAppNumArgs == 2 then
        return (← compIdx? (e.getArg! 1)).map ((·, "id"))
      let some _ := (← getEnv).getProjectionFnInfo? declName | return none
      let args := e.getAppArgs
      let some x := args.back? | return none
      if let some ci ← storedValComp? x then
        return some (ci, declName.getString!)
      throughCodec? x e fun a => mkAppN e.getAppFn (args.set! (args.size - 1) a)
where
  compIdx? (x : Expr) : MetaM (Option Nat) := do
    let x ← whnfR x
    return comps.findIdx? (· == x)
  storedValComp? (x : Expr) : MetaM (Option Nat) := do
    let x ← whnfR x
    if x.isAppOfArity ``Stored.val 2 then return ← compIdx? (x.getArg! 1)
    match x with
    | .proj s 1 c => if s == ``Stored then compIdx? c else return none
    | _ => return none
  /-- `whole` is `f x` for a projection `f : α → β`, and `x` resolves to a
      column of type `α`. Push through `f` exactly when `f` *is* that
      column's encoding: with a fresh `a : α`, `toCol a` must be
      definitionally `toCol (f a)`. `ColCodec.via enc dec` is reducible and
      sets `toCol a := toCol (enc a)`, so the check passes precisely for a
      newtype stored through this projection — and then the column's bytes
      already *are* the encoding of `f a`, so SQLite compares exactly what
      the Lean predicate compares. The column name and table index stay
      those of the underlying field: this unwraps, it does not rename.
      Anything else (a codec that mixes two fields, an unrelated
      projection) fails the check and stays residual. -/
  throughCodec? (x whole : Expr) (rebuild : Expr → Expr) :
      MetaM (Option (Nat × String)) := do
    if fuel == 0 then return none
    let some col ← colOf? comps x (fuel - 1) | return none
    let α ← inferType x
    let β ← inferType whole
    let some ia ← synthInstance? (mkApp (mkConst ``LeanDb.ColCodec) α) | return none
    let some ib ← synthInstance? (mkApp (mkConst ``LeanDb.ColCodec) β) | return none
    let ok ← withLocalDeclD `a α fun a =>
      withNewMCtxDepth <| withDefault <|
        isDefEq (mkApp3 (mkConst ``LeanDb.ColCodec.toCol) α ia a)
                (mkApp3 (mkConst ``LeanDb.ColCodec.toCol) β ib (rebuild a))
    return if ok then some col else none

/-- Does `e` mention any row component (i.e. is it *not* a closed value)? -/
private def usesComps (comps : Array Expr) (e : Expr) : Bool :=
  comps.any fun c => e.containsFVar c.fvarId!

private def isValue (comps : Array Expr) (e : Expr) : Bool :=
  !usesComps comps e && !e.hasExprMVar

/-! Term builders for `PushPred` (the tree is a *term* — embedded values
    reference call-site variables). `andS`/`orS`/`neg` are emitted as
    calls so tt/ff simplification happens when the plan value is built. -/

private def ttE : Expr := mkConst ``PushPred.tt
private def ffE : Expr := mkConst ``PushPred.ff

private def mkOp (op : PushOp) : Expr :=
  match op with
  | .eq => mkConst ``PushOp.eq | .ne => mkConst ``PushOp.ne
  | .lt => mkConst ``PushOp.lt | .le => mkConst ``PushOp.le
  | .gt => mkConst ``PushOp.gt | .ge => mkConst ``PushOp.ge

private def mkVal (v : Expr) : MetaM Expr := do
  mkAppM ``LeanDb.ColCodec.toCol #[← instantiateMVars v]

private def mkCmp (t : Nat) (c : String) (op : PushOp) (v : Expr) : MetaM Expr := do
  mkAppM ``PushPred.cmp #[mkNatLit t, mkStrLit c, mkOp op, ← mkVal v]

private def mkCmp2 (a : Nat × String) (op : PushOp) (b : Nat × String) : MetaM Expr :=
  mkAppM ``PushPred.cmp2 #[mkNatLit a.1, mkStrLit a.2, mkOp op, mkNatLit b.1, mkStrLit b.2]

private def mkCmpVV (a : Expr) (op : PushOp) (b : Expr) : MetaM Expr := do
  mkAppM ``PushPred.cmpVVS #[← mkVal a, mkOp op, ← mkVal b]

private def mkAndS (a b : Expr) : MetaM Expr := mkAppM ``PushPred.andS #[a, b]
private def mkOrS (a b : Expr) : MetaM Expr := mkAppM ``PushPred.orS #[a, b]
private def mkNeg (a : Expr) : MetaM Expr := mkAppM ``PushPred.neg #[a]

private def flipOp : PushOp → PushOp
  | .eq => .eq | .ne => .ne | .lt => .gt | .le => .ge | .gt => .lt | .ge => .le

/-- Reify one comparison. `none` = not translatable. -/
private def cmpStrict (comps : Array Expr) (op : PushOp) (a b : Expr) :
    MetaM (Option Expr) := do
  -- SQL ordering is only sound when both encodings preserve Lean's order.
  -- In particular, Option's `none` ordering and closed-enum constructor
  -- order do not match SQLite NULL/TEXT ordering.
  unless op == .eq || op == .ne do
    unless (← hasSqlOrd a) && (← hasSqlOrd b) do return none
  let ca? ← colOf? comps a
  let cb? ← colOf? comps b
  match ca?, cb? with
  | some ca, some cb => some <$> mkCmp2 ca op cb
  | some ca, none => oneSided ca op b
  | none, some cb => oneSided cb (flipOp op) a
  | none, none =>
      -- neither side is a column: pushable as a value/value test when both
      -- are closed (a case split leaves `constant OP captured-param`)
      if isValue comps a && isValue comps b then
        try return some (← mkCmpVV a op b)
        catch _ => return none
      else
        return none
where
  hasSqlOrd (e : Expr) : MetaM Bool := do
    let ty ← inferType e
    return (← synthInstance? (← mkAppM ``LeanDb.SqlOrd #[ty])).isSome
  /-- col OP other: `other` is a value, or (for eq/ne) `some <col>`. -/
  oneSided (c : Nat × String) (op : PushOp) (other : Expr) : MetaM (Option Expr) := do
    let otherW ← whnfR other
    if otherW.isAppOfArity ``Option.some 2 && (op == .eq || op == .ne) then
      if let some c2 ← colOf? comps (otherW.getArg! 1) then
        return some (← mkCmp2 c op c2)
    if isValue comps other then
      try return some (← mkCmp c.1 c.2 op other)
      catch _ => return none   -- no codec for the value's type
    return none

/-- Reify a whole Bool expression, or `none`. Exact — safe under `or` and
    `not`. `fuel` bounds closed-world case-splitting depth. -/
private partial def strict (comps : Array Expr) (fuel : Nat) (e : Expr) :
    MetaM (Option Expr) := do
  let e ← whnfCore e
  -- a conjunct that doesn't touch the row at all: try to evaluate it (a
  -- case-split branch may be a closed constant); when captured parameters
  -- keep it undecided, fall through — the comparison dispatch below can
  -- still push it as a value/value test
  if !usesComps comps e then
    let v ← withDefault (whnf e)
    if v.isConstOf ``Bool.true then return some ttE
    if v.isConstOf ``Bool.false then return some ffE
  if e.isAppOfArity ``Bool.and 2 then
    let some a ← strict comps fuel (e.getArg! 0) | return none
    let some b ← strict comps fuel (e.getArg! 1) | return none
    return some (← mkAndS a b)
  if e.isAppOfArity ``Bool.or 2 then
    let some a ← strict comps fuel (e.getArg! 0) | return none
    let some b ← strict comps fuel (e.getArg! 1) | return none
    return some (← mkOrS a b)
  if e.isAppOfArity ``Bool.not 1 then
    let some a ← strict comps fuel (e.getArg! 0) | return none
    return some (← mkNeg a)
  -- `if c then t else e` on `Bool` is `(c ∧ t) ∨ (¬c ∧ e)`; the negation is
  -- exact for the same reason `!` is. `ite` carries a `Prop` condition
  -- with its `Decidable` instance, which is exactly a `decide`; `cond`
  -- carries a `Bool` directly.
  if e.isAppOfArity ``ite 5 then
    let c := mkApp2 (mkConst ``Decidable.decide) (e.getArg! 1) (e.getArg! 2)
    if let some r ← ifThenElse fuel c (e.getArg! 3) (e.getArg! 4) then return some r
    return none
  if e.isAppOfArity ``cond 4 then
    if let some r ← ifThenElse fuel (e.getArg! 1) (e.getArg! 2) (e.getArg! 3) then return some r
    return none
  if e.isAppOfArity ``bne 4 then
    if let some p ← cmpStrict comps .ne (e.getArg! 2) (e.getArg! 3) then return some p
    return ← caseSplit fuel e
  if e.isAppOfArity ``BEq.beq 4 then
    if let some p ← cmpStrict comps .eq (e.getArg! 2) (e.getArg! 3) then return some p
    return ← caseSplit fuel e
  if e.isAppOfArity ``decide 2 then
    let p ← whnfCore (e.getArg! 0)
    if p.isAppOfArity ``LT.lt 4 then return ← try2 fuel e .lt (p.getArg! 2) (p.getArg! 3)
    if p.isAppOfArity ``LE.le 4 then return ← try2 fuel e .le (p.getArg! 2) (p.getArg! 3)
    if p.isAppOfArity ``GT.gt 4 then return ← try2 fuel e .gt (p.getArg! 2) (p.getArg! 3)
    if p.isAppOfArity ``GE.ge 4 then return ← try2 fuel e .ge (p.getArg! 2) (p.getArg! 3)
    if p.isAppOfArity ``Eq 3 then return ← try2 fuel e .eq (p.getArg! 1) (p.getArg! 2)
    if p.isAppOfArity ``Ne 3 then return ← try2 fuel e .ne (p.getArg! 1) (p.getArg! 2)
    return ← caseSplit fuel e
  if e.isAppOfArity ``Option.isNone 2 || e.isAppOfArity ``Option.isSome 2 then
    if let some (i, col) ← colOf? comps (e.getArg! 1) then
      let ctor := if e.isAppOfArity ``Option.isNone 2 then ``PushPred.isNull
                  else ``PushPred.isNotNull
      return some (← mkAppM ctor #[mkNatLit i, mkStrLit col])
    return none
  -- bare Bool column
  if let some (i, col) ← colOf? comps e then
    return some (← mkCmp i col .eq (mkConst ``Bool.true))
  -- @[db]-tagged helper: unfold and keep going
  if let .const n _ := e.getAppFn then
    if dbAttr.hasTag (← getEnv) n then
      if let some e' ← unfoldDefinition? e then
        return ← strict comps fuel e'
  caseSplit fuel e
where
  ifThenElse (fuel : Nat) (c t e : Expr) : MetaM (Option Expr) := do
    let some c' ← strict comps fuel c | return none
    let some t' ← strict comps fuel t | return none
    let some e' ← strict comps fuel e | return none
    mkOrS (← mkAndS c' t') (← mkAndS (← mkNeg c') e')
  try2 (fuel : Nat) (whole : Expr) (op : PushOp) (a b : Expr) : MetaM (Option Expr) := do
    if let some r ← cmpStrict comps op a b then return some r
    caseSplit fuel whole
  /-- Case-split on a closed world. A closed-enum column mentioned in `e`
      first: `⋁_c (col IS 'c' ∧ strict (e[col := c]))`. When none is
      left, a captured parameter of closed-enum type (a free variable
      that is not a row component): `⋁_c (param IS 'c' ∧ strict (e[param := c]))`,
      the guard a value/value test. Both are exhaustive because the world
      is closed, and each branch is guarded by the equality that
      justifies its substitution. -/
  caseSplit (fuel : Nat) (e : Expr) : MetaM (Option Expr) := do
    if fuel == 0 then return none
    if let some (colExpr, ic, enumName) ← findEnumCol e then
      return ← splitWorld fuel e colExpr enumName (mkCmp ic.1 ic.2 .eq)
    let some (param, enumName) ← findEnumParam e | return none
    splitWorld fuel e param enumName (mkCmpVV param .eq)
  /-- `⋁_c (tag c ∧ strict (e[x := c]))` over the constructors of `enumName`. -/
  splitWorld (fuel : Nat) (e x : Expr) (enumName : Name) (tag : Expr → MetaM Expr) :
      MetaM (Option Expr) := do
    let info ← getConstInfoInduct enumName
    let mut acc := ffE
    for ctorName in info.ctors do
      let ctor := mkConst ctorName
      let e' := e.replace fun y => if y == x then some ctor else none
      let some branch ← strict comps (fuel - 1) e' | return none
      acc ← mkOrS acc (← mkAndS (← tag ctor) branch)
    return some acc
  /-- First subterm that is a closed-enum column access. -/
  findEnumCol (e : Expr) : MetaM (Option (Expr × (Nat × String) × Name)) := do
    let cands := (collectApps e #[]).filter fun x => usesComps comps x
    for x in cands do
      if let some ic ← colOf? comps x then
        let ty ← whnfR (← inferType x)
        if let .const tyName _ := ty then
          if (← synthInstance? (← mkAppM ``LeanDb.ClosedEnum #[ty])).isSome then
            return some (x, ic, tyName)
    return none
  /-- First free variable of closed-enum type in `e` that is not a row
      component: a captured parameter of the query. Restricted to fvars
      (not arbitrary closed subterms) so the split stays predictable. -/
  findEnumParam (e : Expr) : MetaM (Option (Expr × Name)) := do
    let st := collectFVars {} e
    for fv in st.fvarIds do
      let x := mkFVar fv
      if comps.contains x then continue
      let ty ← whnfR (← inferType x)
      if let .const tyName _ := ty then
        if (← synthInstance? (← mkAppM ``LeanDb.ClosedEnum #[ty])).isSome then
          return some (x, tyName)
    return none
  collectApps (e : Expr) (acc : Array Expr) : Array Expr :=
    match e with
    | .app f a => collectApps f (collectApps a (acc.push e))
    | .proj _ _ x => collectApps x (acc.push e)
    | .mdata _ x => collectApps x acc
    | _ => acc

/-- Top level: conjuncts may individually fail (they become `tt` and count
    residual) — omission only widens the fetch. -/
private partial def lenient (comps : Array Expr) (e : Expr) :
    StateRefT Nat MetaM Expr := do
  let e ← whnfCore e
  if e.isAppOfArity ``Bool.and 2 then
    let a ← lenient comps (e.getArg! 0)
    let b ← lenient comps (e.getArg! 1)
    mkAndS a b
  else
    match ← strict comps 2 e with
    | some p => return p
    | none =>
        modify (· + 1)
        return ttE

/-- Reflect the predicate in a `PlanFor pred` goal into a `SelectPlan` term. -/
def reflectPlan (goalTy : Expr) : MetaM Expr := do
  let goalTy ← instantiateMVars goalTy
  unless goalTy.isAppOfArity ``LeanDb.PlanFor 2 do
    throwError "leandb_plan: goal is not PlanFor"
  let ρ := goalTy.getArg! 0
  let pred := goalTy.getArg! 1
  withComps ρ fun comps pair => do
    let body ← whnfCore (mkApp pred pair)
    let (predE, residual) ← (lenient comps body).run 0
    mkAppM ``LeanDb.SelectPlan.mk #[predE, mkNatLit residual]

elab "leandb_plan" : tactic => do
  let g ← getMainGoal
  let ty ← g.getType
  let plan ← try reflectPlan ty catch _ => pure (mkConst ``LeanDb.SelectPlan.empty)
  if leandb.explain.get (← getOptions) then
    logInfo m!"leandb plan: {← instantiateMVars plan}"
  g.assign (← mkExpectedTypeHint plan ty)

end LeanDb.PlanElab
