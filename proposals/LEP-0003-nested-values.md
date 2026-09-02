# LEP-0003: Nested values

| Field | Value |
|---|---|
| Status | Draft |
| Number | LEP-0003 |
| Created | 2026-09-01 |
| Target | Post-LEP-0002 |
| Primary goal | Structured field types that the schema, migrations and the planner can see |
| Evidence | `examples/kernels/README.md`, "Evidence for LEP-0003" |

## Summary

An entity's fields are scalars, `Option`s and `Ref`s. The kernel base
needed a signature (`KernelSig`: lists of tensor types with symbolic
shapes), a launch configuration (four scalars), numeric properties (two
scalars), a set of fused ops, and stored it all the only way the engine
allows — a JSON string in a TEXT column, with hand-maintained search
columns beside it. The README records what that cost, measured:

- every predicate reading inside the column is a full-table fetch;
- search columns cannot describe a list, are stored twice with no
  engine-visible link to the value they summarize, and desynchronize
  silently under `update`;
- the fingerprint, `migrate` and the enum-drift scan all stop at the JSON
  boundary: adding a field to `TensorTy` leaves `version` saying
  `in_sync:true` and then fails every row on read, because derived
  `FromJson` does not honour structure defaults; removing a field decodes
  silently; renaming a constructor inside the JSON is never scanned.

This proposal makes four encodings derivable, each for the shape of data
it fits, and gives the JSON one what it lacks: a **type shape** the
fingerprint and the migration diff can see, and **derived columns** the
engine computes and checks so a summary can never disagree with its
source.

| Encoding | Fits | Pushdown | Migration sees inside |
|---|---|---|---|
| A. `EnumSet α` bitmask | a set over a closed world (`fuses`) | membership | yes (a CHECK on the mask) |
| B. JSON column with a declared shape | recursive or variable-length values consumed whole (`KernelSig`) | none, by design; **derived columns** carry what must push | shape change is a named migration event |
| C. Inline flatten | small fixed structures (`LaunchConfig`, `NumericProps`) | full | yes |
| D. Child table | lists of records (`sig.ins`, `sig.outs`) | full, via LEP-0004 quantifiers | yes |

## Why do this

Ground rule 2 — the schema has one source, the types — is broken the
moment a field becomes JSON: the column's DDL is `TEXT NOT NULL` whatever
the Lean type says, so the type can change and the schema machinery
cannot know. The kernel base showed this is not theoretical: a one-field
addition to `TensorTy` passes `version`, passes `migrate status`, and
breaks `rows kernel`. Every guarantee LeanDB makes for flat columns
should either hold for nested ones or be *refused* by name.

The second reason is pushdown honesty. `inDtype0`/`outDtype0`/`rank0` are
the right idea — store what must push — implemented the only way the
engine allowed, which is the wrong way: three facts stored twice with
the invariant living in a smart constructor that `update` never runs.
The engine can own that invariant.

## Design

### A. `EnumSet α`

```lean
/-- A set over a closed world, stored as an INTEGER bitmask. Bit `k` is
    variant `k` in declaration order; the CHECK forbids bits outside the
    world. At most 62 variants (a positive Int64). -/
structure EnumSet (α : Type) [ClosedEnum α] where
  bits : UInt64
def EnumSet.contains (s : EnumSet α) (a : α) : Bool
instance [ClosedEnum α] : ColCodec (EnumSet α)      -- INTEGER
-- ColumnSpec gains `mask : Option UInt64`; DDL: CHECK (("col" & ~mask) = 0)
```

Pushdown: one new `Pred` constructor, `bit (c : Col ts (EnumSet α) i)
(a : α)`, rendering `(col & ?) != 0` and denoting through `contains`.
The tactic recognizes `s.contains a` on an `EnumSet` column. Growing the
world appends a bit — additive, `ALTER TABLE` is enough; shrinking it is a
rebuild whose new CHECK rejects rows still using the removed bit, exactly
as closed-enum columns behave today.

Smallest piece; lands first. Replaces kernels' canonical-TEXT `fuses`.

### B. JSON columns with a declared shape

Three parts.

**B1. A LeanDB JSON derive that honours defaults.** `deriving
LeanDb.Json` generates `ToJson`/`FromJson` where an omitted field with a
structure default takes the default — the behaviour `rowOfJson` already
has for rows, extended into nested values. This is what makes an
additive change to a nested type *decodable* against old rows, and it
is the reason B2 can classify such a change as safe.

**B2. Shape.** `deriving LeanDb.Json` also generates
`instance : JsonShape α` — a canonical description of the type: for a
structure, its fields with their types and whether each has a default;
for an inductive, its constructors and their payload types; recursively;
closed enums by their variant list. `ColumnSpec` gains
`shape : Option String`; `ColCodec.json` sets it. The fingerprint hashes
DDL **and** shapes, and `schema_json` stores shapes, so:

- a nested type change is a fingerprint mismatch at open (exit 4) — the
  instance refuses to pretend, as it does for a flat column;
- `planMigration` diffs shapes. **Additive with defaults** (fields added,
  each with a default; constructors added) is classified *safe*: no data
  step, restamp. **Anything else** (a field removed or retyped, a
  constructor removed or renamed, a nested enum shrunk) is refused with
  the reason naming the column and the change, until a typed value
  transformation exists (the "typed transformations coming soon" of the
  README — a future LEP; this one only makes the need loud);
- the enum-drift scan's gap closes as a consequence: a renamed
  constructor inside a JSON type is a shape change, caught at migrate.

**B3. Derived columns.** A field marked `@[derived]` with a default that
depends on earlier fields is a *computed* column:

```lean
structure Kernel where
  sig       : KernelSig
  @[derived] inDtype0 : DType := sig.ins.head!.dtype
  @[derived] rank0    : Nat   := sig.ins.head!.shape.length
```

The derive today warns that such a default "depends on other fields and
is not reified" and leaves the field ordinary. Under this proposal it
generates: `encode` **recomputes** the field from the others (the
supplied value is ignored, so a write through LeanDB cannot desynchronize
it); `decode` **checks** the stored value against the recomputation and
fails with `decode` naming the column if they differ (a raw-SQL write is
caught on read); JSON input may omit it. The column is otherwise ordinary
— it pushes. This is study §3.2's proof-field requirement met without
proof fields: the invariant is enforced on both sides of the boundary by
construction.

### C. Inline flatten

`deriving LeanDb.Inline` on a small flat structure (`LaunchConfig`)
generates the same `Field`/`fieldTy`/`get`/`codec`/`fieldSpec` surface as
`Entity` minus a table. When an entity has a field of an `Inline` type,
its derive flattens it: columns `launch_grid`, `launch_block`, …; symbols
`Kernel.Field.launch_grid`; `get` composes; `encode`/`decode` splice.
Row JSON nests them back under `launch` on output and accepts either
form on input. The planner needs nothing new: `k.val.launch.smemBytes ≤
n` is a projection through a structure whose codec is *not* a `via` —
so `colOf?` learns one more shape, "projection of an inline field",
resolved to the flattened symbol. Full pushdown, full migration
visibility, and `LaunchConfig.make` still validates on decode.

### D. Child tables

A field `ins : List KernelInput` where `KernelInput` is `Inline`-shaped
becomes a generated child entity `Kernel.ins` (table `kernel_ins`) with
`parent : Ref Kernel`, `position : Nat`, and the record's columns.
Writes are transactional (parent, then children); reads reassemble by
parent id; `Stored Kernel` carries the list. Predicates over the list
push through LEP-0004 (`forall`/`exists` over `kernel_ins`), which is
why D follows LEP-0004. Schema visibility is total: the child table is
an ordinary table.

D is the largest piece and the one with the most open questions
(ordering guarantees, partial updates, whether the list is part of
`Stored Kernel` or fetched on demand). This proposal names it and fixes
its relation to the others; its own design note precedes implementation.

## What is not in scope

- Typed value transformations for refused shape changes.
- Pushing predicates *into* JSON (SQLite's `json_extract` exists; the
  honest position is that anything worth filtering on is a derived
  column or a child row).
- D's implementation.

## Staging

1. **A — `EnumSet`** with `Pred.bit`; kernels' `fuses` switches; a golden
   for `s.contains .silu` and a migration test for growing/shrinking the
   world.
2. **B1 + B2 — JSON derive and shape.** kernels' `KernelSig` moves to
   `ColCodec.json`; the transcript demonstrates the `TensorTy` field
   addition now being a fingerprint mismatch, then a safe restamp;
   removing a field is refused by name.
3. **B3 — derived columns.** kernels' search columns become `@[derived]`;
   the transcript's "desynchronized search columns accepted" case becomes
   a `decode` refusal; `kernelInfo`'s Lean-side check is deleted.
4. **C — inline.** kernels' `LaunchConfig` flattens; `smemBytes ≤ n`
   pushes.
5. **D — child tables**, after LEP-0004, with its own note.

Each stage ends with the baseline replay (zero differences for plans that
existed before) and the release check.

## Alternatives considered

### JSON everywhere with `json_extract` pushdown

SQLite can index and filter on `json_extract(col, '$.ins[0].dtype')`.
That gives pushdown without a schema, which is exactly the trade LeanDB
refuses: the path string is stringly, the extracted value is untyped, and
migrations still cannot see the shape. Derived columns are the typed
form of the same idea.

### Proof fields for search-column invariants

Study §3.2's original answer. Proof fields are still planned; for this
invariant a recompute-on-write, check-on-read column is simpler, needs no
decidability of the proposition, and covers raw-SQL writes too.

### A general "sum type as column" encoding

Tagged columns (`kind TEXT, payload TEXT`) for payload-carrying sums.
Useful for a small sum at the top level of an entity; it does not help a
recursive `Dim` inside a list inside a signature. Left for a later note
if a base asks for it.

## Acceptance criteria

1. A: `#check (Pred.bit (.here Kernel.Field.fuses) .silu : Pred [Kernel])`;
   `k.val.fuses.contains .silu` pushes as `("fuses" & ?) != 0`, residual
   0; growing `OpKind` is an `ALTER`, shrinking with live bits rolls back.
2. B: adding a defaulted field to `TensorTy` → `version` reports
   `in_sync:false`; `migrate status` names the column and says "additive
   with defaults: restamp"; `migrate apply` restamps and every old row
   decodes. Removing a field → refused, naming column and field.
   Renaming a `Layout` constructor → refused.
3. B3: a CLI `insert` of a kernel whose `inDtype0` disagrees with `sig` is
   stored with the recomputed value; a raw-SQL `UPDATE` of `inDtype0` alone
   makes `rows kernel` fail with `decode` naming `kernel.inDtype0`.
4. C: `k.val.launch.smemBytes ≤ 100000` pushes with residual 0; row JSON
   shows `launch` as a nested object.
5. Every pre-existing plan in the eight-base baseline is byte-identical.
