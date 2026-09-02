# kernels — GPU kernels, typed signatures, programs, per-SKU benches

The base from `proposals/stress-domains-kernels-restaurants.md` §1, built
against the engine as it is (ROADMAP R2), then moved onto LEP-0003 stage
B as it landed. Its job is to make the nested-values decision concrete:
`KernelSig` lives in **one JSON column with a declared shape**, the
common filters go through **derived search columns** the engine
recomputes and checks, and everything that looks *inside* a signature —
instantiation, unification, composition into `Prog ins outs` — is Lean.
`Bench.sku` is gpumarket's `Gpu`: the first cross-base type reuse, and
its datasheet (`Gpu.spec`, `Gpu.tflops`) drives `roofline`.

```
Kernels/Enums.lean     DType OpKind Lang Arch MemSpace License; Arch.supports (@[db]), Arch.ofGpu
Kernels/Scalars.lean   Micros MilliTflops Permille KernelName Variant SourceHash … DimVar DimBinding FusedOps
Kernels/Sig.lean       Dim Layout TensorTy DimConstraint KernelSig (make, codec, instantiate), unify
Kernels/Entities.lean  Kernel Bench Program ProgramNode ProgramEdge; LaunchConfig; Kernel.make
Kernels/Prog.lean      Prog ins outs; launches, estimate, emit (skeleton), ofRows (the gate)
Kernels/Queries.lean   candidates fastest composable synthesize regressions roofline program kernelInfo
Kernels/Seed.lean      14 kernels, 19 benches (illustrative), one stored program
```

```bash
cd examples/kernels
lake build kernels kernels_tests && ./.lake/build/bin/kernels_tests
k=./.lake/build/bin/kernels
$k query seed
$k query synthesize gemm,rmsNorm h100Sxm M=4096,N=4096,K=4096
$k query regressions h100Sxm
$k log 3
```

`CLI_TRANSCRIPT.md` is the full session from a fresh `data/` dir. The
`lakefile.toml` requires both `leandb` and `gpumarket` by path; nothing
about gpumarket's own `defaultTargets` needed changing.

## What is typed where

- **Row layer.** `Kernel.sig : KernelSig` is `ColCodec.json KernelSig
  KernelSig.validate` — one `TEXT` column of compressed JSON whose
  *shape* (`JsonShape`, from `deriving LeanDb.DbJson`) is in the schema
  and the fingerprint. The codec validates through `KernelSig.make`, so a
  signature that names an undeclared variable, or an output variable no
  input binds, is refused by the SQLite codec and by the CLI's `insert`
  alike (transcript: `kernel.sig: shape variable K is used but not
  declared in vars`, exit 2). `inDtype0`/`outDtype0`/`rank0` are
  `derived sig.…` fields: the engine recomputes them on every write and
  checks them on every read. `DimBinding` is canonical TEXT
  (`K=4096,M=4096,N=4096`, sorted, no duplicates), so equality pushes as
  `binding IS ?` and the same binding typed in any order matches.
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
  the architectures the captured arch supports); `fastest` is a pushed join sorted client-side;
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
engine; **"What stage B changed"** at the end of the section says which
of it no longer holds.

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

**Inline-flattening `LaunchConfig`/`NumericProps`: yes, both.** The base
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
  dtype, rank, layoutKind)`) — the only encoding under which "exactly two
  inputs", "any input column-major" and per-input rank push, and they push
  as LEP-0004's `exists`/`forall`. `ProgramEdge` already is one.
- *`EnumSet` for `fuses`* — the canonical-TEXT set is the cheapest thing
  that works today and the cheapest thing to replace; membership is the
  one question a set is for.
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
  `DimConstraint`, `KernelSig` and `LaunchConfig` derive it instead of
  `Lean.ToJson`/`Lean.FromJson`. The encoding is byte-identical to Lean's
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

**What still stands.** Every per-input question in the first paragraph
— "exactly two inputs", "any input column-major", per-input rank — is
still residual: a derived column carries one fact about the *first*
input, and a fixed set of columns still cannot describe a list. That is
stage D's (child tables, after LEP-0004). `rows --eq` still cannot look
inside `sig` or `launch`; `smemBytes ≤ 100000` is still residual until
stage C flattens `LaunchConfig`; `fuses` is still canonical TEXT until
stage A's `EnumSet`. And a *refused* shape change is refused, not
migrated: typed value transformations are a later LEP.
