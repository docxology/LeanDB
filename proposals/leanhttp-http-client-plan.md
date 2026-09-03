# leanhttp — an HTTP client for Lean 4 over libcurl

**Status:** M0–M3 implemented 2026-09-02 as two sibling repositories:
`leanhttp` and `leandb-http`. The LeanDB transport seam and dashboard
integration are implemented in this repository. The macOS suites and
the complete LeanDB release check pass. Linux CI, public TLS CI, tags,
and published dependency revisions remain M4 release work.

## Why

Lean v4.33 ships an HTTP/1.1 *server* (`Std.Http.Server`) and no client.
LeanDB's typed remote client (`LeanDb.Client`, `client%`) therefore speaks
JSON lines to a base process it spawns itself; it cannot reach a base
served over HTTP (`serve --http`, `leandb host`) on another machine.
libcurl is the boring, correct answer: present on every macOS (SDK
headers plus `libcurl.4.dylib`; 8.7.1 on this machine) and on practically
every Linux, with TLS, redirects, proxies, HTTP/2 and timeouts already
right.

Exit path: if `Std.Http` grows a client, `leandb-http` (below) becomes a
one-file adapter over it and leanhttp retires. The typed surface is
built on `Std.Http`'s data types from day one so that day costs nothing.

## The pattern, taken from leansqlite

leansqlite (`leanprover/leansqlite`, Lean FRO, Apache 2.0) is the
reference for how a C library is bound in this ecosystem. What it does,
and what leanhttp copies:

1. **Three layers, decreasing privacy.** `SQLite/FFI.lean` holds only
   `@[extern]` `opaque` declarations, most of them `private`; `LowLevel.lean`
   wraps them in Lean structures with typed fields and documented
   semantics; `QueryParam`/`QueryResult` are typeclasses over that. The
   raw layer is never the API.
2. **Handles are opaque nonempty types.** `opaque T : NonemptyType`,
   `def Conn : Type := T.type deriving Nonempty`; the C side wraps the
   pointer with `lean_alloc_external` in a class registered once, from a
   `builtin_initialize` that calls `leansqlite_initialize`. The finalizer
   is the library's destructor (`sqlite3_close`, `sqlite3_finalize`).
3. **Lifetime by containment.** A statement is only valid while its
   connection lives, so the wrapper `structure Stmt where db : SQLite;
   stmt : FFI.Stmt` retains the connection inside the statement value.
   Reference counting does the rest.
4. **Ownership at the boundary is explicit.** Handles cross as borrowed
   (`@&Conn`, `b_lean_obj_arg`); strings cross owned and the C side
   `lean_dec`s them after copying; `Option String` is passed as an
   object and tested with `lean_is_scalar`; byte results are
   `lean_alloc_sarray(1, n, n)` plus `memcpy`; scalars are `lean_box_uint64`,
   `lean_box_float`.
5. **Errors are `IO.Error.otherError code msg`** built with
   `lean_mk_io_error_other_error(code, msg)`, so Lean can match on the
   library's own code (LeanDB matches SQLite's 19 this way). Text is
   diagnostics, the code is identity.
6. **Flags are structures, not integers.** `OpenFlags` has fields
   `mode : Mode`, `uri : Bool`, `memory : Bool`, `threading : Option Threading`;
   the bit pattern is computed by `OpenFlags.toInt` in Lean and passed as
   one `Int32`. The C side never sees a Lean enum.
7. **Values in and out go through typeclasses** (`QueryParam`,
   `NullableQueryParam`, `ResultColumn`, `Row`) with deriving handlers,
   and a small reader monad (`RowReader`) sequences column reads.
8. **Build:** `buildO` of the C files with `-I (← getLeanIncludeDir)`,
   one `extern_lib` static library, `lean_lib … precompileModules := true`
   (so `#eval` and the interpreter reach the native code), tests in a
   separate Lake project under `tests/` so consumers inherit no
   test-only dependencies. The toolchain is pinned and moved in lockstep.

Two leansqlite gaps LeanDB had to work around are avoided by design
here: leanhttp exposes an explicit `close`, and it enables the
library's extended diagnostics (`CURLOPT_ERRORBUFFER`) from the start.

## Decision record

Every choice below is recorded the same way: the decision, the
alternatives considered, why this one, what it costs, and what would
make us revisit it. Later sections reference these by number.

### D1. Load libcurl at run time with `dlopen`; never link it

- **Alternatives.** (a) `-lcurl` at link time; (b) vendor libcurl's
  source and build it like leansqlite builds SQLite; (c) `dlopen`.
- **Why (c).** Lake does not propagate a dependency's link flags to
  downstream executables, so (a) means every consumer's lakefile repeats
  `-lcurl` and a missing flag is a linker error far from its cause. (b)
  is not one amalgamation: libcurl needs a TLS backend (OpenSSL,
  SecureTransport, …) and its own build system; vendoring it means
  owning that. (c) keeps "nothing to install": macOS ships
  `libcurl.4.dylib`, nearly every Linux ships `libcurl.so.4`.
- **Cost.** Symbols are resolved at first use, so a missing library is a
  run-time error (typed: `Error.Kind.libraryNotFound`, with the names
  searched). `curl_easy_setopt` is variadic and must be called through
  a variadic function-pointer type or arm64 misbehaves.
- **Revisit when.** M0 fails on Linux, or Lake gains link-flag
  propagation. Fallback kept in the design: a build option that links
  `-lcurl` and skips the loader.

### D2. Synchronous easy interface; concurrency by tasks over sessions

- **Alternatives.** (a) the multi interface with an event loop;
  (b) integrate with `Std.Async`; (c) blocking `curl_easy_perform`.
- **Why (c).** LeanDB's wire is request/response JSON; one blocking call
  per request is the whole need. (a) and (b) are real work (a Lean-side
  poll loop, cancellation, back-pressure) with no consumer yet.
- **Cost.** A `Session` blocks its thread; parallelism is `Task`s each
  owning a session (`requestTask`). A `Session` is not shareable across
  threads — libcurl's own rule for easy handles.
- **Revisit when.** A consumer needs thousands of concurrent requests or
  cancellation mid-transfer.

### D3. Bodies accumulate in C, are typed in Lean

- **Alternatives.** (a) stream chunks into a Lean closure from the
  write callback; (b) accumulate in a C buffer and hand back one
  `ByteArray`.
- **Why (b).** Calling back into Lean from a libcurl callback means
  re-entering the runtime from C with the handle borrowed, error
  propagation across the C frame, and a much larger binding. One
  `ByteArray` per body is what LeanDB (and JSON in general) needs.
- **Cost.** Two copies of each body (C buffer, then `ByteArray`), and
  memory proportional to the body; `maxBody` caps it and turns overflow
  into `Error.Kind.tooLarge` instead of unbounded growth.
- **Revisit when.** Someone downloads files rather than payloads;
  streaming is the post-v1 item.

### D4. Typed errors; an HTTP status is data, not an error

- **Alternatives.** (a) throw `IO.Error` with libcurl's message;
  (b) treat 4xx/5xx as errors; (c) `Except Error Response` with a closed
  `Error.Kind` and a normal `Response` for any status.
- **Why (c).** leansqlite's lesson: the code is identity, the text is
  diagnostics. Callers match on `Kind`, never on strings. Whether a 404
  is an error is the caller's business (LeanDB's `not_found` is a 404
  with a typed body).
- **Cost.** A classification table from `CURLcode` to `Kind` that must
  be kept complete; unknown codes land in `Kind.other` with the raw
  code kept, so nothing is lost.
- **Revisit when.** never; `Outcome` (D11) builds on it.

### D5. Global initialisation once, no cleanup

- **Alternatives.** (a) `curl_global_init` per session; (b) once from
  `builtin_initialize`, with `curl_global_cleanup` at exit; (c) once,
  never cleaned up.
- **Why (c).** (a) is documented as unsafe (not thread-safe, must run
  before any other thread). (b) has no reliable hook in a Lean process.
  libcurl documents (c) as acceptable for process lifetime.
- **Cost.** A leak-checker sees libcurl's global state at exit. Accepted.

### D6. The raw layer is private; three setters cross the FFI

- **Alternatives.** (a) expose `setopt (code : UInt32) (value : …)`;
  (b) one extern per option; (c) three externs by value kind (`long`,
  `string`, `bytes`) and a Lean-side typed option family.
- **Why (c).** Every libcurl option takes a `long`, a `char *`, or a
  pointer with a size, so three setters cover the library. The *pairing*
  of code and value type is where mistakes live, and an indexed
  inductive `Opt : Type → Type` makes a wrong pairing untypeable. (a)
  is the stringly/numberly API this plan exists to avoid; (b) is a C
  function per option with the same drift risk and no extra safety.
- **Cost.** The option codes are transcribed into Lean and mirrored by a
  `_Static_assert` table in `bindings/curl_options.h` that checks each
  against the real header at build time. Generating both tables from one
  source is useful M4 hardening; the initial implementation keeps the
  small duplication visible and covered by compilation and tests.
- **Revisit when.** never for the shape; the table grows as options are
  added.

### D7. Reuse `Std.Http`'s data types for the public vocabulary

- **Alternatives.** (a) own `Method`/`Url`/`Headers`/`Status` types;
  (b) plain strings and numbers; (c) `Std.Http.Method`, `URI`, `Headers`
  with validated `Header.Name`/`Header.Value`, `Status`.
- **Why (c).** They are validated (a header name with a space or a value
  with a CR cannot be constructed), they are what `Std.Http.Server`
  speaks (so a client and a server in one program share one
  vocabulary), and they are what a future `Std` client would use — the
  exit path costs nothing. (a) duplicates them; (b) is the thing to
  avoid.
- **Cost.** These types are new in 4.33 and may churn; leanhttp pins
  the toolchain with LeanDB and tracks it.
- **Revisit when.** `Std.Http` types move in a way that breaks the
  server/client symmetry (unlikely: they are shared by construction).

### D8. `Body` carries its content type; `Tls`, `Redirects`, `Auth` are inductives

- **Alternatives.** (a) `body : Option ByteArray` plus a `Content-Type`
  header the caller remembers to set; `followRedirects : Bool` plus
  `maxRedirects : Nat`; `verifyTls : Bool := true`; (b) inductives whose
  constructors name the policies.
- **Why (b).** A body without a content type is a bug waiting for a
  server; `.json j` sets it, `.form fields` escapes and sets it, and
  the pairing cannot drift. `Redirects.never | .upTo n` has no invalid
  combination (`follow = false, max = 10` means nothing). `Tls.insecureNoVerify`
  is a constructor you have to write out, not a `false` that hides in a
  record update; it logs once. `Auth.basic user pass` sets
  `CURLOPT_USERPWD`, so the credential never passes through a header
  string the caller formats.
- **Cost.** More types to learn than "headers and bytes"; each is small
  and documented.

### D9. `Request.uri` is a parsed `URI`; string conveniences return `Except`

- **Alternatives.** (a) `url : String` handed to libcurl; (b) `URI`
  parsed at construction, with `LeanHttp.get "…"` returning
  `Except Error Response` after parsing.
- **Why (b).** A malformed URL is refused before a socket opens, with
  `Kind.urlMalformed`, instead of surfacing mid-request from libcurl
  with a less specific code. Relative URIs resolve against
  `Session.baseUri` in Lean, deterministically.
- **Cost.** One parse per request (negligible) and `URI` in signatures.

### D10. `Session` owns one handle and its defaults; keep-alive falls out

- **Alternatives.** (a) a fresh handle per request; (b) a global pool;
  (c) `Session` = one easy handle plus defaults (base URI, headers, TLS,
  agent, proxy, encoding, `maxBody`), reused across requests.
- **Why (c).** libcurl keeps connections alive per easy handle, so
  reusing one gives keep-alive without any pooling code; defaults on
  the session are what a LeanDB client needs (base URL, fingerprint
  header, timeouts). (a) reconnects every time; (b) is shared mutable
  state with libcurl's no-sharing rule to police.
- **Cost.** Not thread-safe; `withSession` closes on every path; an
  explicit `close` exists (leansqlite lacked one and LeanDB had to work
  around it).
- **Revisit when.** D2 is revisited.

### D11. Typed bodies both ways, and `Outcome` instead of nested `Except`s

- **Alternatives.** (a) callers decode `Response.body` themselves;
  (b) `ToBody`/`FromBody` classes and `Session.exchange` returning a
  four-constructor `Outcome` (ok, non-2xx, decode failure, transport
  failure).
- **Why (b).** It is leansqlite's `QueryParam`/`ResultColumn` idea at
  the HTTP boundary: encoding and decoding are canonical per type, JSON
  is one instance, `FromJson` types come for free, and the four ways a
  typed exchange can end are four constructors rather than
  `Except Error (Except String (Option α))`.
- **Cost.** One more type (`Outcome`) and the discipline of writing
  instances for domain types; a deriving handler covers the common
  case.

### D12. Header block parsed in Lean, not C

- **Alternatives.** (a) C builds a Lean array of pairs; (b) C returns
  the raw header block and Lean parses it into `Std.Http.Headers`.
- **Why (b).** Keeps the C side to memory movement; parsing (folded
  lines, duplicate names, the status line after a redirect chain) is
  easier to test in Lean and produces the validated `Headers` type
  directly.
- **Cost.** One pass over the header text in Lean per response.

### D13. `libraryNotFound` is a reserved code above libcurl's range

- **Alternatives.** (a) a separate exception type from the loader;
  (b) reuse `CURLE_FAILED_INIT`; (c) code 9000 with the searched names
  in the detail, classified as `Kind.libraryNotFound`.
- **Why (c).** One error path (`otherError code detail`) for
  everything the binding raises; the loader's failure is just another
  code, and `Kind` names it. (b) would be indistinguishable from a real
  init failure.
- **Cost.** A documented reserved range; the table notes it.

### D14. A separate `leandb-http` package; a small transport seam in the engine

- **Alternatives.** (a) `leandb` requires `leanhttp` and gains the
  transport; (b) the transport lives in a third package requiring
  both, and the engine only gains a transport record and a
  `DbError.transport` constructor.
- **Why (b).** Every base links the whole engine; (a) would make every
  base carry the loader even when it never speaks HTTP. The seam in the
  engine is small and honest: `Client` was already "something that
  answers argv with JSON", and naming the transport failure as its own
  `DbError` is one line.
- **Cost.** Three repositories to version together (leanhttp,
  leandb-http, leandb); RELEASING's lockstep note grows by two lines.
- **Revisit when.** `Std.Http` grows a client: `leandb-http` becomes an
  adapter over it and leanhttp retires (the exit path).

### D15. Tests against Lean's own `Std.Http.Server`, in-process

- **Alternatives.** (a) hit public endpoints; (b) a Python or Node
  fixture server; (c) an in-process `Std.Http.Server` on port 0.
- **Why (c).** No network in the default run, no foreign runtime, and
  the server speaks the same `Std.Http` types (D7), so a request that
  round-trips is checked against a typed peer. Public endpoints stay in
  an opt-in TLS job.
- **Cost.** Test routes to write (`/echo`, `/status/:n`,
  `/redirect/:n`, `/slow/:ms`, `/large/:bytes`); they are the test
  suite's fixture and are small.

### D16. `precompileModules`, a pinned toolchain, tests in a sub-project

- **Why.** Directly from leansqlite: native code must be reachable from
  `#eval` and the interpreter; the toolchain pin moves in lockstep with
  LeanDB's; a `tests/` sub-project keeps consumers free of test-only
  dependencies.
- **Cost.** Precompilation adds build time to consumers; leansqlite
  already imposes it on LeanDB, so nothing new.

## The package

```
leanhttp/                       (separate repository)
  lakefile.lean                 extern_lib leanhttp (bindings/leanhttp.c); lean_lib LeanHttp, precompileModules
  lean-toolchain                pinned to LeanDB's (v4.33.0), moved in lockstep
  bindings/leanhttp.c           dlopen loader, handle class, three setters, perform, callbacks
  bindings/curl_options.h       the CURLOPT_* codes leanhttp uses, as a static_assert table
  LeanHttp.lean                 re-exports
  LeanHttp/FFI.lean             private externs (handle-level)
  LeanHttp/Option.lean          the typed option family (internal)
  LeanHttp/Types.lean           Method/URI/Headers/Status from Std.Http; Body, Redirects, Tls, Auth, Timeouts
  LeanHttp/Error.lean           CURLcode newtype, Error.Kind, Error
  LeanHttp/Session.lean         Session: a handle plus defaults; request/perform
  LeanHttp/Codec.lean           ToBody / FromBody typeclasses; JSON instances
  LeanHttp/Headers.lean         header-block parsing into Std.Http.Headers
  tests/                        its own Lake project (as leansqlite does)
```

### Layer 1 — `LeanHttp/FFI.lean` (private)

```lean
module
namespace LeanHttp.FFI

@[extern "leanhttp_initialize"] private opaque init : IO Unit
builtin_initialize init                    -- registers the handle class, curl_global_init, dlopen

opaque T : NonemptyType.{0}
def Handle : Type := T.type deriving Nonempty      -- CURL *; finalizer = curl_easy_cleanup

@[extern "leanhttp_available"]     opaque available : IO Bool
@[extern "leanhttp_version"]       opaque version : IO String          -- curl_version()
@[extern "leanhttp_easy_init"]     private opaque easyInit : IO Handle
@[extern "leanhttp_easy_reset"]    private opaque reset : @&Handle → IO Unit
@[extern "leanhttp_setopt_long"]   private opaque setLong  : @&Handle → UInt32 → Int64 → IO Unit
@[extern "leanhttp_setopt_string"] private opaque setString : @&Handle → UInt32 → String → IO Unit
@[extern "leanhttp_setopt_bytes"]  private opaque setBytes : @&Handle → UInt32 → @&ByteArray → IO Unit
@[extern "leanhttp_set_headers"]   private opaque setHeaders : @&Handle → @&Array String → IO Unit
/-- Perform. A CURLcode ≠ 0 is `IO.Error.otherError code detail`. -/
@[extern "leanhttp_perform"]       private opaque perform : @&Handle → IO UInt32
@[extern "leanhttp_response_headers"] private opaque responseHeaders : @&Handle → IO ByteArray
@[extern "leanhttp_response_body"] private opaque responseBody : @&Handle → IO ByteArray
@[extern "leanhttp_effective_url"] private opaque effectiveUrl : @&Handle → IO String
@[extern "leanhttp_close"]         private opaque close : @&Handle → IO Unit   -- cleanup now, finalizer becomes a no-op
@[extern "leanhttp_escape"]        opaque escape : String → IO String         -- curl_easy_escape, for query encoding
end LeanHttp.FFI
```

Exactly three setters cross the boundary (D6). Every option the library
ever sets is one of `long`, `char *`, or `(ptr, size)`; the *choice* of
code and the *typing* of the value live in Lean.

### Layer 2 — `LeanHttp/Option.lean` (internal): the option family

An indexed inductive (D6): each constructor names one `CURLOPT_*` and
fixes the Lean type of its value. Setting an option is total and cannot
pair a code with the wrong kind of value.

```lean
namespace LeanHttp

/-- One libcurl option, indexed by the type of value it takes. -/
inductive Opt : Type → Type where
  | url              : Opt Std.Http.URI
  | customRequest    : Opt Std.Http.Method
  | httpGet          : Opt Unit                 -- CURLOPT_HTTPGET, resets method state
  | noBody           : Opt Bool                 -- HEAD
  | postFields       : Opt ByteArray            -- + POSTFIELDSIZE_LARGE, set together
  | timeout          : Opt Std.Time.Millisecond.Offset
  | connectTimeout   : Opt Std.Time.Millisecond.Offset
  | followLocation   : Opt Bool
  | maxRedirs        : Opt Nat
  | sslVerifyPeer    : Opt Bool
  | sslVerifyHost    : Opt Bool
  | caInfo           : Opt System.FilePath
  | sslCert          : Opt System.FilePath
  | sslKey           : Opt System.FilePath
  | userAgent        : Opt String
  | acceptEncoding   : Opt Encoding              -- .identity | .gzip | .any
  | httpVersion      : Opt HttpVersion           -- .http11 | .http2 | .http2Tls | .default
  | proxy            : Opt Std.Http.URI
  | noProxy          : Opt (List String)
  | userPwd          : Opt (String × String)     -- basic auth, CURLOPT_USERPWD
  | bearer           : Opt String                -- CURLOPT_XOAUTH2_BEARER + HTTPAUTH_BEARER
  | tcpKeepAlive     : Opt Bool
  | maxFileSize      : Opt Nat                   -- refuse bodies larger than this

/-- The CURLOPT_* code, in one place, checked against the C table. -/
def Opt.code : Opt α → UInt32
/-- How the value crosses: the three setters. -/
private def Opt.set (h : FFI.Handle) : Opt α → α → IO Unit
  | .url, u => FFI.setString h Opt.url.code (toString u)
  | .timeout, ms => FFI.setLong h Opt.timeout.code ms.val …
  | .postFields, b => do FFI.setBytes h Opt.postFields.code b; FFI.setLong h POSTFIELDSIZE_LARGE b.size
  | …
end LeanHttp
```

`bindings/curl_options.h` lists the same codes with
`_Static_assert(LEANHTTP_OPT_URL == CURLOPT_URL, …)` against the real
header at build time, so a libcurl header change cannot silently
renumber an option. The initial Lean table is deliberately adjacent and
small; a generator is M4 hardening.

### Layer 3 — `LeanHttp/Types.lean`: the public vocabulary

Reused from `Std.Http` (D7: already validated types, and the server
speaks them): `Std.Http.Method`, `Std.Http.URI` (parsed, `URI.parse?`),
`Std.Http.Headers` with `Header.Name`/`Header.Value` (validated
constructors; a header with a CR in it does not typecheck into
existence), `Std.Http.Status` (with `Status.toCode`/`ofCode`). Own
types where libcurl has a notion `Std.Http` does not:

```lean
namespace LeanHttp

/-- What is sent. The content type is part of the value, never a loose header. -/
inductive Body where
  | empty
  | bytes (contentType : Std.Http.Header.Value) (data : ByteArray)
  | text  (contentType : Std.Http.Header.Value) (data : String)
  | json  (data : Lean.Json)                              -- application/json
  | form  (fields : List (String × String))               -- application/x-www-form-urlencoded, escaped via FFI.escape

inductive Redirects where
  | never
  | upTo (n : Nat)                                        -- CURLOPT_FOLLOWLOCATION + MAXREDIRS

/-- TLS policy. The insecure form is a named constructor, not a `Bool := false`. -/
inductive Tls where
  | system                                                -- verify peer and host with the system store
  | bundle (caInfo : System.FilePath)                     -- verify with this CA bundle
  | mutual (caInfo : Option System.FilePath) (cert key : System.FilePath)
  | insecureNoVerify                                      -- CURLOPT_SSL_VERIFYPEER 0; logs a warning once

inductive Auth where
  | none
  | basic (user password : String)
  | bearer (token : String)

structure Timeouts where
  connect : Std.Time.Millisecond.Offset := .ofNat 10000
  total   : Std.Time.Millisecond.Offset := .ofNat 30000

inductive Encoding | identity | gzip | any
inductive HttpVersion | default | http11 | http2 | http2Tls

structure Request where
  method   : Std.Http.Method := .get
  uri      : Std.Http.URI
  headers  : Std.Http.Headers := .empty
  body     : Body := .empty
  redirects : Redirects := .upTo 10
  timeouts : Timeouts := {}
  auth     : Auth := .none

structure Response where
  status  : Std.Http.Status
  headers : Std.Http.Headers
  body    : ByteArray
  /-- The URL after redirects (CURLINFO_EFFECTIVE_URL). -/
  effectiveUri : Std.Http.URI
end LeanHttp
```

`Request.uri` is a `URI` (D9), so a malformed URL is refused at
construction (`URI.parse?`), not by libcurl mid-request. Convenience
constructors that take a `String` return `Except LeanHttp.Error Request` and
never panic. `Body`, `Redirects`, `Tls` and `Auth` are inductives by D8.

### Layer 3 — `LeanHttp/Error.lean`

```lean
namespace LeanHttp
/-- libcurl's own code, kept verbatim; the identity of a failure. -/
structure CURLcode where
  toUInt32 : UInt32
  deriving DecidableEq, Repr, Hashable

/-- The closed classification a caller matches on. Every libcurl code maps to one. -/
inductive Error.Kind where
  | libraryNotFound (searched : List String)
  | unsupportedProtocol | urlMalformed
  | couldntResolveProxy | couldntResolveHost | couldntConnect
  | timeout                                   -- CURLE_OPERATION_TIMEDOUT
  | tooManyRedirects
  | ssl (detail : SslFailure)                  -- connectError | peerCertificate | caCert | cipher | clientCert | other
  | sendRecv                                  -- CURLE_SEND_ERROR / RECV_ERROR / PARTIAL_FILE / GOT_NOTHING
  | tooLarge                                  -- CURLE_FILESIZE_EXCEEDED (maxFileSize)
  | aborted                                   -- CURLE_ABORTED_BY_CALLBACK
  | other

structure Error where
  kind    : Error.Kind
  code    : CURLcode
  message : String                            -- curl_easy_strerror
  detail  : String                            -- CURLOPT_ERRORBUFFER, often more specific
  deriving Repr

def Error.ofIO : IO.Error → Option Error       -- `otherError code detail` → Error, none for foreign errors
end LeanHttp
```

The C side raises `lean_mk_io_error_other_error(curlcode, detail)`;
`Error.ofIO` classifies (D4; the loader's `libraryNotFound` is code 9000
by D13). `Session.request` returns `IO (Except Error Response)`, so
callers never match on `IO.Error` text.

### Layer 3 — `LeanHttp/Session.lean` (D10, D2)

```lean
namespace LeanHttp
/-- One libcurl easy handle plus defaults applied to every request made
    through it. Keep-alive is automatic across requests on one session.
    Not thread-safe; one session per task. -/
structure Session where
  private handle : FFI.Handle
  baseUri  : Option Std.Http.URI := none         -- relative `Request.uri`s resolve against it
  headers  : Std.Http.Headers := .empty          -- sent with every request, request headers win
  tls      : Tls := .system
  userAgent : String := "leanhttp/0.1"
  encoding : Encoding := .any
  httpVersion : HttpVersion := .default
  proxy    : Option Std.Http.URI := none
  maxBody  : Option Nat := none

def Session.new (cfg : Session.Config := {}) : IO (Except Error Session)   -- `libraryNotFound` surfaces here
def Session.close (s : Session) : IO Unit
def Session.request (s : Session) (r : Request) : IO (Except Error Response)
def Session.withSession (cfg) (k : Session → IO α) : IO (Except Error α)   -- closes on every path

-- One-shot conveniences, each a Session.new/request/close:
def get     (uri : Std.Http.URI) (headers := .empty) : IO (Except Error Response)
def post    (uri : Std.Http.URI) (body : Body) (headers := .empty) : IO (Except Error Response)
def request (r : Request) : IO (Except Error Response)
def requestTask (r : Request) : IO (Task (Except Error Response))          -- own session inside the task
end LeanHttp
```

### Layer 4 — `LeanHttp/Codec.lean`: typed bodies both ways (D11)

```lean
namespace LeanHttp
/-- Values that become a request body with a content type. -/
class ToBody (α : Type) where
  toBody : α → Body
instance : ToBody Lean.Json := ⟨.json⟩
instance : ToBody String := ⟨.text (Header.Value.ofString! "text/plain; charset=utf-8")⟩
instance : ToBody ByteArray := ⟨.bytes (Header.Value.ofString! "application/octet-stream")⟩

/-- Values decoded from a response body, checking the content type. -/
class FromBody (α : Type) where
  fromBody : Std.Http.Headers → ByteArray → Except String α
instance : FromBody ByteArray
instance : FromBody String                                  -- UTF-8 or a typed failure
instance : FromBody Lean.Json                                -- requires application/json (or a JSON parse)
instance [Lean.FromJson α] : FromBody α                       -- through Json

/-- A typed exchange: encode, send, require a 2xx, decode; every other
    outcome is a constructor of `Outcome`. -/
inductive Outcome (α : Type) where
  | ok (value : α) (response : Response)
  | status (response : Response)                             -- non-2xx, with the body for the caller
  | decode (message : String) (response : Response)
  | transport (error : Error)

def Session.exchange [ToBody β] [FromBody α] (s : Session) (method : Std.Http.Method)
    (uri : Std.Http.URI) (payload : β) (headers := .empty) : IO (Outcome α)
def Session.getAs [FromBody α] (s : Session) (uri : Std.Http.URI) : IO (Outcome α)
end LeanHttp
```

This is the leansqlite `QueryParam`/`ResultColumn` idea applied to HTTP:
the boundary is typed in both directions, `Json` is one instance, and a
deriving handler for `FromBody` over `Lean.FromJson` types is the
`Row`-style convenience.

### The C side (`bindings/leanhttp.c`, ~350 lines; D1, D3, D12, D13)

- **Loader:** `static void *lib; static struct { … } fn;` filled by
  `dlsym` under `pthread_once`; every extern checks and raises
  `libraryNotFound` (a reserved code above libcurl's range, `9000`, with
  the searched names in the detail) otherwise.
- **Handle class:** registered in `leanhttp_initialize`; the external
  data is `struct { CURL *h; struct curl_slist *hdrs; uint8_t *post; size_t post_len; char err[CURL_ERROR_SIZE]; buf headers, body; int closed; }`
  so the header list, the request body, the error buffer and the
  accumulators die with the handle; `close` runs the cleanup early and
  marks `closed` so the finalizer does nothing twice.
- **Callbacks:** `write_cb`/`header_cb` append to `buf` (doubling
  growth, capped by `maxFileSize` when set → `CURLE_WRITE_ERROR` with a
  detail); `perform` converts both to `ByteArray`s, reads
  `CURLINFO_RESPONSE_CODE` and `CURLINFO_EFFECTIVE_URL`, resets the
  accumulators.
- **Setters:** `setopt_long`, `setopt_string` (copies the C string
  before `lean_dec`; libcurl copies strings too), `setopt_bytes` (copies
  into `post`, then sets `POSTFIELDS`+`POSTFIELDSIZE_LARGE`),
  `set_headers` (rebuilds the `curl_slist` from an `Array String` of
  `Name: Value` lines already validated in Lean).
- **Ownership** follows leansqlite: handles borrowed, strings and arrays
  owned and `lean_dec`ed after use, results via `lean_io_result_mk_ok`.
- `curl_options.h` carries the `_Static_assert` table (D6).

## Testing (D15, D16)

`tests/` is its own Lake project. The server is Lean's own
`Std.Http.Server`, started in-process on port 0. The current suite covers
binary bodies including NUL bytes, custom methods, JSON and form content
types, form escaping, default/request header precedence, basic and bearer
auth, generic `FromJson` decoding, duplicate response headers, HEAD, 404
as response data, redirect follow/disable/limit behavior, total timeout,
response size limits, connection refusal, concurrent `requestTask`s, and
the forced-library loader failure. M4 adds Linux and public/self-signed
TLS jobs; those are not claimed by the local suite.

## LeanDB integration: `leandb-http` (D14)

A second small package, so the engine keeps no HTTP-client dependency
and bases that never need it link nothing extra:

```
leandb-http/                    requires leandb (git, tag) and leanhttp (git, tag)
  LeanDbHttp.lean               the HTTP transport for LeanDb.Client
```

- **Engine seam (in LeanDB, no libcurl there):** `LeanDb.Client` becomes
  a transport record — `structure Client where rpc : List String → IO (Except DbError Json); fingerprint : String; close : IO Unit`
  — with the spawned-process form as the first implementation.
  `client%`, `Client.call`, `Client.argv`, `CliRender`, `QueryIn` are
  unchanged. A `DbError.transport (message : String)` constructor names
  wire failures instead of borrowing `.sqlite`.
- **`LeanDb.HttpClient.connect (base : Std.Http.URI) (fingerprint : String) (config : LeanHttp.Session.Config := {}) : IO (Except DbError Client)`**
  performs `GET <base>/version` for the handshake and implements `rpc`
  as `POST <base>/rpc` with `Body.json (argv)` and the
  `X-LeanDb-Fingerprint` header (a `Header.Name` constant, not a string
  at call sites). Under `leandb host`, `base` is `http://host:port/bases/<name>`.
  Response JSON is mapped exactly as the stdio transport does;
  `LeanHttp.Error` becomes `DbError.transport` with its `Kind` in the text.
- **`examples/dashboard`** gets a third leg: the same `slaBreached` stub
  over HTTP against `tickets serve --http`, asserted equal to the local
  and stdio results; the release check runs it with the server it already
  starts for the HTTP smoke.

## Milestones

| M | Deliverable | Done when |
|---|---|---|
| M0 | Spike: loader, handle class, one `long`/`string`/`bytes` setter each, `perform`, GET against an in-process `Std.Http.Server` | implemented and verified on macOS; Linux moves to M4 |
| M1 | `Opt`, `Types`, `Error`, `Session`, header parsing, tests | implemented; macOS suite green |
| M2 | `Codec` (`ToBody`/`FromBody`/`exchange`), `Tls`, `Auth`, proxy, encodings, `requestTask` | implemented; local suite green, TLS CI pending |
| M3 | `leandb-http` + LeanDB transport seam + dashboard third leg | complete; HTTP equals local and full release check is green |
| M4 | CI (macOS + Linux), README, `leanhttp v0.1.0`, `leandb-http v0.1.0` pinned to LeanDB `v0.3.0` | pending publication and CI |

## Risks, by name

- **`dlopen` from Lean binaries on Linux.** Lean executables link the
  system glibc dynamically, so `dlopen` should work; distributions that
  ship only `libcurl.so.4` are why both names are tried. Fallback: a
  build option linking `-lcurl` and skipping the loader.
- **Variadic `curl_easy_setopt` through `dlsym`.** Undefined on arm64
  through a non-variadic pointer; the pointer type is declared variadic
  and M0 exercises a `long`, a `char *` and a function-pointer option.
- **Option-code drift.** Mitigated by the `_Static_assert` table (D6);
  generating the mirrored Lean table is M4 hardening.
- **TLS backends differ.** macOS system curl and Linux distributions may
  use different TLS backends. Backend-specific validation belongs in the
  pending M4 TLS matrix; libcurl failures still surface through the typed
  SSL categories.
- **Two copies of large bodies** (C buffer → `ByteArray`). Fine for
  LeanDB's JSON; a streaming callback into a Lean closure is post-v1.
- **`Std.Http` type churn.** `Headers`/`URI`/`Status` are new in 4.33;
  leanhttp pins the toolchain with LeanDB and tracks it.
- **Windows.** Out of scope for v1 (`LoadLibrary` loader, different
  toolchain); stated in the README.

## Out of scope for v1

WebSockets, HTTP/3 knobs, cookie jars, multipart uploads, the multi
interface, an `Std.Async`-native API, streaming bodies. Each is a
libcurl option away and none is needed for LeanDB's wire.
