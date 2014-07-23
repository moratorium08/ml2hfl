open Util
open Type
open Syntax
open Term_util


let debug () = List.mem "Tupling" !Flag.debug_module


type form =
  | FSimpleRec
  | FNonRec
  | FOther

exception Cannot_compose
exception Not_recursive



let normalize_tuple = make_trans ()

let normalize_tuple_term t =
  match t.desc with
  | Tuple ts ->
      let ts' = List.map normalize_tuple.tr_term ts in
      let xs = List.mapi (fun i t -> Id.new_var ~name:("x" ^ string_of_int (i+1)) t.typ) ts' in
      make_lets (List.map2 (fun x t -> x,[],t) xs ts') @@ make_tuple @@ List.map make_var xs
  | _ -> normalize_tuple.tr_term_rec t

let () = normalize_tuple.tr_term <- normalize_tuple_term
let normalize_tuple = normalize_tuple.tr_term



let rec decomp_let t =
  match t.desc with
  | Let(flag, [f,xs,t1], t2) ->
      let bindings,t2' = decomp_let t2 in
      (flag,(f,xs,t1))::bindings, t2'
  | _ ->
    let r = Id.new_var ~name:"r" t.typ in
    [Nonrecursive, (r,[],t)], make_var r

let partition_bindings x t =
  if debug() then Format.printf "PB: x:%a@." Id.print x;
  let bindings,t' = decomp_let t in
  let check t =
    if List.mem x (get_fv t)
    then (raise Cannot_compose)
  in
  let aux (flag,(f,xs,t)) (before,app_x,after) =
    match app_x, xs, t with
      None, [], {desc=App({desc=Var y}, ts)} when Id.same x y ->
        assert (flag = Nonrecursive);
        before, Some (f,ts), after
    | None, _, _ ->
        if debug() then Format.printf "CHECK: %a@." print_term t;
        check t;
        before, app_x, (flag,(f,xs,t))::after
    | Some _, _, {desc=App({desc=Var y}, ts)} when Id.same x y ->
        raise Cannot_compose
    | Some _, _, _ ->
        check t;
        (flag,(f,xs,t))::before, app_x, after
  in
  let before,app_x,after = List.fold_right aux bindings ([],None,[]) in
  match app_x with
    None -> raise Not_recursive
  | Some xts -> before, xts, after, t'

let classify f t =
  try
    ignore (partition_bindings f t); FSimpleRec
  with
  | Not_recursive -> FNonRec
  | Cannot_compose -> FOther


let tupling = make_trans2 ()

let is_wrapped t =
  match t.desc with
  | If(t1,t2,t3) when is_none t2 -> Option.map (fun t1' -> t1', t3) @@ decomp_is_none t1
  | _ -> None

let inline_wrapped = make_trans ()

let inline_wrapped_term t =
  match t.desc with
  | Tuple ts ->
      let ts' = List.map inline_wrapped.tr_term ts in
      let tts = List.map is_wrapped ts' in
      if List.for_all Option.is_some tts
      then
        let tts' = List.map Option.get tts in
        let xs = List.map (fun (t1,t3) -> Id.new_var t3.typ) tts' in
        let aux x (t1,t3) t_acc =
          make_if (make_is_none t1) (subst x (make_none @@ get_opt_typ t3.typ) t_acc) (subst x t3 t_acc)
        in
        List.fold_right2 aux xs tts' @@ make_tuple @@ List.map make_var xs
      else
        inline_wrapped.tr_term_rec t
  | _ -> inline_wrapped.tr_term_rec t

let () = inline_wrapped.tr_term <- inline_wrapped_term
let inline_wrapped = inline_wrapped.tr_term


let rec compose fg fts =
  if debug() then Format.printf "compose:@.";
  if debug() then List.iter (fun (f,t) -> Format.printf "   %a, %a;@." Id.print f print_term t) fts;
  if debug() then Format.printf "@.";
  let decomp_if i (f,t) =
    match t.desc with
    | If(t1,t2,t3) -> Some (i,f,t1,t2,t3)
    | _ -> None
  in
  let ts' = List.mapi decomp_if fts in
  if List.exists Option.is_some ts'
  then
    let i,f,t1,t2,t3 = Option.get @@ List.find Option.is_some ts' in
    let fts2 = List.replace_nth fts i (f,t2) in
    let fts3 = List.replace_nth fts i (f,t3) in
    make_if t1 (compose fg fts2) (compose fg fts3)
  else
    let forms = List.map (uncurry classify) fts in
    if debug() then Format.printf "compose_let@.";
    if debug() then List.iter (fun (f,t) -> Format.printf "%a:%a@.@." Id.print f print_term t) fts;
    if List.for_all ((=) FSimpleRec) forms
    then
      let aux (f,t) (before_acc, xs, arg_acc, after_acc, ts) =
        let before,(x,arg),after,t' = partition_bindings f @@ Trans.alpha_rename t in
        before@before_acc, x::xs, arg@arg_acc, after@after_acc, t'::ts
      in
      let before,xs,arg,after,ts = List.fold_right aux fts ([],[],[],[],[]) in
      let p = Id.new_var ~name:"p" @@ TTuple xs in
      let pat =
        (p,  [], make_app (make_var fg) arg)
        :: List.mapi (fun i x -> x, [], make_proj i @@ make_var p) xs
      in
      make_lets_f before @@ make_lets pat @@ make_lets_f after @@ make_tuple ts
    else
      let conts,ts = List.split_map (Pair.map_fst make_lets_f -| decomp_let -| snd) fts in
      List.fold_right (@@) conts @@ make_tuple ts



let new_funs = ref ([] : (id list * (id * id list * typed_term)) list)

let assoc_env f env =
  if debug() then Color.printf Color.Reverse "%a@." Id.print f;
  let _,xs,t = Id.assoc f env in
  let ys,t' = decomp_funs t in
  match xs@ys with
  | x::xs' -> x, List.fold_right make_fun xs' t'
  | _ -> raise Not_found

let tupling_term env t =
  match t.desc with
  | Tuple ts ->
      let ts' = List.map decomp_some ts in
      if 2 <= List.length @@ List.filter Option.is_some ts'
      then
        try
          if debug() then Format.printf "TUPLE: %a@." (print_list print_term ", ") ts;
          let fs,tfs =
            let aux t =
              match t.desc with
              | App({desc = Var f}, [{desc = Proj(1, t1)}]) -> f, t1
              | _ -> raise Not_found
            in
            let ftfs = List.map (Option.map aux) ts' in
            List.map (Option.map fst) ftfs,
            List.map (Option.map snd) ftfs
          in
          let tfs' = List.filter_map Std.identity tfs in
          let xs = List.map (Option.map (fun t -> Id.new_var @@ get_opt_typ t.typ)) tfs in
          let xs' = List.filter_map Std.identity xs in
          let bodies =
            let zts = List.map (Option.map @@ flip assoc_env env) fs in
            let aux zt x =
              match zt, x with
              | None, None -> []
              | Some (z,t), Some x -> [subst_var z x @@ normalize_tuple t]
              | _ -> assert false
            in
            List.flatten @@ List.map2 aux zts xs
          in
          let typ =
            match t.typ with
            | TTuple ys ->
                let ys' = List.map2 (fun y t -> Option.map (fun _ -> y) t) ys ts' in
                TTuple (List.filter_map (Option.map @@ Id.map_typ get_opt_typ) ys')
            | _ -> assert false
          in
          let fs' = List.filter_map Std.identity fs in
          let fg =
            try
              let _,(fg,_,_) = List.find (fun (gs,_) -> List.length fs' = List.length gs && List.for_all2 Id.same fs' gs) !new_funs in
              fg
            with
            | Not_found ->
                let fg =
                  let name = String.join "__" @@ List.map Id.name fs' in
                  Id.new_var ~name @@ List.fold_right (fun x typ -> TFun(x,typ)) xs' typ
                in
                let t_body = compose fg @@ List.combine fs' bodies in
                new_funs := (fs', (fg, xs', t_body)) :: !new_funs;
                fg
          in
          let r = Id.new_var ~name:"r" typ in
          if debug() then Format.printf "ADD_fs: %a@." (print_list Id.print ", ") fs';
          if debug() then Format.printf "ADD: %a@." print_id_typ fg;
          let t_app = make_app (make_var fg) @@ List.map make_get_val tfs' in
          let index =
            let aux (i,j,rev_map) t =
              match t with
              | None -> i+1, j, rev_map
              | Some _ -> i+1, j+1, (i,j)::rev_map
            in
            let m,n,map = List.fold_left aux (0,0,[]) ts' in
            assert (List.length ts = m);
            assert (List.length tfs' = n);
            fun i -> List.assoc i map
          in
          let aux i = function
            | None -> make_none @@ get_opt_typ (List.nth ts i).typ
            | Some _ -> make_some @@ make_proj (index i) @@ make_var r
          in
          make_let [r, [], t_app] @@ make_tuple @@ List.mapi aux ts'
        with Not_found -> tupling.tr2_term_rec env t
      else
        tupling.tr2_term_rec env t
  | Let(flag, bindings, t) ->
      let bindings' = List.map (fun (f,xs,t) -> f, xs, tupling.tr2_term env t) bindings in
      let env' = List.map (fun (f,xs,t) -> f,(f,xs,t)) bindings' @ env in
      make_let_f flag bindings' @@ tupling.tr2_term env' t
  | _ -> tupling.tr2_term_rec env t

let () = tupling.tr2_term <- tupling_term

let add_funs = make_trans ()

let add_funs_desc desc =
  match desc with
  | Let(flag, bindings, t) ->
      let bindings' = List.map (fun (f,xs,t) -> add_funs.tr_var f, List.map add_funs.tr_var xs, add_funs.tr_term t) bindings in
      let funs1,funs2 =
        let aux (fs,_) = List.exists (fun (f,_,_) -> Id.mem f fs) bindings in
        List.partition aux !new_funs
      in
      let funs1' =
        let aux (fs,def) =
          List.filter_out (fun f -> List.exists (Id.same f -| fst3) bindings) fs,
          def
        in
        List.map aux funs1 in
      let funs11,funs12 = List.partition ((=) [] -| fst) funs1' in
      new_funs := funs12 @ funs2;
      let t' =
        let t' = add_funs.tr_term t in
        List.fold_left (fun t (_,def) -> make_letrec [def] t) t' funs11
      in
      Let(flag, bindings', t')
  | _ -> add_funs.tr_desc_rec desc

let () = add_funs.tr_desc <- add_funs_desc

let tupling t =
  new_funs := [];
  t
  |> tupling.tr2_term []
  |> add_funs.tr_term












let rec decomp_let_app t =
  match t.desc with
  | Let(Nonrecursive, [x,[], ({desc=App _} as t1)], t2) ->
      let bindings,t' = decomp_let_app t2 in
      (x,[],t1)::bindings, t'
  | _ -> [], t

let is_depend t x = Id.mem x @@ get_fv t

let let_normalize = make_trans ()

let let_normalize_desc desc =
  match desc with
    Let(Nonrecursive, [x,[],{desc=App _}], _) -> let_normalize.tr_desc_rec desc
  | Let(Nonrecursive, [x,[],t1], t2) ->
      let t1' = let_normalize.tr_term t1 in
      let t2' = let_normalize.tr_term t2 in
      let bindings,t2'' = decomp_let_app t2' in
      let rec aux acc bindings =
        match bindings with
          [] -> acc,[]
        | (_,_,t)::bindings' when is_depend t x -> acc, bindings
        | (y,_,t)::bindings' -> aux (acc@[y,[],t]) bindings'
      in
      let bindings1,bindings2 = aux [] bindings in
      if bindings1 = []
      then Let(Nonrecursive, [x,[],t1'], t2')
      else
        let t2''' = make_lets bindings2 t2'' in
        if debug() then Color.printf Color.Yellow "NORMALIZE: %a@." Id.print x;
        if debug() then Color.printf Color.Reverse "[%a]@." (print_list Id.print ";") @@ List.map (fun (x,_,_) -> x) bindings;
        (make_lets bindings1 @@ make_lets [x,[],t1'] t2''').desc
  | _ -> let_normalize.tr_desc_rec desc

let () = let_normalize.tr_desc <- let_normalize_desc
let let_normalize = let_normalize.tr_term



let rec tree_of_tuple t =
  match t.desc with
  | Tuple [t1;t2] when t1 = none_flag || t1 = some_flag -> Rose_tree.Leaf t
  | Tuple ts -> Rose_tree.Node (List.map tree_of_tuple ts)
  | _ -> Rose_tree.Leaf t

let is_subsumed t1 t2 =
  if debug() then Color.printf Color.Yellow "is_subsumed: %a, %a; " print_term t1 print_term t2;
  match t1.desc, t2.desc with
  | App({desc=Var f},ts1), App({desc=Var g},ts2) when Id.same f g ->
      let check t1 t2 =
        try
          let tree1 = tree_of_tuple t1 in
          let tree2 = tree_of_tuple t2 in
          let tts = Rose_tree.flatten @@ Rose_tree.zip tree1 tree2 in
          List.for_all (fun (t1, t2) -> same_term t1 t2 || is_none t1) tts
        with Invalid_argument "Rose_tree.zip" -> false
      in
      List.for_all2 check ts1 ts2
  | _ -> false

let elim_sub_app = make_trans2 ()

let elim_sub_app_desc env desc =
  match desc with
  | Let(Nonrecursive, [x,[],t1], t2) ->
      let env' = (x,t1)::env in
      let t2' =
        try
          let y,_ = List.find (fun (y,t2) -> not (is_depend t1 y) && is_subsumed t2 t1) env in
          if debug() then Format.printf "%a |-> %a@." Id.print y Id.print x;
          make_label (InfoId y) @@ subst y (make_var x) t2
        with Not_found -> t2
      in
      let t2'' = elim_sub_app.tr2_term env' t2' in
      Let(Nonrecursive, [x,[],t1], t2'')
  | _ -> elim_sub_app.tr2_desc_rec env desc
let elim_sub_app_desc env desc =
  match desc with
  | Let(Nonrecursive, [x,[],t1], t2) ->
      let env' = (x,t1)::env in
      let t2' =
        let ys = List.map fst @@ List.filter (fun (y,t2) -> not (is_depend t1 y) && is_subsumed t2 t1) env in
        if debug() then List.iter (fun y -> Format.printf "%a |-> %a@." Id.print y Id.print x) ys;
        List.fold_left (fun t y -> make_label (InfoId y) @@ subst y (make_var x) t) t2 ys
      in
      let t2'' = elim_sub_app.tr2_term env' t2' in
      Let(Nonrecursive, [x,[],t1], t2'')
  | _ -> elim_sub_app.tr2_desc_rec env desc

let () = elim_sub_app.tr2_desc <- elim_sub_app_desc

let elim_substed_let = make_trans2 ()

let elim_substed_let_term xs t =
  match t.desc with
  | Let(Nonrecursive, [x,[],t1], t2) when Id.mem x xs && not (is_depend t2 x) ->
      elim_substed_let.tr2_term xs t2
  | _ -> elim_substed_let.tr2_term_rec xs t

let () = elim_substed_let.tr2_term <- elim_substed_let_term

let elim_sub_app t =
  let t' = elim_sub_app.tr2_term [] t in
  let xs = col_info_id t' in
  if debug() then Format.printf "%a@." (print_list Id.print "; ") xs;
  let t'' = elim_substed_let.tr2_term xs t' in
  Trans.remove_label t''



let is_option t = is_none t || Option.is_some @@ decomp_some t

let is_option_type typ =
  match typ with
  | TTuple[x; _] when Id.typ x = none_flag.typ -> true
  | _ -> false

let elim_same_app = make_trans2 ()

let elim_same_app_term env t =
  match t.desc with
  | Let(Nonrecursive, [x,[],({desc=App({desc=Var _}, [{desc=Tuple _}])} as t1)], t2) ->
      begin
        try
          let y,_ = List.find (same_term t1 -| snd) env in
          if debug() then Format.printf "%a |-> %a@." Id.print x Id.print y;
          elim_same_app.tr2_term env @@ subst x (make_var y) t2
        with Not_found ->
          make_let [x,[],t1] @@ elim_same_app.tr2_term ((x,t1)::env) t2
      end
  | _ -> elim_same_app.tr2_term_rec env t

let () = elim_same_app.tr2_term <- elim_same_app_term
let elim_same_app = elim_same_app.tr2_term []



let replace_app = make_trans2 ()

let is_used_in t1 t2 = col_same_term t1 t2 <> []

let rec decomp_let_app_option f t =
  match t.desc with
  | Let(Nonrecursive, [x, [], {desc=App({desc=Var g}, [{desc=Tuple ts}])} as binding], t2) when Id.same f g ->
      let ts' = List.map decomp_some ts in
      let args = List.flatten @@ List.mapi (fun i t -> match t with None -> [] | Some t' -> [i, x, t']) ts' in
      let bindings,args',t' = decomp_let_app_option f t2 in
      binding::bindings, args@@@args', t'
  | Let(Nonrecursive, [x, [], {desc=App({desc=Var g}, [_])}], t2) when Id.same f g ->
      invalid_argument "decomp_let_app_option"
  | _ -> [], [], t

let replace_app_term env t =
  match t.desc with
  | Let(Nonrecursive, [x, [], {desc=App({desc=Var f},[t1])}], _) ->
      begin
        try
          let bindings,apps1,t2 = decomp_let_app_option f t in
          let env1,env2 = List.partition (Id.same f -| fst) env in
          let apps2 =
            match env1 with
            | [] -> []
            | [_,apps2] -> apps2
            | _ -> assert false
          in
          let cmp (i,_,t1) (j,_,t2) =
            if i = j then
              if same_term t1 t2 then 0 else 1
            else
              compare i j
          in
          let must = List.diff ~cmp apps1 apps2 in
          let apps' = apps1 @@@ apps2 in
          let env' = (f,apps')::env2 in
          let used = List.filter (fun (i,x,_) -> is_used_in (make_proj i @@ make_var x) t2) apps' in
          let must_but_not_used = List.diff ~cmp must used in
          let t2' = replace_app.tr2_term env' t2 in
          if debug() then
            begin
              Format.printf "replace[%d]: %a@." (List.length apps1) Id.print x;
              List.iter (fun (i,x,t) -> Format.printf "APPS: %a = %a ...%d... %a ...@." Id.print x Id.print f i print_term t) apps';
              List.iter (fun (i,x,t) -> Format.printf "USED: %a = %a ...%d... %a ...@." Id.print x Id.print f i print_term t) used;
              List.iter (fun (i,x,t) -> Format.printf "MUST: %a = %a ...%d... %a ...@." Id.print x Id.print f i print_term t) must;
              List.iter (fun (i,x,t) -> Format.printf "MBNU: %a = %a ...%d... %a ...@." Id.print x Id.print f i print_term t) must_but_not_used
            end;
          let y = Id.new_var_id x in
          let sbst, arg =
            List.iteri (fun i _ -> if 1 < List.length @@ List.filter ((=) i -| fst3) used then raise (Invalid_argument "replace_app")) @@ decomp_ttuple t1.typ;
            let aux sbst (i,x,_) = sbst |- replace_term (make_proj i @@ make_var x) (make_proj i @@ make_var y) in
            let sbst = List.fold_left aux Std.identity used in
            let aux i typ =
              try
                make_some @@ trd @@ List.find ((=) i -| fst3) used
              with Not_found -> make_none @@ get_opt_typ typ
            in
            sbst, make_tuple @@ List.mapi aux @@ decomp_ttuple t1.typ
          in
          let t1 = make_app (make_var f) [arg] in
          if debug() then Format.printf "NEW: %a = %a@." Id.print y print_term t1;
          make_lets bindings @@ make_let [y,[],t1] @@ sbst t2'
        with Invalid_argument ("decomp_let_app_option"|"replace_app") -> replace_app.tr2_term_rec env t
      end
  | _ -> replace_app.tr2_term_rec env t

let () = replace_app.tr2_term <- replace_app_term

let replace_app = replace_app.tr2_term []




let trans t =
  t
  |> inline_wrapped
  |@debug()&> Format.printf "%a:@.%a@.@." Color.s_red "inline_wrapped" print_term
  |> Trans.flatten_let
  |> Trans.inline_var
  |@debug()&> Format.printf "%a:@.%a@.@." Color.s_red "flatten_let" print_term
  |> let_normalize
  |@debug()&> Format.printf "%a:@.%a@.@." Color.s_red "normalize let" print_term
  |> elim_sub_app
  |> elim_same_app
  |@debug()&> Format.printf "%a:@.%a@.@." Color.s_red "elim_same_app" print_term
  |> Trans.elim_unused_branch
  |@debug()&> Format.printf "%a:@.%a@.@." Color.s_red "elim_unused_branch" print_term
  |> Trans.elim_unused_let
  |@debug()&> Format.printf "%a:@.%a@.@." Color.s_red "elim_unused_let" print_term
  |@> flip Type_check.check Type.TUnit
  |> tupling
  |@debug()&> Format.printf "%a:@.%a@.@." Color.s_red "tupled" print_term
  |@> flip Type_check.check Type.TUnit
  |> Trans.normalize_let
  |> Trans.flatten_let
  |> Trans.inline_no_effect
  |@debug()&> Format.printf "%a:@.%a@.@." Color.s_red "normalize" print_term
  |> replace_app
  |@debug()&> Format.printf "%a:@.%a@.@." Color.s_red "replace_app" print_term
  |@> flip Type_check.check Type.TUnit
  |> elim_sub_app
  |> elim_same_app
  |@debug()&> Format.printf "%a:@.%a@.@." Color.s_red "elim_unnecessary" print_term
  |@> flip Type_check.check Type.TUnit
  |> Trans.inline_next_redex
  |@debug()&> Format.printf "%a:@.%a@.@." Color.s_red "inline_next_redex" print_term
  |@> flip Type_check.check Type.TUnit
