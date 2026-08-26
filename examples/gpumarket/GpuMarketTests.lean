import GpuMarket

open LeanDb GpuMarket

private def check (c : Bool) (m : String) : IO Unit :=
  unless c do throw <| IO.userError s!"FAIL: {m}"

private def dbPath : System.FilePath := ".lake" / "gpumarket_test.sqlite"

-- Closed worlds are not entities: none of these typecheck.
#check_failure LeanDb.insert Provider Provider.lambdaLabs
#check_failure LeanDb.delete (α := Gpu) ⟨1⟩
#check_failure LeanDb.select [Listing] (fun (m : Stored Model) => m.val.openWeights)

private def expectOk (r : Except DbError α) (ctx : String) : IO α :=
  match r with
  | .ok a => pure a
  | .error e => throw <| IO.userError s!"FAIL: {ctx}: {e}"

private def price (l : Stored Listing) : Nat := l.val.usdHr.milli

def main : IO UInt32 := do
  -- pure vocabulary checks: total functions are the lookup tables
  check (Gpu.vramGb .mi325x == 256 && Gpu.vendor .h200 == .nvidia) "vocabulary tables"
  -- consistency, quantified over the whole closed world
  let world := ClosedEnum.all (α := Gpu)
  check (world.size == 14) "the silicon world has 14 SKUs"
  for g in world do
    let sp := g.spec
    check (sp.memBwGBs > 0 && sp.vramGb > 0 && sp.tdpW > 0 && sp.transistorsB > 0
        && sp.year ≥ 2020 && sp.year ≤ 2026)
      s!"spec sanity for {sp.marketing}"
    check ((g.tflops .fp4).isSome == (sp.arch == .blackwell))
      s!"fp4 is Blackwell-generation only ({sp.marketing})"
    check ((g.tflops .fp8).isSome == (sp.arch != .ampere))
      s!"fp8 exists everywhere after Ampere ({sp.marketing})"
    check ((g.tflops .bf16).isSome && (g.tflops .int8).isSome)
      s!"bf16/int8 universal ({sp.marketing})"
    check (Gpu.vramGb g == sp.vramGb && Gpu.vendor g == sp.vendor)
      s!"@[db] accessors read the spec ({sp.marketing})"
    -- monotone precision ladder: halving precision never loses throughput
    match g.tflops .bf16, g.tflops .fp8 with
    | some b, some f => check (f ≥ b) s!"fp8 ≥ bf16 throughput ({sp.marketing})"
    | _, _ => pure ()
  check ((Gpu.spec .b200).interconnect == .nvlink 5 1800) "B200 carries NVLink 5"
  check ((Gpu.spec .mi300x).cacheMb == 256) "MI300X Infinity Cache"
  check (fitsOn ⟨⟨"m"⟩, .deepseek, 671, some 37, 128, 8, true⟩ .mi300x ⟨8⟩)
    "DeepSeek-V3 fp8 fits an 8x MI300X node"
  check (!fitsOn ⟨⟨"m"⟩, .metaAi, 405, none, 128, 16, true⟩ .rtx4090 ⟨8⟩)
    "405B bf16 does not fit consumer cards"
  if ← dbPath.pathExists then IO.FS.removeFile dbPath
  let r ← withDb dbPath schema do
    seed
    seedModels
    let all ← select [Listing] (fun _ => true)
    let mods ← models
    let top ← h100 .onDemand
    let spotBest ← cheapest .h100Sxm .spot
    let amdRows ← amd
    let big ← bigVram 141
    let cheap ← under 700 .onDemand
    let ds ← canServe ⟨4⟩   -- DeepSeek-V3 (4th insert)
    -- CAS: delist the cheapest H100, then a stale write must fail
    let some vp := top[0]? | throw (.sqlite "no h100 rows")
    discard <| update vp { vp.val with available := false }
    let stale ← (fun conn => ExceptT.mk (.ok <$> (update vp { vp.val with usdHr := ⟨2100⟩ } |>.run conn)))
    return (all.size, mods.size, top.map price, spotBest[0]?.map (·.val.provider),
      amdRows.map (·.val.gpu.vendor), big.size, cheap.size,
      ds[0]?.map (fun (_, l) => (l.val.provider, price l)), stale)
  let (nList, nMod, h100Prices, spotP, amdVendors, nBig, nCheap, dsBest, stale) ←
    expectOk r "seed + queries"
  check (nList == 38 && nMod == 12) s!"seed counts, got {nList}/{nMod}"
  check (h100Prices == #[1990, 2210, 2390, 2390, 2490, 2790, 2950, 3900, 4760, 5950, 6350, 6980])
    s!"cheapest on-demand H100 ordering, got {h100Prices}"
  check (spotP == some .vastAi) "cheapest H100 spot is Vast"
  check (amdVendors.size == 3 && amdVendors.all (· == .amd)) "amd query: AMD only, available only"
  check (nBig == 8) s!"bigVram 141 count, got {nBig}"
  check (nCheap == 5) s!"under $0.70 count, got {nCheap}"
  check (dsBest == some (.hotAisle, 1990)) s!"DeepSeek-V3 cheapest home, got {repr dsBest}"
  match stale with
  | .error (.stale ..) => pure ()
  | _ => throw <| IO.userError "FAIL: stale CAS must be refused"
  IO.println "gpumarket base: all tests passed"
  return 0
