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

/-- Rendered DDL for one entity. Every table gets a rowid-backed `id`
    primary key; references RESTRICT on delete — destruction is loud. -/
def TableSpec.ddl (t : TableSpec) : String :=
  let col := fun (c : ColumnSpec) =>
    let base := s!"\"{c.name}\" {c.sqlType.render}"
    let base := if c.nullable then base else base ++ " NOT NULL"
    let base := match c.enum with
      | some vs =>
          let names := String.intercalate ", " (vs.toList.map fun v => s!"'{v}'")
          base ++ s!" CHECK (\"{c.name}\" IN ({names}))"
      | none => base
    match c.fkTable with
    | some fk => base ++ s!" REFERENCES \"{fk}\"(id) ON DELETE RESTRICT ON UPDATE RESTRICT"
    | none => base
  let cols := t.columns.toList.map col
  let body := String.intercalate ", " ("id INTEGER PRIMARY KEY AUTOINCREMENT" :: cols)
  s!"CREATE TABLE IF NOT EXISTS \"{t.name}\" ({body})"

/-- Schema fingerprint: a hash of the rendered DDL of every table, in
    declaration order. Checked against `_leandb_meta` at open. -/
def fingerprint (specs : List TableSpec) : String :=
  toString <| hash <| String.intercalate ";\n" (specs.map (·.ddl))

end LeanDb
