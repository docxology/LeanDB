import LeanDb.Db

namespace LeanDb

/-! # The public transaction combinator

The engine's private `transaction` (`Db.lean`) is a deferred read snapshot:
it joins an open transaction and never takes the write lock. This module is
the *write* combinator the native adapters consume (LDB-01):

- `transaction` runs a `DbM (Tx ε α)` under `BEGIN IMMEDIATE` at depth 0 —
  the write lock is taken up front, so a second writer waits on
  `busy_timeout` instead of failing mid-transaction — and under a
  `SAVEPOINT` when nested, so a domain abort rolls back only the inner
  scope and leaves the outer transaction intact.
- The body returns `.commit v` to commit or `.abort e` to abort with a
  typed domain value; a `DbError` or host exception rolls back and
  re-raises. A `ROLLBACK` that itself fails poisons the connection
  (`DbError.poisoned`): every later verb is refused until reopen.
- `withTransaction` is the same machinery for bodies that cannot abort
  with a domain value.
- `untrackedSqlite` hands the raw `SQLite` handle to the caller inside the
  current transaction — for statements the typed layer does not render —
  and is deliberately not audit-logged.
-/

/-- What a transaction body decided: commit with `v`, or abort with the
    domain value `e` (rolled back, returned to the caller — not thrown). -/
inductive Tx (ε α : Type) where
  | commit (v : α)
  | abort (e : ε)
  deriving Repr

/-- Run `act` under `BEGIN IMMEDIATE … COMMIT`, or under a `SAVEPOINT`
    when a transaction is already open. `.commit v` commits the innermost
    scope and yields `.ok v`; `.abort e` rolls it back and yields
    `.error e`; a `DbError` or host exception rolls back and re-raises as
    the `DbM` error. A failed `ROLLBACK` poisons the connection. -/
def transaction (act : DbM (Tx ε α)) : DbM (Except ε α) := fun conn => ExceptT.mk do
  let exec (sql : String) : IO (Except DbError Unit) :=
    try conn.raw.exec sql; pure (.ok ()) catch e => pure (.error (.sqlite (toString e)))
  match ← conn.poisoned.get with
  | some why => return .error (.poisoned why)
  | none =>
  let depth ← conn.txDepth.get
  let savepoint := s!"_leandb_tx_{depth}"
  match ← (if depth == 0 then exec "BEGIN IMMEDIATE"
           else exec s!"SAVEPOINT {savepoint}") with
  | .error e => return .error e
  | .ok () =>
  conn.txDepth.set (depth + 1)
  -- Roll the innermost scope back. Returns `some e` when the rollback
  -- itself failed: the transaction state is then unknown, so the
  -- connection is poisoned and refuses every later verb (#72's contract,
  -- defined here rather than inherited).
  let undo : IO (Option DbError) := do
    let r ←
      if depth == 0 then exec "ROLLBACK"
      else
        match ← exec s!"ROLLBACK TO SAVEPOINT {savepoint}" with
        | .error e => pure (.error e)
        | .ok () => exec s!"RELEASE SAVEPOINT {savepoint}"
    match r with
    | .ok () => return none
    | .error re =>
        let why := s!"rollback of {if depth == 0 then "transaction" else savepoint} \
failed: {re.message}"
        conn.poison why
        return some (.poisoned why)
  let finish (r : Except DbError (Tx ε α)) : IO (Except DbError (Except ε α)) := do
    conn.txDepth.set depth
    match r with
    | .ok (.commit v) =>
        let sealed' ←
          if depth == 0 then exec "COMMIT"
          else exec s!"RELEASE SAVEPOINT {savepoint}"
        match sealed' with
        | .ok () => return .ok (.ok v)
        | .error e =>
            match ← undo with
            | some pe => return .error pe
            | none => return .error e
    | .ok (.abort e) =>
        match ← undo with
        | some pe => return .error pe
        | none => return .ok (.error e)
    | .error e =>
        match ← undo with
        | some pe => return .error pe
        | none => return .error e
  let r ← try (act conn).run catch e => pure (.error (.sqlite (toString e)))
  finish r

/-- `transaction` for bodies that cannot abort with a domain value:
    commits what the body returns, rolls back and re-raises on a
    `DbError` or host exception. -/
def withTransaction (act : DbM α) : DbM α := do
  match ← transaction (ε := Empty) (.commit <$> act) with
  | .ok a => return a
  | .error e => nomatch e

/-- The raw `SQLite` handle inside the current transaction: statements
    the typed layer does not render, run on the same connection so they
    see (and are rolled back with) the open transaction. Not audit-logged
    — the caller owns what it runs. -/
def untrackedSqlite (act : SQLite → IO α) : DbM α := fun conn => ExceptT.mk do
  match ← conn.poisoned.get with
  | some why => return .error (.poisoned why)
  | none =>
    try (.ok <$> act conn.raw) catch e => pure (.error (.sqlite (toString e)))

end LeanDb
