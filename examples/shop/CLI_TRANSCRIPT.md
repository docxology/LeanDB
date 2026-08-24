# shop CLI transcript

Captured verbatim from a fresh `data/` directory (`rm -rf data && mkdir data`).
Success JSON goes to stdout (exit 0); typed `DbError` JSON goes to stderr
(exit 2); usage errors go to stderr (exit 3).

```console
$ shop schema
{"base":"shop","fingerprint":"7959798319987259381","ok":true,"tables":[{"columns":[{"name":"name","nullable":false,"type":"TEXT"},{"name":"email","nullable":false,"type":"TEXT"}],"name":"customer"},{"columns":[{"name":"name","nullable":false,"type":"TEXT"},{"name":"sku","nullable":false,"type":"TEXT"},{"enum":["electronics","grocery","apparel","toys"],"name":"category","nullable":false,"type":"TEXT"},{"name":"price","nullable":false,"type":"INTEGER"},{"name":"stock","nullable":false,"type":"INTEGER"}],"name":"product"},{"columns":[{"name":"customer","nullable":false,"references":"customer","type":"INTEGER"},{"enum":["cart","placed","paid","shipped","delivered","cancelled"],"name":"status","nullable":false,"type":"TEXT"},{"name":"placedAt","nullable":false,"type":"INTEGER"}],"name":"purchase"},{"columns":[{"name":"order","nullable":false,"references":"purchase","type":"INTEGER"},{"name":"product","nullable":false,"references":"product","type":"INTEGER"},{"name":"qty","nullable":false,"type":"INTEGER"},{"name":"unitPrice","nullable":false,"type":"INTEGER"}],"name":"line_item"}]}
(exit 0)
```

```console
$ shop query seed
{"ok":true,"seeded":true}
(exit 0)
```

```console
$ shop query active
{"count":2,"ok":true,"rows":[{"customer":2,"id":2,"placedAt":1699892000,"status":"placed"},{"customer":3,"id":3,"placedAt":1699928000,"status":"shipped"}]}
(exit 0)
```

```console
$ shop query basket 4
{"count":3,"ok":true,"rows":[{"item":{"id":9,"order":4,"product":5,"qty":1,"unitPrice":7400},"product":{"category":"apparel","id":5,"name":"Merino Hoodie","price":7400,"sku":"APRL-HD-M","stock":8}},{"item":{"id":8,"order":4,"product":4,"qty":2,"unitPrice":1299},"product":{"category":"grocery","id":4,"name":"Olive Oil 1L","price":1299,"sku":"GROC-OIL-1L","stock":2}},{"item":{"id":7,"order":4,"product":6,"qty":1,"unitPrice":3299},"product":{"category":"toys","id":6,"name":"Wooden Train Set","price":3299,"sku":"TOYS-TRN-3","stock":0}}]}
(exit 0)
```

```console
$ shop insert product '{"name":"USB-C Cable 2m","sku":"ELEC-USB-2M","category":"gadgets","price":599,"stock":50}'
{"code":"decode","message":"product.category: \"gadgets\" is not in the closed world","ok":false}
(exit 2)
```

```console
$ shop insert product '{"name":"USB-C Cable 2m","sku":"ELEC-USB-2M","category":"electronics","price":599,"stock":50}'
{"ok":true,"row":{"category":"electronics","id":7,"name":"USB-C Cable 2m","price":599,"sku":"ELEC-USB-2M","stock":50}}
(exit 0)
```

```console
$ shop update product 7 '{"stock":45,"price":549}'
{"ok":true,"row":{"category":"electronics","id":7,"name":"USB-C Cable 2m","price":549,"sku":"ELEC-USB-2M","stock":45}}
(exit 0)
```

```console
$ shop delete customer 1
{"code":"restricted","message":"customer: row 1 is referenced by other rows","ok":false}
(exit 2)
```

```console
$ shop query nope
{"code":"usage","message":"unknown query \"nope\"; queries: [seed, active, low, basket, revenue]","ok":false}
(exit 3)
```
