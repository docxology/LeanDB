import Lean
import LeanDb.Entity

/-! # `deriving LeanDb.Entity`

Generates the `Entity` instance for a flat structure: table name, column
specs, row encode/decode. The generated instance references only
`columnSpec`/`ColCodec` through the field *types*, so the schema cannot
drift from the structure — there is nothing else it could be derived from.

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
  let cmd ← liftTermElabM <| forallTelescopeReducing ctorInfo.type fun xs _ => do
    unless xs.size == fields.size do
      throwError "deriving LeanDb.Entity: unexpected constructor arity for {declName}"
    let mut colSpecs : Array Term := #[]
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
      colSpecs := colSpecs.push
        (← `(LeanDb.columnSpec $(quote fname.toString) $tyStx $dfltStx))
      encs := encs.push
        (← `(LeanDb.ColCodec.toCol ($(mkCIdent (declName ++ fname)) r)))
    -- decode: right fold of decodeField binds ending in the constructor.
    let ctorArgs := (Array.range fields.size).map fun i => (fieldBinder i : Term)
    let mut body : Term ← `(Except.ok ($(mkCIdent ctorName) $ctorArgs*))
    for i in (List.range fields.size).reverse do
      let fname := fields[i]!
      body ← `(LeanDb.decodeField $(quote tblName) $(quote fname.toString)
                 $(fieldTys[i]!) (row.getD $(quote i) .null) >>= fun $(fieldBinder i) => $body)
    let n := quote fields.size
    `(instance : LeanDb.Entity $(mkCIdent declName) where
        tableName := $(quote tblName)
        columns := #[$colSpecs,*]
        encode := fun r => #[$encs,*]
        decode := fun row =>
          if row.size == $n then $body
          else Except.error (LeanDb.DbError.decode $(quote tblName) "*"
                 s!"expected {$n} columns, found {row.size}"))
  elabCommand cmd
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
