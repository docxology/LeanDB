import Tickets

/-! The tickets CLI: `LeanDb.Cli.run` over this base's entities and
queries. Tables, schema output, and row JSON are all derived from the
entity declarations; only the query registrations below are base code. -/

open Lean (Json) in
open LeanDb LeanDb.Cli Tickets in
def main (args : List String) : IO UInt32 := do
  let ticketRows := fun (rows : Array (Stored Ticket)) =>
    Json.mkObj [("ok", Json.bool true), ("count", Lean.toJson rows.size),
      ("rows", Json.arr (rows.map (rowJson Ticket)))]
  let argNat := fun (args : List String) (name : String) => do
    match args with
    | [v] =>
        match v.toNat? with
        | some n => pure n
        | none => throw (DbError.decode "cli" name s!"expected a natural number, got {v}")
    | _ => throw (DbError.decode "cli" name "exactly one argument expected")
  Cli.run {
    name := "tickets"
    dbPath := "data" / "tickets.sqlite"
    specs := schema
    tables := [.of User, .of Ticket, .of Comment]
    queries := [
      ("seed", fun _ => do
        seed
        return Json.mkObj [("ok", Json.bool true), ("seeded", Json.bool true)]),
      ("open", fun _ => ticketRows <$> openTickets),
      ("unassigned", fun _ => ticketRows <$> unassigned),
      ("queue", fun args => do
        let uid ← argNat args "user-id"
        ticketRows <$> queueOf ⟨Int64.ofNat uid⟩),
      ("sla", fun args => do
        let now ← argNat args "now-epoch-seconds"
        let breaches ← slaBreached ⟨now⟩
        return Json.mkObj [("ok", Json.bool true), ("count", Lean.toJson breaches.size),
          ("rows", Json.arr (breaches.map fun (t, u) =>
            Json.mkObj [("ticket", rowJson Ticket t), ("reporter", rowJson User u)]))])]
  } args
