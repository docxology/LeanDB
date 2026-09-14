# Tickets

An issue tracker demonstrating typed references, optional assignees, and
queries over related users and tickets. Start here for a complete base.
Requires the root project's Lean toolchain; Lake uses the local LeanDB checkout.

From the repository root, build and seed a fresh temporary database:

```bash
cd examples/tickets
lake build tickets
demo_dir=$(mktemp -d)
export LEANDB_DB="$demo_dir/tickets.sqlite"
tickets=./.lake/build/bin/tickets
$tickets seed
$tickets query openTickets
$tickets query queueOf 1
```

The seed creates three users and eight tickets. `openTickets` returns seven
unfinished tickets in priority order; `queueOf 1` returns Ada's two tickets.
The definitions are in [Tickets/Queries.lean](Tickets/Queries.lean).

A timestamp argument is validated before the SLA query runs:

```bash
$tickets query slaBreached notatime
```

This exits with code 2 and a JSON error whose `code` is `decode`.
Use `1700000000` to run the query at the seed's reference time.

Run `lake build tickets_tests && .lake/build/bin/tickets_tests` for query,
update, and foreign-key checks. Common commands and exit codes are documented
in the [CLI reference](../../README.md#the-cli-every-base-gets).
