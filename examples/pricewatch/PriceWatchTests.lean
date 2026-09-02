import PriceWatch

/-! pricewatch tests. The base ships EMPTY (scraper + normalizer come
separately); tests build a throwaway instance in .lake/ through the typed
API — the same door the normalizer will use. -/

open LeanDb PriceWatch

private def check (condition : Bool) (message : String) : IO Unit :=
  unless condition do throw <| IO.userError s!"FAIL: {message}"

-- Closed worlds are not insertable or deletable.
#check_failure insert Store Store.amazon
#check_failure LeanDb.delete (α := Category) ⟨1⟩
-- A predicate over the wrong table does not typecheck.
#check_failure select [Product] (fun (l : Stored Listing) => l.val.availability.buyable)

private def dbPath : System.FilePath := ".lake" / "pricewatch_test.sqlite"

private def expectOk (r : Except DbError α) (context : String) : IO α :=
  match r with
  | .ok a => pure a
  | .error e => throw <| IO.userError s!"FAIL: {context}: {e}"

private def money (m : Nat) : DbM Money := DbM.ofExcept
  ((Money.make m).mapError (.decode "test" "money" ·))

private def listing (p : Ref Product) (s : Store) (priceMinor : Nat)
    (ratingTenths : Option Nat := none) (days : Option Nat := none)
    (avail : Availability := .inStock) (mrp : Option Nat := none) : DbM Unit := do
  let price ← money priceMinor
  let mrp ← mrp.mapM money
  let rating ← ratingTenths.mapM fun t =>
    DbM.ofExcept ((Rating.make t).mapError (.decode "test" "rating" ·))
  match Url.make s!"https://{(Store.displayName s).toLower}.example/x" with
  | .error e => throw (.decode "test" "url" e)
  | .ok url =>
      discard <| insert Listing
        ⟨p, s, url, price, mrp, .inr, rating, rating.map (fun _ => 1200), avail, days, ⟨1756000000⟩⟩

private def product (name : String) (b : String) (c : Category) : DbM (Stored Product) := do
  match ProductName.make name, Brand.make b with
  | .ok n, .ok br => insert Product ⟨n, br, c⟩
  | .error e, _ | _, .error e => throw (.decode "test" "product" e)

private def testChoose : IO Unit := do
  -- pure tradeoff layer over constructed rows is exercised e2e below;
  -- here: dominance basics on a toy type
  let objs : List (Objective (Nat × Nat)) :=
    [⟨.minimize, (·.1)⟩, ⟨.maximize, (·.2)⟩]
  let rows : Array (Nat × Nat) := #[(1, 4), (2, 7), (3, 8), (4, 7)]
  let front := paretoFront objs rows
  check (front == #[(1, 4), (2, 7), (3, 8)]) s!"pareto front, got {front}"
  check (knee? objs rows == some (2, 7)) s!"knee is the balanced row, got {knee? objs rows}"

private def testEndToEnd : IO Unit := do
  if ← dbPath.pathExists then IO.FS.removeFile dbPath
  let r ← withDb dbPath schema do
    let tv ← product "55-inch QLED TV" "Samsung" .electronics
    let phone ← product "Pixel 9" "Google" .electronics
    let soap ← product "Bath Soap 4x" "Dove" .beauty
    -- TV across stores: cheap/slow/unrated vs pricier/fast/loved vs out of stock
    listing tv.ref .flipkart 4299900 (ratingTenths := some 41) (days := some 6)
    listing tv.ref .amazon 4459900 (ratingTenths := some 46) (days := some 2) (mrp := some 5499900)
    listing tv.ref .croma 4199900 (avail := .outOfStock)
    listing phone.ref .amazon 7499900 (ratingTenths := some 45) (days := some 1)
    listing soap.ref .amazon 24900 (ratingTenths := some 44) (days := some 2)
    -- find: budget excludes the phone; out-of-stock excluded by buyable
    let cheap ← find .electronics 4500000 .sorted
    let names := cheap.map fun (p, l) => (p.val.brand.raw, l.val.store)
    -- pareto: flipkart (cheaper) and amazon (better rated, faster) both survive
    let front ← find .electronics 4500000 .pareto
    -- knee: one balanced answer
    let one ← find .electronics 4500000 .knee
    -- compare is per-product, includes out-of-stock rows
    let cmp ← PriceWatch.compare tv.id
    let best ← cheapest tv.id
    let rated ← wellRated .electronics 5000000 44 .sorted
    let fast ← fastDelivery .electronics 3
    let off20 ← deals 15
    return (names, front.size, one.size, cmp.size, best.map (fun (_, l) => l.val.store),
      rated.size, fast.size, off20.size)
  let (names, front, one, cmp, best, rated, fast, off) ← expectOk r "e2e"
  check (names == #[("Samsung", .flipkart), ("Samsung", .amazon)])
    s!"find: budget + buyable + price order, got {repr names}"
  check (front == 2) s!"pareto keeps both tradeoff points, got {front}"
  check (one == 1) "knee returns exactly one"
  check (cmp == 3) s!"compare shows every store incl. out-of-stock, got {cmp}"
  check (best == some .flipkart) s!"cheapest buyable is flipkart, got {repr best}"
  check (rated == 1) s!"min-rating 4.4 leaves only amazon TV, got {rated}"
  check (fast == 2) s!"≤3-day delivery: amazon TV + phone, got {fast}"
  check (off == 1) s!"only the amazon TV is ≥15% off list, got {off}"

def main : IO UInt32 := do
  -- The base value's derived schema is the hand-written one, table for
  -- table: `Base.specs` (dedup + dependency order) must not reorder a
  -- list that is already in dependency order, or the fingerprint moves.
  unless base.specs == schema do
    throw <| IO.userError "FAIL: Base.specs must equal the hand-written schema"
  testChoose
  testEndToEnd
  IO.println "pricewatch base: all tests passed"
  return 0
