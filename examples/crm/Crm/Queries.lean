import Crm.Entities

/-! # Queries

Domain logic as plain defs over `select`. Predicates and sort keys are
ordinary Lean — the compiler checks them against the row types.
-/

namespace Crm

open LeanDb

/-- Biggest deals first; ties broken oldest-first, then by row id. -/
private def byValueDesc : SortBy (Stored Ask) :=
  .andThen (.desc (.key (·.val.value))) (.key (·.val.openedAt))

/-- Every ask still in play (open or waiting), biggest value first. -/
def liveAsks : DbM (Array (Stored Ask)) :=
  select [Ask] (fun a => a.val.status.isLive) byValueDesc

/-- The live pipeline of company `c`: asks joined with the person they
    belong to, where that person works at `c`. Biggest value first. -/
def pipelineFor (c : Ref Company) : DbM (Array (Stored Ask × Stored Person)) :=
  select [Ask, Person]
    (fun (a, p) =>
      a.val.person == p.ref
        && p.val.company == some c
        && a.val.status.isLive)
    (.andThen (.desc (.key fun (a, _) => a.val.value)) (.key fun (a, _) => a.val.openedAt))

/-- Live asks opened more than 30 days before `now` — deals going cold.
    Oldest first. -/
def staleAsks (now : Timestamp) : DbM (Array (Stored Ask)) :=
  select [Ask]
    (fun a => a.val.status.isLive && a.val.openedAt.olderThanDays now 30)
    (.key (·.val.openedAt))

/-- Everyone on record at company `c`, alphabetically. -/
def contactsOf (c : Ref Company) : DbM (Array (Stored Person)) :=
  select [Person] (fun p => p.val.company == some c) (.key (·.val.name))

end Crm
