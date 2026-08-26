# Changelog

## 0.2.0 - 2026-08-25

LeanDB 0.2.0 replaces the earlier decision-query prototype with a typed SQLite engine. Entity structures now derive their table schema, codecs, DDL, JSON representation, CLI operations, migration plan, and schema fingerprint from one Lean definition.

The release includes typed row IDs and foreign references, compare-and-swap updates, restricted deletes, closed enums, multi-table selects, safe SQL pushdown, deterministic sorting, schema migrations, query logging, JSON-lines serving, and the `query%` CLI adapter. `leandb import-sqlite` can generate an editable Lean package and an explicit report of source features it could not carry.

Seven standalone bases exercise the engine: tickets, CRM, shop, GPUs, GPU Market, Price Watch, and a generated legacy SQLite import.

Release review also tightened several boundaries:

- UInt16 and UInt32 decoding now rejects the first out-of-range value instead of wrapping to zero.
- Inserts and partial updates reject non-object JSON and unknown fields.
- CLI row IDs and integer filters reject values outside SQLite's Int64 range.
- SQL identifiers and enum literals are escaped correctly.
- Zero-field entities use valid SQLite insert and update statements.
- Invalid schemas and corrupt migration metadata fail before the database is changed.
- Ordered predicate pushdown is limited to codecs that preserve Lean ordering in SQLite.
- The SQLite importer refuses to overwrite generated files and reports source defaults and foreign-key actions that a later table rebuild would not preserve.
