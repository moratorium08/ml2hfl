let f x y = assert (not ((x () > 0) && (y () <= 0))) in
let h x y = x in
let rec g n = f (h n) (h n) in
   g m
