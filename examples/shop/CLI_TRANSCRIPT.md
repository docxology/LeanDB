# shop CLI transcript

Regenerated 2026-08-24 from a fresh `data/` dir. Query verbs are
`query%`-derived from the query defs — names and arities come from code.
Stdout/stderr merged; exit codes shown.

## schema — derived from the entity declarations

```console
$ shop schema
{"base":"shop","fingerprint":"5377838838812634913","ok":true,"tables":[{"columns":[{"name":"name","nullable":false,"type":"TEXT"},{"name":"email","nullable":false,"type":"TEXT"}],"name":"customer"},{"columns":[{"name":"name","nullable":false,"type":"TEXT"},{"name":"sku","nullable":false,"type":"TEXT"},{"enum":["electronics","grocery","apparel","toys"],"name":"category","nullable":false,"type":"TEXT"},{"name":"price","nullable":false,"type":"INTEGER"},{"name":"stock","nullable":false,"type":"INTEGER"}],"name":"product"},{"columns":[{"name":"customer","nullable":false,"references":"customer","type":"INTEGER"},{"default":"cart","enum":["cart","placed","paid","shipped","delivered","cancelled"],"name":"status","nullable":false,"type":"TEXT"},{"name":"placedAt","nullable":false,"type":"INTEGER"}],"name":"purchase"},{"columns":[{"name":"order","nullable":false,"references":"purchase","type":"INTEGER"},{"name":"product","nullable":false,"references":"product","type":"INTEGER"},{"name":"qty","nullable":false,"type":"INTEGER"},{"name":"unitPrice","nullable":false,"type":"INTEGER"}],"name":"line_item"}]}
(exit 0)
```

## version before any instance exists

```console
$ shop version
{"code_fingerprint":"5377838838812634913","in_sync":false,"instance_fingerprint":null,"ok":true,"schema_version":null}
(exit 0)
```

## seed

```console
$ shop query seed
{"ok":true,"seeded":true}
(exit 0)
```

## version — in sync after first open

```console
$ shop version
{"code_fingerprint":"5377838838812634913","in_sync":true,"instance_fingerprint":"5377838838812634913","ok":true,"schema_version":1}
(exit 0)
```

## zero-arg query

```console
$ shop query activeOrders
{"ok":true,"result":[{"customer":2,"id":2,"placedAt":1699892000,"status":"placed"},{"customer":3,"id":3,"placedAt":1699928000,"status":"shipped"}]}
(exit 0)
```

## typed-arg query

```console
$ shop query lowStock 5
{"ok":true,"result":[{"category":"toys","id":6,"name":"Wooden Train Set","price":3299,"sku":"TOYS-TRN-3","stock":0},{"category":"grocery","id":4,"name":"Olive Oil 1L","price":1299,"sku":"GROC-OIL-1L","stock":2},{"category":"electronics","id":2,"name":"Mechanical Keyboard","price":8950,"sku":"ELEC-KB-77","stock":3}]}
(exit 0)
```

## typed-arg query, bad argument (exit 2)

```console
$ shop query lowStock xx
{"code":"decode","message":"cli.threshold: expected a natural number, got \"xx\"","ok":false}
(exit 2)
```

## insert with an invalid closed-world value (exit 2)

```console
$ shop insert product {"name":"C","sku":"ELEC-C-1","category":"bogus","price":100,"stock":5}
{"code":"decode","message":"product.category: \"bogus\" is not in the closed world","ok":false}
(exit 2)
```

## insert valid (declared defaults fill omitted fields)

```console
$ shop insert product {"name":"C","sku":"ELEC-C-1","category":"electronics","price":100,"stock":5}
{"ok":true,"row":{"category":"electronics","id":7,"name":"C","price":100,"sku":"ELEC-C-1","stock":5}}
(exit 0)
```

## partial update (column-merge + CAS)

```console
$ shop update product 1 {"stock":4}
{"ok":true,"row":{"category":"electronics","id":1,"name":"Noise-Cancelling Headphones","price":19999,"sku":"ELEC-NC-100","stock":4}}
(exit 0)
```

## rows with a typed equality filter

```console
$ shop rows purchase --eq status=placed --limit 3
{"count":1,"ok":true,"rows":[{"customer":2,"id":2,"placedAt":1699892000,"status":"placed"}]}
(exit 0)
```

## rows filter with an out-of-world value (exit 2)

```console
$ shop rows purchase --eq status=bogus
{"code":"decode","message":"purchase.status: \"bogus\" is not in the closed world #[cart, placed, paid, shipped, delivered, cancelled]","ok":false}
(exit 2)
```

## get missing id (exit 2)

```console
$ shop get product 99999
{"code":"not_found","message":"product: no row with id 99999","ok":false}
(exit 2)
```

## delete a referenced row (exit 2)

```console
$ shop delete customer 1
{"code":"restricted","message":"customer: row 1 is referenced by other rows","ok":false}
(exit 2)
```

## usage error (exit 3)

```console
$ shop frobnicate
{"code":"usage","message":"unrecognized command [frobnicate]","ok":false}
(exit 3)
```

## query log — verbs, reified plans, outcomes

```console
$ shop log 3
{"count":3,"entries":[{"at":1787598709,"detail":"customer","error":"restricted","id":29,"ok":false,"rows":0,"verb":"delete"},{"at":1787598709,"detail":"product","error":null,"id":28,"ok":true,"rows":1,"verb":"update"},{"at":1787598709,"detail":"product","error":null,"id":27,"ok":true,"rows":1,"verb":"insert"}],"ok":true}
(exit 0)
```

## migrate status

```console
$ shop migrate status
{"applied":[],"fingerprint":"5377838838812634913","notes":["schema already up to date"],"ok":true}
(exit 0)
```

