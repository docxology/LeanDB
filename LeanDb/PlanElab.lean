import Lean
import LeanDb.Plan

/-! # `leandb_plan`: reifying the select predicate

`select`'s trailing argument `plan : PlanFor where' := by leandb_plan` makes
this tactic run at every call site with the *elaborated* predicate visible
in its goal type. It reifies what it recognizes into a `PushPred` tree:

- `row.val.field OP value` (both orders) via `==`/`!=`/`BEq` and
  `decide`-coerced `<`/`≤`/`>`/`≥`; captured variables and literals become
  embedded `toCol` terms, bound as SQL parameters at run time;
- column-vs-column comparisons — across tables these are join conditions
  (`t.val.ref == u.ref`, also through `some`), routed to the joined executor;
- `&&`, `||`, `!` (negation is exact — see `PushPred.neg`);
- `Option` tests (`== none`, `.isNone`, `.isSome`) as null-safe SQL;
- bare `Bool` columns; `@[db]`-tagged defs unfolded;
- `match` on a closed-enum column (directly or via an unfolded `@[db]`
  function like an SLA table) by *case-splitting on the closed world*:
  `⋁_c (col IS 'c' ∧ reify (conjunct[col := c]))` — total because the
  world is closed; branches that reduce to `false` drop out.

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
    (as projection-fn application or `Expr.proj`) and `Stored.id`/`.ref`. -/
private partial def colOf? (comps : Array Expr) (e : Expr) : MetaM (Option (Nat × String)) := do
  let e ← whnfR e
  match e with
  | .proj s i x =>
      if s == ``Stored && i == 0 then
        return (← compIdx? x).map ((·, "id"))
      let some ci ← storedValComp? x | return none
      let some info := getStructureInfo? (← getEnv) s | return none
      let some fname := info.fieldNames[i]? | return none
      return some (ci, fname.toString)
  | _ =>
      let .const declName _ := e.getAppFn | return none
      if (declName == ``Stored.id || declName == ``Stored.ref) && e.getAppNumArgs == 2 then
        return (← compIdx? (e.getArg! 1)).map ((·, "id"))
      let some _ := (← getEnv).getProjectionFnInfo? declName | return none
      let some x := e.getAppArgs.back? | return none
      let some ci ← storedValComp? x | return none
      return some (ci, declName.getString!)
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

private def mkAndS (a b : Expr) : MetaM Expr := mkAppM ``PushPred.andS #[a, b]
private def mkOrS (a b : Expr) : MetaM Expr := mkAppM ``PushPred.orS #[a, b]
private def mkNeg (a : Expr) : MetaM Expr := mkAppM ``PushPred.neg #[a]

private def flipOp : PushOp → PushOp
  | .eq => .eq | .ne => .ne | .lt => .gt | .le => .ge | .gt => .lt | .ge => .le

/-- Reify one comparison. `none` = not translatable. -/
private def cmpStrict (comps : Array Expr) (op : PushOp) (a b : Expr) :
    MetaM (Option Expr) := do
  let ca? ← colOf? comps a
  let cb? ← colOf? comps b
  match ca?, cb? with
  | some ca, some cb => some <$> mkCmp2 ca op cb
  | some ca, none => oneSided ca op b
  | none, some cb => oneSided cb (flipOp op) a
  | none, none => return none
where
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
  -- a conjunct that doesn't touch the row at all: evaluate it
  if !usesComps comps e then
    let v ← withDefault (whnf e)
    if v.isConstOf ``Bool.true then return some ttE
    if v.isConstOf ``Bool.false then return some ffE
    return none
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
  try2 (fuel : Nat) (whole : Expr) (op : PushOp) (a b : Expr) : MetaM (Option Expr) := do
    if let some r ← cmpStrict comps op a b then return some r
    caseSplit fuel whole
  /-- Find a closed-enum column mentioned in `e` and case-split on its
      world: `⋁_c (col IS 'c' ∧ strict (e[col := c]))`. -/
  caseSplit (fuel : Nat) (e : Expr) : MetaM (Option Expr) := do
    if fuel == 0 then return none
    let some (colExpr, ic, enumName) ← findEnumCol e | return none
    let info ← getConstInfoInduct enumName
    let mut acc := ffE
    for ctorName in info.ctors do
      let ctor := mkConst ctorName
      let e' := e.replace fun x => if x == colExpr then some ctor else none
      let some branch ← strict comps (fuel - 1) e' | return none
      let tag ← mkCmp ic.1 ic.2 .eq ctor
      acc ← mkOrS acc (← mkAndS tag branch)
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
