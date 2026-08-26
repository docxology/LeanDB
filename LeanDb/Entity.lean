import LeanDb.Core

namespace LeanDb

/-! # Entities

An entity is a flat structure whose fields are `ColCodec` scalars, `Option`s
of them, or `Ref`s to other entities. Instances are produced by
`deriving LeanDb.Entity` (see `LeanDb.Derive`) — the types are the schema's
single source of truth, so nothing here is ever written by hand.
-/

class Entity (α : Type) where
  tableName : String
  columns : Array ColumnSpec
  /-- Field values in declaration order, id excluded. -/
  encode : α → Array Col
  /-- Inverse of `encode` over honest data; typed failure otherwise. -/
  decode : Array Col → Except DbError α

/-- A `Ref β` (= `Id β`) column is a foreign key onto `β`'s table. -/
instance [Entity β] : RefTarget (Id β) := ⟨some (Entity.tableName β)⟩

def Entity.spec (α : Type) [Entity α] : TableSpec :=
  ⟨Entity.tableName α, Entity.columns α⟩

/-- A column value as a SQL literal (for `DEFAULT` clauses). -/
def Col.sqlLit : Col → String
  | .int v => toString v
  | .real v => toString v
  | .text v => "'" ++ (v.replace "'" "''") ++ "'"
  | .null => "NULL"

/-- Quote a SQLite identifier, including embedded double quotes. Entity
    and field names normally come from Lean identifiers, but escaped Lean
    names can contain punctuation and must remain valid SQL. -/
def quoteIdent (s : String) : String :=
  "\"" ++ s.replace "\"" "\"\"" ++ "\""

/-- One column's DDL fragment (shared by CREATE TABLE and ALTER ADD). -/
def ColumnSpec.ddlFragment (c : ColumnSpec) : String :=
  let base := s!"{quoteIdent c.name} {c.sqlType.render}"
  let base := if c.nullable then base else base ++ " NOT NULL"
  let base := match c.dflt with
    | some v => base ++ s!" DEFAULT {v.sqlLit}"
    | none => base
  let base := match c.enum with
    | some vs =>
        let names := String.intercalate ", " (vs.toList.map fun v => (Col.text v).sqlLit)
        base ++ s!" CHECK ({quoteIdent c.name} IN ({names}))"
    | none => base
  match c.fkTable with
  | some fk => base ++ s!" REFERENCES {quoteIdent fk}(id) ON DELETE RESTRICT ON UPDATE RESTRICT"
  | none => base

/-- CREATE TABLE DDL under an explicit table name (migration rebuilds
    create under a scratch name, then rename). -/
def TableSpec.ddlNamed (t : TableSpec) (name : String) (ifNotExists : Bool := true) : String :=
  let cols := t.columns.toList.map ColumnSpec.ddlFragment
  let body := String.intercalate ", " ("id INTEGER PRIMARY KEY AUTOINCREMENT" :: cols)
  let guard := if ifNotExists then " IF NOT EXISTS" else ""
  s!"CREATE TABLE{guard} {quoteIdent name} ({body})"

/-- Rendered DDL for one entity. Every table gets a rowid-backed `id`
    primary key; references RESTRICT on delete — destruction is loud. -/
def TableSpec.ddl (t : TableSpec) : String := t.ddlNamed t.name

/-- Validate cross-table invariants that individual derived `Entity`
    instances cannot see. This runs before opening or migrating a file. -/
def validateSchema (specs : List TableSpec) : Except DbError Unit := do
  let tableNames := specs.map (·.name)
  unless tableNames.eraseDups.length == tableNames.length do
    throw (.schemaInvalid "table names must be unique")
  for spec in specs do
    if spec.name.startsWith "_leandb_" then
      throw (.schemaInvalid s!"table {String.quote spec.name} uses the reserved _leandb_ prefix")
    let columnNames := spec.columns.toList.map (·.name)
    if columnNames.contains "id" then
      throw (.schemaInvalid s!"table {String.quote spec.name} declares reserved column \"id\"")
    unless columnNames.eraseDups.length == columnNames.length do
      throw (.schemaInvalid s!"table {String.quote spec.name} has duplicate column names")
    for col in spec.columns do
      if let some target := col.fkTable then
        unless tableNames.contains target do
          throw (.schemaInvalid s!"{spec.name}.{col.name} references missing table {String.quote target}")

/-- Schema fingerprint: a hash of the rendered DDL of every table, in
    declaration order. Checked against `_leandb_meta` at open. -/
def fingerprint (specs : List TableSpec) : String :=
  toString <| hash <| String.intercalate ";\n" (specs.map (·.ddl))

end LeanDb
