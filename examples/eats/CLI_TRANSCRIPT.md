# eats CLI transcript

Regenerated 2026-09-01 from a fresh `data/` dir. Query verbs are
`query%`-derived from the defs in `Eats/Queries.lean` and
`Eats/OfferQueries.lean`; dishes are named by slug, times as `HH:MM`,
coordinates in decimal degrees, an espresso configuration as
`temp/size/milk/shots/decaf|regular` and a pattern as `key=value,…`. No
diet is stored: every dietary answer is computed from ingredient rows at
query time — `suitable` as one `selectP` whose `∀` pushes as `NOT EXISTS`
(LEP-0004). The configurable offers (LEP-0005 stage 1) are a rule column
plus a hand-tabulated `offer_price` child table, with the base
ingredients as an `EnumSet IngredientKind` — an INTEGER bitmask shown as
names in row JSON, whose membership pushes as a bit test; see
`README.md`.
Stdout/stderr merged; exit codes shown.

## schema — eleven tables; closed worlds visible as enum columns, no diet column anywhere; the three offer tables at the end, `espresso_offer.rule` an opaque TEXT

```console
$ eats schema
{"base":"eats","fingerprint":"2842052217298230069","ok":true,"tables":[{"columns":[{"name":"slug","nullable":false,"type":"TEXT"},{"name":"display","nullable":false,"type":"TEXT"},{"enum":["ramen","pho","curry","pizza","burger","salad","latte","tea","tiramisu","gelato","dosa","biryani","pastry"],"name":"family","nullable":false,"type":"TEXT"},{"enum":["drink","starter","main","dessert","side"],"name":"course","nullable":false,"type":"TEXT"}],"name":"canonical_dish"},{"columns":[{"name":"name","nullable":false,"type":"TEXT"},{"enum":["sanFrancisco","oakland","berkeley","paloAlto","sanJose"],"name":"city","nullable":false,"type":"TEXT"},{"name":"neighborhood","nullable":false,"type":"TEXT"},{"name":"lat","nullable":false,"type":"INTEGER"},{"name":"lon","nullable":false,"type":"INTEGER"},{"enum":["japanese","vietnamese","indian","italian","american","mexican","cafe"],"name":"cuisine","nullable":false,"type":"TEXT"},{"enum":["budget","mid","upscale"],"name":"priceTier","nullable":false,"type":"TEXT"}],"name":"restaurant"},{"columns":[{"name":"name","nullable":false,"type":"TEXT"},{"enum":["pork","beef","lamb","chicken","fish","shellfish","egg","dairy","gluten","soy","peanut","treeNut","sesame","allium","mushroom","vegetable","grain","sugar","alcohol","tea","coffee","spice"],"name":"kind","nullable":false,"type":"TEXT"}],"name":"ingredient"},{"columns":[{"name":"restaurant","nullable":false,"references":"restaurant","type":"INTEGER"},{"enum":["mon","tue","wed","thu","fri","sat","sun"],"name":"day","nullable":false,"type":"TEXT"},{"name":"opens","nullable":false,"type":"INTEGER"},{"name":"lastOrder","nullable":false,"type":"INTEGER"},{"name":"closes","nullable":false,"type":"INTEGER"}],"name":"hours"},{"columns":[{"name":"restaurant","nullable":false,"references":"restaurant","type":"INTEGER"},{"name":"canonical","nullable":false,"references":"canonical_dish","type":"INTEGER"},{"name":"menuName","nullable":false,"type":"TEXT"},{"name":"price","nullable":false,"type":"INTEGER"},{"enum":["small","regular","large"],"name":"size","nullable":true,"type":"TEXT"},{"default":1,"name":"available","nullable":false,"type":"INTEGER"},{"default":0,"name":"ingredientsComplete","nullable":false,"type":"INTEGER"}],"name":"dish"},{"columns":[{"name":"dish","nullable":false,"references":"dish","type":"INTEGER"},{"name":"ingredient","nullable":false,"references":"ingredient","type":"INTEGER"},{"default":0,"name":"removable","nullable":false,"type":"INTEGER"},{"name":"substitutable","nullable":true,"references":"ingredient","type":"INTEGER"}],"name":"dish_ingredient"},{"columns":[{"name":"dish","nullable":false,"references":"dish","type":"INTEGER"},{"name":"label","nullable":false,"type":"TEXT"},{"name":"delta","nullable":false,"type":"INTEGER"},{"enum":["pork","beef","lamb","chicken","fish","shellfish","egg","dairy","gluten","soy","peanut","treeNut","sesame","allium","mushroom","vegetable","grain","sugar","alcohol","tea","coffee","spice"],"name":"removes","nullable":true,"type":"TEXT"}],"name":"modification"},{"columns":[{"name":"dish","nullable":false,"references":"dish","type":"INTEGER"},{"name":"price","nullable":false,"type":"INTEGER"},{"name":"observedAt","nullable":false,"type":"INTEGER"},{"enum":["menu","receipt","deliveryApp","crowd"],"name":"source","nullable":false,"type":"TEXT"}],"name":"price_obs"},{"columns":[{"name":"restaurant","nullable":false,"references":"restaurant","type":"INTEGER"},{"name":"canonical","nullable":false,"references":"canonical_dish","type":"INTEGER"},{"name":"rule","nullable":false,"type":"TEXT"},{"enumSet":["pork","beef","lamb","chicken","fish","shellfish","egg","dairy","gluten","soy","peanut","treeNut","sesame","allium","mushroom","vegetable","grain","sugar","alcohol","tea","coffee","spice"],"name":"baseKinds","nullable":false,"type":"INTEGER"},{"name":"minPrice","nullable":false,"type":"INTEGER"},{"name":"maxPrice","nullable":false,"type":"INTEGER"},{"name":"veganPossible","nullable":false,"type":"INTEGER"},{"default":1,"name":"available","nullable":false,"type":"INTEGER"}],"name":"espresso_offer"},{"columns":[{"name":"offer","nullable":false,"references":"espresso_offer","type":"INTEGER"},{"enum":["hot","iced"],"name":"temp","nullable":false,"type":"TEXT"},{"enum":["small","regular","large"],"name":"size","nullable":false,"type":"TEXT"},{"enum":["whole","skim","oat","almond","soy"],"name":"milk","nullable":false,"type":"TEXT"},{"enum":["single","double","triple"],"name":"shots","nullable":false,"type":"TEXT"},{"name":"decaf","nullable":false,"type":"INTEGER"},{"name":"price","nullable":false,"type":"INTEGER"}],"name":"offer_price"},{"columns":[{"name":"offer","nullable":false,"references":"espresso_offer","type":"INTEGER"},{"enum":["hot","iced"],"name":"temp","nullable":false,"type":"TEXT"},{"enum":["small","regular","large"],"name":"size","nullable":false,"type":"TEXT"},{"enum":["whole","skim","oat","almond","soy"],"name":"milk","nullable":false,"type":"TEXT"},{"enum":["single","double","triple"],"name":"shots","nullable":false,"type":"TEXT"},{"name":"decaf","nullable":false,"type":"INTEGER"},{"name":"quoted","nullable":false,"type":"INTEGER"},{"name":"placedAt","nullable":false,"type":"INTEGER"}],"name":"order_line"}]}
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
{"count":6,"entries":[{"at":1788327828,"detail":"dish×restaurant×canonical_dish | pushed: ((((((t0.\"restaurant\" IS t1.\"id\" AND t0.\"canonical\" IS t2.\"id\") AND t2.\"family\" IS ?) AND t1.\"city\" IS ?) AND t0.\"available\" IS ?) AND t0.\"ingredientsComplete\" IS ?) AND NOT EXISTS (SELECT 1 FROM \"dish_ingredient\" AS s0 WHERE s0.\"dish\" IS t0.\"id\" AND NOT EXISTS (SELECT 1 FROM \"ingredient\" AS s1 WHERE s1.\"id\" IS s0.\"ingredient\" AND ((s1.\"kind\" IS NOT ? AND s1.\"kind\" IS NOT ?) OR s0.\"removable\" IS ?)))), residual conjuncts: 0","error":null,"id":942,"ok":true,"rows":2,"verb":"select"},{"at":1788327828,"detail":"dish×restaurant×canonical_dish | pushed: ((((((t0.\"restaurant\" IS t1.\"id\" AND t0.\"canonical\" IS t2.\"id\") AND t2.\"family\" IS ?) AND t1.\"city\" IS ?) AND t0.\"available\" IS ?) AND t0.\"ingredientsComplete\" IS ?) AND NOT EXISTS (SELECT 1 FROM \"dish_ingredient\" AS s0 WHERE s0.\"dish\" IS t0.\"id\" AND NOT EXISTS (SELECT 1 FROM \"ingredient\" AS s1 WHERE s1.\"id\" IS s0.\"ingredient\" AND ((((((s1.\"kind\" IS NOT ? AND s1.\"kind\" IS NOT ?) AND s1.\"kind\" IS NOT ?) AND s1.\"kind\" IS NOT ?) AND s1.\"kind\" IS NOT ?) AND s1.\"kind\" IS NOT ?) OR s0.\"removable\" IS ?)))), residual conjuncts: 0","error":null,"id":941,"ok":true,"rows":1,"verb":"select"},{"at":1788327828,"detail":"restaurant×dish×hours | pushed: (((((t1.\"restaurant\" IS t0.\"id\" AND t2.\"restaurant\" IS t0.\"id\") AND t1.\"canonical\" IS ?) AND t1.\"available\" IS ?) AND t2.\"day\" IS ?) AND ((t2.\"closes\" < t2.\"opens\" AND (t2.\"opens\" <= ? OR t2.\"lastOrder\" > ?)) OR (t2.\"closes\" >= t2.\"opens\" AND (t2.\"opens\" <= ? AND t2.\"lastOrder\" > ?)))), residual conjuncts: 0","error":null,"id":940,"ok":true,"rows":1,"verb":"select"},{"at":1788327828,"detail":"canonical_dish | pushed: t0.\"slug\" IS ?, residual conjuncts: 0","error":null,"id":939,"ok":true,"rows":1,"verb":"select"},{"at":1788327828,"detail":"restaurant×dish×hours | pushed: (((((t1.\"restaurant\" IS t0.\"id\" AND t2.\"restaurant\" IS t0.\"id\") AND t1.\"canonical\" IS ?) AND t1.\"available\" IS ?) AND t2.\"day\" IS ?) AND ((t2.\"closes\" < t2.\"opens\" AND (t2.\"opens\" <= ? OR t2.\"lastOrder\" > ?)) OR (t2.\"closes\" >= t2.\"opens\" AND (t2.\"opens\" <= ? AND t2.\"lastOrder\" > ?)))), residual conjuncts: 0","error":null,"id":938,"ok":true,"rows":3,"verb":"select"},{"at":1788327828,"detail":"canonical_dish | pushed: t0.\"slug\" IS ?, residual conjuncts: 0","error":null,"id":937,"ok":true,"rows":1,"verb":"select"}],"ok":true}
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
{"applied":[],"fingerprint":"2842052217298230069","notes":["schema already up to date"],"ok":true}
(exit 0)
```

## price of one configuration at one offer — offer 4 is Samovar's latte; iced large oat double, from the tabulation: 450 + 50 + 75 + 25

```console
$ eats query priceOf 4 iced/large/oat/double/regular
{"ok":true,"result":600}
(exit 0)
```

## the same configuration at Highwire (offer 5), which has no oat — no `offer_price` row, so `null`

```console
$ eats query priceOf 5 iced/large/oat/double/regular
{"ok":true,"result":null}
(exit 0)
```

## cheapest iced large oat double in San Francisco — the whole configuration as five arguments; offer × tabulation × restaurant, sorted by price; Samovar 600, then Blue Bottle's latte and cappuccino and Sightglass's override at 725

```console
$ eats query cheapestConfigured iced large oat double false sanFrancisco
{"ok":true,"result":[[{"available":1,"baseKinds":[],"canonical":7,"id":4,"maxPrice":675,"minPrice":400,"restaurant":7,"rule":"{\"base\":450,\"deltas\":[[[{\"milk\":{\"m\":\"oat\"}}],50],[[{\"milk\":{\"m\":\"almond\"}}],50],[[{\"milk\":{\"m\":\"soy\"}}],50],[[{\"size\":{\"s\":\"large\"}}],75],[[{\"size\":{\"s\":\"small\"}}],-50],[[{\"temp\":{\"t\":\"iced\"}}],25],[[{\"shots\":{\"n\":\"triple\"}}],75]],\"overrides\":[]}","veganPossible":1},[{"decaf":0,"id":488,"milk":"oat","offer":4,"price":600,"shots":"double","size":"large","temp":"iced"},{"city":"sanFrancisco","cuisine":"cafe","id":7,"lat":37761800,"lon":-122426000,"name":"Samovar Tea Lounge","neighborhood":"Mission","priceTier":"mid"}]],[{"available":1,"baseKinds":[],"canonical":7,"id":1,"maxPrice":825,"minPrice":450,"restaurant":5,"rule":"{\"base\":500,\"deltas\":[[[{\"milk\":{\"m\":\"oat\"}}],75],[[{\"milk\":{\"m\":\"almond\"}}],75],[[{\"milk\":{\"m\":\"soy\"}}],50],[[{\"size\":{\"s\":\"large\"}}],100],[[{\"size\":{\"s\":\"small\"}}],-50],[[{\"temp\":{\"t\":\"iced\"}}],50],[[{\"shots\":{\"n\":\"triple\"}}],100]],\"overrides\":[]}","veganPossible":1},[{"decaf":0,"id":113,"milk":"oat","offer":1,"price":725,"shots":"double","size":"large","temp":"iced"},{"city":"sanFrancisco","cuisine":"cafe","id":5,"lat":37776400,"lon":-122423300,"name":"Blue Bottle Hayes Valley","neighborhood":"Hayes Valley","priceTier":"mid"}]],[{"available":1,"baseKinds":["sugar"],"canonical":8,"id":2,"maxPrice":825,"minPrice":450,"restaurant":5,"rule":"{\"base\":500,\"deltas\":[[[{\"milk\":{\"m\":\"oat\"}}],75],[[{\"milk\":{\"m\":\"almond\"}}],75],[[{\"milk\":{\"m\":\"soy\"}}],50],[[{\"size\":{\"s\":\"large\"}}],100],[[{\"size\":{\"s\":\"small\"}}],-50],[[{\"temp\":{\"t\":\"iced\"}}],50],[[{\"shots\":{\"n\":\"triple\"}}],100]],\"overrides\":[]}","veganPossible":1},[{"decaf":0,"id":238,"milk":"oat","offer":2,"price":725,"shots":"double","size":"large","temp":"iced"},{"city":"sanFrancisco","cuisine":"cafe","id":5,"lat":37776400,"lon":-122423300,"name":"Blue Bottle Hayes Valley","neighborhood":"Hayes Valley","priceTier":"mid"}]],[{"available":1,"baseKinds":[],"canonical":7,"id":3,"maxPrice":855,"minPrice":475,"restaurant":6,"rule":"{\"base\":525,\"deltas\":[[[{\"milk\":{\"m\":\"oat\"}}],80],[[{\"milk\":{\"m\":\"almond\"}}],80],[[{\"milk\":{\"m\":\"soy\"}}],60],[[{\"size\":{\"s\":\"large\"}}],100],[[{\"size\":{\"s\":\"small\"}}],-50],[[{\"temp\":{\"t\":\"iced\"}}],50],[[{\"shots\":{\"n\":\"triple\"}}],100]],\"overrides\":[[[{\"temp\":{\"t\":\"iced\"}},{\"size\":{\"s\":\"large\"}},{\"milk\":{\"m\":\"oat\"}}],725]]}","veganPossible":1},[{"decaf":0,"id":363,"milk":"oat","offer":3,"price":725,"shots":"double","size":"large","temp":"iced"},{"city":"sanFrancisco","cuisine":"cafe","id":6,"lat":37777000,"lon":-122408600,"name":"Sightglass Coffee","neighborhood":"SoMa","priceTier":"mid"}]]]}
(exit 0)
```

## cheapest iced oat of any size/shots — a runtime pattern; Samovar's iced regular oat single at 525 comes first

```console
$ eats query cheapestMatching temp=iced,milk=oat sanFrancisco
{"ok":true,"result":[[{"available":1,"baseKinds":[],"canonical":7,"id":4,"maxPrice":675,"minPrice":400,"restaurant":7,"rule":"{\"base\":450,\"deltas\":[[[{\"milk\":{\"m\":\"oat\"}}],50],[[{\"milk\":{\"m\":\"almond\"}}],50],[[{\"milk\":{\"m\":\"soy\"}}],50],[[{\"size\":{\"s\":\"large\"}}],75],[[{\"size\":{\"s\":\"small\"}}],-50],[[{\"temp\":{\"t\":\"iced\"}}],25],[[{\"shots\":{\"n\":\"triple\"}}],75]],\"overrides\":[]}","veganPossible":1},[{"decaf":0,"id":461,"milk":"oat","offer":4,"price":525,"shots":"single","size":"regular","temp":"iced"},{"city":"sanFrancisco","cuisine":"cafe","id":7,"lat":37761800,"lon":-122426000,"name":"Samovar Tea Lounge","neighborhood":"Mission","priceTier":"mid"}]],[{"available":1,"baseKinds":[],"canonical":7,"id":4,"maxPrice":675,"minPrice":400,"restaurant":7,"rule":"{\"base\":450,\"deltas\":[[[{\"milk\":{\"m\":\"oat\"}}],50],[[{\"milk\":{\"m\":\"almond\"}}],50],[[{\"milk\":{\"m\":\"soy\"}}],50],[[{\"size\":{\"s\":\"large\"}}],75],[[{\"size\":{\"s\":\"small\"}}],-50],[[{\"temp\":{\"t\":\"iced\"}}],25],[[{\"shots\":{\"n\":\"triple\"}}],75]],\"overrides\":[]}","veganPossible":1},[{"decaf":1,"id":462,"milk":"oat","offer":4,"price":525,"shots":"single","size":"regular","temp":"iced"},{"city":"sanFrancisco","cuisine":"cafe","id":7,"lat":37761800,"lon":-122426000,"name":"Samovar Tea Lounge","neighborhood":"Mission","priceTier":"mid"}]],[{"available":1,"baseKinds":[],"canonical":7,"id":4,"maxPrice":675,"minPrice":400,"restaurant":7,"rule":"{\"base\":450,\"deltas\":[[[{\"milk\":{\"m\":\"oat\"}}],50],[[{\"milk\":{\"m\":\"almond\"}}],50],[[{\"milk\":{\"m\":\"soy\"}}],50],[[{\"size\":{\"s\":\"large\"}}],75],[[{\"size\":{\"s\":\"small\"}}],-50],[[{\"temp\":{\"t\":\"iced\"}}],25],[[{\"shots\":{\"n\":\"triple\"}}],75]],\"overrides\":[]}","veganPossible":1},[{"decaf":0,"id":463,"milk":"oat","offer":4,"price":525,"shots":"double","size":"regular","temp":"iced"},{"city":"sanFrancisco","cuisine":"cafe","id":7,"lat":37761800,"lon":-122426000,"name":"Samovar Tea Lounge","neighborhood":"Mission","priceTier":"mid"}]],[{"available":1,"baseKinds":[],"canonical":7,"id":4,"maxPrice":675,"minPrice":400,"restaurant":7,"rule":"{\"base\":450,\"deltas\":[[[{\"milk\":{\"m\":\"oat\"}}],50],[[{\"milk\":{\"m\":\"almond\"}}],50],[[{\"milk\":{\"m\":\"soy\"}}],50],[[{\"size\":{\"s\":\"large\"}}],75],[[{\"size\":{\"s\":\"small\"}}],-50],[[{\"temp\":{\"t\":\"iced\"}}],25],[[{\"shots\":{\"n\":\"triple\"}}],75]],\"overrides\":[]}","veganPossible":1},[{"decaf":1,"id":464,"milk":"oat","offer":4,"price":525,"shots":"double","size":"regular","temp":"iced"},{"city":"sanFrancisco","cuisine":"cafe","id":7,"lat":37761800,"lon":-122426000,"name":"Samovar Tea Lounge","neighborhood":"Mission","priceTier":"mid"}]],[{"available":1,"baseKinds":[],"canonical":7,"id":4,"maxPrice":675,"minPrice":400,"restaurant":7,"rule":"{\"base\":450,\"deltas\":[[[{\"milk\":{\"m\":\"oat\"}}],50],[[{\"milk\":{\"m\":\"almond\"}}],50],[[{\"milk\":{\"m\":\"soy\"}}],50],[[{\"size\":{\"s\":\"large\"}}],75],[[{\"size\":{\"s\":\"small\"}}],-50],[[{\"temp\":{\"t\":\"iced\"}}],25],[[{\"shots\":{\"n\":\"triple\"}}],75]],\"overrides\":[]}","veganPossible":1},[{"decaf":0,"id":465,"milk":"oat","offer":4,"price":600,"shots":"triple","size":"regular","temp":"iced"},{"city":"sanFrancisco","cuisine":"cafe","id":7,"lat":37761800,"lon":-122426000,"name":"Samovar Tea Lounge","neighborhood":"Mission","priceTier":"mid"}]],[{"available":1,"baseKinds":[],"canonical":7,"id":4,"maxPrice":675,"minPrice":400,"restaurant":7,"rule":"{\"base\":450,\"deltas\":[[[{\"milk\":{\"m\":\"oat\"}}],50],[[{\"milk\":{\"m\":\"almond\"}}],50],[[{\"milk\":{\"m\":\"soy\"}}],50],[[{\"size\":{\"s\":\"large\"}}],75],[[{\"size\":{\"s\":\"small\"}}],-50],[[{\"temp\":{\"t\":\"iced\"}}],25],[[{\"shots\":{\"n\":\"triple\"}}],75]],\"overrides\":[]}","veganPossible":1},[{"decaf":0,"id":486,"milk":"oat","offer":4,"price":600,"shots":"single","size":"large","temp":"iced"},{"city":"sanFrancisco","cuisine":"cafe","id":7,"lat":37761800,"lon":-122426000,"name":"Samovar Tea Lounge","neighborhood":"Mission","priceTier":"mid"}]],[{"available":1,"baseKinds":[],"canonical":7,"id":4,"maxPrice":675,"minPrice":400,"restaurant":7,"rule":"{\"base\":450,\"deltas\":[[[{\"milk\":{\"m\":\"oat\"}}],50],[[{\"milk\":{\"m\":\"almond\"}}],50],[[{\"milk\":{\"m\":\"soy\"}}],50],[[{\"size\":{\"s\":\"large\"}}],75],[[{\"size\":{\"s\":\"small\"}}],-50],[[{\"temp\":{\"t\":\"iced\"}}],25],[[{\"shots\":{\"n\":\"triple\"}}],75]],\"overrides\":[]}","veganPossible":1},[{"decaf":1,"id":487,"milk":"oat","offer":4,"price":600,"shots":"single","size":"large","temp":"iced"},{"city":"sanFrancisco","cuisine":"cafe","id":7,"lat":37761800,"lon":-122426000,"name":"Samovar Tea Lounge","neighborhood":"Mission","priceTier":"mid"}]],[{"available":1,"baseKinds":[],"canonical":7,"id":4,"maxPrice":675,"minPrice":400,"restaurant":7,"rule":"{\"base\":450,\"deltas\":[[[{\"milk\":{\"m\":\"oat\"}}],50],[[{\"milk\":{\"m\":\"almond\"}}],50],[[{\"milk\":{\"m\":\"soy\"}}],50],[[{\"size\":{\"s\":\"large\"}}],75],[[{\"size\":{\"s\":\"small\"}}],-50],[[{\"temp\":{\"t\":\"iced\"}}],25],[[{\"shots\":{\"n\":\"triple\"}}],75]],\"overrides\":[]}","veganPossible":1},[{"decaf":0,"id":488,"milk":"oat","offer":4,"price":600,"shots":"double","size":"large","temp":"iced"},{"city":"sanFrancisco","cuisine":"cafe","id":7,"lat":37761800,"lon":-122426000,"name":"Samovar Tea Lounge","neighborhood":"Mission","priceTier":"mid"}]],[{"available":1,"baseKinds":[],"canonical":7,"id":4,"maxPrice":675,"minPrice":400,"restaurant":7,"rule":"{\"base\":450,\"deltas\":[[[{\"milk\":{\"m\":\"oat\"}}],50],[[{\"milk\":{\"m\":\"almond\"}}],50],[[{\"milk\":{\"m\":\"soy\"}}],50],[[{\"size\":{\"s\":\"large\"}}],75],[[{\"size\":{\"s\":\"small\"}}],-50],[[{\"temp\":{\"t\":\"iced\"}}],25],[[{\"shots\":{\"n\":\"triple\"}}],75]],\"overrides\":[]}","veganPossible":1},[{"decaf":1,"id":489,"milk":"oat","offer":4,"price":600,"shots":"double","size":"large","temp":"iced"},{"city":"sanFrancisco","cuisine":"cafe","id":7,"lat":37761800,"lon":-122426000,"name":"Samovar Tea Lounge","neighborhood":"Mission","priceTier":"mid"}]],[{"available":1,"baseKinds":[],"canonical":7,"id":1,"maxPrice":825,"minPrice":450,"restaurant":5,"rule":"{\"base\":500,\"deltas\":[[[{\"milk\":{\"m\":\"oat\"}}],75],[[{\"milk\":{\"m\":\"almond\"}}],75],[[{\"milk\":{\"m\":\"soy\"}}],50],[[{\"size\":{\"s\":\"large\"}}],100],[[{\"size\":{\"s\":\"small\"}}],-50],[[{\"temp\":{\"t\":\"iced\"}}],50],[[{\"shots\":{\"n\":\"triple\"}}],100]],\"overrides\":[]}","veganPossible":1},[{"decaf":0,"id":86,"milk":"oat","offer":1,"price":625,"shots":"single","size":"regular","temp":"iced"},{"city":"sanFrancisco","cuisine":"cafe","id":5,"lat":37776400,"lon":-122423300,"name":"Blue Bottle Hayes Valley","neighborhood":"Hayes Valley","priceTier":"mid"}]],[{"available":1,"baseKinds":[],"canonical":7,"id":1,"maxPrice":825,"minPrice":450,"restaurant":5,"rule":"{\"base\":500,\"deltas\":[[[{\"milk\":{\"m\":\"oat\"}}],75],[[{\"milk\":{\"m\":\"almond\"}}],75],[[{\"milk\":{\"m\":\"soy\"}}],50],[[{\"size\":{\"s\":\"large\"}}],100],[[{\"size\":{\"s\":\"small\"}}],-50],[[{\"temp\":{\"t\":\"iced\"}}],50],[[{\"shots\":{\"n\":\"triple\"}}],100]],\"overrides\":[]}","veganPossible":1},[{"decaf":1,"id":87,"milk":"oat","offer":1,"price":625,"shots":"single","size":"regular","temp":"iced"},{"city":"sanFrancisco","cuisine":"cafe","id":5,"lat":37776400,"lon":-122423300,"name":"Blue Bottle Hayes Valley","neighborhood":"Hayes Valley","priceTier":"mid"}]],[{"available":1,"baseKinds":[],"canonical":7,"id":1,"maxPrice":825,"minPrice":450,"restaurant":5,"rule":"{\"base\":500,\"deltas\":[[[{\"milk\":{\"m\":\"oat\"}}],75],[[{\"milk\":{\"m\":\"almond\"}}],75],[[{\"milk\":{\"m\":\"soy\"}}],50],[[{\"size\":{\"s\":\"large\"}}],100],[[{\"size\":{\"s\":\"small\"}}],-50],[[{\"temp\":{\"t\":\"iced\"}}],50],[[{\"shots\":{\"n\":\"triple\"}}],100]],\"overrides\":[]}","veganPossible":1},[{"decaf":0,"id":88,"milk":"oat","offer":1,"price":625,"shots":"double","size":"regular","temp":"iced"},{"city":"sanFrancisco","cuisine":"cafe","id":5,"lat":37776400,"lon":-122423300,"name":"Blue Bottle Hayes Valley","neighborhood":"Hayes Valley","priceTier":"mid"}]],[{"available":1,"baseKinds":[],"canonical":7,"id":1,"maxPrice":825,"minPrice":450,"restaurant":5,"rule":"{\"base\":500,\"deltas\":[[[{\"milk\":{\"m\":\"oat\"}}],75],[[{\"milk\":{\"m\":\"almond\"}}],75],[[{\"milk\":{\"m\":\"soy\"}}],50],[[{\"size\":{\"s\":\"large\"}}],100],[[{\"size\":{\"s\":\"small\"}}],-50],[[{\"temp\":{\"t\":\"iced\"}}],50],[[{\"shots\":{\"n\":\"triple\"}}],100]],\"overrides\":[]}","veganPossible":1},[{"decaf":1,"id":89,"milk":"oat","offer":1,"price":625,"shots":"double","size":"regular","temp":"iced"},{"city":"sanFrancisco","cuisine":"cafe","id":5,"lat":37776400,"lon":-122423300,"name":"Blue Bottle Hayes Valley","neighborhood":"Hayes Valley","priceTier":"mid"}]],[{"available":1,"baseKinds":["sugar"],"canonical":8,"id":2,"maxPrice":825,"minPrice":450,"restaurant":5,"rule":"{\"base\":500,\"deltas\":[[[{\"milk\":{\"m\":\"oat\"}}],75],[[{\"milk\":{\"m\":\"almond\"}}],75],[[{\"milk\":{\"m\":\"soy\"}}],50],[[{\"size\":{\"s\":\"large\"}}],100],[[{\"size\":{\"s\":\"small\"}}],-50],[[{\"temp\":{\"t\":\"iced\"}}],50],[[{\"shots\":{\"n\":\"triple\"}}],100]],\"overrides\":[]}","veganPossible":1},[{"decaf":0,"id":211,"milk":"oat","offer":2,"price":625,"shots":"single","size":"regular","temp":"iced"},{"city":"sanFrancisco","cuisine":"cafe","id":5,"lat":37776400,"lon":-122423300,"name":"Blue Bottle Hayes Valley","neighborhood":"Hayes Valley","priceTier":"mid"}]],[{"available":1,"baseKinds":["sugar"],"canonical":8,"id":2,"maxPrice":825,"minPrice":450,"restaurant":5,"rule":"{\"base\":500,\"deltas\":[[[{\"milk\":{\"m\":\"oat\"}}],75],[[{\"milk\":{\"m\":\"almond\"}}],75],[[{\"milk\":{\"m\":\"soy\"}}],50],[[{\"size\":{\"s\":\"large\"}}],100],[[{\"size\":{\"s\":\"small\"}}],-50],[[{\"temp\":{\"t\":\"iced\"}}],50],[[{\"shots\":{\"n\":\"triple\"}}],100]],\"overrides\":[]}","veganPossible":1},[{"decaf":1,"id":212,"milk":"oat","offer":2,"price":625,"shots":"single","size":"regular","temp":"iced"},{"city":"sanFrancisco","cuisine":"cafe","id":5,"lat":37776400,"lon":-122423300,"name":"Blue Bottle Hayes Valley","neighborhood":"Hayes Valley","priceTier":"mid"}]],[{"available":1,"baseKinds":["sugar"],"canonical":8,"id":2,"maxPrice":825,"minPrice":450,"restaurant":5,"rule":"{\"base\":500,\"deltas\":[[[{\"milk\":{\"m\":\"oat\"}}],75],[[{\"milk\":{\"m\":\"almond\"}}],75],[[{\"milk\":{\"m\":\"soy\"}}],50],[[{\"size\":{\"s\":\"large\"}}],100],[[{\"size\":{\"s\":\"small\"}}],-50],[[{\"temp\":{\"t\":\"iced\"}}],50],[[{\"shots\":{\"n\":\"triple\"}}],100]],\"overrides\":[]}","veganPossible":1},[{"decaf":0,"id":213,"milk":"oat","offer":2,"price":625,"shots":"double","size":"regular","temp":"iced"},{"city":"sanFrancisco","cuisine":"cafe","id":5,"lat":37776400,"lon":-122423300,"name":"Blue Bottle Hayes Valley","neighborhood":"Hayes Valley","priceTier":"mid"}]],[{"available":1,"baseKinds":["sugar"],"canonical":8,"id":2,"maxPrice":825,"minPrice":450,"restaurant":5,"rule":"{\"base\":500,\"deltas\":[[[{\"milk\":{\"m\":\"oat\"}}],75],[[{\"milk\":{\"m\":\"almond\"}}],75],[[{\"milk\":{\"m\":\"soy\"}}],50],[[{\"size\":{\"s\":\"large\"}}],100],[[{\"size\":{\"s\":\"small\"}}],-50],[[{\"temp\":{\"t\":\"iced\"}}],50],[[{\"shots\":{\"n\":\"triple\"}}],100]],\"overrides\":[]}","veganPossible":1},[{"decaf":1,"id":214,"milk":"oat","offer":2,"price":625,"shots":"double","size":"regular","temp":"iced"},{"city":"sanFrancisco","cuisine":"cafe","id":5,"lat":37776400,"lon":-122423300,"name":"Blue Bottle Hayes Valley","neighborhood":"Hayes Valley","priceTier":"mid"}]],[{"available":1,"baseKinds":[],"canonical":7,"id":3,"maxPrice":855,"minPrice":475,"restaurant":6,"rule":"{\"base\":525,\"deltas\":[[[{\"milk\":{\"m\":\"oat\"}}],80],[[{\"milk\":{\"m\":\"almond\"}}],80],[[{\"milk\":{\"m\":\"soy\"}}],60],[[{\"size\":{\"s\":\"large\"}}],100],[[{\"size\":{\"s\":\"small\"}}],-50],[[{\"temp\":{\"t\":\"iced\"}}],50],[[{\"shots\":{\"n\":\"triple\"}}],100]],\"overrides\":[[[{\"temp\":{\"t\":\"iced\"}},{\"size\":{\"s\":\"large\"}},{\"milk\":{\"m\":\"oat\"}}],725]]}","veganPossible":1},[{"decaf":0,"id":336,"milk":"oat","offer":3,"price":655,"shots":"single","size":"regular","temp":"iced"},{"city":"sanFrancisco","cuisine":"cafe","id":6,"lat":37777000,"lon":-122408600,"name":"Sightglass Coffee","neighborhood":"SoMa","priceTier":"mid"}]],[{"available":1,"baseKinds":[],"canonical":7,"id":3,"maxPrice":855,"minPrice":475,"restaurant":6,"rule":"{\"base\":525,\"deltas\":[[[{\"milk\":{\"m\":\"oat\"}}],80],[[{\"milk\":{\"m\":\"almond\"}}],80],[[{\"milk\":{\"m\":\"soy\"}}],60],[[{\"size\":{\"s\":\"large\"}}],100],[[{\"size\":{\"s\":\"small\"}}],-50],[[{\"temp\":{\"t\":\"iced\"}}],50],[[{\"shots\":{\"n\":\"triple\"}}],100]],\"overrides\":[[[{\"temp\":{\"t\":\"iced\"}},{\"size\":{\"s\":\"large\"}},{\"milk\":{\"m\":\"oat\"}}],725]]}","veganPossible":1},[{"decaf":1,"id":337,"milk":"oat","offer":3,"price":655,"shots":"single","size":"regular","temp":"iced"},{"city":"sanFrancisco","cuisine":"cafe","id":6,"lat":37777000,"lon":-122408600,"name":"Sightglass Coffee","neighborhood":"SoMa","priceTier":"mid"}]],[{"available":1,"baseKinds":[],"canonical":7,"id":3,"maxPrice":855,"minPrice":475,"restaurant":6,"rule":"{\"base\":525,\"deltas\":[[[{\"milk\":{\"m\":\"oat\"}}],80],[[{\"milk\":{\"m\":\"almond\"}}],80],[[{\"milk\":{\"m\":\"soy\"}}],60],[[{\"size\":{\"s\":\"large\"}}],100],[[{\"size\":{\"s\":\"small\"}}],-50],[[{\"temp\":{\"t\":\"iced\"}}],50],[[{\"shots\":{\"n\":\"triple\"}}],100]],\"overrides\":[[[{\"temp\":{\"t\":\"iced\"}},{\"size\":{\"s\":\"large\"}},{\"milk\":{\"m\":\"oat\"}}],725]]}","veganPossible":1},[{"decaf":0,"id":338,"milk":"oat","offer":3,"price":655,"shots":"double","size":"regular","temp":"iced"},{"city":"sanFrancisco","cuisine":"cafe","id":6,"lat":37777000,"lon":-122408600,"name":"Sightglass Coffee","neighborhood":"SoMa","priceTier":"mid"}]],[{"available":1,"baseKinds":[],"canonical":7,"id":3,"maxPrice":855,"minPrice":475,"restaurant":6,"rule":"{\"base\":525,\"deltas\":[[[{\"milk\":{\"m\":\"oat\"}}],80],[[{\"milk\":{\"m\":\"almond\"}}],80],[[{\"milk\":{\"m\":\"soy\"}}],60],[[{\"size\":{\"s\":\"large\"}}],100],[[{\"size\":{\"s\":\"small\"}}],-50],[[{\"temp\":{\"t\":\"iced\"}}],50],[[{\"shots\":{\"n\":\"triple\"}}],100]],\"overrides\":[[[{\"temp\":{\"t\":\"iced\"}},{\"size\":{\"s\":\"large\"}},{\"milk\":{\"m\":\"oat\"}}],725]]}","veganPossible":1},[{"decaf":1,"id":339,"milk":"oat","offer":3,"price":655,"shots":"double","size":"regular","temp":"iced"},{"city":"sanFrancisco","cuisine":"cafe","id":6,"lat":37777000,"lon":-122408600,"name":"Sightglass Coffee","neighborhood":"SoMa","priceTier":"mid"}]],[{"available":1,"baseKinds":[],"canonical":7,"id":4,"maxPrice":675,"minPrice":400,"restaurant":7,"rule":"{\"base\":450,\"deltas\":[[[{\"milk\":{\"m\":\"oat\"}}],50],[[{\"milk\":{\"m\":\"almond\"}}],50],[[{\"milk\":{\"m\":\"soy\"}}],50],[[{\"size\":{\"s\":\"large\"}}],75],[[{\"size\":{\"s\":\"small\"}}],-50],[[{\"temp\":{\"t\":\"iced\"}}],25],[[{\"shots\":{\"n\":\"triple\"}}],75]],\"overrides\":[]}","veganPossible":1},[{"decaf":0,"id":490,"milk":"oat","offer":4,"price":675,"shots":"triple","size":"large","temp":"iced"},{"city":"sanFrancisco","cuisine":"cafe","id":7,"lat":37761800,"lon":-122426000,"name":"Samovar Tea Lounge","neighborhood":"Mission","priceTier":"mid"}]],[{"available":1,"baseKinds":[],"canonical":7,"id":1,"maxPrice":825,"minPrice":450,"restaurant":5,"rule":"{\"base\":500,\"deltas\":[[[{\"milk\":{\"m\":\"oat\"}}],75],[[{\"milk\":{\"m\":\"almond\"}}],75],[[{\"milk\":{\"m\":\"soy\"}}],50],[[{\"size\":{\"s\":\"large\"}}],100],[[{\"size\":{\"s\":\"small\"}}],-50],[[{\"temp\":{\"t\":\"iced\"}}],50],[[{\"shots\":{\"n\":\"triple\"}}],100]],\"overrides\":[]}","veganPossible":1},[{"decaf":0,"id":90,"milk":"oat","offer":1,"price":725,"shots":"triple","size":"regular","temp":"iced"},{"city":"sanFrancisco","cuisine":"cafe","id":5,"lat":37776400,"lon":-122423300,"name":"Blue Bottle Hayes Valley","neighborhood":"Hayes Valley","priceTier":"mid"}]],[{"available":1,"baseKinds":[],"canonical":7,"id":1,"maxPrice":825,"minPrice":450,"restaurant":5,"rule":"{\"base\":500,\"deltas\":[[[{\"milk\":{\"m\":\"oat\"}}],75],[[{\"milk\":{\"m\":\"almond\"}}],75],[[{\"milk\":{\"m\":\"soy\"}}],50],[[{\"size\":{\"s\":\"large\"}}],100],[[{\"size\":{\"s\":\"small\"}}],-50],[[{\"temp\":{\"t\":\"iced\"}}],50],[[{\"shots\":{\"n\":\"triple\"}}],100]],\"overrides\":[]}","veganPossible":1},[{"decaf":0,"id":111,"milk":"oat","offer":1,"price":725,"shots":"single","size":"large","temp":"iced"},{"city":"sanFrancisco","cuisine":"cafe","id":5,"lat":37776400,"lon":-122423300,"name":"Blue Bottle Hayes Valley","neighborhood":"Hayes Valley","priceTier":"mid"}]],[{"available":1,"baseKinds":[],"canonical":7,"id":1,"maxPrice":825,"minPrice":450,"restaurant":5,"rule":"{\"base\":500,\"deltas\":[[[{\"milk\":{\"m\":\"oat\"}}],75],[[{\"milk\":{\"m\":\"almond\"}}],75],[[{\"milk\":{\"m\":\"soy\"}}],50],[[{\"size\":{\"s\":\"large\"}}],100],[[{\"size\":{\"s\":\"small\"}}],-50],[[{\"temp\":{\"t\":\"iced\"}}],50],[[{\"shots\":{\"n\":\"triple\"}}],100]],\"overrides\":[]}","veganPossible":1},[{"decaf":1,"id":112,"milk":"oat","offer":1,"price":725,"shots":"single","size":"large","temp":"iced"},{"city":"sanFrancisco","cuisine":"cafe","id":5,"lat":37776400,"lon":-122423300,"name":"Blue Bottle Hayes Valley","neighborhood":"Hayes Valley","priceTier":"mid"}]],[{"available":1,"baseKinds":[],"canonical":7,"id":1,"maxPrice":825,"minPrice":450,"restaurant":5,"rule":"{\"base\":500,\"deltas\":[[[{\"milk\":{\"m\":\"oat\"}}],75],[[{\"milk\":{\"m\":\"almond\"}}],75],[[{\"milk\":{\"m\":\"soy\"}}],50],[[{\"size\":{\"s\":\"large\"}}],100],[[{\"size\":{\"s\":\"small\"}}],-50],[[{\"temp\":{\"t\":\"iced\"}}],50],[[{\"shots\":{\"n\":\"triple\"}}],100]],\"overrides\":[]}","veganPossible":1},[{"decaf":0,"id":113,"milk":"oat","offer":1,"price":725,"shots":"double","size":"large","temp":"iced"},{"city":"sanFrancisco","cuisine":"cafe","id":5,"lat":37776400,"lon":-122423300,"name":"Blue Bottle Hayes Valley","neighborhood":"Hayes Valley","priceTier":"mid"}]],[{"available":1,"baseKinds":[],"canonical":7,"id":1,"maxPrice":825,"minPrice":450,"restaurant":5,"rule":"{\"base\":500,\"deltas\":[[[{\"milk\":{\"m\":\"oat\"}}],75],[[{\"milk\":{\"m\":\"almond\"}}],75],[[{\"milk\":{\"m\":\"soy\"}}],50],[[{\"size\":{\"s\":\"large\"}}],100],[[{\"size\":{\"s\":\"small\"}}],-50],[[{\"temp\":{\"t\":\"iced\"}}],50],[[{\"shots\":{\"n\":\"triple\"}}],100]],\"overrides\":[]}","veganPossible":1},[{"decaf":1,"id":114,"milk":"oat","offer":1,"price":725,"shots":"double","size":"large","temp":"iced"},{"city":"sanFrancisco","cuisine":"cafe","id":5,"lat":37776400,"lon":-122423300,"name":"Blue Bottle Hayes Valley","neighborhood":"Hayes Valley","priceTier":"mid"}]],[{"available":1,"baseKinds":["sugar"],"canonical":8,"id":2,"maxPrice":825,"minPrice":450,"restaurant":5,"rule":"{\"base\":500,\"deltas\":[[[{\"milk\":{\"m\":\"oat\"}}],75],[[{\"milk\":{\"m\":\"almond\"}}],75],[[{\"milk\":{\"m\":\"soy\"}}],50],[[{\"size\":{\"s\":\"large\"}}],100],[[{\"size\":{\"s\":\"small\"}}],-50],[[{\"temp\":{\"t\":\"iced\"}}],50],[[{\"shots\":{\"n\":\"triple\"}}],100]],\"overrides\":[]}","veganPossible":1},[{"decaf":0,"id":215,"milk":"oat","offer":2,"price":725,"shots":"triple","size":"regular","temp":"iced"},{"city":"sanFrancisco","cuisine":"cafe","id":5,"lat":37776400,"lon":-122423300,"name":"Blue Bottle Hayes Valley","neighborhood":"Hayes Valley","priceTier":"mid"}]],[{"available":1,"baseKinds":["sugar"],"canonical":8,"id":2,"maxPrice":825,"minPrice":450,"restaurant":5,"rule":"{\"base\":500,\"deltas\":[[[{\"milk\":{\"m\":\"oat\"}}],75],[[{\"milk\":{\"m\":\"almond\"}}],75],[[{\"milk\":{\"m\":\"soy\"}}],50],[[{\"size\":{\"s\":\"large\"}}],100],[[{\"size\":{\"s\":\"small\"}}],-50],[[{\"temp\":{\"t\":\"iced\"}}],50],[[{\"shots\":{\"n\":\"triple\"}}],100]],\"overrides\":[]}","veganPossible":1},[{"decaf":0,"id":236,"milk":"oat","offer":2,"price":725,"shots":"single","size":"large","temp":"iced"},{"city":"sanFrancisco","cuisine":"cafe","id":5,"lat":37776400,"lon":-122423300,"name":"Blue Bottle Hayes Valley","neighborhood":"Hayes Valley","priceTier":"mid"}]],[{"available":1,"baseKinds":["sugar"],"canonical":8,"id":2,"maxPrice":825,"minPrice":450,"restaurant":5,"rule":"{\"base\":500,\"deltas\":[[[{\"milk\":{\"m\":\"oat\"}}],75],[[{\"milk\":{\"m\":\"almond\"}}],75],[[{\"milk\":{\"m\":\"soy\"}}],50],[[{\"size\":{\"s\":\"large\"}}],100],[[{\"size\":{\"s\":\"small\"}}],-50],[[{\"temp\":{\"t\":\"iced\"}}],50],[[{\"shots\":{\"n\":\"triple\"}}],100]],\"overrides\":[]}","veganPossible":1},[{"decaf":1,"id":237,"milk":"oat","offer":2,"price":725,"shots":"single","size":"large","temp":"iced"},{"city":"sanFrancisco","cuisine":"cafe","id":5,"lat":37776400,"lon":-122423300,"name":"Blue Bottle Hayes Valley","neighborhood":"Hayes Valley","priceTier":"mid"}]],[{"available":1,"baseKinds":["sugar"],"canonical":8,"id":2,"maxPrice":825,"minPrice":450,"restaurant":5,"rule":"{\"base\":500,\"deltas\":[[[{\"milk\":{\"m\":\"oat\"}}],75],[[{\"milk\":{\"m\":\"almond\"}}],75],[[{\"milk\":{\"m\":\"soy\"}}],50],[[{\"size\":{\"s\":\"large\"}}],100],[[{\"size\":{\"s\":\"small\"}}],-50],[[{\"temp\":{\"t\":\"iced\"}}],50],[[{\"shots\":{\"n\":\"triple\"}}],100]],\"overrides\":[]}","veganPossible":1},[{"decaf":0,"id":238,"milk":"oat","offer":2,"price":725,"shots":"double","size":"large","temp":"iced"},{"city":"sanFrancisco","cuisine":"cafe","id":5,"lat":37776400,"lon":-122423300,"name":"Blue Bottle Hayes Valley","neighborhood":"Hayes Valley","priceTier":"mid"}]],[{"available":1,"baseKinds":["sugar"],"canonical":8,"id":2,"maxPrice":825,"minPrice":450,"restaurant":5,"rule":"{\"base\":500,\"deltas\":[[[{\"milk\":{\"m\":\"oat\"}}],75],[[{\"milk\":{\"m\":\"almond\"}}],75],[[{\"milk\":{\"m\":\"soy\"}}],50],[[{\"size\":{\"s\":\"large\"}}],100],[[{\"size\":{\"s\":\"small\"}}],-50],[[{\"temp\":{\"t\":\"iced\"}}],50],[[{\"shots\":{\"n\":\"triple\"}}],100]],\"overrides\":[]}","veganPossible":1},[{"decaf":1,"id":239,"milk":"oat","offer":2,"price":725,"shots":"double","size":"large","temp":"iced"},{"city":"sanFrancisco","cuisine":"cafe","id":5,"lat":37776400,"lon":-122423300,"name":"Blue Bottle Hayes Valley","neighborhood":"Hayes Valley","priceTier":"mid"}]],[{"available":1,"baseKinds":[],"canonical":7,"id":3,"maxPrice":855,"minPrice":475,"restaurant":6,"rule":"{\"base\":525,\"deltas\":[[[{\"milk\":{\"m\":\"oat\"}}],80],[[{\"milk\":{\"m\":\"almond\"}}],80],[[{\"milk\":{\"m\":\"soy\"}}],60],[[{\"size\":{\"s\":\"large\"}}],100],[[{\"size\":{\"s\":\"small\"}}],-50],[[{\"temp\":{\"t\":\"iced\"}}],50],[[{\"shots\":{\"n\":\"triple\"}}],100]],\"overrides\":[[[{\"temp\":{\"t\":\"iced\"}},{\"size\":{\"s\":\"large\"}},{\"milk\":{\"m\":\"oat\"}}],725]]}","veganPossible":1},[{"decaf":0,"id":361,"milk":"oat","offer":3,"price":725,"shots":"single","size":"large","temp":"iced"},{"city":"sanFrancisco","cuisine":"cafe","id":6,"lat":37777000,"lon":-122408600,"name":"Sightglass Coffee","neighborhood":"SoMa","priceTier":"mid"}]],[{"available":1,"baseKinds":[],"canonical":7,"id":3,"maxPrice":855,"minPrice":475,"restaurant":6,"rule":"{\"base\":525,\"deltas\":[[[{\"milk\":{\"m\":\"oat\"}}],80],[[{\"milk\":{\"m\":\"almond\"}}],80],[[{\"milk\":{\"m\":\"soy\"}}],60],[[{\"size\":{\"s\":\"large\"}}],100],[[{\"size\":{\"s\":\"small\"}}],-50],[[{\"temp\":{\"t\":\"iced\"}}],50],[[{\"shots\":{\"n\":\"triple\"}}],100]],\"overrides\":[[[{\"temp\":{\"t\":\"iced\"}},{\"size\":{\"s\":\"large\"}},{\"milk\":{\"m\":\"oat\"}}],725]]}","veganPossible":1},[{"decaf":1,"id":362,"milk":"oat","offer":3,"price":725,"shots":"single","size":"large","temp":"iced"},{"city":"sanFrancisco","cuisine":"cafe","id":6,"lat":37777000,"lon":-122408600,"name":"Sightglass Coffee","neighborhood":"SoMa","priceTier":"mid"}]],[{"available":1,"baseKinds":[],"canonical":7,"id":3,"maxPrice":855,"minPrice":475,"restaurant":6,"rule":"{\"base\":525,\"deltas\":[[[{\"milk\":{\"m\":\"oat\"}}],80],[[{\"milk\":{\"m\":\"almond\"}}],80],[[{\"milk\":{\"m\":\"soy\"}}],60],[[{\"size\":{\"s\":\"large\"}}],100],[[{\"size\":{\"s\":\"small\"}}],-50],[[{\"temp\":{\"t\":\"iced\"}}],50],[[{\"shots\":{\"n\":\"triple\"}}],100]],\"overrides\":[[[{\"temp\":{\"t\":\"iced\"}},{\"size\":{\"s\":\"large\"}},{\"milk\":{\"m\":\"oat\"}}],725]]}","veganPossible":1},[{"decaf":0,"id":363,"milk":"oat","offer":3,"price":725,"shots":"double","size":"large","temp":"iced"},{"city":"sanFrancisco","cuisine":"cafe","id":6,"lat":37777000,"lon":-122408600,"name":"Sightglass Coffee","neighborhood":"SoMa","priceTier":"mid"}]],[{"available":1,"baseKinds":[],"canonical":7,"id":3,"maxPrice":855,"minPrice":475,"restaurant":6,"rule":"{\"base\":525,\"deltas\":[[[{\"milk\":{\"m\":\"oat\"}}],80],[[{\"milk\":{\"m\":\"almond\"}}],80],[[{\"milk\":{\"m\":\"soy\"}}],60],[[{\"size\":{\"s\":\"large\"}}],100],[[{\"size\":{\"s\":\"small\"}}],-50],[[{\"temp\":{\"t\":\"iced\"}}],50],[[{\"shots\":{\"n\":\"triple\"}}],100]],\"overrides\":[[[{\"temp\":{\"t\":\"iced\"}},{\"size\":{\"s\":\"large\"}},{\"milk\":{\"m\":\"oat\"}}],725]]}","veganPossible":1},[{"decaf":1,"id":364,"milk":"oat","offer":3,"price":725,"shots":"double","size":"large","temp":"iced"},{"city":"sanFrancisco","cuisine":"cafe","id":6,"lat":37777000,"lon":-122408600,"name":"Sightglass Coffee","neighborhood":"SoMa","priceTier":"mid"}]],[{"available":1,"baseKinds":[],"canonical":7,"id":3,"maxPrice":855,"minPrice":475,"restaurant":6,"rule":"{\"base\":525,\"deltas\":[[[{\"milk\":{\"m\":\"oat\"}}],80],[[{\"milk\":{\"m\":\"almond\"}}],80],[[{\"milk\":{\"m\":\"soy\"}}],60],[[{\"size\":{\"s\":\"large\"}}],100],[[{\"size\":{\"s\":\"small\"}}],-50],[[{\"temp\":{\"t\":\"iced\"}}],50],[[{\"shots\":{\"n\":\"triple\"}}],100]],\"overrides\":[[[{\"temp\":{\"t\":\"iced\"}},{\"size\":{\"s\":\"large\"}},{\"milk\":{\"m\":\"oat\"}}],725]]}","veganPossible":1},[{"decaf":0,"id":365,"milk":"oat","offer":3,"price":725,"shots":"triple","size":"large","temp":"iced"},{"city":"sanFrancisco","cuisine":"cafe","id":6,"lat":37777000,"lon":-122408600,"name":"Sightglass Coffee","neighborhood":"SoMa","priceTier":"mid"}]],[{"available":1,"baseKinds":[],"canonical":7,"id":3,"maxPrice":855,"minPrice":475,"restaurant":6,"rule":"{\"base\":525,\"deltas\":[[[{\"milk\":{\"m\":\"oat\"}}],80],[[{\"milk\":{\"m\":\"almond\"}}],80],[[{\"milk\":{\"m\":\"soy\"}}],60],[[{\"size\":{\"s\":\"large\"}}],100],[[{\"size\":{\"s\":\"small\"}}],-50],[[{\"temp\":{\"t\":\"iced\"}}],50],[[{\"shots\":{\"n\":\"triple\"}}],100]],\"overrides\":[[[{\"temp\":{\"t\":\"iced\"}},{\"size\":{\"s\":\"large\"}},{\"milk\":{\"m\":\"oat\"}}],725]]}","veganPossible":1},[{"decaf":0,"id":340,"milk":"oat","offer":3,"price":755,"shots":"triple","size":"regular","temp":"iced"},{"city":"sanFrancisco","cuisine":"cafe","id":6,"lat":37777000,"lon":-122408600,"name":"Sightglass Coffee","neighborhood":"SoMa","priceTier":"mid"}]],[{"available":1,"baseKinds":[],"canonical":7,"id":1,"maxPrice":825,"minPrice":450,"restaurant":5,"rule":"{\"base\":500,\"deltas\":[[[{\"milk\":{\"m\":\"oat\"}}],75],[[{\"milk\":{\"m\":\"almond\"}}],75],[[{\"milk\":{\"m\":\"soy\"}}],50],[[{\"size\":{\"s\":\"large\"}}],100],[[{\"size\":{\"s\":\"small\"}}],-50],[[{\"temp\":{\"t\":\"iced\"}}],50],[[{\"shots\":{\"n\":\"triple\"}}],100]],\"overrides\":[]}","veganPossible":1},[{"decaf":0,"id":115,"milk":"oat","offer":1,"price":825,"shots":"triple","size":"large","temp":"iced"},{"city":"sanFrancisco","cuisine":"cafe","id":5,"lat":37776400,"lon":-122423300,"name":"Blue Bottle Hayes Valley","neighborhood":"Hayes Valley","priceTier":"mid"}]],[{"available":1,"baseKinds":["sugar"],"canonical":8,"id":2,"maxPrice":825,"minPrice":450,"restaurant":5,"rule":"{\"base\":500,\"deltas\":[[[{\"milk\":{\"m\":\"oat\"}}],75],[[{\"milk\":{\"m\":\"almond\"}}],75],[[{\"milk\":{\"m\":\"soy\"}}],50],[[{\"size\":{\"s\":\"large\"}}],100],[[{\"size\":{\"s\":\"small\"}}],-50],[[{\"temp\":{\"t\":\"iced\"}}],50],[[{\"shots\":{\"n\":\"triple\"}}],100]],\"overrides\":[]}","veganPossible":1},[{"decaf":0,"id":240,"milk":"oat","offer":2,"price":825,"shots":"triple","size":"large","temp":"iced"},{"city":"sanFrancisco","cuisine":"cafe","id":5,"lat":37776400,"lon":-122423300,"name":"Blue Bottle Hayes Valley","neighborhood":"Hayes Valley","priceTier":"mid"}]]]}
(exit 0)
```

## query log — cheapestConfigured is one three-table select at residual 0 (five config columns pushed as IS ?); cheapestMatching pushes the joins, `available` and the city, and keeps `Pattern.matches` residual (1): a runtime list has no closed world to split on

```console
$ eats log 2
{"count":2,"entries":[{"at":1788327828,"detail":"espresso_offer×offer_price×restaurant | pushed: (((t1.\"offer\" IS t0.\"id\" AND t0.\"restaurant\" IS t2.\"id\") AND t0.\"available\" IS ?) AND t2.\"city\" IS ?), residual conjuncts: 1","error":null,"id":955,"ok":true,"rows":40,"verb":"select"},{"at":1788327828,"detail":"espresso_offer×offer_price×restaurant | pushed: ((((((((t1.\"offer\" IS t0.\"id\" AND t0.\"restaurant\" IS t2.\"id\") AND t0.\"available\" IS ?) AND t2.\"city\" IS ?) AND t1.\"temp\" IS ?) AND t1.\"size\" IS ?) AND t1.\"milk\" IS ?) AND t1.\"shots\" IS ?) AND t1.\"decaf\" IS ?), residual conjuncts: 0","error":null,"id":954,"ok":true,"rows":4,"verb":"select"}],"ok":true}
(exit 0)
```

## a pattern fixing milk to a size is refused at the CLI boundary with the world named (exit 2)

```console
$ eats query cheapestMatching milk=large sanFrancisco
{"code":"decode","message":"cli.p: milk: \"large\" is not one of #[whole, skim, oat, almond, soy]","ok":false}
(exit 2)
```

## who offers oat milk in SF — a join on the tabulation with milk IS ?, deduplicated to offers

```console
$ eats query offersWith oat sanFrancisco
{"ok":true,"result":[[{"available":1,"baseKinds":[],"canonical":7,"id":1,"maxPrice":825,"minPrice":450,"restaurant":5,"rule":"{\"base\":500,\"deltas\":[[[{\"milk\":{\"m\":\"oat\"}}],75],[[{\"milk\":{\"m\":\"almond\"}}],75],[[{\"milk\":{\"m\":\"soy\"}}],50],[[{\"size\":{\"s\":\"large\"}}],100],[[{\"size\":{\"s\":\"small\"}}],-50],[[{\"temp\":{\"t\":\"iced\"}}],50],[[{\"shots\":{\"n\":\"triple\"}}],100]],\"overrides\":[]}","veganPossible":1},{"city":"sanFrancisco","cuisine":"cafe","id":5,"lat":37776400,"lon":-122423300,"name":"Blue Bottle Hayes Valley","neighborhood":"Hayes Valley","priceTier":"mid"}],[{"available":1,"baseKinds":["sugar"],"canonical":8,"id":2,"maxPrice":825,"minPrice":450,"restaurant":5,"rule":"{\"base\":500,\"deltas\":[[[{\"milk\":{\"m\":\"oat\"}}],75],[[{\"milk\":{\"m\":\"almond\"}}],75],[[{\"milk\":{\"m\":\"soy\"}}],50],[[{\"size\":{\"s\":\"large\"}}],100],[[{\"size\":{\"s\":\"small\"}}],-50],[[{\"temp\":{\"t\":\"iced\"}}],50],[[{\"shots\":{\"n\":\"triple\"}}],100]],\"overrides\":[]}","veganPossible":1},{"city":"sanFrancisco","cuisine":"cafe","id":5,"lat":37776400,"lon":-122423300,"name":"Blue Bottle Hayes Valley","neighborhood":"Hayes Valley","priceTier":"mid"}],[{"available":1,"baseKinds":[],"canonical":7,"id":4,"maxPrice":675,"minPrice":400,"restaurant":7,"rule":"{\"base\":450,\"deltas\":[[[{\"milk\":{\"m\":\"oat\"}}],50],[[{\"milk\":{\"m\":\"almond\"}}],50],[[{\"milk\":{\"m\":\"soy\"}}],50],[[{\"size\":{\"s\":\"large\"}}],75],[[{\"size\":{\"s\":\"small\"}}],-50],[[{\"temp\":{\"t\":\"iced\"}}],25],[[{\"shots\":{\"n\":\"triple\"}}],75]],\"overrides\":[]}","veganPossible":1},{"city":"sanFrancisco","cuisine":"cafe","id":7,"lat":37761800,"lon":-122426000,"name":"Samovar Tea Lounge","neighborhood":"Mission","priceTier":"mid"}],[{"available":1,"baseKinds":[],"canonical":7,"id":3,"maxPrice":855,"minPrice":475,"restaurant":6,"rule":"{\"base\":525,\"deltas\":[[[{\"milk\":{\"m\":\"oat\"}}],80],[[{\"milk\":{\"m\":\"almond\"}}],80],[[{\"milk\":{\"m\":\"soy\"}}],60],[[{\"size\":{\"s\":\"large\"}}],100],[[{\"size\":{\"s\":\"small\"}}],-50],[[{\"temp\":{\"t\":\"iced\"}}],50],[[{\"shots\":{\"n\":\"triple\"}}],100]],\"overrides\":[[[{\"temp\":{\"t\":\"iced\"}},{\"size\":{\"s\":\"large\"}},{\"milk\":{\"m\":\"oat\"}}],725]]}","veganPossible":1},{"city":"sanFrancisco","cuisine":"cafe","id":6,"lat":37777000,"lon":-122408600,"name":"Sightglass Coffee","neighborhood":"SoMa","priceTier":"mid"}]]}
(exit 0)
```

## oat in Oakland — Highwire's tabulation omits every oat configuration (availability is absence in stage 1)

```console
$ eats query offersWith oat oakland
{"ok":true,"result":[]}
(exit 0)
```

## offers whose base holds no sugar, in SF — membership in the `EnumSet` column (LEP-0003 A): `!(o.val.baseKinds.contains k)` pushes as a bit test against `= 0`, residual 0; Blue Bottle's cappuccino (cocoa dusting) is the one left out

```console
$ eats query offersFreeOf sugar sanFrancisco
{"ok":true,"result":[[{"available":1,"baseKinds":[],"canonical":7,"id":1,"maxPrice":825,"minPrice":450,"restaurant":5,"rule":"{\"base\":500,\"deltas\":[[[{\"milk\":{\"m\":\"oat\"}}],75],[[{\"milk\":{\"m\":\"almond\"}}],75],[[{\"milk\":{\"m\":\"soy\"}}],50],[[{\"size\":{\"s\":\"large\"}}],100],[[{\"size\":{\"s\":\"small\"}}],-50],[[{\"temp\":{\"t\":\"iced\"}}],50],[[{\"shots\":{\"n\":\"triple\"}}],100]],\"overrides\":[]}","veganPossible":1},{"city":"sanFrancisco","cuisine":"cafe","id":5,"lat":37776400,"lon":-122423300,"name":"Blue Bottle Hayes Valley","neighborhood":"Hayes Valley","priceTier":"mid"}],[{"available":1,"baseKinds":[],"canonical":7,"id":3,"maxPrice":855,"minPrice":475,"restaurant":6,"rule":"{\"base\":525,\"deltas\":[[[{\"milk\":{\"m\":\"oat\"}}],80],[[{\"milk\":{\"m\":\"almond\"}}],80],[[{\"milk\":{\"m\":\"soy\"}}],60],[[{\"size\":{\"s\":\"large\"}}],100],[[{\"size\":{\"s\":\"small\"}}],-50],[[{\"temp\":{\"t\":\"iced\"}}],50],[[{\"shots\":{\"n\":\"triple\"}}],100]],\"overrides\":[[[{\"temp\":{\"t\":\"iced\"}},{\"size\":{\"s\":\"large\"}},{\"milk\":{\"m\":\"oat\"}}],725]]}","veganPossible":1},{"city":"sanFrancisco","cuisine":"cafe","id":6,"lat":37777000,"lon":-122408600,"name":"Sightglass Coffee","neighborhood":"SoMa","priceTier":"mid"}],[{"available":1,"baseKinds":[],"canonical":7,"id":4,"maxPrice":675,"minPrice":400,"restaurant":7,"rule":"{\"base\":450,\"deltas\":[[[{\"milk\":{\"m\":\"oat\"}}],50],[[{\"milk\":{\"m\":\"almond\"}}],50],[[{\"milk\":{\"m\":\"soy\"}}],50],[[{\"size\":{\"s\":\"large\"}}],75],[[{\"size\":{\"s\":\"small\"}}],-50],[[{\"temp\":{\"t\":\"iced\"}}],25],[[{\"shots\":{\"n\":\"triple\"}}],75]],\"overrides\":[]}","veganPossible":1},{"city":"sanFrancisco","cuisine":"cafe","id":7,"lat":37761800,"lon":-122426000,"name":"Samovar Tea Lounge","neighborhood":"Mission","priceTier":"mid"}]]}
(exit 0)
$ eats log 1
{"count":1,"entries":[{"at":1788327828,"detail":"espresso_offer×restaurant | pushed: (((t0.\"restaurant\" IS t1.\"id\" AND t0.\"available\" IS ?) AND t1.\"city\" IS ?) AND ((t0.\"baseKinds\" & ?) = 0)), residual conjuncts: 0","error":null,"id":958,"ok":true,"rows":3,"verb":"select"}],"ok":true}
(exit 0)
```

## every vegan configuration of Blue Bottle's latte (offer 1), priced by the rule — 75 of 125: oat, almond and soy only, never whole or skim

```console
$ eats query configurationsFor 1 vegan
{"ok":true,"result":[[{"decaf":false,"milk":"oat","shots":"single","size":"small","temp":"hot"},525],[{"decaf":true,"milk":"oat","shots":"single","size":"small","temp":"hot"},525],[{"decaf":false,"milk":"oat","shots":"double","size":"small","temp":"hot"},525],[{"decaf":true,"milk":"oat","shots":"double","size":"small","temp":"hot"},525],[{"decaf":false,"milk":"oat","shots":"triple","size":"small","temp":"hot"},625],[{"decaf":false,"milk":"almond","shots":"single","size":"small","temp":"hot"},525],[{"decaf":true,"milk":"almond","shots":"single","size":"small","temp":"hot"},525],[{"decaf":false,"milk":"almond","shots":"double","size":"small","temp":"hot"},525],[{"decaf":true,"milk":"almond","shots":"double","size":"small","temp":"hot"},525],[{"decaf":false,"milk":"almond","shots":"triple","size":"small","temp":"hot"},625],[{"decaf":false,"milk":"soy","shots":"single","size":"small","temp":"hot"},500],[{"decaf":true,"milk":"soy","shots":"single","size":"small","temp":"hot"},500],[{"decaf":false,"milk":"soy","shots":"double","size":"small","temp":"hot"},500],[{"decaf":true,"milk":"soy","shots":"double","size":"small","temp":"hot"},500],[{"decaf":false,"milk":"soy","shots":"triple","size":"small","temp":"hot"},600],[{"decaf":false,"milk":"oat","shots":"single","size":"regular","temp":"hot"},575],[{"decaf":true,"milk":"oat","shots":"single","size":"regular","temp":"hot"},575],[{"decaf":false,"milk":"oat","shots":"double","size":"regular","temp":"hot"},575],[{"decaf":true,"milk":"oat","shots":"double","size":"regular","temp":"hot"},575],[{"decaf":false,"milk":"oat","shots":"triple","size":"regular","temp":"hot"},675],[{"decaf":false,"milk":"almond","shots":"single","size":"regular","temp":"hot"},575],[{"decaf":true,"milk":"almond","shots":"single","size":"regular","temp":"hot"},575],[{"decaf":false,"milk":"almond","shots":"double","size":"regular","temp":"hot"},575],[{"decaf":true,"milk":"almond","shots":"double","size":"regular","temp":"hot"},575],[{"decaf":false,"milk":"almond","shots":"triple","size":"regular","temp":"hot"},675],[{"decaf":false,"milk":"soy","shots":"single","size":"regular","temp":"hot"},550],[{"decaf":true,"milk":"soy","shots":"single","size":"regular","temp":"hot"},550],[{"decaf":false,"milk":"soy","shots":"double","size":"regular","temp":"hot"},550],[{"decaf":true,"milk":"soy","shots":"double","size":"regular","temp":"hot"},550],[{"decaf":false,"milk":"soy","shots":"triple","size":"regular","temp":"hot"},650],[{"decaf":false,"milk":"oat","shots":"single","size":"large","temp":"hot"},675],[{"decaf":true,"milk":"oat","shots":"single","size":"large","temp":"hot"},675],[{"decaf":false,"milk":"oat","shots":"double","size":"large","temp":"hot"},675],[{"decaf":true,"milk":"oat","shots":"double","size":"large","temp":"hot"},675],[{"decaf":false,"milk":"oat","shots":"triple","size":"large","temp":"hot"},775],[{"decaf":false,"milk":"almond","shots":"single","size":"large","temp":"hot"},675],[{"decaf":true,"milk":"almond","shots":"single","size":"large","temp":"hot"},675],[{"decaf":false,"milk":"almond","shots":"double","size":"large","temp":"hot"},675],[{"decaf":true,"milk":"almond","shots":"double","size":"large","temp":"hot"},675],[{"decaf":false,"milk":"almond","shots":"triple","size":"large","temp":"hot"},775],[{"decaf":false,"milk":"soy","shots":"single","size":"large","temp":"hot"},650],[{"decaf":true,"milk":"soy","shots":"single","size":"large","temp":"hot"},650],[{"decaf":false,"milk":"soy","shots":"double","size":"large","temp":"hot"},650],[{"decaf":true,"milk":"soy","shots":"double","size":"large","temp":"hot"},650],[{"decaf":false,"milk":"soy","shots":"triple","size":"large","temp":"hot"},750],[{"decaf":false,"milk":"oat","shots":"single","size":"regular","temp":"iced"},625],[{"decaf":true,"milk":"oat","shots":"single","size":"regular","temp":"iced"},625],[{"decaf":false,"milk":"oat","shots":"double","size":"regular","temp":"iced"},625],[{"decaf":true,"milk":"oat","shots":"double","size":"regular","temp":"iced"},625],[{"decaf":false,"milk":"oat","shots":"triple","size":"regular","temp":"iced"},725],[{"decaf":false,"milk":"almond","shots":"single","size":"regular","temp":"iced"},625],[{"decaf":true,"milk":"almond","shots":"single","size":"regular","temp":"iced"},625],[{"decaf":false,"milk":"almond","shots":"double","size":"regular","temp":"iced"},625],[{"decaf":true,"milk":"almond","shots":"double","size":"regular","temp":"iced"},625],[{"decaf":false,"milk":"almond","shots":"triple","size":"regular","temp":"iced"},725],[{"decaf":false,"milk":"soy","shots":"single","size":"regular","temp":"iced"},600],[{"decaf":true,"milk":"soy","shots":"single","size":"regular","temp":"iced"},600],[{"decaf":false,"milk":"soy","shots":"double","size":"regular","temp":"iced"},600],[{"decaf":true,"milk":"soy","shots":"double","size":"regular","temp":"iced"},600],[{"decaf":false,"milk":"soy","shots":"triple","size":"regular","temp":"iced"},700],[{"decaf":false,"milk":"oat","shots":"single","size":"large","temp":"iced"},725],[{"decaf":true,"milk":"oat","shots":"single","size":"large","temp":"iced"},725],[{"decaf":false,"milk":"oat","shots":"double","size":"large","temp":"iced"},725],[{"decaf":true,"milk":"oat","shots":"double","size":"large","temp":"iced"},725],[{"decaf":false,"milk":"oat","shots":"triple","size":"large","temp":"iced"},825],[{"decaf":false,"milk":"almond","shots":"single","size":"large","temp":"iced"},725],[{"decaf":true,"milk":"almond","shots":"single","size":"large","temp":"iced"},725],[{"decaf":false,"milk":"almond","shots":"double","size":"large","temp":"iced"},725],[{"decaf":true,"milk":"almond","shots":"double","size":"large","temp":"iced"},725],[{"decaf":false,"milk":"almond","shots":"triple","size":"large","temp":"iced"},825],[{"decaf":false,"milk":"soy","shots":"single","size":"large","temp":"iced"},700],[{"decaf":true,"milk":"soy","shots":"single","size":"large","temp":"iced"},700],[{"decaf":false,"milk":"soy","shots":"double","size":"large","temp":"iced"},700],[{"decaf":true,"milk":"soy","shots":"double","size":"large","temp":"iced"},700],[{"decaf":false,"milk":"soy","shots":"triple","size":"large","temp":"iced"},800]]}
(exit 0)
```

## quote a sold configuration — the tabulated price

```console
$ eats query quote 4 iced/large/oat/double/regular
{"ok":true,"result":600}
(exit 0)
```

## quote a configuration the café does not sell — oat at Highwire (exit 2)

```console
$ eats query quote 5 iced/large/oat/double/regular
{"code":"decode","message":"offer_price.config: offer 5 does not sell iced/large/oat/double/regular: this café does not sell that configuration","ok":false}
(exit 2)
```

## quote a configuration nobody sells — small iced (exit 2)

```console
$ eats query quote 1 iced/small/whole/double/regular
{"code":"decode","message":"offer_price.config: offer 1 does not sell iced/small/whole/double/regular: this café does not sell that configuration","ok":false}
(exit 2)
```

## placeOrder refused: the offer does not sell that configuration, and nothing is inserted (exit 2)

```console
$ eats query placeOrder 5 hot/regular/oat/double/regular 1756684800
{"code":"decode","message":"offer_price.config: offer 5 does not sell hot/regular/oat/double/regular: this café does not sell that configuration","ok":false}
(exit 2)
```

## placeOrder accepted: the order line with the quoted price as its snapshot

```console
$ eats query placeOrder 4 iced/large/oat/double/regular 1756684800
{"ok":true,"result":{"decaf":0,"id":1,"milk":"oat","offer":4,"placedAt":1756684800,"quoted":600,"shots":"double","size":"large","temp":"iced"}}
(exit 0)
```

## typed row filter over the tabulation

```console
$ eats rows offer_price --eq milk=oat --limit 3
{"count":3,"ok":true,"rows":[{"decaf":0,"id":11,"milk":"oat","offer":1,"price":525,"shots":"single","size":"small","temp":"hot"},{"decaf":1,"id":12,"milk":"oat","offer":1,"price":525,"shots":"single","size":"small","temp":"hot"},{"decaf":0,"id":13,"milk":"oat","offer":1,"price":525,"shots":"double","size":"small","temp":"hot"}]}
(exit 0)
```

