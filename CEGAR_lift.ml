open Util
open CEGAR_syntax
open CEGAR_type
open CEGAR_util

module Debug = Debug.Make(struct let check = make_debug_check __MODULE__ end)

let rename_if f x =
  if f x then
    rename_id x
  else
    x

let lift_aux lift_unused f xs t1 =
  let ys,t1' = decomp_fun t1 in
  let xs' =
    if lift_unused then
      xs
    else
      List.Set.inter xs (List.Set.diff (get_fv t1) ys)
  in
  let ys' = List.map (rename_if @@ List.mem -$- xs) ys in
  xs' @ ys',
  List.fold_right2 subst_var ys ys' t1',
  make_app (Var f) @@ List.map _Var xs'

let rec lift_term lift_unused xs t =
  match t with
  | Const c -> [], Const c
  | Var x -> [], Var x
  | App(t1,t2) ->
      let defs1,t1' = lift_term lift_unused xs t1 in
      let defs2,t2' = lift_term lift_unused xs t2 in
      defs1@@@defs2, App(t1',t2')
  | Let(f,t1,t2) ->
      let f' = rename_id f in
      let xs',t1',lifted = lift_aux lift_unused f' xs t1 in
      let defs1,t1'' = lift_term lift_unused xs' t1' in
      let defs2,t2' = lift_term lift_unused xs @@ subst f lifted t2 in
      (f',xs',Const True,[],t1'') :: defs1 @ defs2, t2'
  | Fun _ ->
      let f' = new_id "f" in
      let xs',t',lifted = lift_aux lift_unused f' xs t in
      let defs,t'' = lift_term lift_unused xs' t' in
      (f',xs',Const True,[],t'') :: defs, lifted

let lift_def lift_unused (f,xs,t1,e,t2) =
  let ys,t2' = decomp_fun t2 in
  let xs' = xs@ys in
  let defs1,t1' = lift_term lift_unused xs t1 in
  let defs2,t2'' = lift_term lift_unused xs' t2' in
  (f, xs', t1', e, t2'')::defs1@defs2

let lift0 lift_unused {defs; main; info} =
  let defs = List.rev_flatten_map (lift_def lift_unused) defs in
  Typing.infer {env=[]; defs; main; info}

let lift prog = lift0 true prog
let lift2 prog = lift0 false prog
