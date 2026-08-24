import Lean
import LeanDb.Plan

/-! # `leandb_plan`: reifying the select predicate

`select`'s trailing argument `plan : PlanFor where' := by leandb_plan` makes
this tactic run at every call site with the *elaborated* predicate visible
in its goal type. It walks the lambda's body and reifies the conjuncts it
recognizes into a `SelectPlan`:

- `row.val.field OP value` (and flipped), for `==`/`!=` via `BEq`, and
  `<`/`≤`/`>`/`≥` via `decide`-coerced `Ord`-style props;
- `row.id`/`row.ref` compared to a value;
- `Option` fields against `none`/`some v` (null-safe `IS`);
- bare `Bool` columns;
- captured local variables and literals become embedded values — they are
  *terms referencing the call-site context*, bound as SQL parameters at run
  time.

Everything else — `||`, `not`, user function calls, cross-table (equi-join)
comparisons — is counted residual and left to the client-side lambda, which
is always applied. The tactic never fails: on any surprise it produces
`SelectPlan.empty` (all residual), which is merely unoptimized, never wrong.
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

private def flipOp : PushOp → PushOp
  | .eq => .eq | .ne => .ne | .lt => .gt | .le => .ge | .gt => .lt | .ge => .le

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

/-- Is `e` a closed value w.r.t. the row components (i.e. safe to embed as
    a bound parameter)? -/
private def isValue (comps : Array Expr) (e : Expr) : Bool :=
  !(comps.any fun c => (c.fvarId!) |> e.containsFVar) && !e.hasExprMVar

private structure PlanState where
  pushed : Array (Nat × Expr) := #[]   -- table index × `PushCond` term
  residual : Nat := 0

private abbrev WalkM := StateRefT PlanState MetaM

private def addResidual : WalkM Unit :=
  modify fun s => { s with residual := s.residual + 1 }

private def addPushed (i : Nat) (cond : Expr) : WalkM Unit :=
  modify fun s => { s with pushed := s.pushed.push (i, cond) }

private def mkOp (op : PushOp) : Expr :=
  match op with
  | .eq => mkConst ``PushOp.eq | .ne => mkConst ``PushOp.ne
  | .lt => mkConst ``PushOp.lt | .le => mkConst ``PushOp.le
  | .gt => mkConst ``PushOp.gt | .ge => mkConst ``PushOp.ge

/-- Try to push `a OP b`; count residual otherwise. -/
private def pushCmp (comps : Array Expr) (op : PushOp) (a b : Expr) : WalkM Unit := do
  let ca? ← colOf? comps a
  let cb? ← colOf? comps b
  match ca?, cb? with
  | some (i, col), none =>
      if isValue comps b then tryEmit i col op b else addResidual
  | none, some (i, col) =>
      if isValue comps a then tryEmit i col (flipOp op) a else addResidual
  | _, _ => addResidual   -- col-vs-col (incl. equi-joins) stays residual in v1
where
  tryEmit (i : Nat) (col : String) (op : PushOp) (v : Expr) : WalkM Unit := do
    -- only eq/ne are null-safe (`IS`); order ops must not see NULL, and an
    -- Option-typed operand can only arise under BEq anyway.
    try
      let colVal ← mkAppM ``LeanDb.ColCodec.toCol #[← instantiateMVars v]
      let cond ← mkAppM ``LeanDb.PushCond.cmp #[mkStrLit col, mkOp op, colVal]
      addPushed i cond
    catch _ => addResidual   -- no codec for the value's type

/-- Walk the Bool predicate body, conjunct by conjunct. -/
private partial def walk (comps : Array Expr) (e : Expr) : WalkM Unit := do
  let e ← whnfCore e
  if e.isAppOfArity ``Bool.and 2 then
    walk comps (e.getArg! 0)
    walk comps (e.getArg! 1)
    return
  if e.isConstOf ``Bool.true then
    return
  if e.isAppOfArity ``Bool.not 1 then
    -- `a != b` sugar and negated equality
    let inner ← whnfCore (e.getArg! 0)
    if inner.isAppOfArity ``BEq.beq 4 then
      pushCmp comps .ne (inner.getArg! 2) (inner.getArg! 3)
      return
    addResidual
    return
  if e.isAppOfArity ``bne 4 then
    pushCmp comps .ne (e.getArg! 2) (e.getArg! 3)
    return
  if e.isAppOfArity ``BEq.beq 4 then
    pushCmp comps .eq (e.getArg! 2) (e.getArg! 3)
    return
  if e.isAppOfArity ``decide 2 then
    let p ← whnfCore (e.getArg! 0)
    if p.isAppOfArity ``LT.lt 4 then pushCmp comps .lt (p.getArg! 2) (p.getArg! 3); return
    if p.isAppOfArity ``LE.le 4 then pushCmp comps .le (p.getArg! 2) (p.getArg! 3); return
    if p.isAppOfArity ``GT.gt 4 then pushCmp comps .gt (p.getArg! 2) (p.getArg! 3); return
    if p.isAppOfArity ``GE.ge 4 then pushCmp comps .ge (p.getArg! 2) (p.getArg! 3); return
    if p.isAppOfArity ``Eq 3 then pushCmp comps .eq (p.getArg! 1) (p.getArg! 2); return
    if p.isAppOfArity ``Ne 3 then pushCmp comps .ne (p.getArg! 1) (p.getArg! 2); return
    addResidual
    return
  -- Option null tests: `col.isNone` / `col.isSome`
  if e.isAppOfArity ``Option.isNone 2 || e.isAppOfArity ``Option.isSome 2 then
    if let some (i, col) ← colOf? comps (e.getArg! 1) then
      let ctor := if e.isAppOfArity ``Option.isNone 2 then ``PushCond.isNull else ``PushCond.isNotNull
      addPushed i (← mkAppM ctor #[mkStrLit col])
      return
    addResidual
    return
  -- @[db]-tagged helper: unfold and keep walking
  if let .const n _ := e.getAppFn then
    if dbAttr.hasTag (← getEnv) n then
      if let some e' ← unfoldDefinition? e then
        walk comps e'
        return
  -- bare Bool column: `t.val.available`
  if let some (i, col) ← colOf? comps e then
    try
      let tru ← mkAppM ``LeanDb.ColCodec.toCol #[mkConst ``Bool.true]
      addPushed i (← mkAppM ``LeanDb.PushCond.cmp #[mkStrLit col, mkOp .eq, tru])
    catch _ => addResidual
    return
  addResidual

/-- Reflect the predicate in a `PlanFor pred` goal into a `SelectPlan` term. -/
def reflectPlan (goalTy : Expr) : MetaM Expr := do
  let goalTy ← instantiateMVars goalTy
  unless goalTy.isAppOfArity ``LeanDb.PlanFor 2 do
    throwError "leandb_plan: goal is not PlanFor"
  let ρ := goalTy.getArg! 0
  let pred := goalTy.getArg! 1
  withComps ρ fun comps pair => do
    let body ← whnfCore (mkApp pred pair)
    let (_, st) ← (walk comps body).run {}
    let pairTy ← mkAppM ``Prod #[mkConst ``Nat, mkConst ``LeanDb.PushCond]
    let entries ← st.pushed.mapM fun (i, cond) =>
      mkAppM ``Prod.mk #[mkNatLit i, cond]
    let arr ← mkArrayLit pairTy entries.toList
    mkAppM ``LeanDb.SelectPlan.mk #[arr, mkNatLit st.residual]

elab "leandb_plan" : tactic => do
  let g ← getMainGoal
  let ty ← g.getType
  let plan ← try reflectPlan ty catch _ => pure (mkConst ``LeanDb.SelectPlan.empty)
  if leandb.explain.get (← getOptions) then
    let planVal ← instantiateMVars plan
    logInfo m!"leandb plan: {planVal}"
  g.assign (← mkExpectedTypeHint plan ty)

end LeanDb.PlanElab
