open Util
open Syntax
open Term_util
open Type
open Modular_common


module Debug = Debug.Make(struct let check = make_debug_check __MODULE__ end)


let to_CEGAR_ref_type_base base =
  match base with
  | Ref_type.Unit -> CEGAR_ref_type.Unit
  | Ref_type.Bool -> CEGAR_ref_type.Bool
  | Ref_type.Int -> CEGAR_ref_type.Int
  | Ref_type.Abst s -> CEGAR_ref_type.Abst s
let rec to_CEGAR_ref_type typ =
  match typ with
  | Ref_type.Base(base, x, p) -> CEGAR_ref_type.Base(to_CEGAR_ref_type_base base, Id.to_string x, snd @@ CEGAR_trans.trans_term p)
  | Ref_type.Fun(x, typ1, typ2) -> CEGAR_ref_type.Fun(Id.to_string x, to_CEGAR_ref_type typ1, to_CEGAR_ref_type typ2)
  | Ref_type.Inter(styp, typs) -> CEGAR_ref_type.Inter(CEGAR_trans.trans_typ styp, List.map to_CEGAR_ref_type typs)
  | _ -> unsupported "Ref_type.to_CEGAR_ref_type"

let rec add_id_event t =
  match t.desc with
  | Let(bindings, t') ->
      let bindings' = List.map (Triple.map_trd @@ make_seq (make_event_unit "id")) bindings in
      {t with desc=Let(bindings', add_id_event t')}
  | _ -> t


let make_fix f xs t =
  make_let [f, xs, t] @@ make_var f
let decomp_fix t =
  match t.desc with
  | Let([f, xs, t'], {desc=Var g}) when f = g -> Some (f, xs, t')
  | _ -> None
let is_fix t = decomp_fix t <> None

let get_arg_num = List.length -| Triple.snd -| Option.get -| decomp_fix


let bool_of_term' t = Option.try_any (fun _ -> bool_of_term t)

let merge_paths path1 path2 = path1 @ path2

let append_paths paths1 (vl, ce, paths2) =
  vl, ce, merge_paths paths1 paths2

type answer =
  | Closure of ((id * answer) list * term)
  | VTuple of answer list
  | Fail

exception Exception of answer * bool list * (label * bool) list

let rec value_of ans =
  match ans with
  | Closure(_, v) -> v
  | VTuple anss -> make_tuple (List.map value_of anss)
  | Fail -> fail_unit_term

let rec print_val_env n fm env =
  if n <= 0 then
    Format.fprintf fm "[...]"
  else
    List.print (fun fm (f, ans) -> Format.fprintf fm "%a |-> %a" Id.print f (print_value (n-1)) ans) fm env
and print_value n fm vl =
  match vl with
  | Closure(env, v) -> Format.fprintf fm "@[%a%a@]" (print_val_env n) env Print.term v
  | _ -> unsupported "print_value"
let print_val_env fm ans = print_val_env 1 fm ans
let print_value fm ans = print_value 1 fm ans

let counter = Counter.create ()
let new_label () = Counter.gen counter


let get_label = get_id_option

let rec eval_app val_env ce ans1 paths1 ans2 paths2 =
  match ans1 with
  | Closure(_, {desc=Const (RandValue _)}) ->
      Closure(val_env, make_int 0), ce, merge_paths paths1 paths2
  | Closure(_, {desc=Event("fail",_)}) -> Fail, ce, paths1
  | Fail -> Fail, ce, paths1
  | Closure(val_env1, {desc=Fun(x, t')}) ->
      let val_env' = (x,ans2)::val_env1 in
      eval val_env' ce t'
      |> append_paths paths2
      |> append_paths paths1
  | _ ->
      assert false

(* ASSUME: Input must be normal form *) (* TODO: remove this assumption *)
and eval
      (val_env : (id * answer) list)
      (ce : bool list)
      (t : term)
  =
  let dbg = 0=0 && (match t.desc with Const _ | BinOp _ | Not _ | Fun _ | Event _  | Var _  | App(_, []) -> false | _ -> true) in
  Debug.printf "@[ORIG: %a@\n  @[" Print.term t;
  let r =
  if dbg then
    if true then
      Debug.printf "Dom(VAL_ENV): %a@\n" (List.print Id.print) @@ List.map fst val_env
    else
      Debug.printf "VAL_ENV: %a@\n" print_val_env val_env;
  if dbg then Debug.printf "CE: %a@\n" (List.print Format.pp_print_bool) ce;
  match t.desc with
  | Const _
  | BinOp _
  | Not _
  | Fun _
  | Event _ -> Closure(val_env, t), ce, []
  | Var x -> Id.assoc x val_env, ce, []
  | App(t, []) -> eval val_env ce t
  | App(t1, ts) ->
      let ts',t2 = List.decomp_snoc ts in
      let ans1, ce1, paths1 = eval val_env ce @@ make_app t1 ts' in
      begin
        try
          let ans2, ce2, paths2 = eval val_env ce1 t2 in
          eval_app val_env ce2 ans1 paths1 ans2 paths2
        with Exception(ans2, ce2, paths2) -> raise (Exception(ans2, ce2, merge_paths paths1 paths2))
      end
  | If(_, t2, t3) ->
      let label = get_label t in
      begin
        match ce with
        | [] ->
            assert (label = None);
            assert false
        | br::ce' ->
            let t23 = if br then t2 else t3 in
            let paths' =
              match label with
              | None -> []
              | Some label -> [label, br]
            in
            try
              eval val_env ce' t23
              |> append_paths paths'
            with Exception(ans, ce, paths) -> raise (Exception(ans, ce, merge_paths paths' paths))
      end
  | Let([f,xs,t1], t2) when is_non_rec [f,xs,t1] ->
      let ans, ce, paths = eval val_env ce @@ make_funs xs t1 in
      if ans = Fail then
        (ans, ce, paths)
      else
        let val_env' = (f, ans)::val_env in
        begin
          try
            eval val_env' ce t2
            |> append_paths paths
          with Exception(ans', ce', paths') -> raise (Exception(ans', ce', merge_paths paths paths'))
        end
  | Let([f,xs,t1], t2) ->
      assert (xs <> []);
      let rec val_env' = (f, Closure(val_env', make_funs xs t1))::val_env in
      eval val_env' ce t2
  | Raise t ->
      let ans, ce', paths' = eval val_env ce t in
      raise (Exception(ans, ce', paths'))
  | TryWith(t1, t2) ->
      begin
        try
          eval val_env ce t1
        with Exception(ans1, ce, paths1) ->
             let ans2, ce, paths2 = eval val_env ce t2 in
             eval_app val_env ce ans2 paths2 ans1 paths1
      end
  | Tuple ts ->
      let rec aux t (anss,ce,paths) =
        match anss with
        | Fail::_ -> anss, ce, paths
        | _ ->
            let ans, ce', paths' = eval val_env ce t in
            ans::anss, ce', merge_paths paths' paths
      in
      let anss, ce', paths' = List.fold_right aux ts ([],ce,[]) in
      let ans =
        if List.hd anss = Fail then
          Fail
        else
          VTuple anss
      in
      if ce' <> ce then unsupported "Modular_check.eval tuple";
      ans, ce', paths'
  | Proj(i, t) ->
      let ans, ce, paths = eval val_env ce t in
      if ans = Fail then
        Fail, ce, paths
      else
        let ans =
          match ans with
          | VTuple anss -> List.nth anss i
          | _ -> assert false
        in
        ans, ce, paths
  | _ ->
      Format.printf "@.%a@." Print.term t;
      unsupported "Modular_check.eval"
  in
  if dbg then
    Debug.printf"@]@\nRETURN: %a, %a@\n@]" Print.term (value_of @@ Triple.fst r) print_ce (Triple.trd r);
  r

type result =
  | Typable of Ref_type.env
  | Untypable of ce

let add_context prog f xs t typ =
  let dbg = 0=0 in
  let {fun_typ_env=env; fun_def_env=fun_env; exn_decl} = prog in
  if dbg then Debug.printf "ADD_CONTEXT prog: %a@." print_prog prog;
  if dbg then Debug.printf "ADD_CONTEXT: %a :? %a@." Print.id f Ref_type.print typ;
  let fs =
    List.Set.diff ~eq:Id.eq (get_fv t) (f::xs)
  in
  let af = "Assert_failure" in
  let etyp = Type(["exn", TVariant (exn_decl@[af,[]])], "exn") in
  let typ_exn = Encode.typ_of Encode.all etyp in
  let make_fail typ =
    Encode.all @@ Trans.replace_fail_with (Raise(make_construct "Assert_failure" [] etyp)) @@ make_fail typ
  in
  let fail_unit_desc = (make_fail TUnit).desc in
  let t' =
    unit_term
    |> Trans.ref_to_assert ~typ_exn ~make_fail @@ Ref_type.Env.of_list [f,typ]
    |@dbg&> Debug.printf "ADD_CONTEXT t: %a@." Print.term
    |> normalize false
    |@dbg&> Debug.printf "ADD_CONTEXT t': %a@." Print.term
  in
  let fun_env' =
    env
    |> Ref_type.Env.filter_key (Id.mem -$- fs)
    |> Ref_type.Env.to_list
    |> List.map (Pair.map_snd @@ decomp_funs -| Triple.trd -| Ref_type_gen.generate (Some typ_exn) ~make_fail [] [])
    |@dbg&> Debug.printf "ADD_CONTEXT fun_env': %a@." print_def_env
  in
  let fun_env'' =
    List.map (Pair.map_snd @@ Pair.map_snd @@ normalize false) fun_env' @
    [f, (xs, Trans.replace_fail_with fail_unit_desc @@ normalize false t)]
  in
  if dbg then Debug.printf "ADD_CONTEXT fun_env'': %a@." print_def_env fun_env'';
  t', fun_env''

let complete_ce_set f t ce =
  let let_fun_var = make_col [] (@@@) in
  let let_fun_var_desc desc =
    match desc with
    | Let(bindings,t) ->
        let aux (f,xs,t) =
          let fs = let_fun_var.col_term t in
          if xs = [] then
            fs
          else
            f::fs
        in
        let_fun_var.col_term t @@@ List.rev_map_flatten aux bindings
    | _ -> let_fun_var.col_desc_rec desc
  in
  let_fun_var.col_desc <- let_fun_var_desc;
  let fs = f :: let_fun_var.col_term t in
  List.map (fun f -> f, if Id.mem_assoc f ce then Id.assoc f ce else []) fs

let make_init_ce_set f t =
  f, complete_ce_set f t []


let check prog f typ depth =
  Debug.printf "MAIN_LOOP prog: %a@." print_prog prog;
  let {fun_typ_env=env; fun_def_env=fun_env} = prog in
  let t,fun_env' =
    let xs, t = Id.assoc f prog.fun_def_env in
    let t' =
      let fs = List.filter_out (Id.same f) @@ take_funs_of_depth fun_env f depth in
      let fun_env' = List.filter (fst |- Id.mem -$- fs) fun_env in
      make_lets (List.map Triple.of_pair_r fun_env') t
    in
    Debug.printf "t': %a@." Print.term t';
    add_context prog f xs t' typ
  in
  let top_funs = List.map fst fun_env' in
  Debug.printf "  Check %a : %a@." Id.print f Ref_type.print typ;
  Debug.printf "  t: %a@." Print.term_typ t;
  let make_pps spec =
    Preprocess.and_after Preprocess.CPS @@ Preprocess.all spec
  in
  let (result, make_get_rtyp, set_target'), main, set_target =
    t
    |> make_lets (List.map Triple.of_pair_r fun_env')
    |@> Debug.printf "  t with def: %a@.@." Print.term_typ
    |@> Type_check.check -$- TUnit
    |> Trans.map_main (make_seq -$- unit_term) (* ??? *)
    |> Main_loop.verify ~make_pps:(Some(make_pps)) ~fun_list:(Some []) [] Spec.init
  in
  match result with
  | CEGAR.Safe env ->
      Debug.printf "  Typable@.";
      Debug.printf "  env: %a@." (List.print @@ Pair.print Format.pp_print_string CEGAR_ref_type.print) env;
      let env' = (f,typ) :: Main_loop.trans_env (List.map fst fun_env) make_get_rtyp env in
      Debug.printf "  env': %a@." (List.print @@ Pair.print Id.print Ref_type.print) env';
      Typable (Ref_type.Env.normalize @@ Ref_type.Env.of_list env')
  | CEGAR.Unsafe(sol, ModelCheck.CESafety ce_single) ->
      let ce_single' = List.map ((=) 0) ce_single in
      if !!Debug.check then Main_loop.report_unsafe main sol set_target;
      Debug.printf "  Untypable@.@.";
      Debug.printf "    CE_INIT: %a@\n" (List.print Format.pp_print_bool) ce_single';
      Debug.printf "    TOP_FUNS: %a@\n" (List.print Id.print) top_funs;
      let ans,ce_single'',ce =
        let val_env =
          let aux val_env (f,(xs,t)) =
            let rec val_env' = (f, Closure(val_env', make_funs xs t))::val_env in
            val_env'
          in
          List.fold_left aux [] fun_env'
        in
        try
          eval val_env ce_single' t
        with Exception(ans, ce, paths) -> Fail, ce, paths
      in
      Debug.printf "  CE: %a@\n" print_ce ce;
      assert (ans = Fail);
      assert (ce_single'' = []);
      Untypable ce
  | CEGAR.Unsafe _ -> assert false
