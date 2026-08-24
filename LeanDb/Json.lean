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
