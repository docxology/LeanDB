# kernels — GPU kernels, typed signatures, programs, per-SKU benches

The base from `proposals/stress-domains-kernels-restaurants.md` §1, built
against the engine as it is (ROADMAP R2), then moved onto LEP-0003 stages
B, A, C and D as they landed. Its job is to make the nested-values
decision concrete: `KernelSig` (variables, scalars, constraints) lives in
**one JSON column with a declared shape**, the inputs and outputs are
**child tables** (`kernel_ins`/`kernel_outs`, one row per tensor, part of
the kernel's value) over which per-input questions push as LEP-0004
quantifiers, the common filters go through **derived search columns** the
engine recomputes and checks, the fused-op set is an **`EnumSet` bitmask**
whose membership pushes, the launch configuration and numeric properties
are **inline structures** flattened into sibling columns by the derive,
and everything that looks *inside* a tensor type — instantiation,
unification, composition into `Prog ins outs` — is Lean.
`Bench.sku` is gpumarket's `Gpu`: the first cross-base type reuse, and
its datasheet (`Gpu.spec`, `Gpu.tflops`) drives `roofline`.

```
Kernels/Enums.lean     DType OpKind Lang Arch MemSpace License; Arch.supports (@[db]), Arch.ofGpu
Kernels/Scalars.lean   Micros MilliTflops Permille KernelName Variant SourceHash … DimVar DimBinding
Kernels/Sig.lean       Dim Layout LayoutKind TensorTy DimConstraint KernelSig (make, codec, checkTensors, instantiate) KernelInput (Inline), unify
Kernels/Entities.lean  Kernel (ins/outs child tables, launch/numeric inline, fuses : EnumSet OpKind) Bench Program ProgramNode ProgramEdge; LaunchConfig NumericProps; Kernel.make
Kernels/Prog.lean      Prog ins outs; launches, estimate, emit (skeleton), ofRows (the gate)
Kernels/Queries.lean   candidates fusing fitsSmem reproducible highRank allHighRank anyColMajor exactlyTwoInputs fastest composable synthesize regressions roofline program kernelInfo
Kernels/Seed.lean      14 kernels, 19 benches (illustrative), one stored program
```

```bash
cd examples/kernels
lake build kernels kernels_tests && ./.lake/build/bin/kernels_tests
k=./.lake/build/bin/kernels
$k query seed
$k query synthesize gemm,rmsNorm h100Sxm M=4096,N=4096,K=4096
$k query regressions h100Sxm
$k query fusing silu
$k query fitsSmem 100000
$k query allHighRank 3
$k query anyColMajor
$k log 5
```

`CLI_TRANSCRIPT.md` is the full session from a fresh `data/` dir. The
`lakefile.toml` requires both `leandb` and `gpumarket` by path; nothing
about gpumarket's own `defaultTargets` needed changing.

## What is typed where

- **Row layer.** `Kernel.sig : KernelSig` — the shape variables, scalar
  arguments and constraints — is `ColCodec.json KernelSig
  KernelSig.validate`: one `TEXT` column of compressed JSON whose
  *shape* (`JsonShape`, from `deriving LeanDb.DbJson`) is in the schema
  and the fingerprint. The codec validates through `KernelSig.make`, so a
  constraint over an undeclared variable is refused by the SQLite codec
  and by the CLI's `insert` alike (transcript: `kernel.sig: shape
  variable K is used but not declared in vars`, exit 2). `Kernel.ins`
  and `Kernel.outs` are `List KernelInput` — **child tables**
  `kernel_ins`/`kernel_outs` (LEP-0003 D): one row per tensor with
  `parent` (a cascading FK), `position`, and the record's columns
  `dtype`, `rank`, `layoutKind` (a closed world) and `full` (the whole
  `TensorTy` as a JSON column). The lists are part of the value: every
  read reattaches them, `insert`/`update` write them in the parent's
  transaction, `delete` cascades. The cross-check between a signature and
  its tensors (every variable declared, outputs determined, one of each)
  spans parent and child rows and is `Kernel.make`'s
  (`KernelSig.checkTensors`) — the engine has no whole-value validator
  across tables. `inDtype0`/`outDtype0`/`rank0` are
  `derived` from the first input: the engine recomputes them on every
  write and checks them on every read, once the list is attached.
  `DimBinding` is canonical TEXT
  (`K=4096,M=4096,N=4096`, sorted, no duplicates), so equality pushes as
  `binding IS ?` and the same binding typed in any order matches.
  `fuses : EnumSet OpKind` is an INTEGER bitmask — bit *k* is `OpKind`'s
  *k*-th constructor — with `CHECK (("fuses" & ~1048575) = 0)` in the
  DDL, an open-time scan for bits outside the world, the names in the
  fingerprint, and `["silu"]` in row JSON; `k.val.fuses.contains op`
  pushes as `("fuses" & ?) != 0`. `launch : LaunchConfig` and `numeric :
  NumericProps` are `deriving LeanDb.Inline`: the entity derive flattens
  them into `launch_block`/`launch_smemBytes`/`launch_stages` and
  `numeric_deterministic`/`numeric_accum`, each a symbol of
  `Kernel.Field`, so `k.val.launch.smemBytes ≤ n` pushes as
  `launch_smemBytes <= ?`; row JSON shows `"launch": {…}` and takes
  either spelling.
- **Program layer.** `Prog : List TensorTy → List TensorTy → Type` with
  `kernel` (a `Stored Kernel`, a binding, and a proof that the signature
  instantiates to the node's edge types), `id`, `seq`, `par`, `swap`,
  `dup`. `seq` demands the middle types agree definitionally, so
  `#check_failure Prog.seq (par gemmF32 (id [w])) norm` — an f32 GEMM
  into a bf16 norm — is refused by the compiler (`KernelsTests.lean`).
  `Prog.ofRows` re-types the relational program or names why not;
  `Prog.emit` produces a host-program *skeleton* (launch order, buffer
  names, dtype/shape per edge — not CUDA); `Prog.estimate` sums benches.
- **Queries.** `candidates` pushes every conjunct (`Arch.supports` becomes
  a case split over `minArch`, folded at plan build to the disjunction of
  the architectures the captured arch supports); `fusing` is one pushed
  bit test; `highRank`/`allHighRank`/`anyColMajor` are quantifiers over
  `kernel_ins` (`.all` → `NOT EXISTS`, `.any` → `EXISTS`), residual 0;
  `exactlyTwoInputs` (`ins.length == 2`) is an aggregate and stays
  residual; `fastest` is a pushed join sorted client-side;
  `regressions` is a pushed self-join with the 10% arithmetic residual;
  `composable` narrows on `inDtype0` then unifies in Lean; `synthesize`
  searches candidates depth-first, threading edge types, and returns
  `Σ ins outs, Prog ins outs` (the CLI renders it). `roofline` is Lean
  arithmetic over gpumarket's datasheet. `perDollar` (benches ×
  gpumarket *listings*) is not here: it needs gpumarket's *instance*,
  and `Conn` is one file (study §3.7).

## Evidence for LEP-0003: what the opaque column could not do

Everything below was measured on this base (`set_option leandb.explain
true`, `kernels log`); residual counts are from the tactic. The first
three paragraphs are the record as it was measured against the R2
engine; **"What stage B changed"**, **"What stage A changed"**, **"What
stage C changed"** and **"What stage D changed"** at the end of the
section say which of it no longer holds.

**Predicates I wanted over `sig` and could not push.** Each is one
`select [Kernel]` conjunct that reads the JSON column; each is `residual
conjuncts: 1` and a full-table fetch, with the lambda doing the work:
`k.val.sig.ins.length == 2` ("exactly two inputs"),
`k.val.sig.ins.any (·.layout == .colMajor)`, `k.val.sig.ins.all (·.rank ≥ 3)`
(the `highRank` query: `pushed: t0."rank0" >= ?, residual conjuncts: 1` —
the search column narrows, the honest predicate does not),
`k.val.sig.constraints.any (· matches .divides ..)` ("has a divisibility
constraint"), and the same for the second nested column,
`k.val.launch.smemBytes ≤ 100000`. Two more of the same shape:
`m.val.binding.lookup M ≥ 8192` over the canonical binding TEXT, and
`k.val.fuses.contains .silu` over the canonical set TEXT — both columns
push *equality* and nothing else. `composable` is the query that pays:
for a bf16 output the search column admits 11 of 14 kernels and Lean
unification keeps 9 (the two rank-4 attention kernels go); for f32 it
admits 1. Fine at 14 rows, a scan at 14,000.

**What the search columns bought and cost.** `inDtype0`/`outDtype0`/
`rank0` make `candidates` and `composable` push with residual 0. The
cost is three facts stored twice with no engine-visible link: the
invariant lives in `Kernel.make` only. The transcript inserts a row
through the CLI whose `sig` is `bf16[M] → bf16[M]` and whose columns say
`f64`/`f64`/rank 7; it is accepted (exit 0), and only
`kernelInfo … search_columns_agree:false`, a Lean check, sees it. The
tests do the same with `update` of `sig` alone. Every new pushable
question ("exactly two inputs") is another column plus a migration; the
columns cover the *first* input only, because a fixed set of columns
cannot describe a list. This is study §3.2 made concrete: the derive
needs proof fields (or a decode-time check) before search columns are
honest under `update`.

**What `migrate` cannot see.** The fingerprint is a hash of the DDL, and
the DDL for the column is `"sig" TEXT NOT NULL` whatever `KernelSig`
looks like. Add `stride : Nat := 1` to `TensorTy`, rebuild: `version`
reports `in_sync:true`, `migrate status` says "schema already up to
date" — and the first `rows kernel` fails per-row with a `decode` error
on `kernel.sig`, because derived `FromJson` does not honor field
defaults (verified: a missing defaulted field decodes to
`T.stride: Natural number expected`). Remove a field instead and every
old row decodes silently with the stale key ignored — no journal entry,
no `--allow-destructive`. Rename a `Layout` constructor and the open-time
enum-drift scan does not fire either: it scans enum *columns*, and
`DType`/`MemSpace` inside `sig` are JSON strings it never reads. Every
guarantee the migration machinery gives to flat columns stops at the
JSON boundary.

**What `rows --eq` can and cannot do.** It filters the search columns and
enums fine (`--eq inDtype0=fp8e4m3`), it splits at the first `=` only, and
— since LEP-0002 stage 3 — the value goes through the column's codec like
every other boundary: `--eq binding=M=4096,N=4096,K=4096` is canonicalized
by `DimBinding.make` and matches the same seven benches as the stored
spelling `K=4096,M=4096,N=4096` (transcript). What it still cannot do is
look *inside* `sig` or `launch` at all — only a byte-exact
`--eq sig=<compressed JSON>` would match — so "first input is bf16" is
answerable only because `inDtype0` exists as a column.

**Inline-flattening `LaunchConfig`/`NumericProps`: yes, both.** (As
measured on R2; both are inline since stage C, below.) The base
did one of each on purpose. `NumericProps` is flattened by hand
(`deterministic`, `accum`): `k.val.deterministic && k.val.accum == .f32`
pushes as two `IS` tests. `LaunchConfig` is a second JSON column:
`smemBytes ≤ 100000` is residual, and `LaunchConfig.make`'s validation
is reachable only through the codec. Three scalars in a JSON string buy
nothing; the flattened form loses only the field grouping in row JSON,
which a derive can keep (`launch_block`, or a nested object on output).

**Which encoding to derive, for which fields.**
- *`deriving LeanDb.DbJson` for `KernelSig`* (the `@[dbJson]` this base
  first asked for) — recursive, variable-length, and only ever consumed
  whole by Lean; nothing else fits. Two additions the base showed were
  necessary, both landed as stage B: the fingerprint covers the derived
  codec's *type shape* so `migrate` sees a `TensorTy` change, and the
  search columns are *declared projections* of the JSON field
  (`inDtype0 := derived sig.inDtype0`) that `decode` checks and `encode`
  recomputes, so `update` and the CLI cannot desynchronize them.
- *Inline flatten for `LaunchConfig` and `NumericProps`* — small, fixed,
  scalar fields; full pushdown and migration visibility for free.
- *Child tables for `sig.ins`/`sig.outs`* (`KernelInput (kernel, position,
  dtype, rank, layoutKind)`) — the only encoding under which "any input
  column-major" and per-input rank push, and they push as LEP-0004's
  `exists`/`forall`; landed as stage D (below). "Exactly two inputs" is
  an aggregate and still does not. `ProgramEdge` already is one.
- *`EnumSet` for `fuses`* — landed as stage A (below): the canonical-TEXT
  set was the cheapest thing that worked and the cheapest thing to
  replace; membership is the one question a set is for, and it pushes now.
- *Canonical TEXT for `DimBinding`* is right as it is: equality is the
  only question asked of it, and it pushes.

**Things that turned out better than the study read.** `Arch.supports`
pushes with residual 0 in *either* form. Written as
`target.vendor == minimum.vendor && minimum.gen ≤ target.gen`, the case
split on the `minArch` column leaves closed value/value tests on the
captured `arch`, folded at plan build into `minArch IS 'sm80' OR … OR
minArch IS 'sm90'` (five branches for sm90). Written as a two-argument
`match` on the captured parameter first — the §3.4 trap, residual 1 on
the engine this base was first built against — the tactic now
case-splits the captured parameter too, and the plan is the same
disjunction with the parameter guards folded (`cmpVVS`) at plan build.
The base keeps the accessor form because it reads as the fact it states.
Self-joins, ordering through `Timestamp.epochSeconds` across `t0`/`t1`,
`Option Arch` as `IS NULL OR IS ?`, and gpumarket's `Gpu` as a `CHECK`ed
column all worked unchanged.

**What stage B changed (LEP-0003 B1–B3, this base rebuilt on it).**

- *B1 — `deriving LeanDb.DbJson`.* `Dim`, `Layout`, `TensorTy`,
  `DimConstraint` and `KernelSig` derive it instead of
  `Lean.ToJson`/`Lean.FromJson` (`LaunchConfig` did too, until stage C
  made it inline). The encoding is byte-identical to Lean's
  (the seed rows and the transcript's `sig` strings did not change), but
  an omitted field with a structure default now takes the default:
  `{"dtype":"bf16","shape":[]}` decodes as a `TensorTy` with
  `layout := rowMajor`, `mem := global`, `align := 16` (test). Adding
  `stride : Nat := 1` to `TensorTy` therefore no longer fails every old
  row on read — which is what lets B2 call that change safe.
- *B2 — shape.* Every JSON column carries a `shape` in `schema` and in
  `schema_json`, and the fingerprint hashes DDL **and** shapes (a schema
  with no JSON columns hashes exactly its DDL, so every other base's
  fingerprint is unchanged; this base's moved from `15002238114063248552`
  to the value in the transcript). The shape of `sig` is the whole
  `KernelSig` type, recursively, closed enums by their variant list:

  ```
  KernelSig{vars:[String],ins:[TensorTy{dtype:<f64|f32|tf32|bf16|f16|fp8e4m3|fp8e5m2|fp4e2m1|int8|int4|int32|uint8|bool>,shape:[Dim(lit{n:Nat}|var{v:String}|mul{k:Nat,d:Dim}|add{a:Dim,b:Dim}|div{d:Dim,k:Nat})],layout:Layout(rowMajor|colMajor|strided{strides:[Dim(…)]}|tiled{tile:[Nat],inner:Layout})=,mem:<global|shared|register|constant>=,align:Nat=}],outs:[TensorTy{…}],scalars:[(String,<f64|…|bool>)],constraints:[DimConstraint(divides{k:Nat,d:Dim(…)}|le{a:Dim(…),b:Dim(…)}|eq{a:Dim(…),b:Dim(…)})]}
  ```

  (`=` marks a field with a default; the transcript has it unabridged.)
  So the three "what `migrate` cannot see" cases of the record are now:
  add `stride : Nat := 1` to `TensorTy` → `version` says `in_sync:false`,
  `migrate status` plans `restamp shape of "kernel"."sig"` (no SQL — the
  step exists to be journaled), `migrate apply` restamps and every old
  row decodes; remove a field → refused: `column "sig" changed shape —
  field `align` removed from `TensorTy` … a typed value transformation
  is not yet available`; rename a `Layout` constructor → refused naming
  `constructor `tiled` renamed/removed from `Layout``; shrink `DType`
  → refused naming the variant. The engine tests (`Tests.lean`, `Lep3`)
  pin each of these on two `TableSpec`s that differ only in one
  column's shape, plus the restamp end to end (journaled, fingerprint
  moved, the old code refused at open with exit 4).
- *B3 — derived columns.* `inDtype0 := derived sig.inDtype0`,
  `outDtype0 := derived sig.outDtype0`, `rank0 := derived sig.rank0`.
  `Kernel.make` no longer fills them and `Kernel.searchColumnsAgree` is
  gone, as is `kernelInfo`'s `search_columns_agree` — there is nothing
  left to check in Lean: `encode` recomputes the three from `sig` (the
  transcript's `lying-columns` insert is stored with `bf16`/`bf16`/1,
  whatever the JSON said; JSON may omit them), `decode` compares the
  stored value with the recomputation and fails with
  `decode` naming the column if they differ. The tests' "update of `sig`
  alone leaves the search columns stale" became "update of `sig` alone
  recomputes them", and a raw `UPDATE kernel SET "inDtype0"='f64'` makes
  the next `fetchAll Kernel` fail with `kernel.inDtype0: derived column
  disagrees with its source`. Lean does not allow attributes on structure
  fields, so the mark is the `derived` wrapper in the default rather than
  the `@[derived]` the LEP wrote.

**What stage A changed (LEP-0003 A, `EnumSet`).** `fuses` moved from
"canonical TEXT, equality only" to `EnumSet OpKind`: one INTEGER column
holding a bitmask, bit *k* for `OpKind`'s *k*-th constructor. What that
bought, each shown in the transcript and pinned in `KernelsTests`:

- *Membership pushes.* `fusing op` is `select [Kernel] (fun k =>
  k.val.fuses.contains op)`; the log line is `kernel | pushed:
  ((t0."fuses" & ?) != 0), residual conjuncts: 0`, the bound value the
  op's bit. `!(k.val.fuses.contains .silu)` is the same test against
  `= 0` — one `Pred.bit` leaf whose negation flips a flag, so it stays
  exact under `!`. `op ∈ k.val.fuses` is accepted too. `--eq fuses=1024`
  is set *equality* through the codec, not membership — the CLI filter is
  still `IS`.
- *The world is in the schema.* The DDL says `CHECK (("fuses" & ~1048575)
  = 0)` — the mask of 20 variants — so a raw write of bit 20 is refused
  by the file; the open-time drift scan runs the same test for bits
  written under an older world; the fingerprint hashes the variant
  *names* (the DDL sees only the mask, and a renamed variant changes
  what a stored bit means); `schema` lists them as `enumSet`. This
  base's fingerprint moved from `535084016606190269` to the transcript's.
- *Growing the world is a rebuild that keeps every bit; shrinking it is
  refused by the data.* Appending an `OpKind` constructor changes the
  mask, so `migrate` rebuilds the table (old rows keep their bits);
  removing the last constructor rebuilds under the smaller CHECK, which
  fails on any row still using that bit and rolls back — exactly as
  closed-enum columns behave. Removing a constructor from the *middle*,
  or reordering, would silently re-label the bits above it, so
  `migrate` refuses it by name ("changed its variant order"). The
  engine tests cover all three on a two-column table.
- *JSON is names.* Row JSON shows `"fuses":["silu"]`; `insert` takes an
  array of names (`"swish"` is refused naming the world) or the bare
  mask for round-tripping (bit 20 is refused by index: `kernel.fuses:
  bit 20 is not in the closed world (20 variants)`). The `FusedOps`
  scalar, its codec and its `make` are deleted.

**What stage C changed (LEP-0003 C, inline flatten).** `LaunchConfig`
and `NumericProps` are `deriving LeanDb.Inline`; `Kernel` has `launch :
LaunchConfig` and `numeric : NumericProps`, and the hand-flattened
`deterministic`/`accum` fields are gone. The entity derive flattens both
at derive time — it synthesizes `Inline` for each field's type — into
sibling columns `launch_block`, `launch_smemBytes`, `launch_stages`,
`numeric_deterministic`, `numeric_accum`, one symbol each
(`Kernel.Field.launch_smemBytes`), with the sub-field's type, codec and
default (`launch_stages INTEGER NOT NULL DEFAULT 1`; `numeric_accum`
keeps `DType`'s CHECK) and a `group` naming the parent field. What that
bought, each in the transcript and pinned in `KernelsTests`:

- *The JSON column's residual is gone.* `fitsSmem n` is `select [Kernel]
  (fun k => k.val.launch.smemBytes ≤ n)`; the log line is `kernel |
  pushed: t0."launch_smemBytes" <= ?, residual conjuncts: 0`. The tactic
  learned one shape — a projection of a field whose type is `Inline` is
  the flattened symbol — and nothing else: `Col.here` of a generated
  symbol, so the `via` newtype machinery composes on top unchanged (the
  engine tests push `b.val.size.w.v ≤ 5` through a newtype sub-field).
  `reproducible accum` is `k.val.numeric.deterministic &&
  k.val.numeric.accum == accum`, pushed as two `IS` tests — what the
  hand-flattening gave, with the grouping kept in the type.
- *Migrations, DDL and `rows --eq` see plain columns.* `--eq
  launch_smemBytes=232448` finds the fp8 GEMM; adding an inline field to
  an entity is one `add column` per sub-field (engine test); the
  fingerprint is the DDL's — the group is not material, so every other
  base's fingerprint is unchanged and this base's moved from
  `12236197873572621045` to the transcript's because the columns did.
- *Row JSON keeps the grouping.* Output nests `"launch": {"block": 384,
  "smemBytes": 232448, "stages": 4}` and `"numeric": {…}`; `insert` and
  `update` take the nested object or the flat keys (`launch_block`), a
  sub-field omitted in either form takes its column default, a column
  given in both forms is refused naming it (`kernel.launch_block: given
  twice`), an unknown sub-field by name (`kernel.launch_grid`). `schema`
  shows `"group":"launch"` on each flattened column.
- *What moved off the codec.* `LaunchConfig.make` (block a positive
  multiple of 32 up to 1024, shared memory that fits some arch, positive
  stages) is no longer run by a codec — an inline value has no codec of
  its own; each sub-column is checked by its *type*. The base's own
  writes go through `make`; a CLI insert of `{"block": 7}` is accepted
  as a row. Making those checks column-level is a matter of giving the
  fields validated newtypes, which the flattening supports (the engine
  test's `Dims.w : Milli`); the base keeps plain `Nat`s so the pushed
  predicate reads as `smemBytes ≤ n`.
- *Refused by name at derive time:* `Option LaunchConfig` ("all
  sub-columns NULL" is ambiguous once a sub-field is nullable — use a
  JSON column), an `Inline` field inside an `Inline` structure (one level
  for now), a `derived` default of an inline type.

**What stage D changed (LEP-0003 D, child tables).** `KernelSig` lost
`ins`/`outs`; `Kernel` has `ins : List KernelInput` and `outs : List
KernelInput`, where `KernelInput` is `deriving LeanDb.Inline` with
`dtype`, `rank`, `layoutKind : LayoutKind` (a closed enum derived from
`Layout`) and `full : TensorTy` (the whole type, a JSON column with a
shape — an inline field may be one). The entity derive generated two
child entities, `Kernel.Ins` and `Kernel.Outs` — tables `kernel_ins` and
`kernel_outs` with `parent : Ref Kernel` (`ON DELETE CASCADE`, the one
cascade in the engine), `position : Nat`, then the record's columns —
and `Entity.specs Kernel` lists all three tables. What that bought, each
in the transcript and pinned in `KernelsTests` and the engine tests:

- *The per-input questions push.* `highRank n` is `k.val.rank0 ≥ n &&
  k.val.ins.all (·.rank ≥ n)`; its log line is `kernel | pushed:
  (t0."rank0" >= ? AND NOT EXISTS (SELECT 1 FROM "kernel_ins" AS s0 WHERE
  s0."parent" IS t0."id" AND s0."rank" < ?)), residual conjuncts: 0` —
  the "smallest honest example of the gap" (residual 1 above) has no
  residual. `allHighRank n` is the quantifier alone; `anyColMajor` is
  `k.val.ins.any (·.layoutKind == .colMajor)`, pushed as `EXISTS (… AND
  s0."layoutKind" IS ?)`. The tactic learned one shape: `xs.any f` /
  `xs.all f` with `xs` a child-list field reifies to LEP-0004's
  `exists`/`forall` with the row's `Col.id` as parent, the child's
  `parent` symbol as key, and the lambda body reified over `Kernel.Ins ::
  ts` with `i` replaced by the record rebuilt from the child row — so
  `i.rank` is the child's `rank` column and nothing else in `colOf?`
  changed. The same plan written as data (`Pred.all (.here
  Kernel.Ins.Field.parent) (pred% …)`) renders byte-identically and
  returns the same rows (test). A body the tactic cannot translate makes
  the whole quantifier one opaque leaf; the lambda decides over the
  attached list.
- *"Exactly two inputs" is still residual*, and says so in its docstring:
  `ins.length == 2` is an aggregate over the child rows (`pushed: 1,
  residual conjuncts: 1` in the transcript). LEP-0004 names the
  expressible-but-ugly spelling; an aggregate verb is a later LEP.
- *The list is part of the value.* `Stored Kernel` carries both lists on
  every read path (`get`, `fetchAll`, the filtered fetch, the joined
  executor): one engine-internal `SELECT … FROM kernel_ins WHERE parent
  IN (…) ORDER BY parent, position` per child table per fetch, chunked at
  500 ids — not one per row. `insert` writes the parent then the child
  rows in one transaction (a dangling `Ref` inside a record rolls the
  parent back); `update` keeps its CAS on the kernel's own columns and
  then replaces both lists wholesale in the same transaction (the tests
  swap a GEMM's lists for the RMSNorm's and read the derived columns
  back recomputed); `delete` cascades to the child rows while a bench's
  `Ref Kernel` still RESTRICTs (transcript: `delete kernel 15` takes its
  two `kernel_ins` rows, `delete kernel 1` is `restricted`).
- *The derived columns now read the first child.* `inDtype0 := derived
  ((ins.head?.map (·.dtype)).getD .f32)` and so on. `encode` recomputes
  them from the full value as before; `decode` cannot check them without
  the list, so the check moved to the moment the list is attached
  (`ChildLink.attach`) — the raw-SQL desync in the transcript is still
  refused by name, one read later than the column itself.
- *JSON and the CLI.* Row JSON carries `"ins": [{"dtype": …, "rank": …,
  "layoutKind": …, "full": "…"}, …]` with the position implicit;
  `insert` takes the arrays (omitted means empty), `update` replaces the
  list when given; `rows kernel_ins --eq dtype=bf16` filters the child
  table like any other, and `Main` lists `.of Kernel.Ins`/`.of
  Kernel.Outs` beside `.of Kernel`. `schema` shows `"cascade":true` on
  the `parent` column and the DDL says `ON DELETE CASCADE`, so the
  fingerprint moved (child tables are ordinary tables; adding one is a
  `createTable`, removing one is a destructive `dropTable` — engine
  tests).
- *What moved off the codec.* `KernelSig.make` used to refuse a signature
  whose tensors name an undeclared variable, and the column codec ran it,
  so the CLI refused such a row. The tensors are child rows now, and the
  check spans the parent row and its children: it is
  `KernelSig.checkTensors`, run by `Kernel.make` on the Lean side, and
  the CLI insert of a tensor over an undeclared variable is accepted as
  rows (the constraint-level check still runs through the codec:
  transcript's `bad-sig`). A whole-value validator across tables is a
  later hook, named here rather than approximated.
- *Refused by name at derive time:* `List` of a non-`Inline` type without
  a codec of its own, `Option (List R)`, a list inside an `Inline` record
  (one level), a `derived` child list (LEP-0005's mechanism), and a
  record field named `parent` or `position`.

**What still stands.** "Exactly two inputs" and every other aggregate
over the child rows is residual until an aggregate verb exists. `rows
--eq` still cannot look inside `sig` or a tensor's `full`. The three
search facts on a child row (`dtype`, `rank`, `layoutKind`) are kept
consistent with `full` by `KernelInput.ofTensorTy`, not by the engine —
an `Inline` record cannot carry a `derived` column, so a CLI insert can
write a child row whose `rank` disagrees with its `full`. And a
*refused* shape change is refused, not migrated: typed value
transformations are a later LEP.
