import Shop

/-! Tests for the shop base: seed through smart constructors, assert on
each query, exercise CAS + `.stale`, FK `.restricted`, and check that the
type system rejects wrong-world programs (`#check_failure`). -/

open LeanDb Shop

private def check (condition : Bool) (message : String) : IO Unit :=
  unless condition do throw <| IO.userError s!"FAIL: {message}"

private def checkD (condition : Bool) (message : String) : DbM Unit :=
  unless condition do throw (.sqlite s!"FAIL: {message}")

private def expectOk (r : Except DbError α) (context : String) : IO α :=
  match r with
  | .ok a => pure a
  | .error e => throw <| IO.userError s!"FAIL: {context}: {e}"

private def expectErr (r : Except DbError α) (code : String) (context : String) : IO Unit :=
  match r with
  | .ok _ => throw <| IO.userError s!"FAIL: {context}: expected [{code}], got success"
  | .error e =>
      unless e.code == code do
        throw <| IO.userError s!"FAIL: {context}: expected [{code}], got {e}"

private def dbPath : System.FilePath := ".lake" / "shop_test.sqlite"

/-! ## Negative compile checks -/

-- Closed worlds are not entities: an OrderStatus has no table to insert into.
#check_failure insert OrderStatus OrderStatus.cart

-- A predicate over the wrong table does not typecheck: `select [Customer]`
-- forces `Stored Customer → Bool`.
#check_failure select [Customer] (fun (p : Stored Product) => p.val.stock == 0)

/-! ## Runtime tests -/

private def runQueries : DbM (Stored Customer × Stored Product) := do
  seed
  -- fetchAll: everything landed
  checkD ((← fetchAll Customer).size == 3) "three customers seeded"
  checkD ((← fetchAll Product).size == 6) "six products seeded"
  checkD ((← fetchAll Purchase).size == 5) "five purchases seeded"
  checkD ((← fetchAll LineItem).size == 10) "ten line items seeded"
  let some priya := (← fetchAll Customer).find? (fun c => c.val.name.raw == "Priya Sharma")
    | throw (.sqlite "FAIL: seeded customer priya not found")
  -- activeOrders: placed + shipped only, oldest first
  let active ← activeOrders
  checkD (active.map (·.val.status) == #[OrderStatus.placed, OrderStatus.shipped])
    "activeOrders: placed then shipped, oldest first"
  checkD (active.all (·.val.status.isActive)) "activeOrders all active"
  -- lowStock 5: three products, emptiest shelf first
  let low ← lowStock 5
  checkD (low.map (fun p => (p.val.name.raw, p.val.stock)) == #[
    ("Wooden Train Set", 0), ("Olive Oil 1L", 2), ("Mechanical Keyboard", 3)])
    "lowStock 5 contents + order"
  checkD ((← lowStock 1).map (·.val.name.raw) == #["Wooden Train Set"]) "lowStock 1"
  -- basketOf: the delivered purchase, join LineItem × Product by name
  let some delivered := (← select [Purchase]
      (fun o => o.val.status == OrderStatus.delivered))[0]?
    | throw (.sqlite "FAIL: delivered purchase not found")
  let basket ← basketOf delivered.ref
  checkD (basket.map (fun (li, p) => (p.val.name.raw, li.val.qty.count.toNat)) == #[
    ("Merino Hoodie", 1), ("Olive Oil 1L", 2), ("Wooden Train Set", 1)])
    "basketOf delivered: join contents, alphabetical"
  checkD (basket.all (fun (li, p) => li.val.unitPrice == p.val.price))
    "basket unit prices captured from products"
  -- revenueRows: only the delivered purchase's items; total is fixed by seed
  let revenue ← revenueRows
  checkD (revenue.size == 3) "three revenue rows"
  checkD (revenue.all (fun (o, _) => o.id == delivered.id)) "revenue rows all delivered"
  checkD (revenueCents revenue == 13297) s!"revenue 13297, got {revenueCents revenue}"
  -- CAS update: sell one keyboard
  let some keyboard := (← select [Product]
      (fun p => p.val.sku.raw == "ELEC-KB-77"))[0]?
    | throw (.sqlite "FAIL: keyboard not found")
  let keyboard' ← update keyboard { keyboard.val with stock := keyboard.val.stock - 1 }
  checkD (keyboard'.val.stock == 2) "CAS update applies"
  checkD ((← lowStock 3).map (·.val.stock) == #[0, 2, 2]) "keyboard joined the low shelf"
  -- return a referenced customer and the pre-update (now stale) snapshot
  return (priya, keyboard)

def main : IO UInt32 := do
  if ← dbPath.pathExists then IO.FS.removeFile dbPath
  let (priya, staleKeyboard) ← expectOk (← withDb dbPath schema runQueries) "seed + queries"
  -- the snapshot from before the CAS update no longer matches the row
  expectErr (← withDb dbPath schema do
      discard <| update staleKeyboard { staleKeyboard.val with stock := 99 })
    "stale" "CAS with stale snapshot"
  -- priya owns purchases: delete must refuse loudly
  expectErr (← withDb dbPath schema do delete priya.id)
    "restricted" "delete referenced customer"
  -- data persisted across reopens
  let active ← expectOk (← withDb dbPath schema activeOrders) "reopen"
  check (active.size == 2) "active orders persist across reopen"
  IO.println "shop base: all tests passed"
  return 0
