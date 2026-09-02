import Kernels

/-! Tests for the kernels base: the typed-composition property at compile
time (`#check_failure`), the `KernelSig` boundary (codec round trip, `make`
refusals, CLI-path insert of a malformed signature), the derived search
columns (LEP-0003 B3: recomputed on write, checked on read), the inline
fields (LEP-0003 C: flattened columns, both JSON spellings, pushdown),
and every query over seed data. The five headline `kernels log` plans
are printed, not asserted — they are the evidence the README quotes. -/

open LeanDb Kernels
open GpuMarket (Gpu)

private def check (c : Bool) (m : String) : IO Unit :=
  unless c do throw <| IO.userError s!"FAIL: {m}"

private def checkD (c : Bool) (m : String) : DbM Unit :=
  unless c do throw (.sqlite s!"FAIL: {m}")

private def expectOk (r : Except DbError α) (ctx : String) : IO α :=
  match r with
  | .ok a => pure a
  | .error e => throw <| IO.userError s!"FAIL: {ctx}: {e}"

private def dbPath : System.FilePath := ".lake" / "kernels_test.sqlite"

-- Test-only: lets `Option.get!` unwrap smart-constructor results on
-- literal inputs. The base itself has no `Inhabited` for these on
-- purpose — nothing there should ever conjure a default value.
deriving instance Inhabited for Kernels.DimVar, Kernels.DimBinding, Kernels.KernelName

/-! ## Negative compile checks -/

-- Closed worlds are not entities; gpumarket's SKU world is not one here either.
#check_failure LeanDb.insert DType DType.bf16
#check_failure LeanDb.delete (α := GpuMarket.Gpu) ⟨1⟩
-- A predicate over the wrong table does not typecheck.
#check_failure LeanDb.select [Kernel] (fun (m : Stored Bench) => m.val.sku == Gpu.h100Sxm)
-- LEP-0003 A acceptance: the bit-test leaf over the `fuses` column is a plan.
#check (Pred.bit (.here Kernel.Field.fuses) .silu true : Pred [Kernel])
-- …and over a column that is not an `EnumSet` it is not.
#check_failure (Pred.bit (.here Kernel.Field.op) .silu true : Pred [Kernel])

/-! ## Typed composition

Edge types are the indices of `Prog`; `seq` demands the middle ones agree
*definitionally*. An f32 GEMM output into a kernel expecting bf16 is a
type error, not a runtime check. -/

section TypedComposition

def aTy : TensorTy := { dtype := .bf16, shape := [.lit 4096, .lit 4096] }
def bTy : TensorTy := { dtype := .bf16, shape := [.lit 4096, .lit 4096], layout := .colMajor }
def cF32 : TensorTy := { dtype := .f32, shape := [.lit 4096, .lit 4096] }
def cBf16 : TensorTy := { dtype := .bf16, shape := [.lit 4096, .lit 4096] }
def wTy : TensorTy := { dtype := .bf16, shape := [.lit 4096] }

variable (gemmF32 : Prog [aTy, bTy] [cF32]) (gemmBf16 : Prog [aTy, bTy] [cBf16])
  (norm : Prog [cBf16, wTy] [cBf16])

-- f32 out of the GEMM, bf16 into the norm: refused by the compiler.
#check_failure Prog.seq (Prog.par gemmF32 (Prog.id [wTy])) norm
-- even without the pass-through: the seam itself is the error
#check_failure Prog.seq gemmF32 (Prog.seq (Prog.dup cBf16) (Prog.swap cBf16 cBf16))
-- the bf16-out GEMM composes, and the program's own type is read off
#check (Prog.seq (Prog.par gemmBf16 (Prog.id [wTy])) norm : Prog [aTy, bTy, wTy] [cBf16])

end TypedComposition

/-! ## The signature boundary -/

private def mkGemm : Except String KernelSig := do
  let m ← DimVar.make "M"; let n ← DimVar.make "N"; let k ← DimVar.make "K"
  KernelSig.make [m, n, k]
    [{ dtype := .bf16, shape := [.var m, .var k] },
     { dtype := .bf16, shape := [.var k, .var n], layout := .colMajor }]
    [{ dtype := .f32, shape := [.var m, .var n] }]
    [] [.divides 64 (.var k)]

/-- The CLI-shaped row JSON, with a `sig` string that uses `K` without
    declaring it. -/
private def malformedRow : Lean.Json :=
  let sig := "{\"vars\":[\"M\"],\"ins\":[{\"align\":16,\"dtype\":\"bf16\",\"layout\":\"rowMajor\",\"mem\":\"global\",\"shape\":[{\"var\":{\"v\":\"M\"}},{\"var\":{\"v\":\"K\"}}]}],\"outs\":[{\"align\":16,\"dtype\":\"bf16\",\"layout\":\"rowMajor\",\"mem\":\"global\",\"shape\":[{\"var\":{\"v\":\"M\"}}]}],\"scalars\":[],\"constraints\":[]}"
  Lean.Json.mkObj [("name", "bad-sig"), ("op", "gemm"), ("lang", "cuda"), ("variant", "x"),
    ("sig", sig), ("minArch", "sm90"), ("maxArch", Lean.Json.null),
    ("launch", Lean.Json.mkObj [("block", 256), ("smemBytes", 0), ("stages", 1)]),
    ("numeric", Lean.Json.mkObj [("deterministic", true), ("accum", "f32")]),
    ("fuses", Lean.Json.arr #[]), ("license", "mit"),
    ("source", Lean.Json.str ("".pushn '0' 64)),
    ("inDtype0", "bf16"), ("outDtype0", "bf16"), ("rank0", 2)]

/-- Same row, well-formed signature, search columns that contradict it.
    They are derived now: the supplied values are ignored and recomputed.
    The inline fields come in the *flat* spelling here (`launch_block`,
    `numeric_accum`, …), `stages` omitted — it has a column default. -/
private def lyingRow : Lean.Json :=
  let sig := "{\"vars\":[\"M\"],\"ins\":[{\"align\":16,\"dtype\":\"bf16\",\"layout\":\"rowMajor\",\"mem\":\"global\",\"shape\":[{\"var\":{\"v\":\"M\"}}]}],\"outs\":[{\"align\":16,\"dtype\":\"bf16\",\"layout\":\"rowMajor\",\"mem\":\"global\",\"shape\":[{\"var\":{\"v\":\"M\"}}]}],\"scalars\":[],\"constraints\":[]}"
  Lean.Json.mkObj [("name", "lying-columns"), ("op", "gemm"), ("lang", "cuda"), ("variant", "x"),
    ("sig", sig), ("minArch", "sm90"), ("maxArch", Lean.Json.null),
    ("launch_block", 256), ("launch_smemBytes", 0),
    ("numeric_deterministic", true), ("numeric_accum", "f32"),
    ("fuses", Lean.Json.arr #["silu", "gelu"]), ("license", "mit"),
    ("source", Lean.Json.str ("".pushn '0' 64)),
    ("inDtype0", "f64"), ("outDtype0", "f64"), ("rank0", 7)]

private def pureChecks : IO Unit := do
  -- codec round trip through one TEXT column
  let gemm ← match mkGemm with
    | .ok s => pure s
    | .error e => throw <| IO.userError s!"FAIL: mkGemm: {e}"
  match (fromCol (toCol gemm) : Except String KernelSig) with
  | .ok s' => check (s' == gemm) "KernelSig round-trips through its codec"
  | .error e => throw <| IO.userError s!"FAIL: codec decode: {e}"
  check ((toCol gemm) matches Col.text _) "KernelSig is one TEXT column"
  -- make refuses an unbound variable, an undetermined output, and no outputs
  let m := (DimVar.make "M").toOption.get!
  let k := (DimVar.make "K").toOption.get!
  let unbound := KernelSig.make [m] [{ dtype := .bf16, shape := [.var m, .var k] }]
    [{ dtype := .bf16, shape := [.var m] }]
  check (unbound matches .error _) "KernelSig.make refuses an undeclared variable"
  let undetermined := KernelSig.make [m, k] [{ dtype := .bf16, shape := [.var m] }]
    [{ dtype := .bf16, shape := [.var m, .var k] }]
  check (undetermined matches .error _) "KernelSig.make refuses an output variable no input binds"
  check ((KernelSig.make [m] [{ dtype := .bf16, shape := [.var m] }] []) matches .error _)
    "KernelSig.make refuses a signature with no outputs"
  -- the CLI path: JSON → columns → codecs; the malformed sig is a typed decode error
  match rowOfJson Kernel malformedRow with
  | .error (.decode "kernel" "sig" msg) => check (msg == "shape variable K is used but not declared in vars") s!"malformed sig message, got {msg}"
  | .error e => throw <| IO.userError s!"FAIL: malformed sig: wrong error {e}"
  | .ok _ => throw <| IO.userError "FAIL: malformed sig was accepted"
  -- …and lying search columns are recomputed from sig (B3), not stored as supplied
  match rowOfJson Kernel lyingRow with
  | .ok k =>
      check (k.inDtype0 == .bf16 && k.outDtype0 == .bf16 && k.rank0 == 1)
        "CLI insert recomputes the derived search columns from sig"
      -- the inline fields arrived flat; the omitted `launch_stages` took its default (C)
      check (k.launch == { block := 256, smemBytes := 0, stages := 1 } && k.numeric == ⟨true, .f32⟩)
        "flat spelling of the inline fields decodes; omitted sub-column takes its default"
      -- the EnumSet column comes in as names (LEP-0003 A)
      check (k.fuses == EnumSet.ofList [.silu, .gelu] && k.fuses.names == ["silu", "gelu"])
        "fuses decodes from an array of names"
  | .error e => throw <| IO.userError s!"FAIL: lying row unexpectedly refused: {e}"
  -- an unknown fused op is refused by name; so is a stray bit
  match rowOfJson Kernel (Lean.Json.mkObj (lyingRow.getObj?.toOption.map (·.toList.map fun (k, v) =>
      if k == "fuses" then (k, Lean.Json.arr #["swish"]) else (k, v)) |>.getD [])) with
  | .error (.decode "kernel" "fuses" m) => check ((m.splitOn "\"swish\"").length == 2) s!"unknown fused op message, got {m}"
  | .error e => throw <| IO.userError s!"FAIL: unknown fused op: wrong error {e}"
  | .ok _ => throw <| IO.userError "FAIL: an unknown fused op was accepted"
  -- the column's spec: INTEGER, the world's names, a mask CHECK in the DDL
  let fusesSpec := (Entity.columns Kernel).find? (·.name == "fuses")
  check ((fusesSpec.map (·.sqlType)) == some .integer && (fusesSpec.bind (·.enumSet)) == some (ClosedEnum.variants OpKind)
    && (fusesSpec.bind (·.enum)).isNone) "fuses is an INTEGER column carrying OpKind's world"
  check (((Entity.spec Kernel).ddl.splitOn "\"fuses\" INTEGER NOT NULL CHECK ((\"fuses\" & ~1048575) = 0)").length == 2)
    s!"fuses DDL carries the 20-variant mask CHECK, got {(Entity.spec Kernel).ddl}"
  -- the derived columns may be omitted altogether
  let omitted := Lean.Json.mkObj (lyingRow.getObj?.toOption.map (·.toList.filter fun (k, _) =>
    k != "inDtype0" && k != "outDtype0" && k != "rank0") |>.getD [])
  match rowOfJson Kernel omitted with
  | .ok k => check (k.inDtype0 == .bf16 && k.rank0 == 1) "derived search columns may be omitted from JSON"
  | .error e => throw <| IO.userError s!"FAIL: row without derived columns refused: {e}"
  -- B1: an omitted defaulted field inside the nested type takes its default
  match (Lean.Json.parse "{\"dtype\":\"bf16\",\"shape\":[]}" >>= Lean.fromJson? : Except String TensorTy) with
  | .ok t =>
      check (t.layout == .rowMajor && t.mem == .global && t.align == 16)
        "TensorTy JSON may omit layout/mem/align"
  | .error e => throw <| IO.userError s!"FAIL: defaulted TensorTy fields: {e}"
  -- B2: the shape the fingerprint sees
  let sigShape := (Entity.columns Kernel).find? (·.name == "sig") |>.bind (·.shape)
  check (sigShape.isSome && (sigShape.getD "").startsWith "KernelSig{vars:[String],ins:[TensorTy{dtype:<f64|")
    s!"sig column carries the KernelSig shape, got {sigShape}"
  -- C: the inline fields are sibling columns, grouped, with no column of their own
  check (((Entity.columns Kernel).find? (·.name == "launch")).isNone && ((Entity.columns Kernel).find? (·.name == "numeric")).isNone)
    "no column for an inline field as a whole"
  check (((Entity.columns Kernel).filter (·.group == some "launch")).map (·.name) == #["launch_block", "launch_smemBytes", "launch_stages"])
    "launch flattens to three grouped columns"
  check (((Entity.columns Kernel).filter (·.group == some "numeric")).map (·.name) == #["numeric_deterministic", "numeric_accum"])
    "numeric flattens to two grouped columns"
  check (((Entity.columns Kernel).find? (·.name == "launch_stages") |>.bind (·.dflt)) == some (.int 1))
    "the sub-field default is the column DEFAULT"
  check (((Entity.columns Kernel).find? (·.name == "numeric_accum") |>.bind (·.enum)) == some (ClosedEnum.variants DType))
    "the flattened closed-enum column keeps its CHECK"
  check ((Entity.fieldOfName? Kernel "launch_smemBytes").isSome) "rows --eq can name a flattened column"
  -- the nested spelling, and an unknown sub-field refused by name
  match rowOfJson Kernel malformedRow with
  | .error (.decode "kernel" "sig" _) => pure ()
  | _ => throw <| IO.userError "FAIL: nested inline spelling changed the outcome"
  match rowOfJson Kernel (Lean.Json.mkObj (lyingRow.getObj?.toOption.map (·.toList.map fun (k, v) =>
      if k == "launch_block" then ("launch", Lean.Json.mkObj [("block", 256), ("grid", 4)]) else (k, v)) |>.getD [])) with
  | .error (.decode "kernel" "launch_grid" _) => pure ()
  | .error e => throw <| IO.userError s!"FAIL: unknown inline sub-field: wrong error {e}"
  | .ok _ => throw <| IO.userError "FAIL: an unknown inline sub-field was accepted"
  check (((Entity.columns Kernel).find? (·.name == "inDtype0") |>.bind (·.shape)).isNone)
    "a closed-enum column has no shape"
  -- instantiate / constraints
  match (DimBinding.decode "K=4096,M=4096,N=4096") >>= gemm.instantiate with
  | .ok (ins, outs) =>
      check (ins.map TensorTy.describe == ["bf16[4096,4096]", "bf16[4096,4096]:colMajor"]
        && outs.map TensorTy.describe == ["f32[4096,4096]"]) "instantiate at 4096³"
  | .error e => throw <| IO.userError s!"FAIL: instantiate: {e}"
  check (((DimBinding.decode "K=100,M=4096,N=4096") >>= gemm.instantiate) matches .error _)
    "K % 64 = 0 is enforced by instantiate"
  check (((DimBinding.decode "M=4096,N=4096") >>= gemm.instantiate) matches .error _)
    "an unbound K is refused by instantiate"
  -- canonical binding: order-independent TEXT, equal iff equal
  let b1 := (DimBinding.decode "N=1,M=2").toOption.get!
  let b2 := (DimBinding.decode "M=2,N=1").toOption.get!
  check (b1 == b2 && b1.encode == "M=2,N=1") "DimBinding encoding is canonical"
  check ((DimBinding.decode "M=1,M=2") matches .error _) "DimBinding refuses a duplicate"
  -- unification: same dtype/rank unifies across two variable namespaces; dtype mismatch does not
  let s := (DimVar.make "S").toOption.get!
  let h := (DimVar.make "H").toOption.get!
  check ((unify { dtype := .bf16, shape := [.var m, .var k] } { dtype := .bf16, shape := [.var s, .var h] }).isSome)
    "bf16[M,K] unifies with bf16[S,H]"
  check ((unify { dtype := .f32, shape := [.var m, .var k] } { dtype := .bf16, shape := [.var s, .var h] }).isNone)
    "f32 does not unify with bf16"
  check ((unify { dtype := .bf16, shape := [.var m] } { dtype := .bf16, shape := [.var s, .var h] }).isNone)
    "rank 1 does not unify with rank 2"
  -- vocabulary: supports is same-vendor, monotone
  check (Arch.supports .sm90 .sm80 && !Arch.supports .sm80 .sm90 && !Arch.supports .gfx942 .sm80
    && Arch.supports .gfx950 .gfx942) "Arch.supports"
  for g in ClosedEnum.all (α := Gpu) do
    check ((Arch.ofGpu g).vendor == g.vendor) s!"Arch.ofGpu agrees with gpumarket's vendor ({g.spec.marketing})"

/-! ## Over seed data -/

private def names (ks : Array (Stored Kernel)) : Array String := ks.map (·.val.name.raw)

private def g1 : DimBinding := (DimBinding.decode Kernels.g1).toOption.get!

private def runQueries : DbM (Array Lean.Json) := do
  seed
  checkD ((← fetchAll Kernel).size == 14) "fourteen kernels seeded"
  -- candidates: op + search column + Arch.supports case split + maxArch
  let c ← candidates .gemm .sm90 .bf16
  checkD (names c == #["gemm-cutlass-sm90-bf16", "gemm-cutlass-sm90-bf16-bf16out", "gemm-triton-sm80-bf16"])
    s!"gemm candidates on sm90 at bf16, got {names c}"
  checkD (names (← candidates .gemm .sm89 .f16) == #["gemm-cutlass-sm80-f16"]) "maxArch admits sm89"
  checkD ((← candidates .gemm .sm90 .f16).isEmpty) "maxArch sm89 excludes sm90"
  checkD (names (← candidates .gemm .gfx942 .bf16) == #["gemm-ck-gfx942-bf16", "gemm-ck-gfx942-bf16-silu"])
    "cross-vendor is never supported"
  -- fusing: membership in the EnumSet column pushes as a bit test (LEP-0003 A)
  checkD (names (← fusing .silu) == #["gemm-ck-gfx942-bf16-silu"]) "fusing silu finds the silu-epilogue GEMM"
  checkD ((← fusing .gelu).isEmpty) "nothing fuses gelu"
  let silu ← fusing .silu
  checkD ((silu.map fun k => (rowJson Kernel k).compress).any fun j => (j.splitOn "\"fuses\":[\"silu\"]").length == 2)
    "row JSON shows the fused ops by name"
  let plainRows ← select [Kernel] (fun k => !(k.val.fuses.contains .silu)) (.key (·.val.name))
  checkD (plainRows.size == 13 && !(names plainRows).contains "gemm-ck-gfx942-bf16-silu") "negated membership"
  checkD (((← readLog 1).getD 0 Lean.Json.null |>.getObjValAs? String "detail").toOption ==
      some "kernel | pushed: ((t0.\"fuses\" & ?) = 0), residual conjuncts: 0")
    s!"negated fusing plan, got {← readLog 1}"
  -- fitsSmem: the inline sub-field pushes as its flattened column (LEP-0003 C)
  let small ← fitsSmem 100000
  checkD (small.size == 10 && small.all (·.val.launch.smemBytes ≤ 100000)) s!"ten kernels fit in 100000 bytes, got {small.size}"
  checkD (((← readLog 1).getD 0 Lean.Json.null |>.getObjValAs? String "detail").toOption ==
      some "kernel | pushed: t0.\"launch_smemBytes\" <= ?, residual conjuncts: 0")
    s!"fitsSmem plan, got {← readLog 1}"
  checkD ((small.map fun k => (rowJson Kernel k).compress).all fun j =>
      (j.splitOn "\"launch\":{\"block\":").length == 2 && (j.splitOn "\"numeric\":{\"accum\":").length == 2)
    "row JSON nests launch and numeric"
  let repro ← reproducible .f32
  checkD (repro.size == 11 && repro.all fun k => k.val.numeric.deterministic && k.val.numeric.accum == .f32)
    s!"eleven deterministic f32 kernels, got {repro.size}"
  checkD (((← readLog 1).getD 0 Lean.Json.null |>.getObjValAs? String "detail").toOption ==
      some "kernel | pushed: (t0.\"numeric_deterministic\" IS ? AND t0.\"numeric_accum\" IS ?), residual conjuncts: 0")
    s!"reproducible plan, got {← readLog 1}"
  -- fastest: join + canonical binding TEXT
  let some (k, m) ← fastest .gemm .h100Sxm g1 | throw (.sqlite "FAIL: fastest found nothing")
  checkD (k.val.name.raw == "gemm-cutlass-sm90-bf16-bf16out" && m.val.latency.us == 168)
    "fastest gemm on H100 at 4096³"
  checkD ((← fastest .gemm .h100Sxm ((DimBinding.decode "K=1,M=1,N=1").toOption.get!)).isNone)
    "fastest at an unmeasured binding is none"
  -- regressions: the planted pairs, and only those
  let rh ← regressions .h100Sxm
  checkD (rh.map (fun (a, c) => (a.val.latency.us, c.val.latency.us)) == #[(172, 198)])
    s!"H100 regression is exactly the planted pair, got {rh.size}"
  let ra ← regressions .mi300x
  checkD (ra.map (fun (a, c) => (a.val.latency.us, c.val.latency.us)) == #[(150, 171)])
    "MI300X regression is exactly the planted pair"
  -- roofline: every H100 bench rated, GEMMs compute-bound, norms memory-bound
  let rf ← roofline .h100Sxm
  let rows := (rf.getObjVal? "rows" >>= (·.getArr?)).toOption.getD #[]
  checkD (rows.size == 13) s!"roofline rates 13 H100 benches, got {rows.size}"
  let bound (name : String) : Option String := rows.findSome? fun r =>
    if (r.getObjValAs? String "kernel").toOption == some name then (r.getObjValAs? String "bound").toOption else none
  checkD (bound "gemm-cutlass-sm90-fp8" == some "compute" && bound "rmsnorm-triton-sm80-bf16" == some "memory")
    "roofline classifies GEMM compute-bound and RMSNorm memory-bound"
  checkD ((rf.getObjValAs? Nat "peak_bw_gbs").toOption == some 3350) "roofline reads Gpu.spec"
  -- composable: search-column narrowing then unification in Lean
  let cf ← composable ((KernelName.make "gemm-cutlass-sm90-bf16").toOption.get!)
  checkD (names cf == #["softmax-cuda-sm80-f32"]) s!"only the f32 softmax eats an f32 GEMM, got {names cf}"
  let cb ← composable ((KernelName.make "gemm-cutlass-sm90-bf16-bf16out").toOption.get!)
  checkD ((names cb).contains "rmsnorm-triton-sm80-bf16" && !(names cb).contains "softmax-cuda-sm80-f32"
    && !(names cb).contains "flash-attn-sm90-bf16")
    "bf16 GEMM composes with rank-2 bf16 consumers, not rank-4"
  -- synthesize: a typed chain over seed kernels
  let some sp ← synthesizeProg [.gemm, .rmsNorm] .h100Sxm g1 | throw (.sqlite "FAIL: synthesize found nothing")
  let launches := sp.2.2.launches
  checkD (launches.map (·.kernel.val.name.raw) == ["gemm-cutlass-sm90-bf16-bf16out", "rmsnorm-triton-sm80-bf16"])
    s!"synthesized chain, got {launches.map (·.kernel.val.name.raw)}"
  checkD (sp.ins.map TensorTy.describe == ["bf16[4096,4096]", "bf16[4096,4096]:colMajor", "bf16[4096]"]
    && sp.outs.map TensorTy.describe == ["bf16[4096,4096]"]) "synthesized program's edge types"
  checkD ((launches.map (·.binding.encode)) == ["K=4096,M=4096,N=4096", "H=4096,S=4096"])
    "downstream binding is determined by unification"
  checkD ((sp.2.2.estimate (← benchLookup .h100Sxm)).map (·.us) == some 199) "estimate sums the two benches"
  checkD ((← synthesizeProg [.gemm, .softmax] .mi300x g1).isNone) "no chain when the second op has no gfx942 kernel"
  checkD ((← synthesizeProg [.gemm, .flashAttention] .h100Sxm g1).isNone) "rank-2 output cannot feed rank-4 attention"
  -- ofRows: the stored program re-types to the same chain
  let some p := (← fetchAll Program)[0]? | throw (.sqlite "FAIL: no program")
  let nodes ← select [ProgramNode] (fun x => x.val.program == p.ref)
  let edges ← select [ProgramEdge] (fun e => e.val.program == p.ref)
  let kernels ← fetchAll Kernel
  let kernelOf := fun r => kernels.find? (·.id == r)
  match Prog.ofRows p nodes edges kernelOf with
  | .ok sp' =>
      checkD (sp'.2.2.launches.map (·.kernel.val.name.raw) == launches.map (·.kernel.val.name.raw)
        && sp'.ins == sp.ins && sp'.outs == sp.outs) "ofRows re-types the stored program"
  | .error e => throw (.sqlite s!"FAIL: ofRows: {e}")
  -- …and refuses a mis-wired edge by name
  let broken := edges.map fun e => ⟨e.id, { e.val with fromOutput := 5 }⟩
  checkD ((Prog.ofRows p nodes broken kernelOf) matches .error _) "ofRows refuses a mis-wired edge"
  -- update of sig alone: the derived search columns follow it (B3 closes §3.2)
  let some rms := kernels.find? (·.val.name.raw == "rmsnorm-triton-sm80-bf16") | throw (.sqlite "FAIL: no rmsnorm")
  let some gemm := kernels.find? (·.val.name.raw == "gemm-cutlass-sm90-bf16") | throw (.sqlite "FAIL: no gemm")
  let updated ← update gemm { gemm.val with sig := rms.val.sig }
  let some reread := (← fetchAll Kernel).find? (·.id == gemm.id) | throw (.sqlite "FAIL: updated gemm vanished")
  checkD (reread.val.inDtype0 == rms.val.sig.inDtype0 && reread.val.rank0 == rms.val.sig.rank0
    && reread.val.outDtype0 == rms.val.sig.outDtype0)
    "update of sig alone recomputes the derived search columns"
  discard <| update updated gemm.val
  -- the plans, verbatim, for the README
  discard <| candidates .gemm .sm90 .bf16
  discard <| fastest .gemm .h100Sxm g1
  discard <| regressions .h100Sxm
  discard <| fusing .silu
  discard <| fitsSmem 100000
  readLog 5

def main : IO UInt32 := do
  pureChecks
  if ← dbPath.pathExists then IO.FS.removeFile dbPath
  let log ← expectOk (← withDb dbPath schema runQueries) "seed + queries"
  IO.println "kernels log — the five headline plans:"
  for entry in log.reverse do
    IO.println s!"  {(entry.getObjValAs? String "detail").toOption.getD "?"}"
  -- data persists across reopen; the JSON column decodes on the way back,
  -- and decoding checked every derived column against sig
  let n ← expectOk (← withDb dbPath schema do
      let ks ← fetchAll Kernel
      return ks.size) "reopen"
  check (n == 14) "all seeded kernels decode after reopen"
  -- a raw-SQL write to a derived column is caught on the next read, by name
  let db ← SQLite.open dbPath
  db.exec "UPDATE kernel SET \"inDtype0\" = 'f64' WHERE name = 'gemm-cutlass-sm90-fp8'"
  match ← withDb dbPath schema (fetchAll Kernel) with
  | .error (.decode "kernel" "inDtype0" m) =>
      check (m == "derived column disagrees with its source") s!"desync message, got {m}"
  | .error e => throw <| IO.userError s!"FAIL: raw-SQL desync: wrong error {e}"
  | .ok _ => throw <| IO.userError "FAIL: a raw-SQL desync of inDtype0 was read back"
  db.exec "UPDATE kernel SET \"inDtype0\" = 'fp8e4m3' WHERE name = 'gemm-cutlass-sm90-fp8'"
  discard <| expectOk (← withDb dbPath schema (fetchAll Kernel)) "restored row reads again"
  IO.println "kernels base: all tests passed"
  return 0
