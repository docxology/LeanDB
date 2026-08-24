import Gpus.Queries

/-! # Seed data

All values pass through the smart constructors. `seedM` lifts an
`Except String` validation into `DbM` as a typed `.decode` error.
-/

namespace Gpus

open LeanDb

/-- Lift a smart-constructor result into `DbM`. -/
def seedM (context : String) (r : Except String α) : DbM α :=
  match r with
  | .ok a => pure a
  | .error msg => throw (.decode "seed" context msg)

private def provider! (name console : String) : DbM (Stored Provider) := do
  insert Provider {
    name := ← seedM s!"provider name {name}" (ProviderName.make name)
    console := ← seedM s!"console {console}" (Url.make console) }

private def offering! (provider : Ref Provider) (chip : Chip) (region : Region)
    (tenthsOfCent : Nat) (available : Bool) : DbM (Stored Offering) := do
  insert Offering {
    provider, chip, region, available
    hourly := ← seedM s!"hourly {tenthsOfCent}" (PricePerHour.make tenthsOfCent) }

/-- Four providers, twelve offerings mixing chips, regions, prices, and
    availability. Prices are tenths of a cent: 2490 = $2.49/hr. -/
def seed : DbM Unit := do
  let lambda ← provider! "Lambda" "https://cloud.lambda.ai"
  let runpod ← provider! "RunPod" "https://console.runpod.io"
  let hotaisle ← provider! "Hot Aisle" "https://admin.hotaisle.app"
  let coreweave ← provider! "CoreWeave" "https://cloud.coreweave.com"
  discard <| offering! lambda.ref .h100 .usEast 2490 true
  discard <| offering! lambda.ref .a100 .usWest 1290 true
  discard <| offering! lambda.ref .h100 .eu 2990 false
  discard <| offering! runpod.ref .rtx4090 .usEast 440 true
  discard <| offering! runpod.ref .rtx3090 .usWest 220 true
  discard <| offering! runpod.ref .l40s .eu 790 true
  discard <| offering! runpod.ref .h100 .usWest 2390 true
  discard <| offering! hotaisle.ref .mi300x .usEast 1990 true
  discard <| offering! hotaisle.ref .mi325x .usEast 2790 true
  discard <| offering! hotaisle.ref .mi300x .eu 2190 false
  discard <| offering! coreweave.ref .h100 .apac 3290 true
  discard <| offering! coreweave.ref .l40s .usEast 890 false

end Gpus
