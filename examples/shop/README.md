# Shop

Customers, products, purchases, and line items. The example demonstrates a
typed basket join and inventory filtering. Money is stored in whole cents.
Requires the root project's Lean toolchain and the local LeanDB checkout.

From the repository root:

```bash
cd examples/shop
lake build shop
demo_dir=$(mktemp -d)
export LEANDB_DB="$demo_dir/shop.sqlite"
shop=./.lake/build/bin/shop
$shop seed
$shop query lowStock 5
$shop query basketOf 1
```

`lowStock` returns products with fewer than five units available, emptiest
first. `basketOf 1` joins the first purchase's line items with their products.
See [Shop/Queries.lean](Shop/Queries.lean).

A negative inventory threshold is rejected because the argument is a `Nat`:

```bash
$shop query lowStock -1
```

This exits with code 2 and a JSON `decode` error.

Run `lake build shop_tests && .lake/build/bin/shop_tests` for the example tests.
Common operations are covered by the
[CLI reference](../../README.md#the-cli-every-base-gets).
