import Std.Http
import Std.Sync.Mutex
import LeanDb.Cli

namespace LeanDb.Http

/-! # HTTP over the handler

`<base> serve --http <port>` puts `Base.handle` behind HTTP/1.1 using the
toolchain's `Std.Http.Server`. Every route is sugar over one argv: the
typed routes below and `POST /rpc` (a JSON array of argv strings) reach
the same function, so the surface is exactly the CLI's. Responses are
the handler's JSON; the status code derives from the response `code`.
The connection is one SQLite handle, so requests run one at a time
behind a mutex. A client that sends `X-LeanDb-Fingerprint` is refused
with `schema_mismatch` (409) when it was compiled against another
schema. -/

open Std Std.Http Std.Async
open Lean (Json)

/-- HTTP status for a handler response. -/
def statusOf (j : Json) : Status :=
  if (j.getObjValAs? Bool "ok").toOption == some true then .ok
  else match (j.getObjValAs? String "code").toOption with
    | some "usage" | some "decode" => .badRequest
    | some "not_found" => .notFound
    | some "stale" | some "restricted" | some "duplicate" | some "missing_ref"
    | some "schema_mismatch" | some "unknown_lineage" | some "migrate" => .conflict
    | _ => .internalServerError

private def usage (m : String) : Nat × String := (400, m)

/-- Resolve a request to argv. `segs` are the decoded path segments,
    `query` the decoded query pairs, `body` the request body if any. -/
def route (method : String) (segs : List String) (query : List (String × String))
    (body : Option String) : Except (Nat × String) (List String) := do
  let eqs := query.filter (·.1 == "eq") |>.flatMap fun (_, v) => ["--eq", v]
  let limit := match query.lookup "limit" with | some n => ["--limit", n] | none => []
  let bodyStr ← match body with
    | some s => pure s
    | none => pure ""
  let needBody := fun (what : String) => do
    if bodyStr.trimAscii.isEmpty then throw (usage s!"{what} needs a JSON body") else pure bodyStr
  match method, segs with
  | "GET", ["schema"] => return ["schema"]
  | "GET", ["version"] => return ["version"]
  | "GET", ["help"] | "GET", [] => return ["help"]
  | "GET", ["log"] => return ["log"] ++ (match query.lookup "limit" with | some n => [n] | none => [])
  | "GET", ["tables", t] => return ["rows", t] ++ eqs ++ limit
  | "GET", ["tables", t, id] => return ["get", t, id]
  | "POST", ["tables", t] => return ["insert", t, ← needBody "insert"]
  | "PATCH", ["tables", t, id] | "PUT", ["tables", t, id] => return ["update", t, id, ← needBody "update"]
  | "DELETE", ["tables", t, id] => return ["delete", t, id]
  | "GET", "query" :: q :: args => return ["query", q] ++ args
  | "POST", ["query", q] =>
      -- {"args":["…", …]}: strings, parsed by the query's own CliArg instances
      let args ← if bodyStr.trimAscii.isEmpty then pure [] else
        match Json.parse bodyStr >>= (·.getObjValAs? (Array Json) "args") with
        | .ok arr => arr.toList.mapM fun a => match a with
            | .str s => pure s
            | .num n => pure (toString n)
            | .bool b => pure (toString b)
            | other => throw (usage s!"query argument must be a string, got {other.compress}")
        | .error m => throw (usage s!"expected \{\"args\":[…]}: {m}")
      return ["query", q] ++ args
  | "POST", ["seed"] => return ["seed"]
  | "GET", ["migrate"] | "GET", ["migrate", "status"] => return ["migrate", "status"]
  | "POST", ["migrate", "apply"] =>
      let flags := (if query.lookup "allow_destructive" == some "1" then ["--allow-destructive"] else []) ++
        (if query.lookup "backup" == some "0" then ["--no-backup"] else [])
      return ["migrate", "apply"] ++ flags
  | "POST", ["migrate", "rollback"] => return ["migrate", "rollback"]
  | "GET", ["migrate", "history"] => return ["migrate", "history"] ++ (match query.lookup "limit" with | some n => [n] | none => [])
  | "POST", ["backup"] => return ["backup"]
  | "POST", ["restore"] =>
      match Json.parse (← needBody "restore") >>= (·.getObjValAs? String "file") with
      | .ok f => return ["restore", f]
      | .error m => throw (usage s!"expected \{\"file\":\"…\"}: {m}")
  | "POST", ["rpc"] =>
      match Json.parse (← needBody "rpc") >>= fun j => j.getArr? >>= (·.toList.mapM (·.getStr?)) with
      | .ok argv => return argv
      | .error m => throw (usage s!"expected a JSON array of argv strings: {m}")
  | m, path => throw (404, s!"no route {m} /{String.intercalate "/" path}")

private def errJson (code : String) (m : String) : Json :=
  Json.mkObj [("ok", Json.bool false), ("code", Json.str code), ("message", Json.str m)]

private def respond (status : Status) (j : Json) : ContextAsync (Response Body.Any) := do
  let r ← (Response.withStatus status).json j.compress
  return { line := r.line, body := Body.Any.ofBody r.body, extensions := r.extensions }

/-- One request through `dispatch`. `fingerprint` is the served schema's. -/
def handleRequest (fingerprint : String) (dispatch : List String → IO Json)
    (req : Request Body.Stream) : ContextAsync (Response Body.Any) := do
  -- the handshake: a client compiled against another schema is told so
  if let some claimed := req.line.headers.get? (Header.Name.ofString! "x-leandb-fingerprint") then
    unless toString claimed == fingerprint do
      return ← respond .conflict (DbError.schemaMismatch (toString claimed) fingerprint).toJson
  let method := (toString req.line.method).toUpper
  let segs := (req.line.uri.path.toDecodedSegments.toList).filter (!·.isEmpty)
  let query := req.line.uri.query.toList.filterMap fun (k, v) => do
    let k ← k.decode
    some (k, (v.bind (·.decode)).getD "")
  let bytes : ByteArray ← Body.Stream.readAll req.body
  let body := if bytes.isEmpty then none else String.fromUTF8? bytes
  match route method segs query body with
  | .error (404, m) => respond .notFound (errJson "usage" m)
  | .error (_, m) => respond .badRequest (errJson "usage" m)
  | .ok argv =>
      let j ← dispatch argv
      respond (statusOf j) j

private def parseHost (host : String) : Except String Net.IPv4Addr :=
  match host.splitOn "." |>.map (·.toNat?) with
  | [some a, some b, some c, some d] =>
      if a < 256 && b < 256 && c < 256 && d < 256 then
        .ok (Net.IPv4Addr.ofParts a.toUInt8 b.toUInt8 c.toUInt8 d.toUInt8)
      else .error s!"bad IPv4 address {host}"
  | _ => .error s!"expected a dotted IPv4 address, got {host}"

/-- Serve `dispatch` on `host:port` until shutdown. -/
def serveWith (host : String) (port : UInt16) (fingerprint : String)
    (dispatch : List String → IO Json) (banner : Json) : IO UInt32 := do
  let ip ← match parseHost host with
    | .ok ip => pure ip
    | .error m =>
        IO.eprintln (errJson "usage" m).compress
        return 3
  let addr : Net.SocketAddress := .v4 { addr := ip, port }
  let handler := Std.Http.Server.Handler.ofFn (handleRequest fingerprint dispatch)
  IO.eprintln banner.compress
  Async.block do
    let server ← Std.Http.Server.serve addr handler
    server.waitShutdown
  return 0

/-- `<base> serve --http <port> [--bind <host>]`. -/
def serve (b : Base) (inst : Instance) (host : String) (port : UInt16) : IO UInt32 := do
  match ← Cli.Session.open b inst with
  | .error e =>
      IO.eprintln e.toJson.compress
      return e.exitCode
  | .ok sess =>
      let lock ← Std.Mutex.new sess
      let fp := fingerprint b.specs
      let dispatch := fun (argv : List String) =>
        (lock.atomically (fun ref => do b.handle inst (← ref.get) argv) : IO Json)
      serveWith host port fp dispatch <| Json.mkObj [("ok", Json.bool true),
        ("serving", Json.str s!"http://{host}:{port}"), ("base", Json.str b.name),
        ("instance", Json.str inst.path.toString), ("fingerprint", Json.str fp)]

initialize
  Cli.httpServer.set (some serve)

end LeanDb.Http
