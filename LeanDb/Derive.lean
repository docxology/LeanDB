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
    let mut dflts : Array Term := #[]
    for i in [0:fields.size] do
      let fname := fields[i]!
      let ftype ← inferType xs[i]!
      if (Array.ofSubarray xs[0:i]).any (fun x => ftype.containsFVar x.fvarId!) then
        throwError "deriving LeanDb.Entity: field '{fname}' of {declName} depends on an earlier field; proof/dependent fields are not supported yet"
      let tyStx ← delab ftype
      fieldTys := fieldTys.push tyStx
      colSpecs := colSpecs.push
        (← `(LeanDb.columnSpec $(quote fname.toString) $tyStx))
      encs := encs.push
        (← `(LeanDb.ColCodec.toCol ($(mkCIdent (declName ++ fname)) r)))
      -- Reify `:= default` field values (non-dependent ones) for JSON
      -- decode. The default's defining term is inlined — referencing the
      -- `_default` constant in compiled code trips an LCNF boxing panic
      -- on this toolchain (its inlining attributes interact badly with
      -- closed-term extraction).
      dflts := dflts.push (← do
        match getDefaultFnForField? env declName fname with
        | some dn =>
            let info ← getConstInfo dn
            if info.type.isForall then `((none : Option LeanDb.Col))
            else
              try
                let valStx ← delab info.value!
                `(some (LeanDb.ColCodec.toCol ($valStx : $(fieldTys[i]!))))
              catch _ => `((none : Option LeanDb.Col))
        | none => `((none : Option LeanDb.Col)))
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
        defaults := #[$dflts,*]
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
    let enc ← `(fun x =>
      (#[$variantTerms,*] : Array String)[$(mkCIdent (declName ++ `casesOn))
        (motive := fun _ => Nat) x $idxArms*]!)
    let mut dec : Term ← `((none : Option $(mkCIdent declName)))
    for (ctor, n) in (indVal.ctors.zip names).reverse do
      dec ← `(if s == $(quote n) then some $(mkCIdent ctor) else $dec)
    `(instance : LeanDb.ClosedEnum $(mkCIdent declName) where
        variants := #[$variantTerms,*]
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
