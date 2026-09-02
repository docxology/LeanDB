import LeanDb.Cli

namespace LeanDb

/-! # A typed client for a served base

A project that imports a base package has its types and its query defs;
against a *local* instance it runs them in-process (`Base.withInstance`).
Against a *served* base it needs the wire: `Client` speaks the JSON-lines
protocol to a base process (`<base> serve`), and `client% f` turns a query
def's signature into a stub — arguments rendered through `CliRender`,
the result decoded through `QueryIn` — so the call site is typed exactly
as the local one. The handshake compares fingerprints: a client compiled
against another version of the schema is refused before it asks. -/

open Lean (Json)

/-- How a typed argument renders for the wire (the inverse of `CliArg`).
    Closed enums render by variant name for free; bases add instances for
    their newtypes. -/
class CliRender (α : Type) where
  render : α → String

instance : CliRender Nat := ⟨toString⟩
instance : CliRender Int64 := ⟨toString⟩
instance : CliRender String := ⟨id⟩
instance : CliRender (Id α) := ⟨fun i => toString i.toInt64⟩
instance [ClosedEnum α] : CliRender α := ⟨ClosedEnum.encodeName⟩

/-- How a query result decodes from its JSON (the inverse of `QueryOut`). -/
class QueryIn (α : Type) where
  ofJson : Json → Except String α

/-- `Stored α` from row JSON: `id` plus the entity's fields. -/
def storedOfJson (α : Type) [Entity α] (j : Json) : Except String (Stored α) := do
  let id ← (j.getObjValAs? Int "id").mapError fun _ => s!"{Entity.tableName α}: row JSON without an id"
  let fields := match j with
    | .obj kvs => Json.mkObj (kvs.toList.filter (·.1 != "id"))
    | other => other
  let a ← (rowOfJson α fields).mapError (·.message)
  return ⟨⟨Int64.ofInt id⟩, a⟩

instance [Entity α] : QueryIn (Stored α) := ⟨storedOfJson α⟩
instance [QueryIn α] [QueryIn β] : QueryIn (α × β) := ⟨fun j => do
  match j with
  | .arr #[a, b] => return (← QueryIn.ofJson a, ← QueryIn.ofJson b)
  | other => throw s!"expected a pair, got {other.compress}"⟩
instance [QueryIn α] : QueryIn (Array α) := ⟨fun j => do
  match j with
  | .arr xs => xs.mapM QueryIn.ofJson
  | other => throw s!"expected an array, got {other.compress}"⟩
instance [QueryIn α] : QueryIn (List α) := ⟨fun j => (·.toList) <$> (QueryIn.ofJson j : Except String (Array α))⟩
instance [QueryIn α] : QueryIn (Option α) := ⟨fun j =>
  match j with
  | .null => pure none
  | other => some <$> QueryIn.ofJson other⟩
instance : QueryIn Nat := ⟨fun j => (j.getNat?).mapError fun _ => s!"expected a natural number, got {j.compress}"⟩
instance : QueryIn String := ⟨fun j => (j.getStr?).mapError fun _ => s!"expected a string, got {j.compress}"⟩
instance : QueryIn Bool := ⟨fun j => (j.getBool?).mapError fun _ => s!"expected a boolean, got {j.compress}"⟩
instance : QueryIn Unit := ⟨fun _ => pure ()⟩
instance : QueryIn Json := ⟨pure⟩

/-- A typed error back from the wire, by its code. -/
def DbError.ofJson (j : Json) : DbError :=
  let msg := (j.getObjValAs? String "message").toOption.getD j.compress
  match (j.getObjValAs? String "code").toOption with
  | some "decode" => .decode "remote" "result" msg
  | some "not_found" => .notFound "remote" 0
  | some "stale" => .stale "remote" 0
  | some "restricted" => .restricted "remote" 0
  | some "missing_ref" => .missingRef "remote"
  | some "duplicate" => .duplicate "remote" msg
  | some "schema_mismatch" => .schemaMismatch "" msg
  | some "schema" => .schemaInvalid msg
  | some "enum_drift" => .enumDrift "remote" "" msg
  | some "migrate" => .migrate msg
  | some "unknown_lineage" => .unknownLineage msg []
  | _ => .sqlite msg

/-- A connection to a served base: the process, and the fingerprint the
    client was compiled against. -/
structure Client where
  child : IO.Process.Child { stdin := .piped, stdout := .piped, stderr := .inherit }
  fingerprint : String

abbrev ClientM := ReaderT Client (ExceptT DbError IO)

def ClientM.run (c : Client) (act : ClientM α) : IO (Except DbError α) := (act c).run

/-- One request over JSON lines. -/
def Client.rpc (c : Client) (argv : List String) : IO Json := do
  let line := (Json.arr (argv.map Json.str).toArray).compress
  c.child.stdin.putStrLn line
  c.child.stdin.flush
  let out ← c.child.stdout.getLine
  if out.isEmpty then throw <| IO.userError "the served base closed the connection"
  match Json.parse out.trimAscii.toString with
  | .ok j => return j
  | .error m => throw <| IO.userError s!"unparseable response from the served base: {m}"

/-- End the served session: the client owns the process it spawned. -/
def Client.close (c : Client) : IO Unit := do
  try c.child.kill catch _ => pure ()
  discard <| c.child.wait

/-- Spawn `<exe> serve` (plus `args`, e.g. `--db path`) and shake hands:
    the served schema must be the one this client was compiled against. -/
def Client.connect (exe : System.FilePath) (fingerprint : String) (args : List String := []) :
    IO (Except DbError Client) := do
  let cfg : IO.Process.SpawnArgs := {
    cmd := exe.toString
    args := (args ++ ["serve"]).toArray
    stdin := .piped
    stdout := .piped
    stderr := .inherit }
  let child ← IO.Process.spawn cfg
  let c : Client := { child, fingerprint }
  let v ← c.rpc ["version"]
  match (v.getObjValAs? String "code_fingerprint").toOption with
  | some fp =>
      if fp != fingerprint then
        c.close
        return .error (.schemaMismatch fingerprint fp)
      return .ok c
  | none =>
      c.close
      return .error (.sqlite s!"the served base did not answer version: {v.compress}")

/-- Call a registered query by name; the result is the query's JSON. -/
def Client.call (name : String) (args : List String) : ClientM Json := fun c => ExceptT.mk do
  try
    let j ← c.rpc (["query", name] ++ args)
    if (j.getObjValAs? Bool "ok").toOption == some true then
      return .ok ((j.getObjVal? "result").toOption.getD Json.null)
    else
      return .error (DbError.ofJson j)
  catch e =>
    return .error (.sqlite (toString e))

/-- Decode a typed result. -/
def ClientM.decode (α : Type) [QueryIn α] (j : Json) : ClientM α := fun _ => ExceptT.mk <|
  pure ((QueryIn.ofJson j : Except String α).mapError fun m => .decode "remote" "result" m)

/-- Any argv through the client (rows, insert, migrate status, …). -/
def Client.argv (argv : List String) : ClientM Json := fun c => ExceptT.mk do
  try
    let j ← c.rpc argv
    if (j.getObjValAs? Bool "ok").toOption == some true then return .ok j
    else return .error (DbError.ofJson j)
  catch e =>
    return .error (.sqlite (toString e))

end LeanDb

namespace LeanDb.Cli
open Lean Elab Term Meta

/-- `client% slaBreached` turns `def slaBreached (now : Timestamp) : DbM ρ`
    into `fun now => … : ClientM ρ`: each argument renders through its
    type's `CliRender`, the call goes over the wire under the def's name,
    the result decodes through `QueryIn ρ`. The stub's type is the local
    def's with `DbM` replaced by `ClientM`, so a wrong argument or a
    result the project cannot decode is a compile error. -/
elab "client% " id:ident : term => do
  let name ← realizeGlobalConstNoOverloadWithInfo id
  let info ← getConstInfo name
  let (binderNames, binderTys, retTy) ← forallTelescope info.type fun xs body => do
    unless body.isAppOf ``LeanDb.DbM do
      throwError "client%: {name} must return in DbM, found {body}"
    let mut names : Array Name := #[]
    let mut tys : Array Term := #[]
    for x in xs do
      let decl ← x.fvarId!.getDecl
      unless decl.binderInfo == .default do
        throwError "client%: {name} has non-explicit binder '{decl.userName}'"
      names := names.push decl.userName
      tys := tys.push (← PrettyPrinter.delab (← instantiateMVars decl.type))
    let ret ← PrettyPrinter.delab (← instantiateMVars (body.getArg! 0))
    return (names, tys, ret)
  let nameLit : Term := quote name.getString!
  let idents := binderNames.map fun n => mkIdent n
  let rendered ← (idents.zip binderTys).mapM fun (x, ty) =>
    `(LeanDb.CliRender.render ($x : $ty))
  let args : Term ← `([$rendered,*])
  let body : Term ← `((LeanDb.Client.call $nameLit $args >>= LeanDb.ClientM.decode $retTy : LeanDb.ClientM $retTy))
  let binders ← (idents.zip binderTys).mapM fun (x, ty) => `(Lean.Parser.Term.funBinder| ($x : $ty))
  let stx ← if binders.isEmpty then pure body else `(fun $binders* => $body)
  elabTerm stx none

end LeanDb.Cli
