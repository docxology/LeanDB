import Tickets

/-! The tickets CLI: `LeanDb.Cli.run` over this base's entities and
queries. Tables, schema output, and row JSON are all derived from the
entity declarations; the query registrations are `query%`-derived from
the query defs' signatures — only the imperative `seed` verb is
hand-written. -/

open Lean (Json) in
open LeanDb LeanDb.Cli Tickets in
instance : CliArg Timestamp := ⟨fun s =>
  match s.toNat? with
  | some n => .ok ⟨n⟩
  | none => .error s!"expected an epoch-seconds timestamp, got {String.quote s}"⟩

open Lean (Json) in
open LeanDb LeanDb.Cli Tickets in
def main (args : List String) : IO UInt32 := do
  Cli.run {
    name := "tickets"
    dbPath := "data" / "tickets.sqlite"
    specs := schema
    tables := [.of User, .of Ticket, .of Comment]
    queries := [
      ("seed", fun _ => do
        seed
        return Json.mkObj [("ok", Json.bool true), ("seeded", Json.bool true)]),
      query% openTickets,
      query% unassigned,
      query% queueOf,
      query% slaBreached]
  } args
