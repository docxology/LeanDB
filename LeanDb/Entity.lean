import LeanDb.Core

namespace LeanDb

/-! # Entities

An entity is a flat structure whose fields are `ColCodec` scalars, `Option`s
of them, or `Ref`s to other entities. Instances are produced by
`deriving LeanDb.Entity` (see `LeanDb.Derive`) — the types are the schema's
single source of truth, so nothing here is ever written by hand.

Each entity also gets a generated *field symbol* type (`Ticket.Field`),
which is how the engine names a column; the column's string name is
derived from the symbol (`Entity.fieldSpec`), never the reverse.
-/

class Entity (α : Type) where
  /-- The field symbols: a generated inductive with one constructor per
      declared field, in declaration order (`Ticket.Field.title`). Column
      identity inside the engine is one of these, never a string. -/
  Field : Type
  /-- The declared Lean type of a field. -/
  fieldTy : Field → Type
  /-- Read a field off a value. -/
  get : (f : Field) → α → fieldTy f
  /-- The field type's own codec, reachable from the symbol. -/
  codec : (f : Field) → ColCodec (fieldTy f)
  /-- The column as DDL/JSON/migrations see it. The ONLY place a field's
      name is a string; everything else reaches it through the symbol. -/
  fieldSpec : Field → ColumnSpec
  /-- Every symbol, in declaration order. -/
  fields : Array Field
  tableName : String
  /-- Field values in declaration order, id excluded. -/
  encode : α → Array Col
  /-- Inverse of `encode` over honest data; typed failure otherwise. -/
  decode : Array Col → Except DbError α

/- Instance lookup reduces types only at reducible transparency, so a type
   stated through a class projection (`SqlOrd (Entity.fieldTy f)`,
   `OfNat (Entity.fieldTy f) 40`) is found only if the projection and the
   instance both unfold there. The derived instances are `@[reducible]`;
   these are the projections that appear in types. -/
attribute [reducible] Entity.Field Entity.fieldTy Entity.codec

/-- The symbol type determines its entity. Unification cannot invert
    `Entity.Field ?α =?= Ticket.Field`, so a column reference written from
    the symbol alone (`Col.here Ticket.Field.title`) recovers the entity
    through this class instead; `sym` is the identity, generated with
    every `deriving LeanDb.Entity`. -/
class FieldOf (F : Type) (α : outParam Type) [Entity α] where
  sym : F → Entity.Field α

attribute [reducible] FieldOf.sym

/-- The column specs, in declaration order — computed from the symbols,
    so the string is derived from the symbol and never the other way. -/
def Entity.columns (α : Type) [Entity α] : Array ColumnSpec :=
  (Entity.fields (α := α)).map fun f => Entity.fieldSpec f

/-- The column name of a field symbol (render-only: SQL, JSON, diagnostics). -/
def Entity.fieldName [Entity α] (f : Entity.Field α) : String :=
  (Entity.fieldSpec f).name

/-- Parse a column name at a boundary (argv, JSON, a stored plan) into the
    symbol; `none` names no column of `α`. -/
def Entity.fieldOfName? (α : Type) [Entity α] (s : String) : Option (Entity.Field α) :=
  (Entity.fields (α := α)).find? fun f => Entity.fieldName f == s

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
