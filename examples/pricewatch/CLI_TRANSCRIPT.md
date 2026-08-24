# pricewatch CLI transcript

Captured against the EMPTY instance the base ships with — the scraper and
normalizer land separately; their contract is that every command below
behaves identically (same typed refusals) once rows exist.

## schema — the normalizer's target, derived from the types

```console
$ pricewatch schema
{"base":"pricewatch","fingerprint":"4808075453069076597","ok":true,"tables":[{"columns":[{"name":"name","nullable":false,"type":"TEXT"},{"name":"brand","nullable":false,"type":"TEXT"},{"enum":["electronics","appliances","fashion","grocery","homeKitchen","beauty","toys","sports","books"],"name":"category","nullable":false,"type":"TEXT"}],"name":"product"},{"columns":[{"name":"product","nullable":false,"references":"product","type":"INTEGER"},{"enum":["amazon","flipkart","walmart","bestbuy","newegg","ebay","target","croma"],"name":"store","nullable":false,"type":"TEXT"},{"name":"url","nullable":false,"type":"TEXT"},{"name":"price","nullable":false,"type":"INTEGER"},{"name":"listPrice","nullable":true,"type":"INTEGER"},{"default":"inr","enum":["inr","usd","eur"],"name":"currency","nullable":false,"type":"TEXT"},{"name":"rating","nullable":true,"type":"INTEGER"},{"name":"reviews","nullable":true,"type":"INTEGER"},{"default":"inStock","enum":["inStock","limited","outOfStock","preorder"],"name":"availability","nullable":false,"type":"TEXT"},{"name":"deliveryDays","nullable":true,"type":"INTEGER"},{"name":"observedAt","nullable":false,"type":"INTEGER"}],"name":"listing"}]}
(exit 0)
```

## version

```console
$ pricewatch version
{"code_fingerprint":"4808075453069076597","in_sync":false,"instance_fingerprint":null,"ok":true,"schema_version":null}
(exit 0)
```

## decision query on the empty base: answers, doesn't lie

```console
$ pricewatch query find electronics 3000000 knee
{"ok":true,"result":[]}
(exit 0)
```

## unknown strategy refused

```console
$ pricewatch query find electronics 3000000 fastest
{"code":"decode","message":"cli.strategy: \"fastest\" is not one of #[sorted, pareto, knee]","ok":false}
(exit 2)
```

## unknown store refused (closed world)

```console
$ pricewatch insert listing {"product":1,"store":"aliexpress","url":"https://x.co","price":100,"observedAt":1}
{"code":"decode","message":"listing.store: \"aliexpress\" is not in the closed world","ok":false}
(exit 2)
```

## invalid url refused

```console
$ pricewatch insert listing {"product":1,"store":"amazon","url":"ftp://x","price":100,"observedAt":1}
{"code":"decode","message":"listing.url: not an http(s) url: ftp://x","ok":false}
(exit 2)
```

## zero price refused

```console
$ pricewatch insert listing {"product":1,"store":"amazon","url":"https://x.co","price":0,"observedAt":1}
{"code":"decode","message":"listing.price: price must be positive","ok":false}
(exit 2)
```

## rows with typed filter

```console
$ pricewatch rows listing --eq store=amazon
{"count":0,"ok":true,"rows":[]}
(exit 0)
```

## usage error

```console
$ pricewatch frobnicate
{"code":"usage","message":"unrecognized command [frobnicate]","ok":false}
(exit 3)
```

## migrate status (fresh)

```console
$ pricewatch migrate status
{"applied":[],"fingerprint":"4808075453069076597","notes":["schema already up to date"],"ok":true}
(exit 0)
```

