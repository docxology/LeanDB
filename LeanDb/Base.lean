import LeanDb.Db
import LeanDb.Json
import LeanDb.Migration

namespace LeanDb

/-! # A base, as a value

The three nouns of the design (plan.md §10): the *package* is the truth
(types, queries, and this descriptor), the *instance* is the state (one
SQLite file), the *server* is a process. A base package exports one
`LeanDb.Base` value from its library, so a project that imports the
package gets the types, the query defs, and the descriptor together; the
CLI (`LeanDb.Cli.run`), a server, or another program all start from the
same value. Where the instance lives is decided at run time (`Instance`),
never compiled into the base.
-/

open Lean (Json)

/-- A registered query: the name the CLI/API uses, its positional
    parameters `(binder, type)` as `query%` saw them, and the runner that
    parses argv and renders the result. -/
structure QueryEntry where
  name : String
  params : List (String × String) := []
  footprint : Footprint := {}
  run : List String → DbM Json

/-- One table as the CLI/API sees it: its specs (the entity's own table
    and, for an entity with child lists, its child tables) and the row
    verbs, type-erased into closures over the `Entity` instance. -/
structure CliTable where
  name : String
  /-- The entity's Lean name, for generated source (`migrate freeze`). -/
  typeName : String
  specs : List TableSpec
  insertJson : Json → DbM Json
  getJson : Int64 → DbM Json
  updateJson : Int64 → Json → DbM Json
  deleteRow : Int64 → DbM Json
  /-- `rows` with conjunctive equality filters (plan.md §4.1: `--eq` and
      limit are the CLI's whole filter language — anything more is a
      typed query). -/
  rowsWhere : List (String × String) → Nat → DbM Json

private def okRow (j : Json) : Json := Json.mkObj [("ok", Json.bool true), ("row", j)]

def CliTable.of (α : Type) [Entity α] : CliTable where
  name := Entity.tableName α
  typeName := Entity.typeName α
  specs := Entity.specs α
  insertJson j := do
    let a ← DbM.ofExcept (rowOfJson α j)
    return okRow (rowJson α (← insert α a))
  getJson id := do
    match ← get (⟨id⟩ : Id α) with
    | some s => return okRow (rowJson α s)
    | none => throw (.notFound (Entity.tableName α) id)
  updateJson id j := do
    match ← get (⟨id⟩ : Id α) with
    | some old =>
        let new ← DbM.ofExcept (rowMergeJson α old.val j)
        return okRow (rowJson α (← update old new))
    | none => throw (.notFound (Entity.tableName α) id)
  deleteRow id := do
    delete (⟨id⟩ : Id α)
    return Json.mkObj [("ok", Json.bool true), ("deleted", Lean.toJson id.toInt)]
  rowsWhere eqs limit := do
    let spec := Entity.spec α
    -- (symbol, typed value) per filter; the plan is folded from these
    -- below, outside the monad (`Pred` lives in `Type 1`, `DbM` carries `Type`)
    let mut conds : Array ((f : Entity.Field α) × Entity.fieldTy f) := #[]
    for (col, v) in eqs do
      -- the boundary parses the name into the symbol at once; from here
      -- on the column is `f`, never the string
      match Entity.fieldOfName? α col with
      | none =>
          throw (.decode spec.name col
            s!"no such column; columns: {spec.columns.toList.map (·.name)}")
      | some f =>
          let c := Entity.fieldSpec f
          -- a closed-world column refuses unknown variants loudly — a
          -- silent empty result is the exact failure mode LeanDB exists
          -- to kill
          if let some vs := c.enum then
            unless vs.contains v do
              throw (.decode spec.name col
                s!"{String.quote v} is not in the closed world {vs}")
          let cv ← match c.sqlType with
            | .integer =>
                match v.toInt? with
                | some i =>
                    if i < Int64.minValue.toInt || i > Int64.maxValue.toInt then
                      throw (.decode spec.name col s!"integer out of Int64 range: {v}")
                    pure (Col.int (Int64.ofInt i))
                | none => throw (.decode spec.name col s!"expected an integer, got {String.quote v}")
            | .text => pure (Col.text v)
            | .real => throw (.decode spec.name col "REAL columns cannot be filtered with --eq")
          -- the validated value goes through the column's own codec, like
          -- every other boundary: a validated newtype's canonical encoding
          -- is what SQLite compares, not the spelling on the command line
          let tv ← match (Entity.codec f).fromCol cv with
            | .ok tv => pure tv
            | .error e => throw (.decode spec.name col e)
          conds := conds.push ⟨f, tv⟩
    let pred : Pred [α] := conds.foldl (init := .tt) fun p c => p.andS (.eq (.here c.1) .eq c.2)
    let rows ← fetchFiltered α pred
    let rows := rows.toList.take limit
    return Json.mkObj [("ok", Json.bool true), ("count", Lean.toJson rows.length),
      ("rows", Json.arr (rows.map (rowJson α)).toArray)]

/-- A base: name, tables, named queries, an optional seed, and the
    default instance location. The schema is *derived* from `tables`
    (`Base.specs`), so the two cannot disagree. An entity with child lists
    (LEP-0003 D) contributes its child tables through `Entity.specs`; list
    the children as tables of their own too (`.of Kernel.Ins`) so
    `rows kernel_ins --eq …` works like any other table. -/
structure Base where
  name : String
  tables : List CliTable
  queries : List QueryEntry := []
  /-- The `seed` verb, when the base has one. -/
  seed : Option (DbM Unit) := none
  /-- Instance path used when neither `--db` nor `LEANDB_DB` is given;
      `none` means `data/<name>.sqlite`. -/
  defaultDb : Option System.FilePath := none
  /-- The frozen schema history (`migrate freeze`). `none` = unfrozen:
      migrations are diffed from the instance's stored schema and applied
      mechanically, refusing anything that needs judgment. -/
  chain : Option Chain := none
  /-- The base's Lean module (`Tickets`), where `migrate freeze` writes
      `<module>/Migrations/V<n>.lean`; empty = pass `--module`. -/
  module : String := ""
  /-- Modules a generated migration imports to see the head entity
      types; empty = `[<module>.Entities]`. -/
  freezeImports : List String := []
  /-- Audit retention and migration impact budget; environment settings
      override these defaults when a connection opens. -/
  log : LogConfig := {}

/-- Dedup by table name (first occurrence wins) and order so that every
    foreign-key target precedes its referrer. The sort is stable: among
    the ready tables the earliest declared is emitted first, so a list
    that is already in dependency order comes back unchanged (and so does
    its fingerprint). A self-reference is not a dependency. If a cycle
    remains, the rest is appended in declaration order — SQLite resolves
    `REFERENCES` lazily, and `validateSchema` still checks every target. -/
def orderSpecs (specs : List TableSpec) : List TableSpec := Id.run do
  let mut seen : List String := []
  let mut uniq : Array TableSpec := #[]
  for s in specs do
    unless seen.contains s.name do
      seen := s.name :: seen
      uniq := uniq.push s
  let names := uniq.map (·.name)
  let deps := fun (s : TableSpec) =>
    s.columns.toList.filterMap fun c =>
      c.fkTable.bind fun t => if t == s.name || !names.contains t then none else some t
  let mut pending := uniq.toList
  let mut out : Array TableSpec := #[]
  let mut done : List String := []
  let mut progress := true
  while progress && !pending.isEmpty do
    progress := false
    match pending.find? (fun s => (deps s).all done.contains) with
    | some s =>
        out := out.push s
        done := s.name :: done
        pending := pending.filter (·.name != s.name)
        progress := true
    | none => pure ()
  return out.toList ++ pending

/-- The schema this base's tables imply, in dependency order. -/
def Base.specs (b : Base) : List TableSpec :=
  orderSpecs (b.tables.flatMap (·.specs))

def Base.defaultInstance (b : Base) : System.FilePath :=
  b.defaultDb.getD ("data" / s!"{b.name}.sqlite")

/-- Where a base's state lives: the SQLite file and the directory that
    receives its backups. -/
structure Instance where
  path : System.FilePath
  backups : System.FilePath
  deriving Repr

def Instance.ofPath (path : System.FilePath) : Instance :=
  { path, backups := (path.parent.getD ".") / "backups" }

/-- Resolve the instance for a CLI invocation: `--db <path>` anywhere in
    argv (removed from the returned argv) beats `LEANDB_DB`, which beats
    the base's default. -/
def Instance.resolve (b : Base) (args : List String) :
    IO (Except String (Instance × List String)) := do
  let rec strip : List String → Except String (Option String × List String)
    | [] => .ok (none, [])
    | "--db" :: [] => .error "--db expects a path"
    | "--db" :: p :: rest => do
        let (_, rest) ← strip rest
        return (some p, rest)
    | a :: rest => do
        let (p, rest) ← strip rest
        return (p, a :: rest)
  match strip args with
  | .error m => return .error m
  | .ok (flag, rest) =>
      let env ← IO.getEnv "LEANDB_DB"
      let path : System.FilePath :=
        match flag, env with
        | some p, _ => p
        | none, some p => if p.isEmpty then b.defaultInstance else p
        | none, none => b.defaultInstance
      return .ok (Instance.ofPath path, rest)

/-- `"Tickets.UserProfile"` → `"user_profile"`: the derive's table naming,
    for a type the base no longer lists (a dropped entity). -/
private def snakeOfType (ty : String) : String :=
  let last := (ty.splitOn ".").getLast?.getD ty
  last.foldl (init := "") fun acc c =>
    if c.isUpper then (if acc.isEmpty then acc else acc ++ "_") ++ c.toLower.toString
    else acc ++ c.toString

/-- A static footprint names entity *types*; the base knows their tables.
    A type it does not list (dropped from the code) falls back to the
    derive's naming. -/
def Base.resolveFootprint (b : Base) (f : Footprint) : Footprint :=
  let tableOf := fun (ty : String) =>
    match b.tables.find? (·.typeName == ty) with
    | some t => t.name
    | none => snakeOfType ty
  { tables := f.tables.map tableOf, columns := f.columns.map fun (t, c) => (tableOf t, c),
    residual := f.residual }

/-- The version a fresh instance of this base starts at: the chain's head,
    or 1 when unfrozen (the counter mode). -/
def Base.headVersion (b : Base) : Nat :=
  (b.chain.map (·.headVersion)).getD 1

/-- Open the instance for this base and run an action — the whole
    lifecycle for another program that imports the base. -/
def Base.withInstance (b : Base) (i : Instance) (act : DbM α) : IO (Except DbError α) := do
  if let some parent := i.path.parent then
    IO.FS.createDirAll parent
  match ← openDbRaw i.path with
  | .error e => return .error e
  | .ok conn =>
      if let some c := b.chain then discard <| c.adopt conn
      match ← conn.verify b.specs b.headVersion with
      | .error e => return .error e
      | .ok () => act.run conn

end LeanDb
