import B2T2.Entities
import B2T2.Fixtures

namespace B2T2

open LeanDb

def base : Base := {
  name := "b2t2"
  tables := [
    .of Student, .of StudentMissing, .of Employee, .of Department,
    .of JellyAnon, .of JellyNamed, .of Gradebook, .of GradebookMissing,
    .of GradebookSeq, .of GradebookNested]
  seed := some seed
}

end B2T2
