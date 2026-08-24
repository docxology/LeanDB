# gpus CLI transcript

Captured verbatim from a fresh `data/` directory (`rm -rf data && mkdir data`).
Success JSON goes to stdout (exit 0); typed `DbError` JSON goes to stderr
(exit 2); usage errors go to stderr (exit 3).

```console
$ gpus schema
{"base":"gpus","fingerprint":"15921433160047119671","ok":true,"tables":[{"columns":[{"name":"name","nullable":false,"type":"TEXT"},{"name":"console","nullable":false,"type":"TEXT"}],"name":"provider"},{"columns":[{"name":"provider","nullable":false,"references":"provider","type":"INTEGER"},{"enum":["h100","a100","l40s","rtx4090","rtx3090","mi300x","mi325x"],"name":"chip","nullable":false,"type":"TEXT"},{"enum":["usEast","usWest","eu","apac"],"name":"region","nullable":false,"type":"TEXT"},{"name":"hourly","nullable":false,"type":"INTEGER"},{"name":"available","nullable":false,"type":"INTEGER"}],"name":"offering"}]}
(exit 0)
```

```console
$ gpus query seed
{"ok":true,"seeded":true}
(exit 0)
```

```console
$ gpus query chip h100
{"count":3,"ok":true,"rows":[{"available":1,"chip":"h100","hourly":2390,"id":7,"provider":2,"region":"usWest"},{"available":1,"chip":"h100","hourly":2490,"id":1,"provider":1,"region":"usEast"},{"available":1,"chip":"h100","hourly":3290,"id":11,"provider":4,"region":"apac"}]}
(exit 0)
```

```console
$ gpus query chip h200
{"code":"decode","message":"cli.chip: unknown chip \"h200\"; known: #[h100, a100, l40s, rtx4090, rtx3090, mi300x, mi325x]","ok":false}
(exit 2)
```

```console
$ gpus insert offering '{"provider":2,"chip":"h200","region":"usEast","hourly":3990,"available":1}'
{"code":"decode","message":"offering.chip: \"h200\" is not in the closed world","ok":false}
(exit 2)
```

```console
$ gpus insert offering '{"provider":2,"chip":"mi325x","region":"usWest","hourly":2590,"available":1}'
{"ok":true,"row":{"available":1,"chip":"mi325x","hourly":2590,"id":13,"provider":2,"region":"usWest"}}
(exit 0)
```

```console
$ gpus update offering 13 '{"hourly":2490,"available":0}'
{"ok":true,"row":{"available":0,"chip":"mi325x","hourly":2490,"id":13,"provider":2,"region":"usWest"}}
(exit 0)
```

```console
$ gpus delete provider 3
{"code":"restricted","message":"provider: row 3 is referenced by other rows","ok":false}
(exit 2)
```

```console
$ gpus frobnicate
{"code":"usage","message":"unrecognized command [frobnicate]","ok":false}
(exit 3)
```
