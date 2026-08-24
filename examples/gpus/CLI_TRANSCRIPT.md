# gpus CLI transcript

Regenerated 2026-08-24 from a fresh `data/` dir. Query verbs are
`query%`-derived from the query defs — names and arities come from code.
Stdout/stderr merged; exit codes shown.

## schema — derived from the entity declarations

```console
$ gpus schema
{"base":"gpus","fingerprint":"15921433160047119671","ok":true,"tables":[{"columns":[{"name":"name","nullable":false,"type":"TEXT"},{"name":"console","nullable":false,"type":"TEXT"}],"name":"provider"},{"columns":[{"name":"provider","nullable":false,"references":"provider","type":"INTEGER"},{"enum":["h100","a100","l40s","rtx4090","rtx3090","mi300x","mi325x"],"name":"chip","nullable":false,"type":"TEXT"},{"enum":["usEast","usWest","eu","apac"],"name":"region","nullable":false,"type":"TEXT"},{"name":"hourly","nullable":false,"type":"INTEGER"},{"name":"available","nullable":false,"type":"INTEGER"}],"name":"offering"}]}
(exit 0)
```

## version before any instance exists

```console
$ gpus version
{"code_fingerprint":"15921433160047119671","in_sync":false,"instance_fingerprint":null,"ok":true,"schema_version":null}
(exit 0)
```

## seed

```console
$ gpus query seed
{"ok":true,"seeded":true}
(exit 0)
```

## version — in sync after first open

```console
$ gpus version
{"code_fingerprint":"15921433160047119671","in_sync":true,"instance_fingerprint":"15921433160047119671","ok":true,"schema_version":1}
(exit 0)
```

## zero-arg query

```console
$ gpus query amdOfferings
{"ok":true,"result":[{"available":1,"chip":"mi300x","hourly":1990,"id":8,"provider":3,"region":"usEast"},{"available":0,"chip":"mi300x","hourly":2190,"id":10,"provider":3,"region":"eu"},{"available":1,"chip":"mi325x","hourly":2790,"id":9,"provider":3,"region":"usEast"}]}
(exit 0)
```

## typed-arg query

```console
$ gpus query availableChip h100
{"ok":true,"result":[{"available":1,"chip":"h100","hourly":2390,"id":7,"provider":2,"region":"usWest"},{"available":1,"chip":"h100","hourly":2490,"id":1,"provider":1,"region":"usEast"},{"available":1,"chip":"h100","hourly":3290,"id":11,"provider":4,"region":"apac"}]}
(exit 0)
```

## typed-arg query, bad argument (exit 2)

```console
$ gpus query availableChip h200
{"code":"decode","message":"cli.c: \"h200\" is not one of #[h100, a100, l40s, rtx4090, rtx3090, mi300x, mi325x]","ok":false}
(exit 2)
```

## insert with an invalid closed-world value (exit 2)

```console
$ gpus insert offering {"provider":1,"chip":"h200","region":"eu","hourly":100,"available":true}
{"code":"decode","message":"offering.chip: \"h200\" is not in the closed world","ok":false}
(exit 2)
```

## insert valid

```console
$ gpus insert offering {"provider":1,"chip":"h100","region":"eu","hourly":100,"available":true}
{"ok":true,"row":{"available":1,"chip":"h100","hourly":100,"id":13,"provider":1,"region":"eu"}}
(exit 0)
```

## partial update (column-merge + CAS)

```console
$ gpus update offering 1 {"available":false}
{"ok":true,"row":{"available":0,"chip":"h100","hourly":2490,"id":1,"provider":1,"region":"usEast"}}
(exit 0)
```

## rows with a typed equality filter

```console
$ gpus rows offering --eq chip=h100 --limit 3
{"count":3,"ok":true,"rows":[{"available":0,"chip":"h100","hourly":2490,"id":1,"provider":1,"region":"usEast"},{"available":0,"chip":"h100","hourly":2990,"id":3,"provider":1,"region":"eu"},{"available":1,"chip":"h100","hourly":2390,"id":7,"provider":2,"region":"usWest"}]}
(exit 0)
```

## rows filter on a nonexistent column (exit 2)

```console
$ gpus rows offering --eq nope=1
{"code":"decode","message":"offering.nope: no such column; columns: [provider, chip, region, hourly, available]","ok":false}
(exit 2)
```

## get missing id (exit 2)

```console
$ gpus get offering 99999
{"code":"not_found","message":"offering: no row with id 99999","ok":false}
(exit 2)
```

## delete a referenced row (exit 2)

```console
$ gpus delete provider 1
{"code":"restricted","message":"provider: row 1 is referenced by other rows","ok":false}
(exit 2)
```

## usage error (exit 3)

```console
$ gpus frobnicate
{"code":"usage","message":"unrecognized command [frobnicate]","ok":false}
(exit 3)
```

## query log — verbs, reified plans, outcomes

```console
$ gpus log 3
{"count":3,"entries":[{"at":1787584196,"detail":"provider","error":"restricted","id":21,"ok":false,"rows":0,"verb":"delete"},{"at":1787584196,"detail":"offering","error":null,"id":20,"ok":true,"rows":1,"verb":"update"},{"at":1787584196,"detail":"offering","error":null,"id":19,"ok":true,"rows":1,"verb":"insert"}],"ok":true}
(exit 0)
```

## migrate status

```console
$ gpus migrate status
{"applied":[],"fingerprint":"15921433160047119671","notes":["schema already up to date"],"ok":true}
(exit 0)
```

