#!/bin/sh
# Build the legacy.db fixture for `leandb import-sqlite` (system sqlite3).
set -e
cd "$(dirname "$0")"
rm -f legacy.db
/usr/bin/sqlite3 legacy.db <<'SQL'
CREATE TABLE customers (
  id INTEGER PRIMARY KEY,
  name TEXT NOT NULL,
  email TEXT,
  balance REAL NOT NULL DEFAULT 0
);
CREATE TABLE orders (
  id INTEGER PRIMARY KEY,
  customer_id INTEGER NOT NULL REFERENCES customers(id),
  item TEXT NOT NULL,
  qty INT NOT NULL
);
CREATE VIEW big_orders AS SELECT * FROM orders WHERE qty > 10;
CREATE INDEX idx_orders_customer ON orders(customer_id);
CREATE TABLE link (
  a INTEGER,
  b INTEGER,
  PRIMARY KEY (a, b)
);
INSERT INTO customers (name, email, balance) VALUES ('Ada Lovelace', 'ada@example.com', 120.5);
INSERT INTO customers (name, email, balance) VALUES ('Grace Hopper', NULL, 0);
INSERT INTO orders (customer_id, item, qty) VALUES (1, 'punch cards', 12);
INSERT INTO orders (customer_id, item, qty) VALUES (2, 'compiler', 1);
INSERT INTO orders (customer_id, item, qty) VALUES (1, 'difference engine', 42);
INSERT INTO link (a, b) VALUES (1, 2);
SQL
echo "wrote $(pwd)/legacy.db"
