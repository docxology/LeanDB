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

/-- A column value as row JSON: an `EnumSet` column's bitmask renders as
    the array of its members' names (`["silu","gelu"]`, declaration
    order); everything else as `Col.toJson`. -/
def Col.toJsonFor (spec : ColumnSpec) : Col → Json
  | .int v =>
      match spec.enumSet with
      | some vs =>
          let bits := v.toNatClampNeg.toUInt64
          Json.arr <| vs.zipIdx.filterMap fun (name, k) =>
            if (bits >>> k.toUInt64) &&& 1 != 0 then some (Json.str name) else none
      | none => Col.toJson (.int v)
  | c => c.toJson

/-- Decode one JSON value as the column's SQL type. An `EnumSet` column
    takes an array of variant names (an unknown name is refused by name)
    or, for round-tripping, the bare bitmask. -/
def Col.fromJson (spec : ColumnSpec) (j : Json) : Except String Col :=
  match j with
  | Json.null =>
      if spec.nullable then .ok .null
      else .error s!"{spec.name}: null not allowed"
  | Json.bool b =>
      -- Bool columns store as INTEGER 0/1; accept JSON booleans for them
      if spec.sqlType == .integer && spec.enumSet.isNone then .ok (.int (if b then 1 else 0))
      else .error s!"{spec.name}: boolean not allowed for a {spec.sqlType.render} column"
  | Json.arr items =>
      match spec.enumSet with
      | some vs => do
          let mut bits : UInt64 := 0
          for item in items do
            let name ← item.getStr?
            match vs.findIdx? (· == name) with
            | some k => bits := bits ||| ((1 : UInt64) <<< k.toUInt64)
            | none => throw s!"{spec.name}: {String.quote name} is not in the closed world {vs}"
          return .int (Int64.ofNat bits.toNat)
      | none => .error s!"{spec.name}: array not allowed for a {spec.sqlType.render} column"
  | _ =>
      match spec.sqlType with
      | .integer => do
          let i ← j.getInt?
          if i < Int64.minValue.toInt || i > Int64.maxValue.toInt then
            throw s!"{spec.name}: {i} out of INTEGER range"
          return .int (Int64.ofInt i)
      | .text => .text <$> j.getStr?
      | .real => .real <$> (j.getNum? <&> (·.toFloat))

/-- A nested value type that lives in one JSON TEXT column: its JSON
    encoding both ways plus its declared shape. Instances come from
    `deriving LeanDb.DbJson` (see `LeanDb.Derive`), which — unlike Lean's
    own derive — lets an omitted field with a structure default take the
    default, so an additive change to a nested type still decodes old rows.
    (Named `DbJson`, not `Json`: a `LeanDb.Json` would shadow `Lean.Json`
    in every engine module that opens it.) -/
class DbJson (α : Type) extends ToJson α, Lean.FromJson α, JsonShape α

/-- The codec of a JSON column: compressed JSON in a TEXT column, decoded
    through `validate` (a smart constructor over the whole value, so a
    row written by an older build or by the CLI is refused the same way a
    Lean constructor call would be). The column's `shape` is the type's
    `JsonShape`; `columnSpec` reads it off the codec. -/
@[reducible] def ColCodec.json (α : Type) [ToJson α] [Lean.FromJson α] [JsonShape α]
    (validate : α → Except String α := .ok) : ColCodec α where
  sqlType := .text
  toCol a := .text (toJson a).compress
  fromCol
    | .text t => Json.parse t >>= Lean.fromJson? >>= validate
    | c => .error s!"expected TEXT, found {c.describe}"
  shape := some (JsonShape.shape α)

/-- `fromJson?` of `key` in `json`, or `dflt ()` when the key is absent —
    how a `deriving LeanDb.DbJson` decoder treats a field with a default.
    An explicit `null` is a present value, decoded as such. -/
def jsonFieldOr [Lean.FromJson α] (json : Json) (key : String) (dflt : Unit → α) :
    Except String α :=
  match json.getObjVal? key with
  | .ok v => Lean.fromJson? v
  | .error _ => .ok (dflt ())

def DbError.toJson (e : DbError) : Json :=
  Json.mkObj [("ok", Json.bool false), ("code", Json.str e.code),
    ("message", Json.str e.message)]

def ColumnSpec.toJson (c : ColumnSpec) : Json :=
  Json.mkObj <|
    [("name", Json.str c.name), ("type", Json.str c.sqlType.render),
     ("nullable", Json.bool c.nullable)]
    ++ (c.fkTable.map fun fk => ("references", Json.str fk)).toList
    ++ (c.enum.map fun vs => ("enum", Json.arr (vs.map Json.str))).toList
    ++ (c.enumSet.map fun vs => ("enumSet", Json.arr (vs.map Json.str))).toList
    ++ (c.dflt.map fun v => ("default", v.toJson)).toList
    ++ (c.shape.map fun s => ("shape", Json.str s)).toList

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
  let enumSet := (j.getObjVal? "enumSet").toOption.bind fun a =>
    (a.getArr?.toOption).map fun vs => vs.filterMap (·.getStr?.toOption)
  let partial_ : ColumnSpec := { name, sqlType, nullable, fkTable, enum, enumSet }
  -- default roundtrips through the column's own type (stored schema JSON
  -- must decode identically or migrations would see phantom diffs)
  let dflt := (j.getObjVal? "default").toOption.bind fun v =>
    (Col.fromJson partial_ v).toOption
  let shape := (j.getObjVal? "shape").toOption.bind (·.getStr?.toOption)
  return { partial_ with dflt, shape }

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
    (fields.toList.map fun (c, v) => (c.name, v.toJsonFor c))

/-- The columns of `α` with whether each is derived, in declaration order. -/
private def columnsWithDerived (α : Type) [Entity α] : Array (ColumnSpec × Bool) :=
  (Entity.fields (α := α)).map fun f => (Entity.fieldSpec f, Entity.isDerived f)

/-- Decode a full row from JSON field-by-field, then through the entity's
    codecs (and thus every smart constructor). An omitted field takes its
    declared default; without one it is `null` if the column is nullable
    and a typed error otherwise. An explicit JSON `null` is always `null`,
    default or not. A derived column is recomputed from its sources: it
    may be omitted, and a supplied value is ignored. -/
def rowOfJson (α : Type) [Entity α] (j : Json) : Except DbError α := do
  let table := Entity.tableName α
  let obj ← match j with
    | .obj obj => .ok obj
    | _ => .error (.decode table "*" "expected a JSON object")
  let known := (Entity.columns α).map (·.name)
  for (name, _) in obj.toList do
    unless known.contains name do
      throw (.decode table name s!"unknown field; fields: {known.toList}")
  let cols ← (columnsWithDerived α).mapM fun (c, derived) =>
    if derived then .ok .null else
    match j.getObjVal? c.name with
    | .ok v =>
        match Col.fromJson c v with
        | .ok col => .ok col
        | .error m => .error (.decode table c.name m)
    | .error _ =>
        match c.dflt with
        | some col => .ok col
        | none =>
            if c.nullable then .ok .null
            else .error (.decode table c.name "missing required field")
  Entity.decodeRecomputing cols

/-- Overlay a partial JSON object onto an existing row at the column level,
    then re-decode — validation applies to the merged result. This is the
    CLI's `update <table> <id> <partial-json>`. Derived columns are
    recomputed from the merged sources, never kept from the old row. -/
def rowMergeJson (α : Type) [Entity α] (base : α) (j : Json) : Except DbError α := do
  let table := Entity.tableName α
  let obj ← match j with
    | .obj obj => .ok obj
    | _ => .error (.decode table "*" "expected a JSON object")
  let known := (Entity.columns α).map (·.name)
  for (name, _) in obj.toList do
    unless known.contains name do
      throw (.decode table name s!"unknown field; fields: {known.toList}")
  let cols ← ((columnsWithDerived α).zip (Entity.encode base)).mapM fun ((c, derived), old) =>
    if derived then .ok .null else
    match j.getObjVal? c.name with
    | .ok v =>
        match Col.fromJson c v with
        | .ok col => .ok col
        | .error m => .error (.decode table c.name m)
    | .error _ => .ok old
  Entity.decodeRecomputing cols

end LeanDb
