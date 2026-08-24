# crm CLI conformance transcript

Captured from `examples/crm` against a fresh `data/crm.sqlite`:

```console
$ lake build crm
$ rm -rf data && mkdir -p data   # fresh instance; the CLI creates the db file on first open
```

`crm` below is `.lake/build/bin/crm`. Stderr lines are prefixed `stderr>`.

## schema — derived from the entity declarations

```console
$ crm schema
{"base":"crm","fingerprint":"5821729634224352920","ok":true,"tables":[{"columns":[{"name":"name","nullable":false,"type":"TEXT"},{"enum":["smb","midMarket","enterprise"],"name":"segment","nullable":false,"type":"TEXT"}],"name":"company"},{"columns":[{"name":"name","nullable":false,"type":"TEXT"},{"name":"email","nullable":false,"type":"TEXT"},{"name":"company","nullable":true,"references":"company","type":"INTEGER"}],"name":"person"},{"columns":[{"name":"person","nullable":false,"references":"person","type":"INTEGER"},{"enum":["email","call","meeting","chat"],"name":"channel","nullable":false,"type":"TEXT"},{"name":"note","nullable":false,"type":"TEXT"},{"name":"happenedAt","nullable":false,"type":"INTEGER"}],"name":"interaction"},{"columns":[{"name":"person","nullable":false,"references":"person","type":"INTEGER"},{"name":"title","nullable":false,"type":"TEXT"},{"enum":["open","waiting","won","lost"],"name":"status","nullable":false,"type":"TEXT"},{"name":"value","nullable":false,"type":"INTEGER"},{"name":"openedAt","nullable":false,"type":"INTEGER"}],"name":"ask"}]}
exit code: 0
```

## query seed — populate through the smart constructors

```console
$ crm query seed
{"ok":true,"seeded":true}
exit code: 0
```

## query live — live asks, biggest value first

```console
$ crm query live
{"count":6,"ok":true,"rows":[{"id":1,"openedAt":1696544000,"person":1,"status":"open","title":"Enterprise rollout","value":50000},{"id":6,"openedAt":1696976000,"person":4,"status":"waiting","title":"Platform migration","value":45000},{"id":7,"openedAt":1699827200,"person":5,"status":"open","title":"Compliance module","value":30000},{"id":3,"openedAt":1699136000,"person":2,"status":"waiting","title":"Security review","value":20000},{"id":8,"openedAt":1696112000,"person":6,"status":"open","title":"Consulting retainer","value":15000},{"id":4,"openedAt":1699568000,"person":3,"status":"open","title":"Starter plan","value":1200}]}
exit code: 0
```

## insert with an INVALID enum value — closed world refuses (code=decode, exit 2)

```console
$ crm insert company '{"name":"Zenith Tools","segment":"galactic"}'
stderr> {"code":"decode","message":"company.segment: \"galactic\" is not in the closed world","ok":false}
exit code: 2
```

## insert valid — a fourth company

```console
$ crm insert company '{"name":"Zenith Tools","segment":"smb"}'
{"ok":true,"row":{"id":4,"name":"Zenith Tools","segment":"smb"}}
exit code: 0
```

## update partial — only the segment field

```console
$ crm update company 4 '{"segment":"midMarket"}'
{"ok":true,"row":{"id":4,"name":"Zenith Tools","segment":"midMarket"}}
exit code: 0
```

## get missing id — not_found, exit 2

```console
$ crm get person 999
stderr> {"code":"not_found","message":"person: no row with id 999","ok":false}
exit code: 2
```

## delete a referenced row — ON DELETE RESTRICT, exit 2

```console
$ crm delete person 1
stderr> {"code":"restricted","message":"person: row 1 is referenced by other rows","ok":false}
exit code: 2
```

## usage error — unknown command, exit 3

```console
$ crm frobnicate everything
stderr> {"code":"usage","message":"unrecognized command [frobnicate, everything]","ok":false}
exit code: 3
```

