import Crm.Entities
import Crm.Queries
import Crm.Seed

/-! The crm base as a value: tables (the schema is derived from them),
`query%`-derived queries, and the seed. -/

namespace Crm

open LeanDb LeanDb.Cli

instance : CliArg Timestamp := ⟨fun s =>
  match s.toNat? with
  | some n => .ok ⟨n⟩
  | none => .error s!"expected an epoch-seconds timestamp, got {String.quote s}"⟩

def base : LeanDb.Base := {
  name := "crm"
  tables := [.of Company, .of Person, .of Interaction, .of Ask]
  queries := [
    query% liveAsks,
    query% pipelineFor,
    query% staleAsks,
    query% contactsOf]
  seed := some seed
}

end Crm
