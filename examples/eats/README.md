# Eats

Restaurant and menu queries, with opening hours and ingredient-based dietary
filters. Configurable drink pricing is an advanced experiment; its design
and synchronization limits are documented in [DESIGN.md](DESIGN.md).
Requires the root project's Lean toolchain and the local LeanDB checkout.

From the repository root:

```bash
cd examples/eats
lake build eats
demo_dir=$(mktemp -d)
export LEANDB_DB="$demo_dir/eats.sqlite"
eats=./.lake/build/bin/eats
$eats seed
$eats query avgPrice chai-latte sanFrancisco
$eats query openFor tiramisu fri 21:30
```

The average seeded chai-latte price in San Francisco is 600 cents:

```json
{"ok":true,"result":600}
```

`openFor` joins restaurants, dishes, and service hours to find tiramisu
available at 21:30 on Friday. The definitions are in
[Eats/Queries.lean](Eats/Queries.lean).

A well-formed slug that names no dish is an error:

```bash
$eats query avgPrice unknown-dish sanFrancisco
```

This exits with code 2 and a JSON `decode` error naming the missing dish.

Run `lake build eats_tests eats_offers_tests`, then
`.lake/build/bin/eats_tests` and `.lake/build/bin/eats_offers_tests` for the checks.
See the shared [CLI reference](../../README.md#the-cli-every-base-gets).
