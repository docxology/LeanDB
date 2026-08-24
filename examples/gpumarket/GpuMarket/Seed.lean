import GpuMarket.Entities

/-! Illustrative market snapshot (prices are plausible ballpark
    USD/GPU-hr as of mid-2026, not live quotes). -/

namespace GpuMarket

open LeanDb

private def observed : Timestamp := ⟨1756000000⟩

private def row (pr : Provider) (g : Gpu) (n : Nat) (p : Pricing)
    (milli : Nat) (r : Region := .northAmerica) (avail : Bool := true) :
    DbM Unit := do
  match Price.make milli, GpuCount.make n with
  | .ok price, .ok count =>
      discard <| insert Listing
        ⟨pr, g, count, p, r, price, avail, observed⟩
  | .error e, _ | _, .error e => throw (.decode "seed" "listing" e)

def seed : DbM Unit := do
  -- H100 SXM, on-demand
  row .lambdaLabs .h100Sxm 8 .onDemand 2490
  row .runpod     .h100Sxm 8 .onDemand 2790
  row .vastAi     .h100Sxm 8 .onDemand 2210
  row .coreweave  .h100Sxm 8 .onDemand 4760
  row .awsEc2     .h100Sxm 8 .onDemand 6980
  row .gcp        .h100Sxm 8 .onDemand 6350 (r := .europe)
  row .nebius     .h100Sxm 8 .onDemand 2950 (r := .europe)
  row .crusoe     .h100Sxm 8 .onDemand 3900
  row .togetherAi .h100Sxm 8 .onDemand 2390
  row .voltagePark .h100Sxm 8 .onDemand 1990
  -- H100 spot / reserved
  row .vastAi     .h100Sxm 8 .spot 1650
  row .runpod     .h100Sxm 8 .spot 1790
  row .awsEc2     .h100Sxm 8 .spot 2860
  row .lambdaLabs .h100Sxm 8 .reserved1yr 1850
  row .coreweave  .h100Sxm 8 .reserved1yr 3430
  -- H100 PCIe
  row .runpod     .h100Pcie 1 .onDemand 2390
  row .paperspace .h100Pcie 1 .onDemand 5950
  -- H200 / B200 / GH200
  row .lambdaLabs .h200 8 .onDemand 3290
  row .runpod     .h200 8 .onDemand 3590
  row .coreweave  .h200 8 .onDemand 6310
  row .nebius     .b200 8 .onDemand 5500 (r := .europe)
  row .coreweave  .b200 8 .onDemand 8900
  row .lambdaLabs .gh200 1 .onDemand 3190
  -- A100
  row .lambdaLabs .a100Sxm80 8 .onDemand 1290
  row .runpod     .a100Sxm80 8 .onDemand 1640
  row .vastAi     .a100Pcie40 1 .onDemand 640
  row .azure      .a100Sxm80 8 .onDemand 3670 (r := .europe)
  -- Workstation / inference cards
  row .runpod     .l40s 1 .onDemand 860
  row .coreweave  .l40s 1 .onDemand 1250
  row .gcp        .l4 1 .onDemand 700
  row .vastAi     .rtx4090 1 .onDemand 350
  row .runpod     .rtx4090 1 .onDemand 690
  row .vastAi     .rtx5090 1 .onDemand 640
  row .paperspace .a10 1 .onDemand 760
  -- AMD
  row .hotAisle   .mi300x 8 .onDemand 1990
  row .runpod     .mi300x 8 .onDemand 2490
  row .hotAisle   .mi325x 8 .onDemand 2990 (avail := false)
  row .vastAi     .mi300x 1 .spot 1550

end GpuMarket
