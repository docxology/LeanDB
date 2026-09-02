import Lean
import LeanDb.Entity

/-! # `deriving LeanDb.Entity`

Generates, for a flat structure `Ticket`:

- `inductive Ticket.Field` — one constructor per declared field, in order,
  spelled as the structure spells it (`«at»`), `deriving DecidableEq, Repr`;
- the `Entity Ticket` instance: `fieldTy`/`get`/`codec`/`fieldSpec` as a
  `match` over the symbols, `fields`, table name, row encode/decode;
- the `FieldOf Ticket.Field Ticket` instance (symbol type → entity).

The generated code references only `columnSpec`/`ColCodec` through the
field *types*, so the schema cannot drift from the structure — there is
nothing else it could be derived from. A structure that already declares
`Field` in its namespace is refused.

Not supported (typed error, not a runtime surprise): parameterized
structures, and fields whose types depend on earlier fields (proof fields —
planned, Architecture §4.3).
-/

namespace LeanDb.Derive

open Lean Elab Command Term Meta PrettyPrinter

private unsafe def evalColUnsafe (e : Expr) : MetaM LeanDb.Col :=
  evalExpr LeanDb.Col (mkConst ``LeanDb.Col) e

/-- Evaluate a `Col`-valued closed expression at elaboration time. Used to
    turn structure field defaults into literals with their definition-site
    instances baked in (a delab/re-elaborate round trip can resolve scoped
    instances differently, and referencing the `_default` constant from
    compiled code trips an LCNF panic on this toolchain). -/
@[implemented_by evalColUnsafe]
private opaque evalCol (e : Expr) : MetaM LeanDb.Col

/-- Quote an evaluated `Col` back into surface syntax. -/
private def colLitStx (v : LeanDb.Col) : Elab.TermElabM Term :=
  match v with
  | .text s => `(LeanDb.Col.text $(quote s))
  | .int i =>
      let n : Nat := i.toInt.natAbs
      if i.toInt < 0 then `(LeanDb.Col.int (-(Int64.ofNat $(quote n))))
      else `(LeanDb.Col.int (Int64.ofNat $(quote n)))
  | .real f => `(LeanDb.Col.real (Float.ofBits (UInt64.ofNat $(quote f.toBits.toNat))))
  | .null => `(LeanDb.Col.null)

/-- `"UserProfile"` → `"user_profile"`. -/
def tableNameOf (declName : Name) : String :=
  let last := declName.getString!
  last.foldl (init := "") fun acc c =>
    if c.isUpper then
      (if acc.isEmpty then acc else acc ++ "_") ++ c.toLower.toString
    else
      acc ++ c.toString

private def fieldBinder (i : Nat) : Ident := mkIdent (Name.mkSimple s!"f{i}")

def deriveEntity (declName : Name) : CommandElabM Bool := do
  let env ← getEnv
  unless isStructure env declName do
    throwError "deriving LeanDb.Entity: {declName} is not a structure"
  let indVal ← getConstInfoInduct declName
  unless indVal.numParams == 0 && indVal.numIndices == 0 do
    throwError "deriving LeanDb.Entity: {declName} must not have type parameters"
  let ctorName := indVal.ctors.head!
  let ctorInfo ← getConstInfoCtor ctorName
  let fields := getStructureFields env declName
  let tblName := tableNameOf declName
  if tblName.startsWith "_leandb_" then
    throwError "deriving LeanDb.Entity: table name '{tblName}' uses the reserved _leandb_ prefix"
  if fields.any (·.getString! == "id") then
    throwError "deriving LeanDb.Entity: field 'id' is reserved for LeanDB row identity"
  let fieldTyName := declName ++ `Field
  if env.contains fieldTyName then
    throwError "deriving LeanDb.Entity: {declName} already declares '{fieldTyName}'; LeanDB generates the field symbols under that name"
  -- 1. The field symbols. Declared under `_root_` so the current namespace
  --    is not prepended; a private structure gets a private symbol type
  --    (re-mangled to exactly `declName ++ Field` — same module).
  let symId := mkIdent (`_root_ ++ (privateToUserName? declName).getD declName ++ `Field)
  let ctors ← fields.mapM fun f => `(Lean.Parser.Command.ctor| | $(mkIdent f):ident)
  let symCmd ←
    if isPrivateName declName then
      `(private inductive $symId:ident where $ctors* deriving DecidableEq, Repr)
    else
      `(inductive $symId:ident where $ctors* deriving DecidableEq, Repr)
  elabCommand symCmd
  unless (← getEnv).contains fieldTyName do
    throwError "deriving LeanDb.Entity: failed to declare '{fieldTyName}'"
  -- 2. The instances.
  let cmds ← liftTermElabM <| forallTelescopeReducing ctorInfo.type fun xs _ => do
    unless xs.size == fields.size do
      throwError "deriving LeanDb.Entity: unexpected constructor arity for {declName}"
    let mut tyAlts : Array (TSyntax ``Lean.Parser.Term.matchAlt) := #[]
    let mut getAlts : Array (TSyntax ``Lean.Parser.Term.matchAlt) := #[]
    let mut codecAlts : Array (TSyntax ``Lean.Parser.Term.matchAlt) := #[]
    let mut specAlts : Array (TSyntax ``Lean.Parser.Term.matchAlt) := #[]
    let mut syms : Array Term := #[]
    let mut encs : Array Term := #[]
    let mut fieldTys : Array Term := #[]
    for i in [0:fields.size] do
      let fname := fields[i]!
      let ftype ← inferType xs[i]!
      if (Array.ofSubarray xs[0:i]).any (fun x => ftype.containsFVar x.fvarId!) then
        throwError "deriving LeanDb.Entity: field '{fname}' of {declName} depends on an earlier field; proof/dependent fields are not supported yet"
      let tyStx ← delab ftype
      fieldTys := fieldTys.push tyStx
      -- Reify a `:= default` field value by EVALUATING it here, at
      -- elaboration time, with its definition-site instances — then embed
      -- the literal in the column spec (DDL DEFAULT, JSON omission,
      -- migration backfill all read it from there).
      let dfltStx : Term ← do
        match getDefaultFnForField? env declName fname with
        | some dn =>
            let info ← getConstInfo dn
            if info.type.isForall then
              logWarning m!"deriving LeanDb.Entity: default of '{declName}.{fname}' depends on other fields and is not reified — JSON inserts must supply it"
              `((none : Option LeanDb.Col))
            else
              try
                let v ← evalCol (← mkAppM ``LeanDb.ColCodec.toCol #[info.value!])
                `(some $(← colLitStx v))
              catch ex =>
                logWarning m!"deriving LeanDb.Entity: default of '{declName}.{fname}' could not be evaluated ({ex.toMessageData}) — JSON inserts must supply it"
                `((none : Option LeanDb.Col))
        | none => `((none : Option LeanDb.Col))
      let sym : Ident := mkCIdent (fieldTyName ++ fname)
      syms := syms.push sym
      tyAlts := tyAlts.push (← `(Lean.Parser.Term.matchAltExpr| | $sym:ident => $tyStx))
      getAlts := getAlts.push
        (← `(Lean.Parser.Term.matchAltExpr| | $sym:ident => $(mkCIdent (declName ++ fname)) r))
      codecAlts := codecAlts.push
        (← `(Lean.Parser.Term.matchAltExpr| | $sym:ident => (inferInstance : LeanDb.ColCodec $tyStx)))
      specAlts := specAlts.push
        (← `(Lean.Parser.Term.matchAltExpr| | $sym:ident =>
              LeanDb.columnSpec $(quote fname.toString) $tyStx $dfltStx))
      encs := encs.push
        (← `(LeanDb.ColCodec.toCol ($(mkCIdent (declName ++ fname)) r)))
    -- A zero-field structure has an empty symbol type: every function
    -- over it is `nomatch`.
    let bySym (alts : Array (TSyntax ``Lean.Parser.Term.matchAlt)) : TermElabM Term :=
      if fields.isEmpty then `(fun f => nomatch f)
      else `(fun f => match f with $alts:matchAlt*)
    let fieldTyFn ← bySym tyAlts
    let codecFn ← bySym codecAlts
    let specFn ← bySym specAlts
    let getFn ←
      if fields.isEmpty then `(fun f _ => nomatch f)
      else `(fun f r => match f with $getAlts:matchAlt*)
    -- decode: right fold of decodeField binds ending in the constructor.
    let ctorArgs := (Array.range fields.size).map fun i => (fieldBinder i : Term)
    let mut body : Term ← `(Except.ok ($(mkCIdent ctorName) $ctorArgs*))
    for i in (List.range fields.size).reverse do
      let fname := fields[i]!
      body ← `(LeanDb.decodeField $(quote tblName) $(quote fname.toString)
                 $(fieldTys[i]!) (row.getD $(quote i) .null) >>= fun $(fieldBinder i) => $body)
    let n := quote fields.size
    -- `@[reducible]`: instance lookup only sees through `Entity.fieldTy f`
    -- to the field's type if the instance unfolds at reducible transparency
    -- (see `LeanDb.Entity`).
    let entityCmd : TSyntax `command ← `(@[reducible] instance : LeanDb.Entity $(mkCIdent declName) where
        Field := $(mkCIdent fieldTyName)
        fieldTy := $fieldTyFn
        get := $getFn
        codec := $codecFn
        fieldSpec := $specFn
        fields := #[$syms,*]
        tableName := $(quote tblName)
        encode := fun r => #[$encs,*]
        decode := fun row =>
          if row.size == $n then $body
          else Except.error (LeanDb.DbError.decode $(quote tblName) "*"
                 s!"expected {$n} columns, found {row.size}"))
    let fieldOfCmd : TSyntax `command ← `(@[reducible] instance :
        LeanDb.FieldOf $(mkCIdent fieldTyName) $(mkCIdent declName) := ⟨fun f => f⟩)
    return (entityCmd, fieldOfCmd)
  elabCommand cmds.1
  elabCommand cmds.2
  return true

def entityHandler : DerivingHandler := fun declNames => do
  for declName in declNames do
    discard <| deriveEntity declName
  return true

initialize registerDerivingHandler ``LeanDb.Entity entityHandler

/-! ## `deriving LeanDb.ClosedEnum` -/

def deriveClosedEnum (declName : Name) : CommandElabM Bool := do
  let indVal ← getConstInfoInduct declName
  unless indVal.numParams == 0 && indVal.numIndices == 0 do
    throwError "deriving LeanDb.ClosedEnum: {declName} must not have type parameters"
  for c in indVal.ctors do
    let ci ← getConstInfoCtor c
    unless ci.numFields == 0 do
      throwError "deriving LeanDb.ClosedEnum: constructor '{c}' carries data; only payload-free inductives are closed worlds (stored sums are planned separately)"
  let names := indVal.ctors.map (·.getString!)
  let cmd ← liftTermElabM do
    let variantTerms : Array Term := (names.map fun n => (quote n : Term)).toArray
    -- The scalar `Nat` motive matters: a `String`-motive casesOn inside a
    -- closed term (e.g. a reified field default) panics the compiler's
    -- boxing pass on this toolchain; an index into the variants array
    -- compiles everywhere.
    let idxArms : Array Term := (List.range names.length).toArray.map fun i => quote i
    let enc ← `(
      let vs : Array String := #[$variantTerms,*]
      fun x => vs[$(mkCIdent (declName ++ `casesOn)) (motive := fun _ => Nat) x $idxArms*]!)
    let mut dec : Term ← `((none : Option $(mkCIdent declName)))
    for (ctor, n) in (indVal.ctors.zip names).reverse do
      dec ← `(if s == $(quote n) then some $(mkCIdent ctor) else $dec)
    let ctorTerms : Array Term := (indVal.ctors.map fun c => (mkCIdent c : Term)).toArray
    `(instance : LeanDb.ClosedEnum $(mkCIdent declName) where
        variants := #[$variantTerms,*]
        all := #[$ctorTerms,*]
        encodeName := $enc
        decodeName := fun s => $dec)
  elabCommand cmd
  return true

def closedEnumHandler : DerivingHandler := fun declNames => do
  for declName in declNames do
    discard <| deriveClosedEnum declName
  return true

initialize registerDerivingHandler ``LeanDb.ClosedEnum closedEnumHandler

end LeanDb.Derive
