(* succの引数の順番を変えるのは単純な並び替えでは無理 *)
let succ f x = f (x + 1)
let rec app x f = if Random.bool () then app (x - 1) (succ f) else f x
let check x y = if x = y then () else assert false
let main n = app n (check n)
