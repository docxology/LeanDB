# crm CLI transcript

Regenerated 2026-08-24 from a fresh `data/` dir. Query verbs are
`query%`-derived from the query defs — names and arities come from code.
Stdout/stderr merged; exit codes shown.

## schema — derived from the entity declarations

```console
$ crm schema
{"base":"crm","fingerprint":"15822784086805850012","ok":true,"tables":[{"columns":[{"name":"name","nullable":false,"type":"TEXT"},{"enum":["smb","midMarket","enterprise"],"name":"segment","nullable":false,"type":"TEXT"}],"name":"company"},{"columns":[{"name":"name","nullable":false,"type":"TEXT"},{"name":"email","nullable":false,"type":"TEXT"},{"name":"company","nullable":true,"references":"company","type":"INTEGER"}],"name":"person"},{"columns":[{"name":"person","nullable":false,"references":"person","type":"INTEGER"},{"enum":["email","call","meeting","chat"],"name":"channel","nullable":false,"type":"TEXT"},{"name":"note","nullable":false,"type":"TEXT"},{"name":"happenedAt","nullable":false,"type":"INTEGER"}],"name":"interaction"},{"columns":[{"name":"person","nullable":false,"references":"person","type":"INTEGER"},{"name":"title","nullable":false,"type":"TEXT"},{"default":"open","enum":["open","waiting","won","lost"],"name":"status","nullable":false,"type":"TEXT"},{"name":"value","nullable":false,"type":"INTEGER"},{"name":"openedAt","nullable":false,"type":"INTEGER"}],"name":"ask"}]}
(exit 0)
```

## version before any instance exists

```console
$ crm version
{"code_fingerprint":"15822784086805850012","in_sync":false,"instance_fingerprint":null,"ok":true,"schema_version":null}
(exit 0)
```

## seed

```console
$ crm query seed
{"ok":true,"seeded":true}
(exit 0)
```

## version — in sync after first open

```console
$ crm version
{"code_fingerprint":"15822784086805850012","in_sync":true,"instance_fingerprint":"15822784086805850012","ok":true,"schema_version":1}
(exit 0)
```

## zero-arg query

```console
$ crm query liveAsks
{"ok":true,"result":[{"id":1,"openedAt":1696544000,"person":1,"status":"open","title":"Enterprise rollout","value":50000},{"id":6,"openedAt":1696976000,"person":4,"status":"waiting","title":"Platform migration","value":45000},{"id":7,"openedAt":1699827200,"person":5,"status":"open","title":"Compliance module","value":30000},{"id":3,"openedAt":1699136000,"person":2,"status":"waiting","title":"Security review","value":20000},{"id":8,"openedAt":1696112000,"person":6,"status":"open","title":"Consulting retainer","value":15000},{"id":4,"openedAt":1699568000,"person":3,"status":"open","title":"Starter plan","value":1200}]}
(exit 0)
```

## typed-arg query

```console
$ crm query pipelineFor 1
{"ok":true,"result":[[{"id":1,"openedAt":1696544000,"person":1,"status":"open","title":"Enterprise rollout","value":50000},{"company":1,"email":"ada@acme.example","id":1,"name":"Ada Lovelace"}],[{"id":3,"openedAt":1699136000,"person":2,"status":"waiting","title":"Security review","value":20000},{"company":1,"email":"grace@acme.example","id":2,"name":"Grace Hopper"}]]}
(exit 0)
```

## typed-arg query, bad argument (exit 2)

```console
$ crm query pipelineFor x
{"code":"decode","message":"cli.c: expected a natural number, got \"x\"","ok":false}
(exit 2)
```

## insert with an invalid closed-world value (exit 2)

```console
$ crm insert ask {"person":1,"title":"T","status":"bogus","value":10,"openedAt":1700000000}
{"code":"decode","message":"ask.status: \"bogus\" is not in the closed world","ok":false}
(exit 2)
```

## insert valid (declared defaults fill omitted fields)

```console
$ crm insert ask {"person":1,"title":"T","value":10,"openedAt":1700000000}
{"ok":true,"row":{"id":9,"openedAt":1700000000,"person":1,"status":"open","title":"T","value":10}}
(exit 0)
```

## partial update (column-merge + CAS)

```console
$ crm update ask 1 {"status":"waiting"}
{"ok":true,"row":{"id":1,"openedAt":1696544000,"person":1,"status":"waiting","title":"Enterprise rollout","value":50000}}
(exit 0)
```

## rows with a typed equality filter

```console
$ crm rows ask --eq status=open --limit 3
{"count":3,"ok":true,"rows":[{"id":4,"openedAt":1699568000,"person":3,"status":"open","title":"Starter plan","value":1200},{"id":7,"openedAt":1699827200,"person":5,"status":"open","title":"Compliance module","value":30000},{"id":8,"openedAt":1696112000,"person":6,"status":"open","title":"Consulting retainer","value":15000}]}
(exit 0)
```

## rows filter with an out-of-world value (exit 2)

```console
$ crm rows ask --eq status=bogus
{"code":"decode","message":"ask.status: \"bogus\" is not in the closed world #[open, waiting, won, lost]","ok":false}
(exit 2)
```

## get missing id (exit 2)

```console
$ crm get ask 99999
{"code":"not_found","message":"ask: no row with id 99999","ok":false}
(exit 2)
```

## delete a referenced row (exit 2)

```console
$ crm delete person 1
{"code":"restricted","message":"person: row 1 is referenced by other rows","ok":false}
(exit 2)
```

## usage error (exit 3)

```console
$ crm frobnicate
{"code":"usage","message":"unrecognized command [frobnicate]","ok":false}
(exit 3)
```

## query log — verbs, reified plans, outcomes

```console
$ crm log 3
{"count":3,"entries":[{"at":1788380249,"detail":"person","error":"restricted","id":24,"ok":false,"plan":null,"query":null,"rows":0,"verb":"delete"},{"at":1788380249,"detail":"ask×person | pushed: ((t0.\"person\" IS t1.\"id\" AND t1.\"company\" IS ?) AND (t0.\"status\" IS ? OR t0.\"status\" IS ?)), residual conjuncts: 0","error":null,"id":23,"ok":true,"plan":{"footprint":{"columns":["ask.person","person.id","person.company","ask.status"],"residual":false,"tables":["ask","person"]},"plan":{"a":{"a":{"kind":"eq2","left":{"column":"person","table":"ask"},"op":"IS","right":{"column":"id","table":"person"}},"b":{"col":{"column":"company","table":"person"},"kind":"eq","op":"IS","value":1},"kind":"and"},"b":{"a":{"col":{"column":"status","table":"ask"},"kind":"eq","op":"IS","value":"open"},"b":{"col":{"column":"status","table":"ask"},"kind":"eq","op":"IS","value":"waiting"},"kind":"or"},"kind":"and"},"tables":["ask","person"]},"query":"pipelineFor","rows":2,"verb":"select"},{"at":1788380249,"detail":"ask | pushed: (t0.\"status\" IS ? OR t0.\"status\" IS ?), residual conjuncts: 0","error":null,"id":22,"ok":true,"plan":{"footprint":{"columns":["ask.status"],"residual":false,"tables":["ask"]},"plan":{"a":{"col":{"column":"status","table":"ask"},"kind":"eq","op":"IS","value":"open"},"b":{"col":{"column":"status","table":"ask"},"kind":"eq","op":"IS","value":"waiting"},"kind":"or"},"tables":["ask"]},"query":"liveAsks","rows":6,"verb":"select"}],"ok":true}
(exit 0)
```

## migrate status

```console
$ crm migrate status
{"applied":[],"fingerprint":"15822784086805850012","notes":["schema already up to date"],"ok":true}
(exit 0)
```

