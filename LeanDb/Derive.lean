import Lean
import LeanDb.Json

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

A field whose default is `derived e`, with `e` over earlier fields, is a
**derived column** (LEP-0003 B3): `encode` recomputes it from its sources
(the supplied value is ignored), `decode` checks the stored value against
the recomputation and fails with `decode` naming the column if they
differ, and the JSON boundary may omit it. Lean forbids attributes on
structure fields, so the mark is the `derived` wrapper in the default.

Not supported (typed error, not a runtime surprise): parameterized
structures, and fields whose types depend on earlier fields (proof fields —
planned, Architecture §4.3).

# `deriving LeanDb.DbJson`

For a nested value type (a structure or an inductive, recursive or not,
without parameters): `Lean.ToJson` and `Lean.FromJson` in exactly the
encoding Lean's own derive produces — objects for structures,
constructor-tagged objects for inductives — except that an omitted
structure field with a default takes the default; plus `JsonShape`, the
canonical description of the type that the fingerprint and `migrate` see.
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

/-- An identifier for a declaration generated next to `declName`, anchored
    at `_root_` so the current namespace is not prepended (a private
    declaration re-mangles to the same private name — same module). -/
private def rootIdent (n : Name) : Ident :=
  mkIdent (`_root_ ++ (privateToUserName? n).getD n)

/-- Delaborate for re-elaboration in generated code: full names, so the
    term means the same thing wherever the instance is elaborated. -/
private def delabFull (e : Expr) : TermElabM Term :=
  withOptions (fun o => o.setBool `pp.fullNames true) (delab e)

/-- A structure field's default, analysed. Structure default functions
    (`S.f._default`) are never compiled — Lean adds them for elaboration
    only, and referencing one from compiled code panics LCNF — so the
    value is *reified*: delaborated and re-elaborated inside the generated
    code. `params` are the fields the default depends on, in order (the
    lambda binders Lean abstracts, named after the fields), so the reified
    term applied to those fields' values is the default. -/
private structure DefaultInfo where
  /-- The whole `_default` value (a lambda over `params` if nonempty). -/
  value : Expr
  params : Array Name
  /-- Marked `LeanDb.derived`. -/
  isDerived : Bool

private partial def stripIdMData : Expr → Expr
  | .mdata _ e => stripIdMData e
  | e => if e.isAppOfArity ``id 2 then stripIdMData e.appArg! else e

private def defaultInfo? (declName fname : Name) (fields : Array Name) :
    MetaM (Option DefaultInfo) := do
  let env ← getEnv
  let some dn := getDefaultFnForField? env declName fname | return none
  let info ← getConstInfo dn
  let value := info.value!
  -- leading lambdas named after fields are the dependencies; anything
  -- else is the value itself (a function-typed field)
  let rec deps (e : Expr) (acc : Array Name) : Array Name :=
    match e with
    | .lam n _ b _ => if fields.contains n then deps b (acc.push n) else acc
    | _ => acc
  let params := deps value #[]
  let body ← lambdaBoundedTelescope value params.size fun _ body => pure body
  return some { value, params, isDerived := (stripIdMData body).isAppOf ``LeanDb.derived }

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
  let symId := rootIdent (declName ++ `Field)
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
    let mut derivedAlts : Array (TSyntax ``Lean.Parser.Term.matchAlt) := #[]
    let mut syms : Array Term := #[]
    let mut encs : Array Term := #[]
    let mut fieldTys : Array Term := #[]
    -- derived fields: (index, reified default fn, parameter field indices)
    let mut derivedFields : Array (Nat × Term × Array Nat) := #[]
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
      -- migration backfill all read it from there). A `derived` default
      -- is reified as a *function* of its source fields instead.
      let mut recompute : Option (Term × Array Nat) := none
      let dfltStx : Term ← do
        match ← defaultInfo? declName fname fields with
        | some d =>
            if d.params.isEmpty then
              if d.isDerived then
                throwError "deriving LeanDb.Entity: field '{fname}' of {declName} is marked `derived` but its default does not depend on other fields"
              try
                let v ← evalCol (← mkAppM ``LeanDb.ColCodec.toCol #[d.value])
                `(some $(← colLitStx v))
              catch ex =>
                logWarning m!"deriving LeanDb.Entity: default of '{declName}.{fname}' could not be evaluated ({ex.toMessageData}) — JSON inserts must supply it"
                `((none : Option LeanDb.Col))
            else if d.isDerived then
              let idxs ← d.params.mapM fun p => do
                match fields.findIdx? (· == p) with
                | some j => if j < i then pure j else
                    throwError "deriving LeanDb.Entity: derived field '{fname}' of {declName} depends on '{p}', which is not an earlier field"
                | none => throwError "deriving LeanDb.Entity: derived field '{fname}' of {declName} depends on '{p}', which is not a field"
              recompute := some (← delabFull d.value, idxs)
              `((none : Option LeanDb.Col))
            else
              logWarning m!"deriving LeanDb.Entity: default of '{declName}.{fname}' depends on other fields and is not reified — JSON inserts must supply it (mark it `derived` to have LeanDB compute it)"
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
      derivedAlts := derivedAlts.push
        (← `(Lean.Parser.Term.matchAltExpr| | $sym:ident => $(quote recompute.isSome)))
      match recompute with
      | some (fn, idxs) =>
          derivedFields := derivedFields.push (i, fn, idxs)
          -- encode recomputes from the record's source fields
          let args ← idxs.mapM fun j => `($(mkCIdent (declName ++ fields[j]!)) r)
          encs := encs.push (← `(LeanDb.ColCodec.toCol (($fn) $args*)))
      | none =>
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
    let derivedFn ← bySym derivedAlts
    let getFn ←
      if fields.isEmpty then `(fun f _ => nomatch f)
      else `(fun f r => match f with $getAlts:matchAlt*)
    -- decode: right fold of decodeField binds ending in the constructor.
    -- `checking`: a derived column is decoded and compared with its
    -- recomputation; otherwise it is recomputed and the stored value ignored.
    let ctorArgs := (Array.range fields.size).map fun i => (fieldBinder i : Term)
    let recomputed (fn : Term) (idxs : Array Nat) : TermElabM Term :=
      let args : Array Term := idxs.map fun j => (fieldBinder j : Term)
      `(($fn) $args*)
    let mkDecode (checking : Bool) : TermElabM Term := do
      let mut body : Term ← `(Except.ok ($(mkCIdent ctorName) $ctorArgs*))
      if checking then
        for (i, fn, idxs) in derivedFields.reverse do
          body ← `(if $(fieldBinder i) == $(← recomputed fn idxs) then $body
                   else Except.error (LeanDb.DbError.decode $(quote tblName)
                     $(quote fields[i]!.toString) "derived column disagrees with its source"))
      for i in (List.range fields.size).reverse do
        let fname := fields[i]!
        match derivedFields.find? (·.1 == i) with
        | some (_, fn, idxs) =>
            if checking then
              body ← `(LeanDb.decodeField $(quote tblName) $(quote fname.toString)
                         $(fieldTys[i]!) (row.getD $(quote i) .null) >>= fun $(fieldBinder i) => $body)
            else
              body ← `(let $(fieldBinder i) : $(fieldTys[i]!) := $(← recomputed fn idxs); $body)
        | none =>
            body ← `(LeanDb.decodeField $(quote tblName) $(quote fname.toString)
                       $(fieldTys[i]!) (row.getD $(quote i) .null) >>= fun $(fieldBinder i) => $body)
      return body
    let bodyCheck ← mkDecode true
    let bodyRecompute ← mkDecode false
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
          if row.size == $n then $bodyCheck
          else Except.error (LeanDb.DbError.decode $(quote tblName) "*"
                 s!"expected {$n} columns, found {row.size}")
        isDerived := $derivedFn
        decodeRecomputing := fun row =>
          if row.size == $n then $bodyRecompute
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

/-! ## `deriving LeanDb.DbJson` -/

/-- The name a shape uses for a nested type: the last component. -/
private def shapeName (n : Name) : String :=
  ((privateToUserName? n).getD n).getString!

private def shapeDelims : List Char :=
  ['{', '}', '(', ')', '<', '>', '[', ']', ',', '|', ':', '?', '=']

private def checkShapeName (what : String) (n : Name) : TermElabM Unit := do
  let s := n.getString!
  if s.any (shapeDelims.contains ·) then
    throwError "deriving LeanDb.DbJson: {what} '{n}' contains a character reserved by the shape grammar ({shapeDelims})"

/-- The shape of a type expression, as a `String`-valued term: containers
    are walked here (so a recursive reference renders as the type's bare
    name instead of looping), nested types go through their `JsonShape`
    instance at run time, closed enums through their variant list. -/
private partial def shapeTerm (declName : Name) (owner : String) (ty : Expr) : TermElabM Term := do
  let ty ← instantiateMVars ty
  let ty := ty.consumeMData
  if ty.isConstOf declName then return quote (shapeName declName)
  let args := ty.getAppArgs
  match ty.getAppFn.constName?, args.size with
  | some ``List, 1 | some ``Array, 1 => `(LeanDb.JsonShape.list $(← shapeTerm declName owner args[0]!))
  | some ``Option, 1 => `(LeanDb.JsonShape.option $(← shapeTerm declName owner args[0]!))
  | some ``Prod, 2 =>
      `(LeanDb.JsonShape.pair $(← shapeTerm declName owner args[0]!) $(← shapeTerm declName owner args[1]!))
  | _, _ =>
      if (ty.find? (·.isConstOf declName)).isSome then
        throwError "deriving LeanDb.DbJson: {owner}: a recursive occurrence of {declName} inside {ty} is only supported under List, Array, Option and pairs"
      let tyStx ← delabFull ty
      if (← synthInstance? (← mkAppM ``LeanDb.JsonShape #[ty])).isSome then
        `(LeanDb.JsonShape.shape $tyStx)
      else if (← synthInstance? (← mkAppM ``LeanDb.ClosedEnum #[ty])).isSome then
        `(LeanDb.JsonShape.closed (LeanDb.ClosedEnum.variants $tyStx))
      else
        throwError "deriving LeanDb.DbJson: {owner} has type {ty}, which has no JsonShape — derive LeanDb.DbJson for it, or declare `instance : LeanDb.JsonShape {ty}`"

/-- Does any constructor field of `declName` mention `declName`? -/
private def isSelfReferential (declName : Name) : MetaM Bool := do
  let indVal ← getConstInfoInduct declName
  indVal.ctors.anyM fun c => do
    let ci ← getConstInfoCtor c
    forallTelescopeReducing ci.type fun xs _ =>
      xs.anyM fun x => do return ((← inferType x).find? (·.isConstOf declName)).isSome

def deriveDbJson (declName : Name) : CommandElabM Bool := do
  let env ← getEnv
  let indVal ← getConstInfoInduct declName
  unless indVal.numParams == 0 && indVal.numIndices == 0 do
    throwError "deriving LeanDb.DbJson: {declName} must not have type parameters"
  let selfId := mkCIdent declName
  let toFn := declName ++ `leandbToJson
  let fromFn := declName ++ `leandbFromJson
  let toId := rootIdent toFn
  let fromId := rootIdent fromFn
  -- inside their own bodies the functions are named without `_root_`
  let toRef := mkIdent ((privateToUserName? toFn).getD toFn)
  let fromRef := mkIdent ((privateToUserName? fromFn).getD fromFn)
  let errPrefix (field : Name) : String := s!"{(privateToUserName? declName).getD declName}.{field}: "
  let cmds ← liftTermElabM do
    let selfRef ← isSelfReferential declName
    let (toBody, fromBody, shape) ← if isStructure env declName then do
      -- structure: an object, one key per (flattened) field
      let fields := getStructureFieldsFlattened env declName (includeSubobjectFields := false)
      for f in fields do checkShapeName "field" f
      let allFields := getStructureFields env declName
      withLocalDeclD `x (mkConst declName) fun x => do
        let mut pairs : Array Term := #[]
        let mut getters : Array (TSyntax ``Lean.Parser.Term.doSeqItem) := #[]
        let mut shapeFields : Array Term := #[]
        for f in fields do
          let proj ← mkProjection x f
          let fty ← inferType proj
          if fty.containsFVar x.fvarId! then
            throwError "deriving LeanDb.DbJson: field '{f}' of {declName} depends on another field; dependent fields are not supported"
          let key := quote f.toString
          let fId := mkIdent f
          let ftyStx ← delabFull fty
          pairs := pairs.push (← `(($key, Lean.toJson ($(mkIdent `x)).$fId:ident)))
          let dflt? ← defaultInfo? declName f allFields
          let required ← `(Except.mapError (fun s => $(quote (errPrefix f)) ++ s)
            (Lean.Json.getObjValAs? json $ftyStx $key))
          match dflt? with
          | some d =>
              let fnStx ← delabFull d.value
              let args : Array Term := d.params.map fun p => (mkIdent p : Term)
              let dfltTerm : Term ← if args.isEmpty then pure fnStx else `(($fnStx) $args*)
              let rhs ← `(Except.mapError (fun s => $(quote (errPrefix f)) ++ s)
                (LeanDb.jsonFieldOr json $key (fun _ => $dfltTerm)))
              getters := getters.push (← `(Lean.Parser.Term.doSeqItem| let $fId:ident : $ftyStx ← $rhs:term))
          | none =>
              getters := getters.push (← `(Lean.Parser.Term.doSeqItem| let $fId:ident : $ftyStx ← $required:term))
          shapeFields := shapeFields.push
            (← `(($key, $(← shapeTerm declName s!"field '{f}' of {declName}" fty), $(quote dflt?.isSome))))
        let fieldIds := fields.map mkIdent
        let toBody ← `(fun ($(mkIdent `x) : $selfId) => Lean.Json.mkObj [$pairs,*])
        let fromBody ← `(fun (json : Lean.Json) => do
          $getters*
          return { $[$fieldIds:ident := $(id fieldIds)],* })
        let shape ← `(LeanDb.JsonShape.struct $(quote (shapeName declName)) [$shapeFields,*])
        pure (toBody, fromBody, shape)
    else do
      -- inductive: Lean's constructor-tagged encoding
      let mut toAlts : Array (TSyntax ``Lean.Parser.Term.matchAlt) := #[]
      let mut fromAlts : Array (TSyntax ``Lean.Parser.Term.matchAlt) := #[]
      let mut shapeCtors : Array Term := #[]
      for ctorName in indVal.ctors do
        let ci ← getConstInfoCtor ctorName
        let ctorStr := ctorName.eraseMacroScopes.getString!
        checkShapeName "constructor" (Name.mkSimple ctorStr)
        let (toAlt, fromAlt, shapeCtor) ← forallTelescopeReducing ci.type fun xs _ => do
          let mut binders : Array Ident := #[]
          let mut tys : Array Expr := #[]
          let mut userNames : Array Name := #[]
          for i in [0:ci.numFields] do
            let x := xs[i]!
            let decl ← x.fvarId!.getDecl
            if (Array.ofSubarray xs[0:i]).any (fun y => decl.type.containsFVar y.fvarId!) then
              throwError "deriving LeanDb.DbJson: constructor '{ctorName}' has a dependent field; not supported"
            unless decl.userName.hasMacroScopes do
              userNames := userNames.push decl.userName
            binders := binders.push (mkIdent (← mkFreshUserName `a))
            tys := tys.push decl.type
          let named := userNames.size == binders.size
          if named then for u in userNames do checkShapeName "constructor field" u
          let ctorId := mkCIdent ctorName
          -- encode
          let payload : Term ← match binders.size, named with
            | 0, _ => `(Lean.toJson $(quote ctorStr))
            | 1, false => `(Lean.Json.mkObj [($(quote ctorStr), Lean.toJson $(binders[0]!))])
            | _, false =>
                let xs ← binders.mapM fun b => `(Lean.toJson $b)
                `(Lean.Json.mkObj [($(quote ctorStr), Lean.Json.arr #[$xs,*])])
            | _, true =>
                let kvs ← (binders.zip userNames).mapM fun (b, u) =>
                  `(($(quote u.getString!), Lean.toJson $b))
                `(Lean.Json.mkObj [($(quote ctorStr), Lean.Json.mkObj [$kvs,*])])
          let toAlt ← `(Lean.Parser.Term.matchAltExpr| | @$ctorId:ident $binders* => $payload)
          -- decode
          let fromRhs : Term ←
            if binders.size == 0 then `(pure $ctorId)
            else do
              let namesOpt : Term ← if named then
                  let ns := userNames.map fun u => (quote u : Term)
                  `(some #[$ns,*])
                else `(none)
              let mut body : Term ← `(pure ($ctorId $binders*))
              for i in (List.range binders.size).reverse do
                let tyStx ← delabFull tys[i]!
                body ← `((Lean.fromJson? (jsons[$(quote i)]!) : Except String $tyStx) >>= fun $(binders[i]!) => $body)
              `((Lean.Json.parseCtorFields json $(quote ctorStr) $(quote binders.size) $namesOpt).bind
                  fun jsons => $body)
          let fromAlt ← `(Lean.Parser.Term.matchAltExpr| | $(quote ctorStr):str => $fromRhs)
          -- shape
          let shapePayload : Term ← match binders.size, named with
            | 0, _ => `(LeanDb.JsonShape.Payload.none)
            | _, true =>
                let kvs ← (tys.zip userNames).mapM fun (t, u) => do
                  `(($(quote u.getString!), $(← shapeTerm declName s!"constructor '{ctorName}'" t)))
                `(LeanDb.JsonShape.Payload.named [$kvs,*])
            | _, false =>
                let ts ← tys.mapM fun t => shapeTerm declName s!"constructor '{ctorName}'" t
                `(LeanDb.JsonShape.Payload.positional [$ts,*])
          let shapeCtor ← `(($(quote ctorStr), $shapePayload))
          pure (toAlt, fromAlt, shapeCtor)
        toAlts := toAlts.push toAlt
        fromAlts := fromAlts.push fromAlt
        shapeCtors := shapeCtors.push shapeCtor
      let toBody ← `(fun (x : $selfId) => match x with $toAlts:matchAlt*)
      let fromBody ← `(fun (json : Lean.Json) =>
        match Lean.Json.getTag? json with
        | some tag =>
            match tag with
            $fromAlts:matchAlt*
            | _ => Except.error "no inductive constructor matched"
        | none => Except.error "no inductive tag found")
      let shape ← `(LeanDb.JsonShape.inductive' $(quote (shapeName declName)) [$shapeCtors,*])
      pure (toBody, fromBody, shape)
    -- the aux functions: `partial` with local instances when recursive,
    -- exactly as Lean's own derive does
    let priv := isPrivateName declName
    let mkDef (id : Ident) (binder : TSyntax ``Lean.Parser.Term.bracketedBinder) (ty body : Term) :
        TermElabM (TSyntax `command) :=
      match priv, selfRef with
      | true, true => `(private partial def $id:ident $binder : $ty := $body)
      | true, false => `(private def $id:ident $binder : $ty := $body)
      | false, true => `(partial def $id:ident $binder : $ty := $body)
      | false, false => `(def $id:ident $binder : $ty := $body)
    let toBody' ← if selfRef then `(let _inst : Lean.ToJson $selfId := ⟨$toRef⟩; ($toBody) x)
      else `(($toBody) x)
    let fromBody' ← if selfRef then `(let _inst : Lean.FromJson $selfId := ⟨$fromRef⟩; ($fromBody) json)
      else `(($fromBody) json)
    let toDef ← mkDef toId (← `(Lean.Parser.Term.bracketedBinderF| (x : $selfId))) (← `(Lean.Json)) toBody'
    let fromDef ← mkDef fromId (← `(Lean.Parser.Term.bracketedBinderF| (json : Lean.Json)))
      (← `(Except String $selfId)) fromBody'
    let instCmds : Array (TSyntax `command) := #[
      ← `(instance : Lean.ToJson $selfId := ⟨$toId⟩),
      ← `(instance : Lean.FromJson $selfId := ⟨$fromId⟩),
      ← `(instance : LeanDb.JsonShape $selfId := ⟨$shape⟩),
      ← `(instance : LeanDb.DbJson $selfId := {})]
    pure (#[toDef, fromDef] ++ instCmds)
  for c in cmds do elabCommand c
  return true

def dbJsonHandler : DerivingHandler := fun declNames => do
  for declName in declNames do
    discard <| deriveDbJson declName
  return true

initialize registerDerivingHandler ``LeanDb.DbJson dbJsonHandler

end LeanDb.Derive
