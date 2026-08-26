import GpuMarket.Enums

/-! # The silicon, deeply

Everything the market *knows* about the vocabulary lives here as total
functions over the closed worlds — datasheet facts are code, not rows
(taxonomy after jacobpeake.com/ai-chip-architectures). Because `ChipSpec`
is vocabulary (never a stored column), it is free to use the full type
language: payload-carrying interconnects, `Option` for
precision-not-supported, nested structures.

Add a `Gpu` constructor and the compiler refuses to build until every
table below has learned about it. Throughput figures are DENSE (no
structured sparsity), TFLOPS (TOPS for int8), per single GPU/die-package.
-/

namespace GpuMarket

/-- Architecture generation (NVIDIA SM lineage / AMD CDNA). -/
inductive Arch where
  | ampere | ada | hopper | blackwell | cdna3
  deriving Repr, DecidableEq, Ord, LeanDb.ClosedEnum

/-- Memory technology on the package. -/
inductive MemTech where
  | hbm2 | hbm2e | hbm3 | hbm3e | gddr6 | gddr6x | gddr7
  deriving Repr, DecidableEq, Ord, LeanDb.ClosedEnum

inductive FormFactor where
  | sxm | pcieCard | oam | superchip
  deriving Repr, DecidableEq, Ord, LeanDb.ClosedEnum

/-- Numeric precision — a closed world, so it can be a typed CLI argument. -/
inductive Precision where
  | fp64 | fp32 | tf32 | bf16 | fp8 | fp4 | int8
  deriving Repr, DecidableEq, Ord, LeanDb.ClosedEnum

/-- Scale-up interconnect — a sum with payloads (vocabulary types are not
    columns; nothing forces them flat). Bandwidth is per-GPU aggregate
    bidirectional GB/s. -/
inductive Interconnect where
  | nvlink (gen : Nat) (gbPerS : Nat)
  | infinityFabric (gbPerS : Nat)
  | pcieOnly (gen : Nat)
  deriving Repr, DecidableEq

def Interconnect.describe : Interconnect → String
  | .nvlink g bw => s!"NVLink {g} ({bw} GB/s)"
  | .infinityFabric bw => s!"Infinity Fabric ({bw} GB/s)"
  | .pcieOnly g => s!"PCIe Gen{g} only"

/-- Everything we know about one SKU. -/
structure ChipSpec where
  marketing    : String
  vendor       : Vendor
  arch         : Arch
  year         : Nat
  processNm    : Nat
  transistorsB : Nat
  /-- compute dies in the package (B200: 2; MI300X: 8 XCDs). -/
  dies         : Nat := 1
  vramGb       : Nat
  memTech      : MemTech
  memBwGBs     : Nat
  /-- L2 (NVIDIA) / Infinity Cache (AMD), MB. -/
  cacheMb      : Nat
  tdpW         : Nat
  form         : FormFactor
  interconnect : Interconnect
  deriving Repr

/-- Total: the datasheet, one row per constructor. -/
def Gpu.spec : Gpu → ChipSpec
  | .h100Sxm => ⟨"H100 SXM5", .nvidia, .hopper, 2022, 4, 80, 1, 80, .hbm3, 3350, 50, 700, .sxm, .nvlink 4 900⟩
  | .h100Pcie => ⟨"H100 PCIe", .nvidia, .hopper, 2022, 4, 80, 1, 80, .hbm2e, 2000, 50, 350, .pcieCard, .nvlink 4 600⟩
  | .h200 => ⟨"H200 SXM", .nvidia, .hopper, 2023, 4, 80, 1, 141, .hbm3e, 4800, 50, 700, .sxm, .nvlink 4 900⟩
  | .b200 => ⟨"B200", .nvidia, .blackwell, 2024, 4, 208, 2, 192, .hbm3e, 8000, 60, 1000, .sxm, .nvlink 5 1800⟩
  | .gh200 => ⟨"GH200 Grace Hopper", .nvidia, .hopper, 2023, 4, 80, 1, 96, .hbm3, 4000, 50, 700, .superchip, .nvlink 4 900⟩
  | .a100Sxm80 => ⟨"A100 SXM4 80GB", .nvidia, .ampere, 2020, 7, 54, 1, 80, .hbm2e, 2039, 40, 400, .sxm, .nvlink 3 600⟩
  | .a100Pcie40 => ⟨"A100 PCIe 40GB", .nvidia, .ampere, 2020, 7, 54, 1, 40, .hbm2, 1555, 40, 250, .pcieCard, .nvlink 3 600⟩
  | .l40s => ⟨"L40S", .nvidia, .ada, 2023, 4, 76, 1, 48, .gddr6, 864, 96, 350, .pcieCard, .pcieOnly 4⟩
  | .l4 => ⟨"L4", .nvidia, .ada, 2023, 4, 36, 1, 24, .gddr6, 300, 48, 72, .pcieCard, .pcieOnly 4⟩
  | .a10 => ⟨"A10", .nvidia, .ampere, 2021, 8, 28, 1, 24, .gddr6, 600, 6, 150, .pcieCard, .pcieOnly 4⟩
  | .rtx4090 => ⟨"GeForce RTX 4090", .nvidia, .ada, 2022, 4, 76, 1, 24, .gddr6x, 1008, 72, 450, .pcieCard, .pcieOnly 4⟩
  | .rtx5090 => ⟨"GeForce RTX 5090", .nvidia, .blackwell, 2025, 4, 92, 1, 32, .gddr7, 1792, 88, 575, .pcieCard, .pcieOnly 5⟩
  | .mi300x => ⟨"Instinct MI300X", .amd, .cdna3, 2023, 5, 153, 8, 192, .hbm3, 5300, 256, 750, .oam, .infinityFabric 896⟩
  | .mi325x => ⟨"Instinct MI325X", .amd, .cdna3, 2024, 5, 153, 8, 256, .hbm3e, 6000, 256, 1000, .oam, .infinityFabric 896⟩

/-- Dense throughput at each precision, TFLOPS (int8: TOPS). `none` =
    not meaningfully supported on that silicon (fp8 arrived with Hopper /
    Ada / CDNA3; fp4 is Blackwell-generation only; consumer parts have no
    usable fp64). -/
def Gpu.tflops : Gpu → Precision → Option Nat
  | .h100Sxm, p | .gh200, p | .h200, p =>
      match p with
      | .fp64 => some 34 | .fp32 => some 67 | .tf32 => some 495
      | .bf16 => some 990 | .fp8 => some 1979 | .fp4 => none | .int8 => some 1979
  | .h100Pcie, p =>
      match p with
      | .fp64 => some 26 | .fp32 => some 51 | .tf32 => some 378
      | .bf16 => some 756 | .fp8 => some 1513 | .fp4 => none | .int8 => some 1513
  | .b200, p =>
      match p with
      | .fp64 => some 40 | .fp32 => some 80 | .tf32 => some 1100
      | .bf16 => some 2250 | .fp8 => some 4500 | .fp4 => some 9000 | .int8 => some 4500
  | .a100Sxm80, p | .a100Pcie40, p =>
      match p with
      | .fp64 => some 10 | .fp32 => some 19 | .tf32 => some 156
      | .bf16 => some 312 | .fp8 => none | .fp4 => none | .int8 => some 624
  | .l40s, p =>
      match p with
      | .fp64 => none | .fp32 => some 92 | .tf32 => some 183
      | .bf16 => some 366 | .fp8 => some 733 | .fp4 => none | .int8 => some 733
  | .l4, p =>
      match p with
      | .fp64 => none | .fp32 => some 30 | .tf32 => some 60
      | .bf16 => some 121 | .fp8 => some 242 | .fp4 => none | .int8 => some 242
  | .a10, p =>
      match p with
      | .fp64 => none | .fp32 => some 31 | .tf32 => some 62
      | .bf16 => some 125 | .fp8 => none | .fp4 => none | .int8 => some 250
  | .rtx4090, p =>
      match p with
      | .fp64 => none | .fp32 => some 83 | .tf32 => some 165
      | .bf16 => some 330 | .fp8 => some 661 | .fp4 => none | .int8 => some 661
  | .rtx5090, p =>
      match p with
      | .fp64 => none | .fp32 => some 105 | .tf32 => some 210
      | .bf16 => some 419 | .fp8 => some 838 | .fp4 => some 1676 | .int8 => some 838
  | .mi300x, p | .mi325x, p =>
      match p with
      | .fp64 => some 163 | .fp32 => some 163 | .tf32 => some 653
      | .bf16 => some 1307 | .fp8 => some 2614 | .fp4 => none | .int8 => some 2614

/-- Single source: the vocabulary accessors used in query predicates read
    the spec (`@[db]`: in a `select` they compile to SQL by case-splitting
    the closed world). -/
@[db] def Gpu.vendor (g : Gpu) : Vendor := g.spec.vendor
@[db] def Gpu.vramGb (g : Gpu) : Nat := g.spec.vramGb
@[db] def Gpu.memBwGBs (g : Gpu) : Nat := g.spec.memBwGBs
@[db] def Gpu.arch (g : Gpu) : Arch := g.spec.arch

open Lean (Json) in
def ChipSpec.toJson (c : ChipSpec) (g : Gpu) : Json :=
  Json.mkObj [
    ("marketing", Json.str c.marketing),
    ("vendor", Json.str (LeanDb.ClosedEnum.encodeName c.vendor)),
    ("arch", Json.str (LeanDb.ClosedEnum.encodeName c.arch)),
    ("year", Lean.toJson c.year),
    ("process_nm", Lean.toJson c.processNm),
    ("transistors_b", Lean.toJson c.transistorsB),
    ("dies", Lean.toJson c.dies),
    ("vram_gb", Lean.toJson c.vramGb),
    ("mem", Json.str (LeanDb.ClosedEnum.encodeName c.memTech)),
    ("mem_bw_gbs", Lean.toJson c.memBwGBs),
    ("cache_mb", Lean.toJson c.cacheMb),
    ("tdp_w", Lean.toJson c.tdpW),
    ("form", Json.str (LeanDb.ClosedEnum.encodeName c.form)),
    ("interconnect", Json.str c.interconnect.describe),
    ("tflops_dense", Json.mkObj <|
      (LeanDb.ClosedEnum.all (α := Precision)).toList.filterMap fun p =>
        (Gpu.tflops g p).map fun t => (LeanDb.ClosedEnum.encodeName p, Lean.toJson t))]

end GpuMarket
