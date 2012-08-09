let make_array n i = assert (0 <= i && i < n); 0 in
let rec dotprod n v1 v2 i sum =
  if i >= n then sum
  else (dotprod n v1 v2 (i+1) (sum + v1 i + v2 i);
           dotprod n v1 v2 (i+1) (sum + v1 i + v2 i))
in
let v1 = make_array n in
let v2 = make_array n in
  if z=0 then (dotprod n v1 v2 z z; ()) else ()
