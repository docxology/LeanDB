namespace LeanDb

/-! # Core typed values

The scalar layer: how a Lean value lives in a SQL column, with typed errors.
No domain knowledge lives here; entity structure lives in `LeanDb.Entity`.
-/

/-- A SQL storage class. LeanDB v1 uses INTEGER, TEXT, and REAL. -/
inductive SqlType where
  | integer
  | text
  | real
  deriving Repr, DecidableEq, Inhabited

def SqlType.render : SqlType → String
  | .integer => "INTEGER"
  | .text => "TEXT"
  | .real => "REAL"

/-- A value in a SQL column. -/
inductive Col where
  | int (v : Int64)
  | text (v : String)
  | real (v : Float)
  | null
  deriving Repr, Inhabited, BEq

def Col.describe : Col → String
  | .int v => s!"INTEGER {v}"
  | .text v => s!"TEXT {String.quote v}"
  | .real v => s!"REAL {v}"
  | .null => "NULL"

/-- Typed database errors. Constructors are the machine-readable codes;
    the `String` fields are diagnostics, never identity. -/
inductive DbError where
  /-- A stored value failed to decode as its column's Lean type. -/
  | decode (table field message : String)
  /-- Row addressed by id does not exist. -/
  | notFound (table : String) (id : Int64)
  /-- Compare-and-swap `update` lost a race: the row no longer equals `old`. -/
  | stale (table : String) (id : Int64)
  /-- Delete refused because other rows reference this one (FK RESTRICT). -/
  | restricted (table : String) (id : Int64)
  /-- A uniqueness constraint rejected the write. -/
  | duplicate (table detail : String)
  /-- The instance's schema fingerprint does not match the code's. -/
  | schemaMismatch (expected actual : String)
  /-- A stored value is outside its column's closed world — the vocabulary
      moved without a migration. -/
  | enumDrift (table column value : String)
  /-- A migration was refused or failed; the message says why. -/
  | migrate (message : String)
  /-- Raw SQLite error that no typed constructor claims. -/
  | sqlite (message : String)
  deriving Repr

def DbError.code : DbError → String
  | .decode .. => "decode"
  | .notFound .. => "not_found"
  | .stale .. => "stale"
  | .restricted .. => "restricted"
  | .duplicate .. => "duplicate"
  | .schemaMismatch .. => "schema_mismatch"
  | .enumDrift .. => "enum_drift"
  | .migrate .. => "migrate"
  | .sqlite .. => "sqlite"

def DbError.message : DbError → String
  | .decode table field msg => s!"{table}.{field}: {msg}"
  | .notFound table id => s!"{table}: no row with id {id}"
  | .stale table id => s!"{table}: row {id} changed since it was read"
  | .restricted table id => s!"{table}: row {id} is referenced by other rows"
  | .duplicate table detail => s!"{table}: {detail}"
  | .schemaMismatch expected actual =>
      s!"schema fingerprint mismatch: code has {expected}, instance has {actual}"
  | .enumDrift table column value =>
      s!"{table}.{column}: stored value {String.quote value} is not in the closed world"
  | .migrate msg => msg
  | .sqlite msg => msg

instance : ToString DbError := ⟨fun e => s!"[{e.code}] {e.message}"⟩

/-- Process exit code for a failed command (plan.md §4.5): fingerprint
    drift is 4, every other typed error is 2. Matching on the constructor,
    not the code string — strings are diagnostics, never identity. -/
def DbError.exitCode : DbError → UInt32
  | .schemaMismatch .. => 4
  | _ => 2

/-- Typed row identity: `Id User` and `Id Ticket` are distinct types. -/
structure Id (α : Type) where
  toInt64 : Int64
  deriving DecidableEq, Repr, Hashable

instance : BEq (Id α) := ⟨fun a b => a.toInt64 == b.toInt64⟩
-- manual: the derived instance would demand `Ord α` for a phantom parameter
instance : Ord (Id α) := ⟨fun a b => compare a.toInt64 b.toInt64⟩

/-- A foreign reference to a row of `α`. Definitionally an `Id α`, so a
    `Ref` field compares directly against a fetched row's id. -/
abbrev Ref (α : Type) := Id α

/-- A row as it exists in the database: its identity plus its value. -/
structure Stored (α : Type) where
  id : Id α
  val : α
  deriving Repr

/-- The reference other rows use to point at this row. -/
abbrev Stored.ref (s : Stored α) : Ref α := s.id

/-- How a scalar type lives in one SQL column. Decoding is total over
    honest data and *typed-fails* over anything else — a value that does
    not pass its type's validation never enters the program. -/
class ColCodec (α : Type) where
  sqlType : SqlType
  nullable : Bool := false
  toCol : α → Col
  fromCol : Col → Except String α

export ColCodec (toCol fromCol)

/-- Build a codec for a validated newtype from the codec of its raw
    representation and its smart constructor. -/
@[reducible] def ColCodec.via [ColCodec β] (enc : α → β) (dec : β → Except String α) : ColCodec α where
  sqlType := ColCodec.sqlType β
  nullable := ColCodec.nullable β
  toCol a := toCol (enc a)
  fromCol c := do dec (← fromCol c)

private def expected (want : String) (got : Col) : Except String α :=
  .error s!"expected {want}, found {got.describe}"

instance : ColCodec Int64 where
  sqlType := .integer
  toCol := .int
  fromCol
    | .int v => .ok v
    | c => expected "INTEGER" c

/-- `Nat` stores as INTEGER. Values ≥ 2^63 are not representable in a
    SQLite INTEGER and wrap on encode; model such magnitudes explicitly
    rather than reaching them through a `Nat` column. -/
instance : ColCodec Nat where
  sqlType := .integer
  toCol n := .int (Int64.ofNat n)
  fromCol
    | .int v => if v < 0 then .error s!"expected Nat, found {v}" else .ok v.toNatClampNeg
    | c => expected "INTEGER" c

instance : ColCodec UInt32 := ColCodec.via (β := Int64) (fun n => Int64.ofNat n.toNat)
  (fun v => if 0 ≤ v && v ≤ Int64.ofNat UInt32.size then .ok (UInt32.ofNat v.toNatClampNeg)
            else .error s!"UInt32 out of range: {v}")

instance : ColCodec UInt16 := ColCodec.via (β := Int64) (fun n => Int64.ofNat n.toNat)
  (fun v => if 0 ≤ v && v ≤ Int64.ofNat UInt16.size then .ok (UInt16.ofNat v.toNatClampNeg)
            else .error s!"UInt16 out of range: {v}")

instance : ColCodec Bool := ColCodec.via (β := Int64) (fun b => if b then 1 else 0)
  (fun | 0 => .ok false | 1 => .ok true | v => .error s!"expected 0 or 1, found {v}")

instance : ColCodec String where
  sqlType := .text
  toCol := .text
  fromCol
    | .text v => .ok v
    | c => expected "TEXT" c

instance : ColCodec Float where
  sqlType := .real
  toCol := .real
  fromCol
    | .real v => .ok v
    | .int v => .ok v.toFloat
    | c => expected "REAL" c

instance : ColCodec (Id α) := ColCodec.via (β := Int64) Id.toInt64 (fun v => .ok ⟨v⟩)

instance [ColCodec α] : ColCodec (Option α) where
  sqlType := ColCodec.sqlType α
  nullable := true
  toCol
    | none => .null
    | some a => toCol a
  fromCol
    | .null => .ok none
    | c => .some <$> fromCol (α := α) c

/-- A closed world: a payload-free inductive whose constructors are the
    complete vocabulary. Instances come from `deriving LeanDb.ClosedEnum`.
    Closed types are not entities — they have no table of their own to
    insert into or delete from; changing the vocabulary is a code change. -/
class ClosedEnum (α : Type) where
  variants : Array String
  encodeName : α → String
  decodeName : String → Option α

/-- Closed enums store as TEXT constructor names, guarded by a CHECK
    constraint in the DDL and a drift scan at open. -/
instance [ClosedEnum α] : ColCodec α where
  sqlType := .text
  toCol a := .text (ClosedEnum.encodeName a)
  fromCol
    | .text s =>
        match ClosedEnum.decodeName (α := α) s with
        | some a => .ok a
        | none => .error s!"{String.quote s} is not in the closed world"
    | c => expected "TEXT" c

/-- Closed-world metadata for a column type, for CHECK generation and the
    open-time drift scan. -/
class ColEnum (α : Type) where
  variants : Option (Array String) := none

instance (priority := 50) : ColEnum α := ⟨none⟩
instance [ColEnum α] : ColEnum (Option α) := ⟨ColEnum.variants α⟩
instance (priority := 100) [ClosedEnum α] : ColEnum α := ⟨some (ClosedEnum.variants α)⟩

/-- Foreign-key metadata for a column type. The catch-all instance says
    "not a reference"; `LeanDb.Entity` provides the `Id β` instance. -/
class RefTarget (α : Type) where
  target : Option String := none

instance (priority := 50) : RefTarget α := ⟨none⟩
instance [RefTarget α] : RefTarget (Option α) := ⟨RefTarget.target α⟩

/-- One column of a table, fully described. Derived from types — never
    written by hand outside the deriving machinery. -/
structure ColumnSpec where
  name : String
  sqlType : SqlType
  nullable : Bool
  fkTable : Option String
  enum : Option (Array String) := none
  /-- Declared default, as an evaluated column value — emitted as a SQL
      `DEFAULT`, used when incoming JSON omits the field, and what lets a
      migration add a NOT NULL column to existing rows. -/
  dflt : Option Col := none
  deriving Repr, BEq, Inhabited

/-- The single way a `ColumnSpec` is made: from a field's type. -/
def columnSpec (name : String) (α : Type) (dflt : Option Col := none)
    [ColCodec α] [RefTarget α] [ColEnum α] : ColumnSpec where
  name := name
  sqlType := ColCodec.sqlType α
  nullable := ColCodec.nullable α
  fkTable := RefTarget.target α
  enum := ColEnum.variants α
  dflt := dflt

structure TableSpec where
  name : String
  columns : Array ColumnSpec
  deriving Repr, BEq

/-- Decode one column, attaching table/field context to failures. -/
def decodeField (table field : String) (α : Type) [ColCodec α] (c : Col) : Except DbError α :=
  match fromCol c with
  | .ok a => .ok a
  | .error msg => .error (.decode table field msg)

end LeanDb
