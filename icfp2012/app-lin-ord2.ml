(* verification succeeded *)
let app f x = f x
let check x y = assert (x = y)
let main a b = app (check (2 * a + 3 * b)) (2 * a + 3 * b)
