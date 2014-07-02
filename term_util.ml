open Util
open Syntax
open Type


let debug () = List.mem "Trans" !Flag.debug_module


let occur = Syntax.occur
let get_vars_pat = Syntax.get_vars_pat
let get_fv = Syntax.get_fv

(*** TERM CONSTRUCTORS ***)

let typ_result = TConstr("X", false)
let typ_event = TFun(Id.new_var "" TUnit, TUnit)
let typ_event' = TFun(Id.new_var "" TUnit, typ_result)
let typ_event_cps =
  let u = Id.new_var "" TUnit in
  let r = Id.new_var "" TUnit in
  let k = Id.new_var "" (TFun(r,typ_result)) in
    TFun(u, TFun(k, typ_result))
let typ_excep_init = TConstr("exn",true)
let typ_excep = ref typ_excep_init

let dummy_var = Id.make (-1) "" TInt
let abst_var = Id.make (-1) "v" typ_unknown
let abst_var_int = Id.set_typ abst_var TInt
let abst_var_bool = Id.set_typ abst_var TBool
let length_var =
  let x = Id.make (-1) "l" (TList typ_unknown) in
    Id.make (-1) "length" (TFun(x, TInt))

let unit_term = {desc=Const Unit; typ=TUnit}
let true_term = {desc=Const True;typ=TBool}
let false_term = {desc=Const False;typ=TBool}
let cps_result = {desc=Const CPS_result; typ=typ_result}
let fail_term = {desc=Event("fail",false);typ=typ_event}
let fail_term_cps = {desc=Event("fail",false);typ=typ_event'}
let randint_term = {desc=RandInt false; typ=TFun(Id.new_var "" TUnit,TInt)}
let randint_unit_term = {desc=App(randint_term,[unit_term]); typ=TInt}
let randbool_unit_term =
  {desc=BinOp(Eq, {desc=App(randint_term, [unit_term]);typ=TInt}, {desc=Const(Int 0);typ=TInt}); typ=TBool}
let make_bottom typ = {desc=Bottom;typ=typ}
let make_event s = {desc=Event(s,false);typ=typ_event}
let make_event_cps s = {desc=Event(s,true);typ=typ_event_cps}
let make_var x = {desc=Var x; typ=Id.typ x}
let make_int n = {desc=Const(Int n); typ=TInt}
let make_randvalue typ = {desc=RandValue(typ,false); typ=TFun(Id.new_var "" TUnit,typ)}
let make_randvalue_unit typ = {desc=App(make_randvalue typ, [unit_term]); typ=typ}
let make_randvalue_cps typ =
  let u = Id.new_var "" TUnit in
  let r = Id.new_var "" typ in
  let k = Id.new_var "" (TFun(r,typ_result)) in
  {desc=RandValue(typ,true); typ=TFun(u,TFun(k,typ_result))}
let make_randint_cps () =
  let u = Id.new_var "" TUnit in
  let r = Id.new_var "" TInt in
  let k = Id.new_var "" (TFun(r,typ_result)) in
  {desc=RandInt true; typ=TFun(u,TFun(k,typ_result))}
let rec make_app t ts =
  match t,ts with
  | t,[] -> t
  | {desc=App(t1,ts1);typ=TFun(x,typ)}, t2::ts2 ->
      if not (not Flag.check_typ || Type.can_unify (Id.typ x) t2.typ)
      then
        begin
          Format.printf "make_app:@ %a@ <=/=>@ %a@.%a@.%a@."
                        print_typ (Id.typ x)
                        print_typ t2.typ
                        print_term t
                        print_term t2;
          assert false
        end;
      make_app {desc=App(t1,ts1@[t2]); typ=typ} ts2
  | {typ=TFun(x,typ)}, t2::ts
  | {typ=TPred({Id.typ=TFun(x,typ)},_)}, t2::ts ->
      if not (not Flag.check_typ || Type.can_unify (Id.typ x) t2.typ)
      then (Color.printf Color.Red "make_app:@ %a@ <=/=>@ %a,@.fun: %a@.arg: %a@."
                         print_typ (Id.typ x)
                         print_typ t2.typ
                         print_term' t
                         print_term' t2;
            assert false);
      make_app {desc=App(t,[t2]); typ=typ} ts
  | _ when not Flag.check_typ -> {desc=App(t,ts); typ=typ_unknown}
  | _ ->
      Format.printf "Untypable(make_app): %a@." print_term' {desc=App(t,ts);typ=typ_unknown};
      assert false
let make_lets bindings t2 =
  List.fold_right
    (fun binding t2 ->
       {desc=Let(Nonrecursive,[binding],t2); typ=t2.typ})
    bindings
    t2
let make_let_f flag bindings t2 =
  if bindings = []
  then t2
  else
    let rec aux (f,xs,t) =
      match t.desc with
          Fun(x,t') -> aux (f, xs@[x], t')
        | _ -> f, xs, t
    in
    let bindings' = List.map aux bindings in
      {desc=Let(flag,bindings',t2); typ=t2.typ}
let make_lets_f bindings t2 =
  List.fold_right (fun (flag,binding) -> make_let_f flag [binding]) bindings t2
let make_let bindings t2 = make_let_f Nonrecursive bindings t2
let make_letrec bindings t2 = make_let_f Recursive bindings t2
let make_seq t1 t2 =
  match t1.desc with
  | Const _
  | Var _ -> t2
  | _ -> make_let [Id.new_var "u" t1.typ, [], t1] t2
let make_loop typ =
  let u = Id.new_var "u" TUnit in
  let f = Id.new_var "loop" (TFun(u,typ)) in
  let t = make_app (make_var f) [make_var u] in
  make_letrec [f, [u], t] (make_app (make_var f) [unit_term])
let make_fail typ = make_seq (make_app fail_term [unit_term]) @@ make_bottom typ
let make_fun x t = {desc=Fun(x,t); typ=TFun(x,t.typ)}
let make_not t = {desc=Not t; typ=TBool}
let make_and t1 t2 =
  if t1 = true_term
  then t2
  else
    if t1 = false_term
    then false_term
    else
      if t2 = true_term
      then t1
      else {desc=BinOp(And, t1, t2); typ=TBool}
let make_or t1 t2 =
  if t1 = true_term
  then true_term
  else
    if t1 = false_term
    then t2
    else {desc=BinOp(Or, t1, t2); typ=TBool}
let make_add t1 t2 = {desc=BinOp(Add, t1, t2); typ=TInt}
let make_sub t1 t2 = {desc=BinOp(Sub, t1, t2); typ=TInt}
let make_mul t1 t2 = {desc=BinOp(Mult, t1, t2); typ=TInt}
let make_neg t = make_sub (make_int 0) t
let make_if_ t1 t2 t3 =
  assert (not Flag.check_typ || Type.can_unify t1.typ TBool);
  assert (not Flag.check_typ || Type.can_unify t2.typ t3.typ);
  match t1.desc with
  | Const True -> t2
  | Const False -> t3
  | _ ->
      let typ =
        match has_pred t2.typ, has_pred t3.typ with
          false, false -> t2.typ
        | true, false -> t2.typ
        | false, true -> t3.typ
        | true, true ->
            if t2.typ <> t3.typ
            then Format.printf "@[<hv 2>Warning: if-branches have different types@ %a and@ %a@]@." print_typ t2.typ print_typ t3.typ;
            t2.typ
      in
      {desc=If(t1, t2, t3); typ=typ}
let make_branch t2 t3 =
  assert (not Flag.check_typ || Type.can_unify t2.typ t3.typ);
  {desc=Branch(t2, t3); typ=t2.typ}
let make_eq t1 t2 =
  assert (not Flag.check_typ || Type.can_unify t1.typ t2.typ);
  {desc=BinOp(Eq, t1, t2); typ=TBool}
let make_neq t1 t2 =
  make_not (make_eq t1 t2)
let make_lt t1 t2 =
  assert (true || not Flag.check_typ || Type.can_unify t1.typ TInt);
  assert (true || not Flag.check_typ || Type.can_unify t2.typ TInt);
  {desc=BinOp(Lt, t1, t2); typ=TBool}
let make_gt t1 t2 =
  assert (true || not Flag.check_typ || Type.can_unify t1.typ TInt);
  assert (true || not Flag.check_typ || Type.can_unify t2.typ TInt);
  {desc=BinOp(Gt, t1, t2); typ=TBool}
let make_leq t1 t2 =
  assert (true || not Flag.check_typ || Type.can_unify t1.typ TInt);
  assert (true || not Flag.check_typ || Type.can_unify t2.typ TInt);
  {desc=BinOp(Leq, t1, t2); typ=TBool}
let make_geq t1 t2 =
  assert (true || not Flag.check_typ || Type.can_unify t1.typ TInt);
  assert (true || not Flag.check_typ || Type.can_unify t2.typ TInt);
  {desc=BinOp(Geq, t1, t2); typ=TBool}
let make_fst t = {desc=Fst t; typ=fst_typ t.typ}
let make_snd t = {desc=Snd t; typ=snd_typ t.typ}
let make_tpair ?(s="x") typ1 typ2 = TPair(Id.new_var s typ1, typ2)
let make_pair ?(s="x") t1 t2 = {desc=Pair(t1,t2); typ=make_tpair ~s t1.typ t2.typ}
let make_nil typ = {desc=Nil; typ=TList typ}
let make_nil2 typ = {desc=Nil; typ=typ}
let make_cons t1 t2 =
  assert (not Flag.check_typ || Type.can_unify (TList t1.typ) t2.typ);
  {desc=Cons(t1,t2); typ=t2.typ}
let make_pany typ = {pat_desc=PAny; pat_typ=typ}
let make_pvar x = {pat_desc=PVar x; pat_typ=Id.typ x}
let make_pconst t = {pat_desc=PConst t; pat_typ=t.typ}
let make_ppair p1 p2 = {pat_desc=PPair(p1, p2); pat_typ=TPair(Id.new_var "x" p1.pat_typ, p2.pat_typ)}
let make_pnil typ = {pat_desc=PNil; pat_typ=TList typ}
let make_pnil2 typ = {pat_desc=PNil; pat_typ=typ}
let make_pcons p1 p2 = {pat_desc=PCons(p1,p2); pat_typ=p2.pat_typ}
let make_match t1 pats = {desc=Match(t1,pats); typ=(fun (_,_,t) -> t.typ) (List.hd pats)}
let make_single_match t1 p t2 =
  make_match t1 [p, true_term, t2; make_pany p.pat_typ, true_term, make_fail t2.typ]
let rec make_nth i n t =
  match i,n with
  | 0,1 -> t
  | 0,_ -> make_fst t
  | _ -> make_nth (i-1) (n-1) (make_snd t)
let make_assert t = make_if_ t unit_term (make_app fail_term [unit_term])
let make_assume t1 t2 = make_if_ t1 t2 (make_bottom t2.typ)
let make_label info t = {desc=Label(info,t); typ=t.typ}
let make_ref t = {desc=Ref t; typ=TRef t.typ}
let make_deref t = {desc=Deref t; typ=ref_typ t.typ}
let make_setref r t = {desc=SetRef(r, t); typ=TUnit}

let imply t1 t2 = {desc=BinOp(Or, {desc=Not t1;typ=TBool}, t2); typ=TBool}
let and_list ts = match ts with
    [] -> {desc=Const True; typ=TBool}
  | [t] -> t
  | t::ts -> List.fold_left (fun t1 t2 -> {desc=BinOp(And,t1,t2);typ=TBool}) t ts

let make_eq_dec t1 t2 =
  assert (not Flag.check_typ || Type.can_unify t1.typ t2.typ);
  let aux t =
    match t.desc with
    | Var x -> make_var x, Std.identity
    | _ ->
        let x = Id.new_var "x" t.typ in
        make_var x, make_let [x,[],t]
  in
  let rec make t1 t2 =
    match t1.typ with
    | TBool
    | TInt -> make_eq t1 t2
    | TPair _ -> make_and (make (make_fst t1) (make_fst t2)) (make (make_snd t1) (make_snd t2))
    | _ -> assert false
  in
  let t1',k1 = aux t1 in
  let t2',k2 = aux t2 in
  k1 @@ k2 @@ make t1' t2'


let rec make_term typ =
  match elim_tpred typ with
    TUnit -> unit_term
  | TBool -> true_term
  | TInt -> make_int 0
  | TFun(x,typ) -> make_fun x (make_term typ)
  | TPair(x,typ) -> make_pair (make_term @@ Id.typ x) (make_term typ)
  | TConstr("X", false) -> cps_result
  | TList typ' -> make_nil typ'
  | _ -> Format.printf "ERROR:@.%a@." Syntax.print_typ typ; assert false


let none_flag = false_term
let some_flag = true_term
(*
let none_flag = make_int 0
let some_flag = make_int 1
 *)
let opt_typ typ = TPair(Id.new_var "x" none_flag.typ, typ)
let get_opt_typ typ = snd_typ typ
let is_none t =
  match t.desc with
  | Pair(t1,t2) -> t1 = none_flag
  | _ -> false
let make_none typ = make_pair none_flag (make_term typ)
let make_some t = make_pair some_flag t
let make_is_none t = make_eq (make_fst t) none_flag
let make_is_some t = make_not (make_is_none t)
let make_get_val t = make_snd t
let decomp_is_none t =
  match t.desc with
  | BinOp(Eq, {desc=Fst t1}, t2) when t2 = none_flag -> Some t1
  | _ -> None
let decomp_get_val t =
  match t.desc with
  | Snd t -> Some t
  | _ -> None
let decomp_some t =
  match t.desc with
  | Pair(t1,t2) when t1 = some_flag -> Some t2
  | _ -> None

let make_tuple ts =
  match ts with
  | []
  | [_] -> raise (Invalid_argument "make_tuple")
  | t::ts' -> List.fold_left (make_pair) t ts'
let rec decomp_tuple top t =
  match t.desc with
  | Pair(t1,t2) -> t1 :: decomp_tuple false t2
  | _ when top -> raise (Invalid_argument "decomp_tuple")
  | _ -> [t]
let decomp_tuple = decomp_tuple true

let make_ttuple typs =
  match typs with
  | []
  | [_] -> raise (Invalid_argument "tuple_typ")
  | typ::typs' -> List.fold_left (make_tpair) typ typs'
let rec decomp_ttuple top typ =
  match typ with
    TPair(x,typ) -> Id.typ x :: decomp_ttuple false typ
  | _ when top -> raise (Invalid_argument "make_tuple")
  | _ -> [typ]
let decomp_ttuple = decomp_ttuple true

let make_proj i t =
  let n = List.length @@ decomp_ttuple t.typ in
  let t' = repeat make_snd (i-1) t in
  if i = n then t' else make_fst t'


(*** AUXILIARY FUNCTIONS ***)

let rec decomp_fun = function
    {desc=Fun(x,t)} ->
      let xs,t' = decomp_fun t in
        x::xs, t'
  | t -> [], t

let rec decomp_let t =
  match t.desc with
  | Let(flag, bindings, t2) ->
      let fbindings,t2' = decomp_let t2 in
      (flag,bindings)::fbindings, t2'
  | _ -> [], t


let get_int = make_col [] (@@@)

let get_int_term t =
  match t.desc with
  | Const (Int n) -> [n]
  | _ -> get_int.col_term_rec t

let get_int_typ typ = []

let () = get_int.col_term <- get_int_term
let () = get_int.col_typ <- get_int_typ
let get_int t = List.unique @@ get_int.col_term t




let rec get_args = function
  | TFun(x,typ) -> x :: get_args typ
  | _ -> []

let rec get_argvars = function
  | TFun(x,typ) -> x :: get_argvars (Id.typ x) @ get_argvars typ
  | _ -> []

let rec get_argtyps = function
  | TFun(x,typ) -> Id.typ x :: get_argtyps typ
  | _ -> []

let arg_num typ = List.length (get_args typ)



let is_poly_typ = make_col false (||)

let is_poly_typ_typ typ =
  match typ with
  | TVar{contents=None} -> true
  | TPred(x,_) -> is_poly_typ.col_var x
  | _ -> is_poly_typ.col_typ_rec typ

let () = is_poly_typ.col_typ <- is_poly_typ_typ
let is_poly_typ = is_poly_typ.col_typ



let subst = make_trans2 ()

(* [x |-> t], [t/x] *)
let subst_term (x,t) t' =
  match t'.desc with
  | Var y when Id.same x y -> t
  | Fun(y, t1) when Id.same x y -> t'
  | Let(Nonrecursive, bindings, t2) ->
      let aux (f,xs,t1) =
        subst.tr2_var (x,t) f,
        List.map (subst.tr2_var (x,t)) xs,
        if List.exists (Id.same x) xs then t1 else subst.tr2_term (x,t) t1 in
      let bindings' = List.map aux bindings in
      let t2' =
        if List.exists (fun (f,_,_) -> Id.same f x) bindings
        then t2
        else subst.tr2_term (x,t) t2
      in
      make_let bindings' t2'
  | Let(Recursive, bindings, t2) when List.exists (fun (f,_,_) -> Id.same f x) bindings -> t'
  | Let(Recursive, bindings, t2) ->
      let aux (f,xs,t1) =
        subst.tr2_var (x,t) f,
        List.map (subst.tr2_var (x,t)) xs,
        if List.exists (Id.same x) xs then t1 else subst.tr2_term (x,t) t1
      in
      let bindings' = List.map aux bindings in
      let t2' = subst.tr2_term (x,t) t2 in
      make_letrec bindings' t2'
  | Match(t1,pats) ->
      let aux (pat,cond,t1) =
        let xs = get_vars_pat pat in
        if List.exists (Id.same x) xs
        then pat, cond, t1
        else pat, subst.tr2_term (x,t) cond, subst.tr2_term (x,t) t1
      in
      make_match (subst.tr2_term (x,t) t1) (List.map aux pats)
  | _ -> subst.tr2_term_rec (x,t) t'


let subst_int = make_trans2 ()

let subst_int_term (n,t) t' =
  match t'.desc with
  | Const (Int m) when n = m -> t
  | Const (Int m) -> make_add t @@ make_int (m-n)
  | _ -> subst_int.tr2_term_rec (n,t) t'

let () = subst_int.tr2_term <- subst_int_term
let subst_int n t t' = subst_int.tr2_term (n,t) t'


let subst_map = make_trans2 ()

let subst_map_term map t =
  match t.desc with
  | Var y -> if Id.mem_assoc y map then Id.assoc y map else t
  | Fun(y, t1) ->
      let map' = List.filter (fun (x,_) -> not (Id.same x y)) map in
      let t1' = subst_map.tr2_term map' t1 in
      make_fun y t1'
  | Let(Nonrecursive, bindings, t2) ->
      let rec aux map acc = function
          [] -> map, List.rev acc
        | (f,xs,t1)::bindings ->
            let map' = List.filter (fun (x,_) -> not (Id.mem x xs)) map in
            aux map' ((f, xs, subst_map.tr2_term map' t1)::acc) bindings in
      let map',bindings' = aux map [] bindings in
      let t2' = subst_map.tr2_term map' t2 in
      make_let bindings' t2'
  | Let(Recursive, bindings, t2) ->
      let map' = List.filter (fun (x,_) -> not (List.exists (fun (f,_,_) -> Id.same f x) bindings)) map in
      let aux (f,xs,t1) =
        let map'' = List.filter (fun (x,_) -> not (Id.mem x xs)) map' in
        f, xs, subst_map.tr2_term map'' t1
      in
      let bindings' = List.map aux bindings in
      let t2' = subst_map.tr2_term map' t2 in
      make_letrec bindings' t2'
  | Match(t1,pats) -> (* TODO: fix *)
      let aux (pat,cond,t1) = pat, cond, subst_map.tr2_term map t1 in
      {desc=Match(subst_map.tr2_term map t1, List.map aux pats); typ=t.typ}
  | _ -> subst_map.tr2_term_rec map t

let () = subst_map.tr2_term <- subst_map_term
let subst_map = subst_map.tr2_term


let () = subst.tr2_term <- subst_term
let subst_type x t typ = subst.tr2_typ (x,t) typ
let subst x t1 t2 = subst.tr2_term (x,t1) t2
let subst_var x y t = subst x (make_var y) t






let max_pat_num = make_col 0 max

let max_pat_num_term t =
  match t.desc with
  | Match(t,pats) ->
      let m = max (List.length pats) (max_pat_num.col_term t) in
      let aux acc (_,cond,t) = max acc (max (max_pat_num.col_term t) (max_pat_num.col_term cond)) in
      List.fold_left aux m pats
  | _ -> max_pat_num.col_term_rec t

let () = max_pat_num.col_term <- max_pat_num_term
let max_pat_num = max_pat_num.col_term





let is_parameter x = Fpat.Util.String.starts_with (Id.name x) Flag.extpar_header


let rec is_value t =
  match t.desc with
  | Const _ | Var _ | Nil -> true
  | _ -> false



let rec merge_typ typ1 typ2 =
  match typ1,typ2 with
  | TVar{contents=Some typ1}, typ2
  | typ1, TVar{contents=Some typ2} -> merge_typ typ1 typ2
  | TVar({contents=None}), _ -> typ2
  | _, TVar({contents=None}) -> typ1
  | TUnit, TUnit -> TUnit
  | TBool, TBool -> TBool
  | TInt, TInt -> TInt
  | TPred(x1,ps1), TPred(x2,ps2) ->
      let typ = merge_typ (Id.typ x1) (Id.typ x2) in
      let x1' = Id.set_typ x1 typ in
      let x1_no_pred = Id.set_typ x1 (elim_tpred typ) in
      let ps2' = List.map (subst x2 (make_var x1_no_pred)) ps2 in
      TPred(x1', ps1 @@@ ps2')
  | TPred(x, ps), typ
  | typ, TPred(x, ps) -> TPred(Id.set_typ x (merge_typ (Id.typ x) typ), ps)
  | TFun(x1,typ1), TFun(x2,typ2) ->
      let x_typ = merge_typ (Id.typ x1) (Id.typ x2) in
      let x = Id.new_var (Id.name x1) x_typ in
      let typ = merge_typ (subst_type x1 (make_var x) typ1) (subst_type x2 (make_var x) typ2) in
      TFun(x, typ)
  | TList typ1, TList typ2 -> TList(merge_typ typ1 typ2)
  | TPair(x1,typ1), TPair(x2,typ2) ->
      let x_typ = merge_typ (Id.typ x1) (Id.typ x2) in
      let x = Id.new_var (Id.name x1) x_typ in
      let typ = merge_typ (subst_type x1 (make_var x) typ1) (subst_type x2 (make_var x) typ2) in
      TPair(x, typ)
  | _ when typ1 = typ_unknown -> typ2
  | _ when typ2 = typ_unknown -> typ1
  | TConstr _, TConstr _ -> assert (typ1 = typ2); typ1
  | TOption typ1, TOption typ2 -> TOption (merge_typ typ1 typ2)
  | _ -> Format.printf "typ1:%a, typ2:%a@." print_typ typ1 print_typ typ2; assert false


let make_if t1 t2 t3 =
  assert (not Flag.check_typ || Type.can_unify t1.typ TBool);
  if Flag.check_typ && not (Type.can_unify t2.typ t3.typ)
  then Format.printf "%a <=/=> %a@." print_typ t2.typ print_typ t3.typ;
  assert (not Flag.check_typ || Type.can_unify t2.typ t3.typ);
  match t1.desc with
  | Const True -> t2
  | Const False -> t3
  | _ -> {desc=If(t1, t2, t3); typ=merge_typ t2.typ t3.typ}

let rec get_top_funs acc = function
    {desc=Let(flag, defs, t)} ->
      let acc' = List.fold_left (fun acc (f,_,_) -> f::acc) acc defs in
        get_top_funs acc' t
  | _ -> acc
let get_top_funs = get_top_funs []

let rec get_top_funs acc = function
    {desc=Let(flag, defs, t)} ->
      let acc' = List.fold_left (fun acc (f,_,_) -> f::acc) acc defs in
        get_top_funs acc' t
  | _ -> acc
let get_top_funs = get_top_funs []


let rec get_typ_default = function
  | TUnit -> unit_term
  | TBool -> true_term
  | TAbsBool -> assert false
  | TInt -> make_int 0
  | TRInt _ -> assert false
  | TVar _ -> assert false
  | TFun(x,typ) -> make_fun x (get_typ_default typ)
  | TList typ -> make_nil typ
  | TPair(x,typ) -> make_pair ~s:(Id.name x) (get_typ_default (Id.typ x)) (get_typ_default typ)
  | TConstr(s,b) -> assert false
  | TPred _ -> assert false
  | TRef _ -> assert false
  | TOption typ -> {desc=TNone; typ=typ}




let has_no_effect = make_col true (&&)

let has_no_effect_term t =
  match t.desc with
  | App _ -> false
  | Branch _ -> false
  | Let(_,bindings,t) ->
      has_no_effect.col_term t && List.for_all (fun (f,xs,t) -> xs <> [] || has_no_effect.col_term t) bindings
  | Proj _ -> false
  | SetField _ -> false
  | Raise _ -> false
  | Bottom -> false
  | Ref _ -> false
  | Deref _ -> false
  | SetRef _ -> false
  | _ -> has_no_effect.col_term_rec t

let () = has_no_effect.col_term <- has_no_effect_term
let has_no_effect = has_no_effect.col_term



let rec is_simple_aexp t =
  if t.typ <> TInt
  then false
  else
    match t.desc with
      Const _ -> true
    | Var _ -> true
    | BinOp(_, t1, t2) -> is_simple_aexp t1 && is_simple_aexp t2
    | _ -> false

and is_simple_bexp t =
  if t.typ <> TInt
  then false
  else
    match t.desc with
      Const _ -> true
    | Var _ -> true
    | BinOp(_, t1, t2) ->
        is_simple_bexp t1 && is_simple_bexp t2 ||
        is_simple_aexp t1 && is_simple_aexp t2
    | Not t -> is_simple_bexp t
    | _ -> false



let same_list same xs ys = List.length xs = List.length ys && List.for_all2 same xs ys

let rec same_const = (=)
and same_term t1 t2 = same_desc t1.desc t2.desc
and same_desc t1 t2 =
  match t1,t2 with
  | Const c1, Const c2 -> same_const c1 c2
  | RandInt b1, RandInt b2 -> b1 = b2
  | RandValue _, RandValue _ -> unsupported "same_term 1 "
  | Var x, Var y -> Id.same x y
  | Fun(x,t1), Fun(y,t2) -> Id.same x y && same_term t1 t2
  | App(t1,ts1), App(t2,ts2) -> same_list same_term (t1::ts1) (t2::ts2)
  | If(t11,t12,t13), If(t21,t22,t23) -> same_term t11 t21 && same_term t12 t22 && same_term t13 t23
  | Branch(t11,t12), Branch(t21,t22) -> same_term t11 t21 && same_term t12 t22
  | Let(flag1,bindings1,t1), Let(flag2,bindings2,t2) ->
     let same_binding (f,xs,t1) (g,ys,t2) = Id.same f g && same_list Id.same xs ys && same_term t1 t2 in
     flag1 = flag1 && same_list same_binding bindings1 bindings2 && same_term t1 t2
  | BinOp(op1,t11,t12), BinOp(op2,t21,t22) -> op1 = op2 && same_term t11 t21 && same_term t12 t22
  | Not t1, Not t2 -> same_term t1 t2
  | Event(s1,b1), Event(s2,b2) -> s1 = s2 && b1 = b2
  | Record _, Record _ -> unsupported "same_term 2"
  | Proj _, Proj _ -> unsupported "same_term 3"
  | SetField _, SetField _ -> unsupported "same_term 4"
  | Nil, Nil -> true
  | Cons _, Cons _ -> unsupported "same_term 5"
  | Constr _, Constr _ -> unsupported "same_term 6"
  | Match _, Match _ -> unsupported "same_term 7"
  | Raise _, Raise _ -> unsupported "same_term 8"
  | TryWith _, TryWith _ -> unsupported "same_term 9"
  | Pair(t11,t12), Pair(t21,t22) -> same_term t11 t21 && same_term t12 t22
  | Fst t1, Fst t2 -> same_term t1 t2
  | Snd t1, Snd t2 -> same_term t1 t2
  | Bottom, Bottom -> true
  | Label _, Label _ -> unsupported "same_term 11"
  | _ -> false

and same_info i1 i2 = unsupported "same_term"
and same_type_kind k1 k2 = unsupported "same_term"

and same_typed_pattern p1 p2 = same_pattern p1.desc p2.desc
and same_pattern p1 p2 = unsupported "same_term"

let same_term' t1 t2 = try same_term t1 t2 with _ -> false


let rec var_name_of_term t =
  match t.desc, elim_tpred t.typ with
  | Var x, _       -> Id.name x
  | _,     TUnit   -> "u"
  | _,     TBool   -> "b"
  | _,     TInt    -> "n"
  | _,     TFun _  -> "f"
  | _,     TPair _ -> "p"
  | App _, _       -> "r"
  | Fst t, _       -> var_name_of_term t ^ "_l"
  | Snd _, _       -> var_name_of_term t ^ "_r"
  | Fun _, _       -> assert false
  | _,     _       -> "x"

let var_of_term t = Id.new_var (var_name_of_term t) t.typ

let is_dependend t x = Id.mem x @@ get_fv t



let col_same_term = make_col2 [] (@@@)

let col_same_term_term t1 t2 =
  let b = try same_term t1 t2 with _ -> false in
  if b then [t2] else col_same_term.col2_term_rec t1 t2

let () = col_same_term.col2_term <- col_same_term_term
let col_same_term = col_same_term.col2_term



let col_info_id = make_col [] (@@@)

let col_info_id_desc desc =
  match desc with
  | Label(InfoId x, t) -> x::col_info_id.col_term t
  | _ -> col_info_id.col_desc_rec desc

let () = col_info_id.col_desc <- col_info_id_desc
let col_info_id = col_info_id.col_term



let subst_rev = make_trans2 ()

(* [t1 |-> x] *)
let subst_rev_term (t1,x) t2 =
  if same_term' t1 t2 || t1 = t2
  then make_var x
  else subst_rev.tr2_term_rec (t1,x) t2

let () = subst_rev.tr2_term <- subst_rev_term
let subst_rev t1 x t2 = subst_rev.tr2_term (t1,x) t2


(* replace t1 with t2 in t3 *)
let replace_term t1 t2 t3 =
  let x = Id.new_var "x" t1.typ in
  subst x t2 @@ subst_rev t1 x t3


let get_bound_variables = make_col [] (@@@)

let get_bound_variables_desc desc =
  match desc with
  | Fun(x,t) -> x :: get_bound_variables.col_term t
  | Let(flag,bindings,t) ->
      let aux (f,xs,t) =
        f::xs @@@ get_bound_variables.col_term t
      in
      get_bound_variables.col_term t @@@ List.rev_map_flatten aux bindings
  | _ -> get_bound_variables.col_desc_rec desc

let () = get_bound_variables.col_desc <- get_bound_variables_desc
let get_bound_variables = get_bound_variables.col_term

let is_id_unique t =
  let bv = get_bound_variables t in
  let rec check xs =
    match xs with
    | [] -> true
    | x::xs' ->
        if Id.mem x xs'
        then (Format.printf "%a" Id.print x; false)
        else check xs'
  in
  check bv
(*
  List.length bv = List.length (List.unique ~cmp:Id.same bv)
*)



let rec is_bottom_def flag f xs t =
  match flag, xs, t.desc with
  | Recursive, _::_, App({desc=Var g},ts) ->
      Id.same f g && List.for_all has_no_effect ts
  | _ -> false
