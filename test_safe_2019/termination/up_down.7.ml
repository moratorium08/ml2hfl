let rec app (_:bool) (_:int) (_:int) (_:bool) (_:int)
           (f:(bool -> int -> int -> unit)) (set_flag_down_125:bool)
           (s_down_x_122:int) (x:int) = f set_flag_down_125 s_down_x_122 x
and down (prev_set_flag_down_124:bool) (s_prev_down_x_123:int) (x:int) =
  if prev_set_flag_down_124
  then
    if s_prev_down_x_123 > x && x >= 0 then () else assert false;
  down_without_checking_145
    prev_set_flag_down_124 s_prev_down_x_123 x
and down_without_checking_145 (_:bool) (_:int) (x:int) =
  let set_flag_down_125 = true
  in
  let s_down_x_122 = x
  in
  if x = 0
  then
    ()
  else
    down_without_checking_145 set_flag_down_125 s_down_x_122 (x - 1)
and up (set_flag_down_125:bool) (s_down_x_122:int) (x:int) =
  if x = 0 then () else up set_flag_down_125 s_down_x_122 (x + 1)
let main (set_flag_down_125:bool) (s_down_x_122:int)
        (():unit) =
  let t1 = Random.int 0
  in
  let t2 = Random.int 0
  in
  if t1 > 0
  then
    app
      set_flag_down_125 s_down_x_122 0 set_flag_down_125
      s_down_x_122 down set_flag_down_125 s_down_x_122 t1
  else
    (if t2 < 0
     then
       app
         set_flag_down_125 s_down_x_122 0 set_flag_down_125
         s_down_x_122 up set_flag_down_125 s_down_x_122 t2)
let u_9421 = main false 0 ()
