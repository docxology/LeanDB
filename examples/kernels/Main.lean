import Kernels

/-! The kernels CLI. Query names and arities are `query%`-derived from
the defs in `Kernels/Queries.lean`; closed-world arguments (op, arch,
dtype, and gpumarket's SKU) parse by variant name, `DimBinding` as
`M=4096,N=4096,K=4096`, op lists as `gemm,rmsNorm`. The child tables
`kernel_ins`/`kernel_outs` (LEP-0003 D) are listed as tables of their
own, so `rows kernel_ins --eq dtype=bf16` works like any other table;
`rows kernel` shows the lists nested. -/

open Lean (Json) in
open LeanDb LeanDb.Cli Kernels in
def main (args : List String) : IO UInt32 := do
  Cli.run {
    name := "kernels"
    dbPath := "data" / "kernels.sqlite"
    specs := schema
    tables := [.of Kernel, .of Kernel.Ins, .of Kernel.Outs, .of Bench, .of Program,
      .of ProgramNode, .of ProgramEdge]
    queries := [
      ("seed", fun _ => do
        seed
        return Json.mkObj [("ok", Json.bool true), ("seeded", Json.bool true)]),
      query% candidates,
      query% forArch,
      query% fusing,
      query% fitsSmem,
      query% reproducible,
      query% highRank,
      query% allHighRank,
      query% anyColMajor,
      query% exactlyTwoInputs,
      query% fastest,
      query% regressions,
      query% roofline,
      query% composable,
      query% synthesize,
      query% program,
      query% kernelInfo]
  } args
