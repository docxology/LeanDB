# eats CLI transcript

Regenerated 2026-09-01 from a fresh `data/` dir. Query verbs are
`query%`-derived from the defs in `Eats/Queries.lean`; dishes are named by
slug, times as `HH:MM`, coordinates in decimal degrees. No diet is stored:
every dietary answer is computed from ingredient rows at query time —
`suitable` as one `selectP` whose `∀` pushes as `NOT EXISTS` (LEP-0004).
Stdout/stderr merged; exit codes shown.

## schema — eight tables; closed worlds visible as enum columns, no diet column anywhere

```console
$ eats schema
{"base":"eats","fingerprint":"6544436943739024249","ok":true,"tables":[{"columns":[{"name":"slug","nullable":false,"type":"TEXT"},{"name":"display","nullable":false,"type":"TEXT"},{"enum":["ramen","pho","curry","pizza","burger","salad","latte","tea","tiramisu","gelato","dosa","biryani","pastry"],"name":"family","nullable":false,"type":"TEXT"},{"enum":["drink","starter","main","dessert","side"],"name":"course","nullable":false,"type":"TEXT"}],"name":"canonical_dish"},{"columns":[{"name":"name","nullable":false,"type":"TEXT"},{"enum":["sanFrancisco","oakland","berkeley","paloAlto","sanJose"],"name":"city","nullable":false,"type":"TEXT"},{"name":"neighborhood","nullable":false,"type":"TEXT"},{"name":"lat","nullable":false,"type":"INTEGER"},{"name":"lon","nullable":false,"type":"INTEGER"},{"enum":["japanese","vietnamese","indian","italian","american","mexican","cafe"],"name":"cuisine","nullable":false,"type":"TEXT"},{"enum":["budget","mid","upscale"],"name":"priceTier","nullable":false,"type":"TEXT"}],"name":"restaurant"},{"columns":[{"name":"name","nullable":false,"type":"TEXT"},{"enum":["pork","beef","lamb","chicken","fish","shellfish","egg","dairy","gluten","soy","peanut","treeNut","sesame","allium","mushroom","vegetable","grain","sugar","alcohol","tea","coffee","spice"],"name":"kind","nullable":false,"type":"TEXT"}],"name":"ingredient"},{"columns":[{"name":"restaurant","nullable":false,"references":"restaurant","type":"INTEGER"},{"enum":["mon","tue","wed","thu","fri","sat","sun"],"name":"day","nullable":false,"type":"TEXT"},{"name":"opens","nullable":false,"type":"INTEGER"},{"name":"lastOrder","nullable":false,"type":"INTEGER"},{"name":"closes","nullable":false,"type":"INTEGER"}],"name":"hours"},{"columns":[{"name":"restaurant","nullable":false,"references":"restaurant","type":"INTEGER"},{"name":"canonical","nullable":false,"references":"canonical_dish","type":"INTEGER"},{"name":"menuName","nullable":false,"type":"TEXT"},{"name":"price","nullable":false,"type":"INTEGER"},{"enum":["small","regular","large"],"name":"size","nullable":true,"type":"TEXT"},{"default":1,"name":"available","nullable":false,"type":"INTEGER"},{"default":0,"name":"ingredientsComplete","nullable":false,"type":"INTEGER"}],"name":"dish"},{"columns":[{"name":"dish","nullable":false,"references":"dish","type":"INTEGER"},{"name":"ingredient","nullable":false,"references":"ingredient","type":"INTEGER"},{"default":0,"name":"removable","nullable":false,"type":"INTEGER"},{"name":"substitutable","nullable":true,"references":"ingredient","type":"INTEGER"}],"name":"dish_ingredient"},{"columns":[{"name":"dish","nullable":false,"references":"dish","type":"INTEGER"},{"name":"label","nullable":false,"type":"TEXT"},{"name":"delta","nullable":false,"type":"INTEGER"},{"enum":["pork","beef","lamb","chicken","fish","shellfish","egg","dairy","gluten","soy","peanut","treeNut","sesame","allium","mushroom","vegetable","grain","sugar","alcohol","tea","coffee","spice"],"name":"removes","nullable":true,"type":"TEXT"}],"name":"modification"},{"columns":[{"name":"dish","nullable":false,"references":"dish","type":"INTEGER"},{"name":"price","nullable":false,"type":"INTEGER"},{"name":"observedAt","nullable":false,"type":"INTEGER"},{"enum":["menu","receipt","deliveryApp","crowd"],"name":"source","nullable":false,"type":"TEXT"}],"name":"price_obs"}]}
(exit 0)
```

## seed

```console
$ eats query seed
{"ok":true,"seeded":true}
(exit 0)
```

## average chai latte in San Francisco — (550 + 600 + 650) / 3; the unavailable 700 and the Oakland/Berkeley chais are excluded

```console
$ eats query avgPrice chai-latte sanFrancisco
{"ok":true,"result":600}
(exit 0)
```

## the same in Oakland

```console
$ eats query avgPrice chai-latte oakland
{"ok":true,"result":525}
(exit 0)
```

## tiramisu on Friday at 21:30 — Stella closes at 22:00; Tosca's row wraps midnight (17:00–02:00); Bellanico's last order was 19:30

```console
$ eats query openFor tiramisu fri 21:30
{"ok":true,"result":[[{"city":"sanFrancisco","cuisine":"italian","id":10,"lat":37800400,"lon":-122409300,"name":"Stella Pastry","neighborhood":"North Beach","priceTier":"mid"},[{"available":1,"canonical":6,"id":11,"ingredientsComplete":1,"menuName":"Tiramisu","price":700,"restaurant":10,"size":"small"},{"closes":1320,"day":"fri","id":67,"lastOrder":1305,"opens":480,"restaurant":10}]],[{"city":"sanFrancisco","cuisine":"italian","id":11,"lat":37797600,"lon":-122406100,"name":"Tosca Cafe","neighborhood":"North Beach","priceTier":"upscale"},[{"available":1,"canonical":6,"id":12,"ingredientsComplete":1,"menuName":"Tiramisù","price":1200,"restaurant":11,"size":"regular"},{"closes":120,"day":"fri","id":73,"lastOrder":60,"opens":1020,"restaurant":11}]]]}
(exit 0)
```

## tiramisu on Friday at 19:00 — all three

```console
$ eats query openFor tiramisu fri 19:00
{"ok":true,"result":[[{"city":"oakland","cuisine":"italian","id":12,"lat":37807700,"lon":-122223500,"name":"Bellanico","neighborhood":"Glenview","priceTier":"mid"},[{"available":1,"canonical":6,"id":13,"ingredientsComplete":1,"menuName":"Tiramisu della casa","price":900,"restaurant":12,"size":"regular"},{"closes":1200,"day":"fri","id":80,"lastOrder":1170,"opens":690,"restaurant":12}]],[{"city":"sanFrancisco","cuisine":"italian","id":10,"lat":37800400,"lon":-122409300,"name":"Stella Pastry","neighborhood":"North Beach","priceTier":"mid"},[{"available":1,"canonical":6,"id":11,"ingredientsComplete":1,"menuName":"Tiramisu","price":700,"restaurant":10,"size":"small"},{"closes":1320,"day":"fri","id":67,"lastOrder":1305,"opens":480,"restaurant":10}]],[{"city":"sanFrancisco","cuisine":"italian","id":11,"lat":37797600,"lon":-122406100,"name":"Tosca Cafe","neighborhood":"North Beach","priceTier":"upscale"},[{"available":1,"canonical":6,"id":12,"ingredientsComplete":1,"menuName":"Tiramisù","price":1200,"restaurant":11,"size":"regular"},{"closes":120,"day":"fri","id":73,"lastOrder":60,"opens":1020,"restaurant":11}]]]}
(exit 0)
```

## tiramisu on Friday at 00:30 — only the midnight wrap serves

```console
$ eats query openFor tiramisu fri 00:30
{"ok":true,"result":[[{"city":"sanFrancisco","cuisine":"italian","id":11,"lat":37797600,"lon":-122406100,"name":"Tosca Cafe","neighborhood":"North Beach","priceTier":"upscale"},[{"available":1,"canonical":6,"id":12,"ingredientsComplete":1,"menuName":"Tiramisù","price":1200,"restaurant":11,"size":"regular"},{"closes":120,"day":"fri","id":73,"lastOrder":60,"opens":1020,"restaurant":11}]]]}
(exit 0)
```

## vegetarian ramen in SF — only the vegetable ramen; the tonkotsu has pork, the paitan has chicken broth, and the dashi ramen's ingredient list is incomplete

```console
$ eats query suitable ramen vegetarian sanFrancisco
{"ok":true,"result":[[{"available":1,"canonical":3,"id":3,"ingredientsComplete":1,"menuName":"Shoyu Vegetable Ramen","price":1700,"restaurant":3,"size":"regular"},{"city":"sanFrancisco","cuisine":"japanese","id":3,"lat":37762600,"lon":-122421100,"name":"Shizen","neighborhood":"Mission","priceTier":"mid"}]]}
(exit 0)
```

## ramen without pork or beef — the paitan's chashu is removable, so it qualifies

```console
$ eats query suitable ramen noPorkBeef sanFrancisco
{"ok":true,"result":[[{"available":1,"canonical":2,"id":2,"ingredientsComplete":1,"menuName":"Tori Paitan Shoyu","price":1900,"restaurant":2,"size":"regular"},{"city":"sanFrancisco","cuisine":"japanese","id":2,"lat":37785900,"lon":-122417200,"name":"Mensho Tokyo SF","neighborhood":"Tenderloin","priceTier":"mid"}],[{"available":1,"canonical":3,"id":3,"ingredientsComplete":1,"menuName":"Shoyu Vegetable Ramen","price":1700,"restaurant":3,"size":"regular"},{"city":"sanFrancisco","cuisine":"japanese","id":3,"lat":37762600,"lon":-122421100,"name":"Shizen","neighborhood":"Mission","priceTier":"mid"}]]}
(exit 0)
```

## query log — the reified plans, newest first: suitable is ONE select at residual 0 — the ∀ over ingredient rows is a correlated NOT EXISTS subquery, with the captured diet case-split into a kind IS NOT ? conjunction inside it (LEP-0004); openFor is one three-table join at residual 0, midnight wrap included

```console
$ eats log 6
{"count":6,"entries":[{"at":1788324262,"detail":"dish×restaurant×canonical_dish | pushed: ((((((t0.\"restaurant\" IS t1.\"id\" AND t0.\"canonical\" IS t2.\"id\") AND t2.\"family\" IS ?) AND t1.\"city\" IS ?) AND t0.\"available\" IS ?) AND t0.\"ingredientsComplete\" IS ?) AND NOT EXISTS (SELECT 1 FROM \"dish_ingredient\" AS s0 WHERE s0.\"dish\" IS t0.\"id\" AND NOT EXISTS (SELECT 1 FROM \"ingredient\" AS s1 WHERE s1.\"id\" IS s0.\"ingredient\" AND ((s1.\"kind\" IS NOT ? AND s1.\"kind\" IS NOT ?) OR s0.\"removable\" IS ?)))), residual conjuncts: 0","error":null,"id":202,"ok":true,"rows":2,"verb":"select"},{"at":1788324262,"detail":"dish×restaurant×canonical_dish | pushed: ((((((t0.\"restaurant\" IS t1.\"id\" AND t0.\"canonical\" IS t2.\"id\") AND t2.\"family\" IS ?) AND t1.\"city\" IS ?) AND t0.\"available\" IS ?) AND t0.\"ingredientsComplete\" IS ?) AND NOT EXISTS (SELECT 1 FROM \"dish_ingredient\" AS s0 WHERE s0.\"dish\" IS t0.\"id\" AND NOT EXISTS (SELECT 1 FROM \"ingredient\" AS s1 WHERE s1.\"id\" IS s0.\"ingredient\" AND ((((((s1.\"kind\" IS NOT ? AND s1.\"kind\" IS NOT ?) AND s1.\"kind\" IS NOT ?) AND s1.\"kind\" IS NOT ?) AND s1.\"kind\" IS NOT ?) AND s1.\"kind\" IS NOT ?) OR s0.\"removable\" IS ?)))), residual conjuncts: 0","error":null,"id":201,"ok":true,"rows":1,"verb":"select"},{"at":1788324262,"detail":"restaurant×dish×hours | pushed: (((((t1.\"restaurant\" IS t0.\"id\" AND t2.\"restaurant\" IS t0.\"id\") AND t1.\"canonical\" IS ?) AND t1.\"available\" IS ?) AND t2.\"day\" IS ?) AND ((t2.\"closes\" < t2.\"opens\" AND (t2.\"opens\" <= ? OR t2.\"lastOrder\" > ?)) OR (t2.\"closes\" >= t2.\"opens\" AND (t2.\"opens\" <= ? AND t2.\"lastOrder\" > ?)))), residual conjuncts: 0","error":null,"id":200,"ok":true,"rows":1,"verb":"select"},{"at":1788324262,"detail":"canonical_dish | pushed: t0.\"slug\" IS ?, residual conjuncts: 0","error":null,"id":199,"ok":true,"rows":1,"verb":"select"},{"at":1788324262,"detail":"restaurant×dish×hours | pushed: (((((t1.\"restaurant\" IS t0.\"id\" AND t2.\"restaurant\" IS t0.\"id\") AND t1.\"canonical\" IS ?) AND t1.\"available\" IS ?) AND t2.\"day\" IS ?) AND ((t2.\"closes\" < t2.\"opens\" AND (t2.\"opens\" <= ? OR t2.\"lastOrder\" > ?)) OR (t2.\"closes\" >= t2.\"opens\" AND (t2.\"opens\" <= ? AND t2.\"lastOrder\" > ?)))), residual conjuncts: 0","error":null,"id":198,"ok":true,"rows":3,"verb":"select"},{"at":1788324262,"detail":"canonical_dish | pushed: t0.\"slug\" IS ?, residual conjuncts: 0","error":null,"id":197,"ok":true,"rows":1,"verb":"select"}],"ok":true}
(exit 0)
```

## the same as an ad-hoc list of kinds (residual by nature: a runtime list has no closed world to split on)

```console
$ eats query suitableAdHoc ramen pork,beef sanFrancisco
{"ok":true,"result":[[{"available":1,"canonical":2,"id":2,"ingredientsComplete":1,"menuName":"Tori Paitan Shoyu","price":1900,"restaurant":2,"size":"regular"},{"city":"sanFrancisco","cuisine":"japanese","id":2,"lat":37785900,"lon":-122417200,"name":"Mensho Tokyo SF","neighborhood":"Tenderloin","priceTier":"mid"}],[{"available":1,"canonical":3,"id":3,"ingredientsComplete":1,"menuName":"Shoyu Vegetable Ramen","price":1700,"restaurant":3,"size":"regular"},{"city":"sanFrancisco","cuisine":"japanese","id":3,"lat":37762600,"lon":-122421100,"name":"Shizen","neighborhood":"Mission","priceTier":"mid"}]]}
(exit 0)
```

## every diet the vegetable ramen satisfies

```console
$ eats query dietsFor 3
{"ok":true,"result":["omnivore","noPorkBeef","noBeef","noPork","pescatarian","vegetarian","vegan","halal","kosher","nutFree"]}
(exit 0)
```

## the paitan: no pork/beef once the chashu is held, but never vegetarian

```console
$ eats query dietsFor 2
{"ok":true,"result":["omnivore","noPorkBeef","noBeef","noPork","halal","kosher","nutFree"]}
(exit 0)
```

## the dashi ramen: incomplete ingredient list, so no diet at all

```console
$ eats query dietsFor 4
{"ok":true,"result":[]}
(exit 0)
```

## price with modifications — Blue Bottle chai, oat milk (+75) and an extra shot (+100)

```console
$ eats query priceWith 5 6,7
{"ok":true,"result":725}
(exit 0)
```

## a modification that belongs to another dish is refused (exit 2)

```console
$ eats query priceWith 5 1
{"code":"not_found","message":"modification: no row with id 1","ok":false}
(exit 2)
```

## within 1 km of Japantown — the pushed box admits four; the residual haversine keeps two

```console
$ eats query nearby 37.7852 -122.4316 1000
{"ok":true,"result":[{"city":"sanFrancisco","cuisine":"japanese","id":4,"lat":37785000,"lon":-122429900,"name":"Hinodeya Ramen Bar","neighborhood":"Japantown","priceTier":"budget"},{"city":"sanFrancisco","cuisine":"japanese","id":1,"lat":37785200,"lon":-122431600,"name":"Marufuku Ramen","neighborhood":"Japantown","priceTier":"mid"}]}
(exit 0)
```

## price history of the tonkotsu, newest first

```console
$ eats query history 1
{"ok":true,"result":[{"dish":1,"id":3,"observedAt":1748736000,"price":1850,"source":"deliveryApp"},{"dish":1,"id":2,"observedAt":1725148800,"price":1750,"source":"receipt"},{"dish":1,"id":1,"observedAt":1704067200,"price":1650,"source":"menu"}]}
(exit 0)
```

## an unknown slug is a typed error, not an empty answer (exit 2)

```console
$ eats query avgPrice pho-bo sanFrancisco
{"code":"decode","message":"canonical_dish.slug: no canonical dish with slug \"pho-bo\"","ok":false}
(exit 2)
```

## a bad clock (exit 2)

```console
$ eats query openFor tiramisu fri 25:00
{"code":"decode","message":"cli.t: expected HH:MM with H < 24 and M < 60, got \"25:00\"","ok":false}
(exit 2)
```

## a diet outside the closed world is refused with the world named (exit 2)

```console
$ eats query suitable ramen paleo sanFrancisco
{"code":"decode","message":"cli.diet: \"paleo\" is not one of #[omnivore, noPorkBeef, noBeef, noPork, pescatarian, vegetarian, vegan, jain, halal, kosher, glutenFree, nutFree]","ok":false}
(exit 2)
```

## insert with a city outside the closed world (exit 2)

```console
$ eats insert restaurant {"name":"Zuni","city":"losAngeles","neighborhood":"Civic Center","lat":37776000,"lon":-122421000,"cuisine":"american","priceTier":"upscale"}
{"code":"decode","message":"restaurant.city: \"losAngeles\" is not in the closed world","ok":false}
(exit 2)
```

## typed row filter

```console
$ eats rows dish --eq canonical=5 --eq available=1
{"count":5,"ok":true,"rows":[{"available":1,"canonical":5,"id":5,"ingredientsComplete":1,"menuName":"Chai Latte","price":550,"restaurant":5,"size":"regular"},{"available":1,"canonical":5,"id":6,"ingredientsComplete":1,"menuName":"Masala Chai Latte","price":600,"restaurant":6,"size":"regular"},{"available":1,"canonical":5,"id":7,"ingredientsComplete":1,"menuName":"Masala Chai (with milk)","price":650,"restaurant":7,"size":"regular"},{"available":1,"canonical":5,"id":9,"ingredientsComplete":1,"menuName":"Chai Latte","price":525,"restaurant":8,"size":"regular"},{"available":1,"canonical":5,"id":10,"ingredientsComplete":1,"menuName":"Chai Latte","price":475,"restaurant":9,"size":"regular"}]}
(exit 0)
```

## migrate status

```console
$ eats migrate status
{"applied":[],"fingerprint":"6544436943739024249","notes":["schema already up to date"],"ok":true}
(exit 0)
```

