import B2T2.Entities

/-! Independent expected values transcribed from B2T2 ExampleTables.md
    at fd227efadf532a20aefd25c7a8580978c2d684a2. -/

namespace B2T2

open LeanDb

def students : Array Student := #[
  { name := "Bob", age := 12, favoriteColor := "blue" },
  { name := "Alice", age := 17, favoriteColor := "green" },
  { name := "Eve", age := 13, favoriteColor := "red" }]

def studentsMissing : Array StudentMissing := #[
  { name := "Bob", age := none, favoriteColor := some "blue" },
  { name := "Alice", age := some 17, favoriteColor := some "green" },
  { name := "Eve", age := some 13, favoriteColor := none }]

def employees : Array Employee := #[
  { lastName := "Rafferty", departmentId := some 31 },
  { lastName := "Jones", departmentId := some 33 },
  { lastName := "Heisenberg", departmentId := some 33 },
  { lastName := "Robinson", departmentId := some 34 },
  { lastName := "Smith", departmentId := some 34 },
  { lastName := "Williams", departmentId := none }]

def departments : Array Department := #[
  { departmentId := 31, departmentName := "Sales" },
  { departmentId := 33, departmentName := "Engineering" },
  { departmentId := 34, departmentName := "Clerical" },
  { departmentId := 35, departmentName := "Marketing" }]

def jellyAnon : Array JellyAnon := #[
  { getAcne := true,  red := false, black := false, white := false, green := true,  yellow := false, brown := false, orange := true,  pink := false, purple := false },
  { getAcne := true,  red := false, black := true,  white := false, green := true,  yellow := true,  brown := false, orange := false, pink := false, purple := false },
  { getAcne := false, red := false, black := false, white := false, green := true,  yellow := false, brown := false, orange := false, pink := true,  purple := false },
  { getAcne := false, red := false, black := false, white := false, green := false, yellow := true,  brown := false, orange := false, pink := false, purple := false },
  { getAcne := false, red := false, black := false, white := false, green := false, yellow := true,  brown := false, orange := false, pink := true,  purple := false },
  { getAcne := true,  red := false, black := true,  white := false, green := false, yellow := false, brown := false, orange := true,  pink := true,  purple := false },
  { getAcne := false, red := false, black := true,  white := false, green := false, yellow := false, brown := false, orange := false, pink := true,  purple := false },
  { getAcne := true,  red := false, black := false, white := false, green := false, yellow := false, brown := true,  orange := true,  pink := false, purple := false },
  { getAcne := true,  red := false, black := false, white := false, green := false, yellow := false, brown := false, orange := true,  pink := false, purple := false },
  { getAcne := false, red := true,  black := false, white := false, green := false, yellow := true,  brown := true,  orange := false, pink := true,  purple := false }]

def jellyNamed : Array JellyNamed := #[
  { name := "Emily",    getAcne := true,  red := false, black := false, white := false, green := true,  yellow := false, brown := false, orange := true,  pink := false, purple := false },
  { name := "Jacob",    getAcne := true,  red := false, black := true,  white := false, green := true,  yellow := true,  brown := false, orange := false, pink := false, purple := false },
  { name := "Emma",     getAcne := false, red := false, black := false, white := false, green := true,  yellow := false, brown := false, orange := false, pink := true,  purple := false },
  { name := "Aidan",    getAcne := false, red := false, black := false, white := false, green := false, yellow := true,  brown := false, orange := false, pink := false, purple := false },
  { name := "Madison",  getAcne := false, red := false, black := false, white := false, green := false, yellow := true,  brown := false, orange := false, pink := true,  purple := false },
  { name := "Ethan",    getAcne := true,  red := false, black := true,  white := false, green := false, yellow := false, brown := false, orange := true,  pink := true,  purple := false },
  { name := "Hannah",   getAcne := false, red := false, black := true,  white := false, green := false, yellow := false, brown := false, orange := false, pink := true,  purple := false },
  { name := "Matthew",  getAcne := true,  red := false, black := false, white := false, green := false, yellow := false, brown := true,  orange := true,  pink := false, purple := false },
  { name := "Hailey",   getAcne := true,  red := false, black := false, white := false, green := false, yellow := false, brown := false, orange := true,  pink := false, purple := false },
  { name := "Nicholas", getAcne := false, red := true,  black := false, white := false, green := false, yellow := true,  brown := true,  orange := false, pink := true,  purple := false }]

def gradebook : Array Gradebook := #[
  { name := "Bob",   age := 12, quiz1 := 8, quiz2 := 9, midterm := 77, quiz3 := 7, quiz4 := 9, «final» := 87 },
  { name := "Alice", age := 17, quiz1 := 6, quiz2 := 8, midterm := 88, quiz3 := 8, quiz4 := 7, «final» := 85 },
  { name := "Eve",   age := 13, quiz1 := 7, quiz2 := 9, midterm := 84, quiz3 := 8, quiz4 := 8, «final» := 77 }]

def gradebookMissing : Array GradebookMissing := #[
  { name := "Bob",   age := 12, quiz1 := some 8, quiz2 := 9, midterm := 77, quiz3 := some 7, quiz4 := 9, «final» := 87 },
  { name := "Alice", age := 17, quiz1 := some 6, quiz2 := 8, midterm := 88, quiz3 := none,   quiz4 := 7, «final» := 85 },
  { name := "Eve",   age := 13, quiz1 := none,   quiz2 := 9, midterm := 84, quiz3 := some 8, quiz4 := 8, «final» := 77 }]

def gradebookSeq : Array GradebookSeq := #[
  { name := "Bob",   age := 12, quizzes := [8, 9, 7, 9], midterm := 77, «final» := 87 },
  { name := "Alice", age := 17, quizzes := [6, 8, 8, 7], midterm := 88, «final» := 85 },
  { name := "Eve",   age := 13, quizzes := [7, 9, 8, 8], midterm := 84, «final» := 77 }]

def quizzesOf (grades : List Nat) : List Quiz :=
  grades.zipIdx.map fun (g, i) => { quizNum := i + 1, grade := g }

def gradebookNested : Array GradebookNested := #[
  { name := "Bob",   age := 12, quizzes := quizzesOf [8, 9, 7, 9], midterm := 77, «final» := 87 },
  { name := "Alice", age := 17, quizzes := quizzesOf [6, 8, 8, 7], midterm := 88, «final» := 85 },
  { name := "Eve",   age := 13, quizzes := quizzesOf [7, 9, 8, 8], midterm := 84, «final» := 77 }]

def seed : DbM Unit := do
  for r in students do discard <| insert Student r
  for r in studentsMissing do discard <| insert StudentMissing r
  for r in employees do discard <| insert Employee r
  for r in departments do discard <| insert Department r
  for r in jellyAnon do discard <| insert JellyAnon r
  for r in jellyNamed do discard <| insert JellyNamed r
  for r in gradebook do discard <| insert Gradebook r
  for r in gradebookMissing do discard <| insert GradebookMissing r
  for r in gradebookSeq do discard <| insert GradebookSeq r
  for r in gradebookNested do discard <| insert GradebookNested r

end B2T2
