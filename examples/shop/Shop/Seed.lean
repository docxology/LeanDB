import Shop.Queries

/-! # Seed data

All values pass through the smart constructors. `seedM` lifts an
`Except String` validation into `DbM` as a typed `.decode` error, so seed
stays total — no `panic!`, no `Option.get!`.
-/

namespace Shop

open LeanDb

/-- Lift a smart-constructor result into `DbM`. -/
def seedM (context : String) (r : Except String α) : DbM α :=
  match r with
  | .ok a => pure a
  | .error msg => throw (.decode "seed" context msg)

/-- The fixed "now" the seed data is laid out around. -/
def seedNow : Timestamp := ⟨1700000000⟩

/-- `h` hours before `seedNow`. -/
def hoursAgo (h : Nat) : Timestamp := ⟨seedNow.epochSeconds - h * 3600⟩

private def customer! (name email : String) : DbM (Stored Customer) := do
  insert Customer {
    name := ← seedM s!"customer name {name}" (CustomerName.make name)
    email := ← seedM s!"email {email}" (Email.make email) }

private def product! (name sku : String) (category : Category)
    (priceCents stock : Nat) : DbM (Stored Product) := do
  insert Product {
    name := ← seedM s!"product name {name}" (ProductName.make name)
    sku := ← seedM s!"sku {sku}" (Sku.make sku)
    category
    price := ← seedM s!"price {priceCents}" (Money.make priceCents)
    stock }

private def purchase! (customer : Ref Customer) (status : OrderStatus)
    (placedAt : Timestamp) : DbM (Stored Purchase) :=
  insert Purchase { customer, status, placedAt }

private def lineItem! (order : Ref Purchase) (product : Stored Product)
    (qty : Nat) : DbM (Stored LineItem) := do
  insert LineItem {
    order
    product := product.ref
    qty := ← seedM s!"qty {qty}" (Qty.make qty)
    unitPrice := product.val.price }

/-- Three customers, six products across all four categories, five
    purchases in mixed statuses, ten line items. The only delivered
    purchase totals 13297 cents (3299 + 2×1299 + 7400). -/
def seed : DbM Unit := do
  let priya ← customer! "Priya Sharma" "priya@example.com"
  let marco ← customer! "Marco Diaz" "marco@example.com"
  let jia ← customer! "Jia Wen" "jia@example.com"
  let headphones ← product! "Noise-Cancelling Headphones" "ELEC-NC-100" .electronics 19999 12
  let keyboard ← product! "Mechanical Keyboard" "ELEC-KB-77" .electronics 8950 3
  let espresso ← product! "Organic Espresso Beans" "GROC-ESP-01" .grocery 1450 40
  let oliveOil ← product! "Olive Oil 1L" "GROC-OIL-1L" .grocery 1299 2
  let hoodie ← product! "Merino Hoodie" "APRL-HD-M" .apparel 7400 8
  let trainSet ← product! "Wooden Train Set" "TOYS-TRN-3" .toys 3299 0
  -- five purchases: cart, placed, shipped, delivered, cancelled
  let o1 ← purchase! priya.ref .cart (hoursAgo 1)
  let o2 ← purchase! marco.ref .placed (hoursAgo 30)
  let o3 ← purchase! jia.ref .shipped (hoursAgo 20)
  let o4 ← purchase! priya.ref .delivered (hoursAgo 200)
  let o5 ← purchase! marco.ref .cancelled (hoursAgo 50)
  discard <| lineItem! o1.ref keyboard 1
  discard <| lineItem! o1.ref espresso 2
  discard <| lineItem! o2.ref headphones 1
  discard <| lineItem! o2.ref oliveOil 1
  discard <| lineItem! o3.ref espresso 3
  discard <| lineItem! o3.ref hoodie 1
  discard <| lineItem! o4.ref trainSet 1
  discard <| lineItem! o4.ref oliveOil 2
  discard <| lineItem! o4.ref hoodie 1
  discard <| lineItem! o5.ref headphones 1

end Shop
