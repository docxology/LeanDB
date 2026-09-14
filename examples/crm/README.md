# CRM

Companies, contacts, and sales opportunities. This example joins each live
opportunity to its contact and filters by the contact's optional company.
Requires the root project's Lean toolchain and the local LeanDB checkout.

From the repository root:

```bash
cd examples/crm
lake build crm
demo_dir=$(mktemp -d)
export LEANDB_DB="$demo_dir/crm.sqlite"
crm=./.lake/build/bin/crm
$crm seed
$crm query contactsOf 1
$crm query pipelineFor 1
```

Company 1 is Acme Analytics. The first query returns Ada and Grace; the second
returns their live opportunities, largest value first. See
[Crm/Queries.lean](Crm/Queries.lean) for the join.

A malformed company reference is rejected:

```bash
$crm query pipelineFor not-an-id
```

This exits with code 2 and a JSON `decode` error.

Run `lake build crm_tests && .lake/build/bin/crm_tests` for the example tests.
See the shared [CLI reference](../../README.md#the-cli-every-base-gets) for
CRUD commands, argument handling, and exit codes.
