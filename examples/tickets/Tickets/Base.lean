import Tickets.Entities
import Tickets.Queries
import Tickets.Seed

/-! The tickets base as a value. Tables, schema output, and row JSON are
all derived from the entity declarations; the query registrations are
`query%`-derived from the query defs' signatures; the seed is the one
imperative verb. Where the instance lives is decided at run time
(`--db`, `$LEANDB_DB`, or `data/tickets.sqlite`). -/

namespace Tickets

open LeanDb LeanDb.Cli

instance : CliArg Timestamp := ⟨fun s =>
  match s.toNat? with
  | some n => .ok ⟨n⟩
  | none => .error s!"expected an epoch-seconds timestamp, got {String.quote s}"⟩

def base : LeanDb.Base := {
  name := "tickets"
  tables := [.of User, .of Ticket, .of Comment]
  queries := [
    query% openTickets,
    query% unassigned,
    query% queueOf,
    query% slaBreached]
  seed := some seed
}

end Tickets
