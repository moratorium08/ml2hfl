open Util
open Syntax
open Term_util
open Type
open Modular_syntax


module Debug = Debug.Make(struct let cond = Debug.Module "Check_mod" end)


(*
let print_ce_set fm ce_set =
  let pr fm (f, ce) = Format.fprintf fm "%a: %a" Id.print f (List.print Format.pp_print_int) ce in
  Format.fprintf fm "%a" (print_list pr ",@ ") ce_set
 *)
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
  | Let(flag, bindings, t') ->
      let bindings' = List.map (Triple.map_trd @@ make_seq (make_event_unit "id")) bindings in
      {t with desc=Let(flag, bindings', add_id_event t')}
  | _ -> t


let make_fix f xs t =
  make_letrec [f, xs, t] @@ make_var f
let decomp_fix t =
  match t.desc with
  | Let(Recursive, [f, xs, t'], {desc=Var g}) when f = g -> Some (f, xs, t')
  | _ -> None
let is_fix t = decomp_fix t <> None

let get_arg_num = List.length -| Triple.snd -| Option.get -| decomp_fix


let bool_of_term' t = Option.try_any (fun _ -> bool_of_term t)

let merge_paths paths1 paths2 =
  let aux (x,ce) acc =
    if Id.mem_assoc x acc then
      List.map (fun (y,ce') -> let ce'' = if Id.same x y then ce@ce' else ce' in y, ce'') acc
    else
      (x,ce)::acc
  in
  List.fold_right aux paths1 paths2

let append_paths paths1 (vl, ce, paths2) =
  vl, ce, merge_paths paths1 paths2

type answer =
  | Closure of ((id * answer) list * term)
  | VTuple of answer list
  | Fail

exception Exception of answer * int list * (id * int list) list

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


let make_label_env = make_col2 [] (@)
let make_label_env_term cnt t =
  match t.desc with
  | Let(_, bindings, t1) ->
      let aux (g,xs,t) =
        let env = make_label_env.col2_term cnt t in
        if xs = [] then env else (g, Counter.gen cnt)::env
      in
      List.flatten_map aux bindings @ make_label_env.col2_term cnt t1
  | _ -> make_label_env.col2_term_rec cnt t
let () = make_label_env.col2_term <- make_label_env_term
let make_label_env f t =
  let cnt = Counter.create () in
  (f, Counter.gen cnt) :: make_label_env.col2_term cnt t


let add_label = make_trans2 ()
let add_label_term (l,env) t =
  match t.desc with
  | If _ ->
      let t' = add_label.tr2_term_rec (l,env) t in
      assert (Option.is_none @@ get_id_option t');
      add_id l t'
  | Let(flag, bindings, t1) ->
      let bindings' =
        let aux (g,xs,t) =
          g,
          xs,
          if xs = [] then
            add_label.tr2_term (l,env) t
          else
            add_label.tr2_term (Id.assoc g env, env) t
        in
        List.map aux bindings
      in
      let t1' = add_label.tr2_term (l,env) t1 in
      make_let_f flag bindings' t1'
  | _ -> add_label.tr2_term_rec (l,env) t
let () = add_label.tr2_term <- add_label_term
let add_label l env = add_label.tr2_term (l, env)

let get_label = get_id_option

let rec eval_app top_funs val_env ce label_env ans1 paths1 ans2 paths2 =
  match ans1 with
  | Closure(_, {desc=Const (RandValue _)}) ->
      Closure(val_env, make_int 0), ce, merge_paths paths1 paths2
  | Closure(_, {desc=Event("fail",_)}) -> Fail, ce, paths1
  | Fail -> Fail, ce, paths1
  | Closure(val_env1, {desc=Fun(x, t')}) ->
      let val_env' = (x,ans2)::val_env1 in
      eval top_funs val_env' ce label_env t'
      |> append_paths paths2
      |> append_paths paths1
  | _ ->
      assert false

(* ASSUME: Input must be normal form *) (* TODO: remove this assumption *)
and eval top_funs val_env ce label_env t =
  let dbg = 0=0 && (match t.desc with Const _ | BinOp _ | Not _ | Fun _ | Event _  | Var _  | App(_, []) -> false | _ -> true) in
  Debug.printf "@[ORIG: %a@\n  @[" Print.term t;
  let r =
  if dbg then
    if true then
      Debug.printf "Dom(VAL_ENV): %a@\n" (List.print Id.print) @@ List.map fst val_env
    else Debug.printf "VAL_ENV: %a@\n" print_val_env val_env;
  if dbg then Debug.printf "CE: %a@\n" (List.print Format.pp_print_int) ce;
  match t.desc with
  | Const _
  | BinOp _
  | Not _
  | Fun _
  | Event _ -> Closure(val_env, t), ce, []
  | Var x -> Id.assoc x val_env, ce, []
  | App(t, []) -> eval top_funs val_env ce label_env t
  | App(t1, ts) ->
      let ts',t2 = List.decomp_snoc ts in
      let ans1, ce1, paths1 = eval top_funs val_env ce label_env @@ make_app t1 ts' in
      begin
        try
          let ans2, ce2, paths2 = eval top_funs val_env ce1 label_env t2 in
          eval_app top_funs val_env ce2 label_env ans1 paths1 ans2 paths2
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
            let t23 = if br = 0 then t2 else t3 in
            let paths' =
              match label with
              | None -> []
              | Some label -> [List.assoc label label_env, [br]]
            in
            try
              eval top_funs val_env ce' label_env t23
              |> append_paths paths'
            with Exception(ans, ce, paths) -> raise (Exception(ans, ce, merge_paths paths' paths))
      end
  | Let(Nonrecursive, [f,xs,t1], t2) ->
      let ans, ce, paths = eval top_funs val_env ce label_env @@ make_funs xs t1 in
      if ans = Fail then
        (ans, ce, paths)
      else
        let val_env' = (f, ans)::val_env in
        eval top_funs val_env' ce label_env t2
        |> append_paths paths
  | Let(Recursive, [f,xs,t1], t2) ->
      assert (xs <> []);
      let rec val_env' = (f, Closure(val_env', make_funs xs t1))::val_env in
      eval top_funs val_env' ce label_env t2
  | Raise t ->
      let ans, ce', paths' = eval top_funs val_env ce label_env t in
      raise (Exception(ans, ce', paths'))
  | TryWith(t1, t2) ->
      begin
        try
          eval top_funs val_env ce label_env t1
        with Exception(ans1, ce, paths1) ->
             let ans2, ce, paths2 = eval top_funs val_env ce label_env t2 in
             eval_app top_funs val_env ce label_env ans2 paths2 ans1 paths1
      end
  | Tuple ts ->
      let rec aux t (anss,ce,paths) =
        match anss with
        | Fail::_ -> anss, ce, paths
        | _ ->
            let ans, ce', paths' = eval top_funs val_env ce label_env t in
            ans::anss, ce', merge_paths paths' paths
      in
      let anss, ce', paths' = List.fold_right aux ts ([],ce,[]) in
      let ans =
        if List.hd anss = Fail then
          Fail
        else
          VTuple anss
      in
      if ce' <> ce then unsupported "Check_mod.eval tuple";
      ans, ce', paths'
  | Proj(i, t) ->
      let ans, ce, paths = eval top_funs val_env ce label_env t in
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
      unsupported "Check_mod.eval"
  in
  if dbg then
    Format.printf"@]@\nRETURN: %a@\n@]" Print.term (value_of @@ Triple.fst r);
  r

type result =
  | Typable of Ref_type.env
  | Untypable of ce_set

let add_context prog f typ =
  let {fun_typ_env=env; fun_def_env=fun_env} = prog in
  let dbg = 0=0 in
  if dbg then Debug.printf "ADD_CONTEXT prog: %a@." print_prog prog;
  if dbg then Debug.printf "ADD_CONTEXT: %a :? %a@." Print.id f Ref_type.print typ;
  let fs =
    let xs,t = Id.assoc f fun_env in
    List.Set.diff ~eq:Id.eq (get_fv t) (f::xs)
  in
(*
  let label_env = List.mapi (fun i f -> f, i) fs in
  let label_env = [f, 0] in
 *)
  let label_env =
    Id.assoc f fun_env
    |> snd
    |@dbg&> Format.printf "AC body: %a@." Print.term
    |> make_label_env f
    |@dbg&> Format.printf "AC Dom(label_env): %a@." (List.print Id.print) -| List.map fst
  in
  let af = "Assert_failure" in
  let etyp = Type(["exn", TVariant (prog.exn_decl@[af,[]])], "exn") in
  let typ_exn = Encode.typ_of Encode.all etyp in
  let make_fail typ =
    make_raise (make_construct af [] etyp) typ
    |> Encode.all
  in
  let t' =
    unit_term
    |> Trans.ref_to_assert ~typ_exn ~make_fail @@ Ref_type.Env.of_list [f,typ]
    |@dbg&> Format.printf "ADD_CONTEXT t: %a@." Print.term
    |> normalize
    |@dbg&> Format.printf "ADD_CONTEXT t': %a@." Print.term
  in
  let fun_env' =
    env
    |> Ref_type.Env.filter_key (Id.mem -$- fs)
    |> Ref_type.Env.to_list
    |> List.map (Pair.map_snd @@ decomp_funs -| Triple.trd -| Ref_type_gen.generate (Some typ_exn) ~make_fail [] [])
    |@dbg&> Format.printf "ADD_CONTEXT fun_env': %a@." Modular_syntax.print_def_env
  in
  let fun_env'' =
    List.map (Pair.map_snd @@ Pair.map_snd normalize) fun_env' @
    [f, Pair.map_snd (add_label (List.assoc f label_env) label_env -| normalize) @@ Id.assoc f fun_env]
  in
  if dbg then Format.printf "ADD_CONTEXT fun_env'': %a@." Modular_syntax.print_def_env fun_env'';
  t', fun_env'', List.map Pair.swap label_env

let complete_ce_set f t ce =
  let let_fun_var = make_col [] (@@@) in
  let let_fun_var_desc desc =
    match desc with
    | Let(flag,bindings,t) ->
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


let check prog f typ =
  Debug.printf "MAIN_LOOP prog: %a@." print_prog prog;
  let {fun_typ_env=env; fun_def_env=fun_env} = prog in
  let t,fun_env',label_env = add_context prog f typ in
  let top_funs = List.map fst fun_env' in
  Debug.printf "  Check %a : %a@." Id.print f Ref_type.print typ;
  Debug.printf "  t: %a@." Print.term_typ t;
  let make_pps spec =
    let open Main_loop in
    preprocesses spec
    |> preprocess_and_after CPS
  in
  let (result, make_get_rtyp, set_target'), main, set_target =
    t
    |> make_letrecs (List.map Triple.of_pair_r fun_env')
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
      if !!Debug.check then Main_loop.report_unsafe main sol set_target;
      Debug.printf "  Untypable@.@.";
      Debug.printf "    CE_INIT: %a@\n" (List.print Format.pp_print_int) ce_single;
      Debug.printf "    LABEL_ENV: %a@\n" (List.print @@ Pair.print Format.pp_print_int Id.print) label_env;
      Debug.printf "    TOP_FUNS: %a@\n" (List.print Id.print) top_funs;
      let ans,ce_single',ce =
        let val_env = List.fold_left (fun val_env (f,(xs,t)) -> let rec val_env' = (f, Closure(val_env', make_funs xs t))::val_env in val_env') [] fun_env' in
        try
          eval top_funs val_env ce_single label_env t
        with Exception(ans, ce, paths) -> Fail, ce, paths
      in
      Debug.printf "  CE: %a@\n" print_ce ce;
      assert (ans = Fail);
      assert (ce_single' = []);
      let ce_set = (f, complete_ce_set f (snd @@ Id.assoc f fun_env) ce) :: List.map (fun (f,(xs,t)) -> make_init_ce_set f t) fun_env in
      Debug.printf "  PATHS': %a@\n" print_ce_set ce_set;
      Untypable ce_set
  | CEGAR.Unsafe _ -> assert false
