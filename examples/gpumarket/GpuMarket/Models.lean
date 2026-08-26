import GpuMarket.Entities
import GpuMarket.Arch

/-! # Models — the other open world

Model releases are rows, not vocabulary (they ship weekly); their *makers*
are a closed world. The cross-table query `canServe` joins the model table
against the listings market: VRAM arithmetic stays a residual conjunct
(the lambda is always applied), while the availability and join conditions
push to SQL. -/

namespace GpuMarket

open LeanDb

inductive Maker where
  | metaAi | deepseek | alibaba | mistral | openai | google | moonshot | zhipu
  deriving Repr, DecidableEq, Ord, LeanDb.ClosedEnum

structure ModelName where
  raw : String
  deriving Repr, DecidableEq

def ModelName.make (s : String) : Except String ModelName :=
  let t := s.trimAscii.toString
  if t.isEmpty then .error "model name must be nonempty" else .ok ⟨t⟩

instance : ColCodec ModelName := ColCodec.via (·.raw) ModelName.make

structure Model where
  name        : ModelName
  maker       : Maker
  paramsB     : Nat            -- total parameters, billions
  activeB     : Option Nat     -- MoE active parameters, if sparse
  contextK    : Nat            -- context window, thousands of tokens
  quantBits   : Nat := 16      -- native serving precision (16 bf16, 8 fp8, 4 mxfp4)
  openWeights : Bool := true
  deriving Repr, LeanDb.Entity

/-- Weights at native precision plus ~25% for KV cache and activations,
    in GB. -/
def Model.servingGb (m : Model) : Nat :=
  let weights := m.paramsB * m.quantBits / 8
  weights + weights / 4

/-- Does a listing's node hold the model? (VRAM arithmetic — residual at
    the SQL layer, still exact.) -/
def fitsOn (m : Model) (g : Gpu) (count : GpuCount) : Bool :=
  g.vramGb * count.n ≥ m.servingGb

/-- Available listings whose node fits the model, cheapest per-GPU-hour
    first — "where can I serve DeepSeek-V3, cheapest?". -/
def canServe (m : Ref Model) : DbM (Array (Stored Model × Stored Listing)) :=
  select [Model, Listing]
    (fun (mo, l) => mo.id == m && l.val.available && fitsOn mo.val l.val.gpu l.val.count)
    (.key fun (_, l) => l.val.usdHr)

def schema : List TableSpec := [Entity.spec Listing, Entity.spec Model]

def models : DbM (Array (Stored Model)) :=
  select [Model] (fun _ => true) (.key (·.val.paramsB))

private def mrow (name : String) (mk : Maker) (params : Nat)
    (active : Option Nat) (ctxK : Nat) (bits : Nat := 16) : DbM Unit := do
  match ModelName.make name with
  | .ok n => discard <| insert Model ⟨n, mk, params, active, ctxK, bits, true⟩
  | .error e => throw (.decode "seed" "model" e)

def seedModels : DbM Unit := do
  mrow "Llama-3.1-405B" .metaAi 405 none 128
  mrow "Llama-3.1-70B" .metaAi 70 none 128
  mrow "Llama-3.1-8B" .metaAi 8 none 128
  mrow "DeepSeek-V3" .deepseek 671 (some 37) 128 (bits := 8)
  mrow "DeepSeek-R1" .deepseek 671 (some 37) 128 (bits := 8)
  mrow "Qwen3-235B-A22B" .alibaba 235 (some 22) 128
  mrow "Qwen3-32B" .alibaba 32 none 128
  mrow "Mistral-Large-2" .mistral 123 none 128
  mrow "GPT-OSS-120B" .openai 120 (some 5) 128 (bits := 4)
  mrow "Kimi-K2" .moonshot 1000 (some 32) 128 (bits := 8)
  mrow "GLM-4.5" .zhipu 355 (some 32) 128
  mrow "Gemma-3-27B" .google 27 none 128

end GpuMarket
