import Kernels.Entities
import Kernels.Queries
import Kernels.Seed

/-! The kernels base as a value. Query names and arities are
`query%`-derived from the defs in `Kernels/Queries.lean`; closed-world
arguments (op, arch, dtype, and gpumarket's SKU) parse by variant name,
`DimBinding` as `M=4096,N=4096,K=4096`, op lists as `gemm,rmsNorm`. The
child tables `kernel_ins`/`kernel_outs` (LEP-0003 D) are listed as
tables of their own, so `rows kernel_ins --eq dtype=bf16` works like any
other table; `rows kernel` shows the lists nested. -/

namespace Kernels

open LeanDb LeanDb.Cli

def base : LeanDb.Base := {
  name := "kernels"
  tables := [.of Kernel, .of Kernel.Ins, .of Kernel.Outs, .of Bench, .of Program,
    .of ProgramNode, .of ProgramEdge]
  queries := [
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
  seed := some seed
}

end Kernels
