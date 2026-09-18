/-! Portable domain types with no LeanDB import (LDB-10).
    Storage codecs are derived post-hoc in the test module. -/

inductive PortableRole where
  | admin | user
  deriving Repr, DecidableEq

structure PortableReply where
  body : String
  deriving Repr
