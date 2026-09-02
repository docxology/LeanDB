# legacy — the imported base, tightened and migrated

`Scalars.lean`, `Entities.lean` (as generated), `Base.lean`, `IMPORT.md`
and `import-report.json` are `leandb import-sqlite`'s output over
`../import-fixture/legacy.db`. Everything after that is the hand:

- **V0** — `legacy migrate freeze` froze the imported schema as
  `Legacy/Migrations/V0.lean` (the snapshot as data, the rows as stored
  as raw structures).
- **V1** — `orders.qty : Int64` became `size : OrderSize` (`small |
  bulk`), the closed world the uncarried `big_orders` view (`qty > 10`)
  had encoded as a filter. The mechanical diff refuses it (a NOT NULL
  column with no value for existing rows); `migrate freeze` wrote
  `V1.lean` with the hole, and the transform in it decides every row:
  `V0.Orders → Except String Orders`.
- `LegacyTests.lean` carries `leandb_check_head` (the build is red until
  the code's schema is the chain's head) and the drill: adopt the raw
  fixture (stamped at V0 by its columns), `migrate status`, `apply`
  (backup, transform, ids kept), `rollback`, apply again.

```bash
lake build && ./.lake/build/bin/legacy_tests
mkdir -p data && cp ../import-fixture/legacy.db data/
./.lake/build/bin/legacy migrate status
./.lake/build/bin/legacy migrate apply --allow-destructive
./.lake/build/bin/legacy rows orders
```
