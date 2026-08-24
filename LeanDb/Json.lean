import Lean.Data.Json
import LeanDb.Entity

namespace LeanDb

/-! # JSON, derived from the schema

Everything here is computed from `Entity`/`TableSpec` — the JSON surface
cannot drift from the types. Incoming JSON decodes *through* the column
codecs and smart constructors: a caller can be wrong, never ill-typed.
-/

open Lean (Json ToJson toJson)

def Col.toJson : Col → Json
  | .int v => Lean.toJson v.toInt
  | .text v => Json.str v
  | .real v => Lean.toJson v
  | .null => Json.null

/-- Decode one JSON value as the column's SQL type. -/
def Col.fromJson (spec : ColumnSpec) (j : Json) : Except String Col :=
  match j with
  | Json.null =>
      if spec.nullable then .ok .null
      else .error s!"{spec.name}: null not allowed"
  | Json.bool b =>
      -- Bool columns store as INTEGER 0/1; accept JSON booleans for them
      if spec.sqlType == .integer then .ok (.int (if b then 1 else 0))
      else .error s!"{spec.name}: boolean not allowed for a {spec.sqlType.render} column"
  | _ =>
      match spec.sqlType with
      | .integer => do
          let i ← j.getInt?
          if i < Int64.minValue.toInt || i > Int64.maxValue.toInt then
            throw s!"{spec.name}: {i} out of INTEGER range"
          return .int (Int64.ofInt i)
      | .text => .text <$> j.getStr?
      | .real => .real <$> (j.getNum? <&> (·.toFloat))

def DbError.toJson (e : DbError) : Json :=
  Json.mkObj [("ok", Json.bool false), ("code", Json.str e.code),
    ("message", Json.str e.message)]

def ColumnSpec.toJson (c : ColumnSpec) : Json :=
  Json.mkObj <|
    [("name", Json.str c.name), ("type", Json.str c.sqlType.render),
     ("nullable", Json.bool c.nullable)]
    ++ (c.fkTable.map fun fk => ("references", Json.str fk)).toList
    ++ (c.enum.map fun vs => ("enum", Json.arr (vs.map Json.str))).toList

def TableSpec.toJson (t : TableSpec) : Json :=
  Json.mkObj [("name", Json.str t.name),
    ("columns", Json.arr (t.columns.map (·.toJson)))]

def SqlType.fromJson? (j : Json) : Except String SqlType := do
  match ← j.getStr? with
  | "INTEGER" => return .integer
  | "TEXT" => return .text
  | "REAL" => return .real
  | s => throw s!"unknown SQL type {s}"

def ColumnSpec.fromJson? (j : Json) : Except String ColumnSpec := do
  let name ← j.getObjVal? "name" >>= (·.getStr?)
  let sqlType ← SqlType.fromJson? (← j.getObjVal? "type")
  let nullable ← j.getObjVal? "nullable" >>= (·.getBool?)
  let fkTable := (j.getObjVal? "references").toOption.bind (·.getStr?.toOption)
  let enum := (j.getObjVal? "enum").toOption.bind fun a =>
    (a.getArr?.toOption).map fun vs => vs.filterMap (·.getStr?.toOption)
  return { name, sqlType, nullable, fkTable, enum }

def TableSpec.fromJson? (j : Json) : Except String TableSpec := do
  let name ← j.getObjVal? "name" >>= (·.getStr?)
  let cols ← j.getObjVal? "columns" >>= (·.getArr?)
  return ⟨name, ← cols.mapM ColumnSpec.fromJson?⟩

/-- Serialize/parse a whole schema — how an instance remembers the shape
    it was last migrated to. -/
def specsToJson (specs : List TableSpec) : Json :=
  Json.arr (specs.toArray.map (·.toJson))

def specsFromJson? (j : Json) : Except String (List TableSpec) := do
  return (← (← j.getArr?).mapM TableSpec.fromJson?).toList

/-- The schema surface: derived from the specs, which are derived from the
    types. There is no other source. -/
def schemaJson (name : String) (specs : List TableSpec) : Json :=
  Json.mkObj [("ok", Json.bool true), ("base", Json.str name),
    ("fingerprint", Json.str (fingerprint specs)),
    ("tables", Json.arr (specs.toArray.map (·.toJson)))]

/-- A stored row as JSON: id plus one field per column, by column name. -/
def rowJson (α : Type) [Entity α] (s : Stored α) : Json :=
  let fields := (Entity.columns α).zip (Entity.encode s.val)
  Json.mkObj <| ("id", Lean.toJson s.id.toInt64.toInt) ::
    (fields.toList.map fun (c, v) => (c.name, v.toJson))

/-- Decode a full row from JSON field-by-field, then through the entity's
    codecs (and thus every smart constructor). Missing nullable fields are
    `null`; missing required fields are typed errors. -/
def rowOfJson (α : Type) [Entity α] (j : Json) : Except DbError α := do
  let table := Entity.tableName α
  let cols ← (Entity.columns α).mapM fun c =>
    match j.getObjVal? c.name with
    | .ok v =>
        match Col.fromJson c v with
        | .ok col => .ok col
        | .error m => .error (.decode table c.name m)
    | .error _ =>
        if c.nullable then .ok .null
        else .error (.decode table c.name "missing required field")
  Entity.decode cols

/-- Overlay a partial JSON object onto an existing row at the column level,
    then re-decode — validation applies to the merged result. This is the
    CLI's `update <table> <id> <partial-json>`. -/
def rowMergeJson (α : Type) [Entity α] (base : α) (j : Json) : Except DbError α := do
  let table := Entity.tableName α
  let obj ← match j with
    | .obj _ => .ok ()
    | _ => .error (.decode table "*" "expected a JSON object")
  let _ := obj
  let cols ← ((Entity.columns α).zip (Entity.encode base)).mapM fun (c, old) =>
    match j.getObjVal? c.name with
    | .ok v =>
        match Col.fromJson c v with
        | .ok col => .ok col
        | .error m => .error (.decode table c.name m)
    | .error _ => .ok old
  Entity.decode cols

end LeanDb
