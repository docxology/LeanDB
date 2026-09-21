import LeanDb.Http
import LeanDb.Client

namespace LeanDb.Host

/-! # `leandb host`: many bases, one port

Each base is its own binary (its types are compiled in), so hosting many
means supervising many: `leandb host --port P <name>=<exe>[,--db path]…`
spawns every base in `serve` mode (JSON lines over stdio), keeps one
connection each, and serves `/bases/<name>/…` with the same routes a
base serves alone — the argv is the wire between the two processes.
`GET /bases` lists them with their fingerprints. -/

open Lean (Json)

structure Child where
  name : String
  client : Client
  lock : Std.Mutex Unit
  fingerprint : String

/-- `name=path/to/exe[,arg,…]` → spawn and handshake the child: it must
    answer `version` within `deadlineMs` (default `handshakeDeadlineMs`)
    or the host kills it and reports a diagnostic naming the failed spec —
    a silent base, or one stalled mid-banner-line, must not wedge the host
    pre-bind (#62 facet 2). -/
def spawn (spec : String) (deadlineMs : Nat := handshakeDeadlineMs) : IO (Except String Child) := do
  match spec.splitOn "=" with
  | name :: rest =>
      let rest := String.intercalate "=" rest
      match rest.splitOn "," with
      | exe :: args =>
          if name.isEmpty || exe.isEmpty then return .error s!"expected name=exe[,args], got {spec}"
          let cfg : IO.Process.SpawnArgs := {
            cmd := exe
            args := (args ++ ["serve"]).toArray
            stdin := .piped
            stdout := .piped
            stderr := .inherit }
          try
            let child ← IO.Process.spawn cfg
            let client := Client.ofProcess child
            match ← client.rpcBounded ["version"] deadlineMs with
            | none =>
                client.close
                return .error s!"{name}: no handshake from {exe} within {deadlineMs} ms — killed the silent (or mid-line stalled) child from spec {spec}"
            | some (.error e) => client.close; return .error s!"{name}: could not query {exe}: {e}"
            | some (.ok v) =>
                let fp := (v.getObjValAs? String "code_fingerprint").toOption.getD ""
                return .ok { name, client := { client with fingerprint := fp }, lock := ← Std.Mutex.new (), fingerprint := fp }
          catch e =>
            return .error s!"{name}: could not start {exe}: {e}"
      | [] => return .error s!"expected name=exe[,args], got {spec}"
  | [] => return .error s!"expected name=exe[,args], got {spec}"

def Child.call (c : Child) (argv : List String) : IO Json :=
  c.lock.atomically fun _ => do
    match ← c.client.rpc argv with
    | .ok json => return json
    | .error e => return e.toJson

/-- `leandb host --port P [--bind H] name=exe[,args]…` -/
def run (args : List String) : IO UInt32 := do
  let rec parse : List String → Except String (Option Nat × String × Option String × List String)
    | [] => .ok (none, "127.0.0.1", none, [])
    | "--port" :: p :: rest => do
        let (_, h, t, specs) ← parse rest
        match p.toNat? with
        | some n => return (some n, h, t, specs)
        | none => throw s!"--port expects a number, got {p}"
    | "--bind" :: h :: rest => do let (p, _, t, specs) ← parse rest; return (p, h, t, specs)
    | "--auth-token" :: t :: rest => do let (p, h, _, specs) ← parse rest; return (p, h, some t, specs)
    | spec :: rest => do let (p, h, t, specs) ← parse rest; return (p, h, t, spec :: specs)
  let usage := "host --port <port> [--bind <host>] [--auth-token <t>] <name>=<exe>[,<arg>,…]…"
  match parse args with
  | .error m =>
      IO.eprintln (Json.mkObj [("ok", Json.bool false), ("code", Json.str "usage"), ("message", Json.str s!"{m}; {usage}")]).compress
      return 3
  | .ok (port?, host, token?, specs) =>
      let some port := port? | do
        IO.eprintln (Json.mkObj [("ok", Json.bool false), ("code", Json.str "usage"), ("message", Json.str usage)]).compress
        return 3
      if specs.isEmpty then
        IO.eprintln (Json.mkObj [("ok", Json.bool false), ("code", Json.str "usage"), ("message", Json.str s!"no bases given; {usage}")]).compress
        return 3
      let mut children : Array Child := #[]
      for spec in specs do
        match ← spawn spec with
        | .ok c => children := children.push c
        | .error m =>
            IO.eprintln (Json.mkObj [("ok", Json.bool false), ("code", Json.str "usage"), ("message", Json.str s!"{m} (host port {port})")]).compress
            return 3
      let list := Json.mkObj [("ok", Json.bool true), ("bases", Json.arr (children.map fun c =>
        Json.mkObj [("name", Json.str c.name), ("fingerprint", Json.str c.fingerprint)]))]
      let bases := fun (name : String) =>
        (children.find? (·.name == name)).map fun c => (c.fingerprint, c.call)
      Http.serveHosted host port.toUInt16 (← Http.Auth.resolve token?) list bases <| Json.mkObj [("ok", Json.bool true),
        ("serving", Json.str s!"http://{host}:{port}"),
        ("bases", Json.arr (children.map fun c => Json.str c.name))]

end LeanDb.Host
