import LeanDb

/-! # The closed worlds

Providers, silicon, pricing models and regions are *vocabulary*, not rows:
inserting or deleting one does not typecheck — the market's shape changes
by editing this file and migrating. Facts about the vocabulary are total
functions: add a provider and the compiler walks you to every table that
must learn about it. -/

namespace GpuMarket

/-- Every GPU cloud in this base's world. Deleting one is a refactor the
    compiler referees, not a DML statement. -/
inductive Provider where
  | lambdaLabs | coreweave | runpod | vastAi | awsEc2 | gcp | azure
  | nebius | crusoe | hotAisle | togetherAi | voltagePark | paperspace
  deriving Repr, DecidableEq, Ord, LeanDb.ClosedEnum

def Provider.displayName : Provider → String
  | .lambdaLabs => "Lambda" | .coreweave => "CoreWeave" | .runpod => "RunPod"
  | .vastAi => "Vast.ai" | .awsEc2 => "AWS EC2" | .gcp => "Google Cloud"
  | .azure => "Azure" | .nebius => "Nebius" | .crusoe => "Crusoe"
  | .hotAisle => "Hot Aisle" | .togetherAi => "Together AI"
  | .voltagePark => "Voltage Park" | .paperspace => "Paperspace"

def Provider.website : Provider → String
  | .lambdaLabs => "https://lambdalabs.com" | .coreweave => "https://coreweave.com"
  | .runpod => "https://runpod.io" | .vastAi => "https://vast.ai"
  | .awsEc2 => "https://aws.amazon.com/ec2" | .gcp => "https://cloud.google.com"
  | .azure => "https://azure.microsoft.com" | .nebius => "https://nebius.com"
  | .crusoe => "https://crusoe.ai" | .hotAisle => "https://hotaisle.xyz"
  | .togetherAi => "https://together.ai" | .voltagePark => "https://voltagepark.com"
  | .paperspace => "https://paperspace.com"

/-- The silicon SKUs on the market. -/
inductive Gpu where
  | h100Sxm | h100Pcie | h200 | b200 | gh200
  | a100Sxm80 | a100Pcie40 | l40s | l4 | a10 | rtx4090 | rtx5090
  | mi300x | mi325x
  deriving Repr, DecidableEq, Ord, LeanDb.ClosedEnum

inductive Vendor where
  | nvidia | amd
  deriving Repr, DecidableEq, Ord, LeanDb.ClosedEnum

/-- Total: a new Gpu constructor forces a row here — the compiler is the
    completeness check. `@[db]`: usable inside `select` predicates, where
    it compiles to SQL by case-splitting the closed world. -/
@[db] def Gpu.vendor : Gpu → Vendor
  | .mi300x | .mi325x => .amd
  | _ => .nvidia

@[db] def Gpu.vramGb : Gpu → Nat
  | .h100Sxm | .h100Pcie => 80
  | .h200 => 141 | .b200 => 192 | .gh200 => 96
  | .a100Sxm80 => 80 | .a100Pcie40 => 40
  | .l40s => 48 | .l4 => 24 | .a10 => 24
  | .rtx4090 => 24 | .rtx5090 => 32
  | .mi300x => 192 | .mi325x => 256

@[db] def Gpu.isH100 (g : Gpu) : Bool :=
  g == .h100Sxm || g == .h100Pcie

/-- How the hour is bought. -/
inductive Pricing where
  | onDemand | spot | reserved1mo | reserved1yr
  deriving Repr, DecidableEq, Ord, LeanDb.ClosedEnum

inductive Region where
  | northAmerica | europe | asiaPacific | middleEast
  deriving Repr, DecidableEq, Ord, LeanDb.ClosedEnum

end GpuMarket
