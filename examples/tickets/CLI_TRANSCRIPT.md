# tickets CLI transcript

Regenerated 2026-08-24 from a fresh `data/` dir. Query verbs are
`query%`-derived from the query defs — names and arities come from code.
Stdout/stderr merged; exit codes shown.

## schema — derived from the entity declarations

```console
$ tickets schema
{"base":"tickets","fingerprint":"14584463042647267630","ok":true,"tables":[{"columns":[{"name":"handle","nullable":false,"type":"TEXT"},{"name":"display","nullable":false,"type":"TEXT"}],"name":"user"},{"columns":[{"name":"title","nullable":false,"type":"TEXT"},{"name":"body","nullable":false,"type":"TEXT"},{"default":"backlog","enum":["backlog","inProgress","blocked","inReview","done"],"name":"status","nullable":false,"type":"TEXT"},{"default":"p2","enum":["p0","p1","p2","p3"],"name":"priority","nullable":false,"type":"TEXT"},{"name":"reporter","nullable":false,"references":"user","type":"INTEGER"},{"name":"assignee","nullable":true,"references":"user","type":"INTEGER"},{"name":"estimate","nullable":true,"type":"INTEGER"},{"name":"createdAt","nullable":false,"type":"INTEGER"}],"name":"ticket"},{"columns":[{"name":"ticket","nullable":false,"references":"ticket","type":"INTEGER"},{"name":"author","nullable":false,"references":"user","type":"INTEGER"},{"name":"body","nullable":false,"type":"TEXT"},{"name":"at","nullable":false,"type":"INTEGER"}],"name":"comment"}]}
(exit 0)
```

## version before any instance exists

```console
$ tickets version
{"code_fingerprint":"14584463042647267630","in_sync":false,"instance_fingerprint":null,"ok":true,"schema_version":null}
(exit 0)
```

## seed

```console
$ tickets query seed
{"ok":true,"seeded":true}
(exit 0)
```

## version — in sync after first open

```console
$ tickets version
{"code_fingerprint":"14584463042647267630","in_sync":true,"instance_fingerprint":"14584463042647267630","ok":true,"schema_version":1}
(exit 0)
```

## zero-arg query

```console
$ tickets query openTickets
{"ok":true,"result":[{"assignee":2,"body":"Details for: Login crashes on empty password","createdAt":1699978400,"estimate":3,"id":1,"priority":"p0","reporter":1,"status":"inProgress","title":"Login crashes on empty password"},{"assignee":null,"body":"Details for: Data export corrupts unicode","createdAt":1699992800,"estimate":null,"id":2,"priority":"p0","reporter":2,"status":"backlog","title":"Data export corrupts unicode"},{"assignee":1,"body":"Details for: Search results stale","createdAt":1699892000,"estimate":8,"id":3,"priority":"p1","reporter":3,"status":"blocked","title":"Search results stale"},{"assignee":2,"body":"Details for: Onboarding email typo","createdAt":1699712000,"estimate":1,"id":5,"priority":"p2","reporter":2,"status":"inReview","title":"Onboarding email typo"},{"assignee":null,"body":"Details for: Refactor billing module","createdAt":1699964000,"estimate":40,"id":6,"priority":"p2","reporter":3,"status":"backlog","title":"Refactor billing module"},{"assignee":null,"body":"Details for: Update dependencies","createdAt":1699280000,"estimate":null,"id":7,"priority":"p3","reporter":1,"status":"backlog","title":"Update dependencies"},{"assignee":1,"body":"Details for: Improve docs","createdAt":1699956800,"estimate":5,"id":8,"priority":"p3","reporter":2,"status":"inProgress","title":"Improve docs"}]}
(exit 0)
```

## typed-arg query

```console
$ tickets query slaBreached 1700000000
{"ok":true,"result":[[{"assignee":2,"body":"Details for: Login crashes on empty password","createdAt":1699978400,"estimate":3,"id":1,"priority":"p0","reporter":1,"status":"inProgress","title":"Login crashes on empty password"},{"display":"Ada Lovelace","handle":"ada","id":1}],[{"assignee":1,"body":"Details for: Search results stale","createdAt":1699892000,"estimate":8,"id":3,"priority":"p1","reporter":3,"status":"blocked","title":"Search results stale"},{"display":"Cara Chen","handle":"cara","id":3}],[{"assignee":2,"body":"Details for: Onboarding email typo","createdAt":1699712000,"estimate":1,"id":5,"priority":"p2","reporter":2,"status":"inReview","title":"Onboarding email typo"},{"display":"Bob Harris","handle":"bob","id":2}],[{"assignee":null,"body":"Details for: Update dependencies","createdAt":1699280000,"estimate":null,"id":7,"priority":"p3","reporter":1,"status":"backlog","title":"Update dependencies"},{"display":"Ada Lovelace","handle":"ada","id":1}]]}
(exit 0)
```

## typed-arg query, bad argument (exit 2)

```console
$ tickets query slaBreached notatime
{"code":"decode","message":"cli.now: expected an epoch-seconds timestamp, got \"notatime\"","ok":false}
(exit 2)
```

## insert with an invalid closed-world value (exit 2)

```console
$ tickets insert ticket {"title":"T","body":"b","status":"bogus","priority":"p1","reporter":1,"createdAt":1700000000}
{"code":"decode","message":"ticket.status: \"bogus\" is not in the closed world","ok":false}
(exit 2)
```

## insert valid (declared defaults fill omitted fields)

```console
$ tickets insert ticket {"title":"T","body":"b","priority":"p1","reporter":1,"createdAt":1700000000}
{"ok":true,"row":{"assignee":null,"body":"b","createdAt":1700000000,"estimate":null,"id":9,"priority":"p1","reporter":1,"status":"backlog","title":"T"}}
(exit 0)
```

## partial update (column-merge + CAS)

```console
$ tickets update ticket 1 {"status":"inProgress"}
{"ok":true,"row":{"assignee":2,"body":"Details for: Login crashes on empty password","createdAt":1699978400,"estimate":3,"id":1,"priority":"p0","reporter":1,"status":"inProgress","title":"Login crashes on empty password"}}
(exit 0)
```

## rows with a typed equality filter

```console
$ tickets rows ticket --eq status=backlog --limit 3
{"count":3,"ok":true,"rows":[{"assignee":null,"body":"Details for: Data export corrupts unicode","createdAt":1699992800,"estimate":null,"id":2,"priority":"p0","reporter":2,"status":"backlog","title":"Data export corrupts unicode"},{"assignee":null,"body":"Details for: Refactor billing module","createdAt":1699964000,"estimate":40,"id":6,"priority":"p2","reporter":3,"status":"backlog","title":"Refactor billing module"},{"assignee":null,"body":"Details for: Update dependencies","createdAt":1699280000,"estimate":null,"id":7,"priority":"p3","reporter":1,"status":"backlog","title":"Update dependencies"}]}
(exit 0)
```

## rows filter with an out-of-world value (exit 2)

```console
$ tickets rows ticket --eq status=bogus
{"code":"decode","message":"ticket.status: \"bogus\" is not in the closed world #[backlog, inProgress, blocked, inReview, done]","ok":false}
(exit 2)
```

## get missing id (exit 2)

```console
$ tickets get ticket 99999
{"code":"not_found","message":"ticket: no row with id 99999","ok":false}
(exit 2)
```

## delete a referenced row (exit 2)

```console
$ tickets delete user 1
{"code":"restricted","message":"user: row 1 is referenced by other rows","ok":false}
(exit 2)
```

## usage error (exit 3)

```console
$ tickets frobnicate
{"code":"usage","message":"unrecognized command [frobnicate]","ok":false}
(exit 3)
```

## query log — verbs, reified plans, outcomes

```console
$ tickets log 3
{"count":3,"entries":[{"at":1787598707,"detail":"user","error":"restricted","id":19,"ok":false,"rows":0,"verb":"delete"},{"at":1787598707,"detail":"ticket","error":null,"id":18,"ok":true,"rows":1,"verb":"update"},{"at":1787598706,"detail":"ticket","error":null,"id":17,"ok":true,"rows":1,"verb":"insert"}],"ok":true}
(exit 0)
```

## migrate status

```console
$ tickets migrate status
{"applied":[],"fingerprint":"14584463042647267630","notes":["schema already up to date"],"ok":true}
(exit 0)
```

