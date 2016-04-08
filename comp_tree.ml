open Util
open Syntax
open Term_util
open Type

module RT = Rose_tree

let debug () = List.mem "Comp_tree" !Flag.debug_module

type label =
  | Term of typed_term
  | Assume of typed_term
  | Bind of (id * typed_term) list
  | Fail
type t = label RT.t

let print_label fm = function
  | Term t -> Print.term fm t
  | Assume t -> Format.fprintf fm "Assume: %a" Print.term t
  | Bind map ->
      let pr fm (x,t) = Format.fprintf fm "%a := %a" Id.print x Print.term t in
      Format.fprintf fm "%a" (List.print pr) map
  | Fail -> Format.fprintf fm "Fail"
let rec print fm (Rose_tree.Node(l,ts)) =
  Format.fprintf fm "(@[<hov 2>%a,@ %a@])" print_label l (List.print print) ts

let make_fix f xs t =
  make_letrec [f, xs, t] @@ make_var f
let decomp_fix t =
  match t.desc with
  | Let(Recursive, [f, xs, t'], {desc=Var g}) when f = g -> Some (f, xs, t')
  | _ -> None
let is_fix t = decomp_fix t <> None

let get_arg_num = List.length -| Triple.snd -| Option.get -| decomp_fix


let counter = Counter.create ()
let new_label () = Counter.gen counter

let add_label = make_trans2 ()
let add_label_term (f,l) t =
  let t' = add_label.tr2_term_rec (f,l) t in
  match t.desc with
  | Var g when Id.same f g -> add_id l t'
  | If(t1, t2, t3) -> add_id l t'
  | _ -> t'
let () = add_label.tr2_term <- add_label_term
let add_label = add_label.tr2_term
let get_label t = get_id t

let is_fail t =
  match t.desc with
  | App({desc=Event("fail",_)}, [_]) -> true
  | _ -> false

let exists_fail ts = List.exists is_fail ts

let append_path path rs =
  List.map (Triple.map_trd @@ (@) path) rs

(* check v_env for fix *)
let rec from_term fun_env v_env ce_set ce_env t : t list =
  let f = if !!debug then fun f -> print_begin_end f else (!!) in
  f (fun () ->
  match t.desc with
  | BinOp(And, _, _) -> assert false
  | BinOp(Or, _, _) -> assert false
  | Const _
  | Var _
  | BinOp _
  | Not _
  | Fun _
  | Event _
  | Bottom -> [RT.leaf (Term t)]
  | _ when is_fail t -> [RT.leaf Fail]
  | App({desc=Var f}, ts) when Id.mem_assoc f v_env ->
      if !!debug then Format.printf "[APP1: %a@\n" Print.term t;
      let ys,t_f = Id.assoc f v_env in
      if ys = [] then
        (assert (Option.is_some @@ decomp_var t_f);
        [RT.Node(Term t, from_term fun_env v_env ce_set ce_env @@ make_app t_f ts)])
      else
        let ys' = List.map Id.new_var_id ys in
        if !!debug then Format.printf "[APP1: %a, %d@\n" Print.term t_f (List.length ts);
        let t_f' = List.fold_right2 subst_var ys ys' t_f in
        let arg_map = List.combine ys' ts in
        let v_env' = List.map (Pair.map_snd decomp_funs) arg_map @ v_env in
        [RT.Node(Term t, [RT.Node(Bind arg_map, from_term fun_env v_env' ce_set ce_env t_f')])]
  | App({desc=Var f}, ts) when Id.mem_assoc f fun_env ->
      if !!debug then Format.printf "[APP2,%a@\n" Id.print f;
      let ys,t_f = Id.assoc f fun_env in
      assert (List.length ys = List.length ts);
      let label = new_label () in
      if !!debug then Format.printf "[label: %d@\n" label;
      let f' = Id.new_var_id f in
      let t_f' = add_label (f',label) @@ subst_var f f' t_f in
      let t' = make_app (add_id label @@ make_var f') ts in
      let aux path =
        let v_env' = (f',(ys,t_f'))::v_env in
        let ce_env' = (label,path)::ce_env in
        from_term fun_env v_env' ce_set ce_env' t'
      in
      let paths = List.assoc_all ~cmp:Id.eq f ce_set in
      let merge children (RT.Node(t'',children')) =
        assert (Term t' = t'');
        children @ children'
      in
      [RT.Node(Term t', List.fold_left merge [] @@ List.flatten_map aux paths)]
  | App _ ->
      assert false
  | If(t1, t2, t3) ->
      let label = get_label t in
      let ce,ce_env' = List.decomp_assoc label ce_env in
      if !!debug then Format.printf "[IF: %a, %a@\n" (List.print Format.pp_print_int) ce Print.term t1;
      begin
        match ce with
        | [] -> []
        | br::ce' ->
            if !!debug then Format.printf "[CE[%d]: %a@\n" label (List.print Format.pp_print_int) ce;
            let cond,t23 = if br = 0 then t1, t2 else make_not t1, t3 in
            let ce_env'' = (label,ce')::ce_env' in
            if !!debug then Format.printf "[t23: %a@\n" Print.term t23;
            [RT.Node(Term t, [RT.Node(Assume cond, from_term fun_env v_env ce_set ce_env'' t23)])]
      end
  | Let(flag, [f,xs,t1], t2) ->
      let v_env' = (f,(xs,t1))::v_env in
      [RT.Node(Bind [f, make_funs xs t1], from_term fun_env v_env' ce_set ce_env t2)]
  | _ ->
      if !!debug then Format.printf "%a@." Print.term t;
      unsupported "Comp_tree.from_term"
  )
let from_term fun_env ce_set t = from_term fun_env [] ce_set [] t



let from_program fun_env (ce_set: (id * int list) list) main =
  make_app (make_var main) [make_var @@ Id.new_var ~name:"v0" TInt]
  |> from_term fun_env ce_set
  |> List.get
  |@> Format.printf "@.@.%a@." print
