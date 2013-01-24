open Util

module S = Syntax

type base =
    Unit
  | Bool
  | Int

type t =
    Base of base * S.id * S.typed_term
  | Fun of S.id * t * t
  | Pair of S.id * t * t
  | Inter of t list
  | Union of t list
  | ExtArg of S.id * t * t
  | List of S.id * S.typed_term * S.id * S.typed_term * t

let is_fun_typ = function
    Fun(_,_,_) ->
      true
  | _ ->
      false

let print_base fm = function
    Unit -> Format.pp_print_string fm "unit"
  | Bool -> Format.pp_print_string fm "bool"
  | Int -> Format.pp_print_string fm "int"

let rec occur x = function
    Base(_,_,p) -> List.exists (Id.same x) (S.get_fv p)
  | Fun(_,typ1,typ2) -> occur x typ1 || occur x typ2
  | Pair(_,typ1,typ2) -> occur x typ1 || occur x typ2
  | Inter typs
  | Union typs -> List.exists (occur x) typs
  | ExtArg(_,typ1,typ2) -> occur x typ1 || occur x typ2
  | List(_,p_len,_,p_i,typ) ->
      let aux p =  List.exists (Id.same x) (S.get_fv p) in
        aux p_len || aux p_i || occur x typ

let rec print fm = function
    Base(base,x,p) when p = S.true_term ->
      Format.fprintf fm "%a" print_base base
  | Base(Bool,x,p) when S.make_var x = p ->
      Format.fprintf fm "{true}"
  | Base(Bool,x,p) when S.make_not (S.make_var x) = p ->
      Format.fprintf fm "{false}"
  | Base(base,x,p) ->
      Format.fprintf fm "{%a:%a | %a}" Id.print x print_base base S.pp_print_term p
  | Fun(x, typ1, typ2) ->
      if occur x typ2
      then Format.fprintf fm "(@[<hov 4>%a:%a@ ->@ %a@])" Id.print x print typ1 print typ2
      else Format.fprintf fm "(@[<hov 4>%a@ ->@ %a@])" print typ1 print typ2
  | Pair(x, typ1, typ2) ->
      if occur x typ2
      then Format.fprintf fm "(@[%a:%a@ *@ %a@])" Id.print x print typ1 print typ2
      else Format.fprintf fm "(@[%a@ *@ %a@])" print typ1 print typ2
  | Inter [] -> Format.fprintf fm "Top"
  | Inter [typ] -> print fm typ
  | Inter typs -> Format.fprintf fm "(@[%a@])" (print_list print " /\\@ " false) typs
  | Union [] -> Format.fprintf fm "Bottom"
  | Union [typ] -> print fm typ
  | Union typs -> Format.fprintf fm "(@[%a@])" (print_list print " \\/@ " false) typs
  | ExtArg(x,typ1,typ2) ->
      Format.fprintf fm "(@[%a where %a:%a@])" print typ2 Id.print x print typ1
  | List(x,p_len,y,p_i,typ2) ->
      if List.exists (Id.same x) (S.get_fv p_i) || occur x typ2
      then
        if p_len = S.true_term
        then Format.fprintf fm "(@[list|%a|" Id.print x
        else Format.fprintf fm "(@[list|%a:%a|" Id.print x S.pp_print_term p_len
      else
        if p_len = S.true_term
        then Format.fprintf fm "(@[list"
        else Format.fprintf fm "(@[list|%a:%a|" Id.print x S.pp_print_term p_len;
      if occur y typ2
      then
        if p_i = S.true_term
        then Format.fprintf fm "[%a@]@ %a@])" Id.print y print typ2
        else Format.fprintf fm "[%a:%a@]@ %a@])" Id.print y S.pp_print_term p_i print typ2
      else
        if p_i = S.true_term
        then Format.fprintf fm " %a@])" print typ2
        else Format.fprintf fm "[%a:%a]@ %a@])" Id.print y S.pp_print_term p_i print typ2

let rec decomp_fun n typ =
  match typ with
      Base _
    | Pair _
    | Inter _
    | Union _
    | List _ -> assert (n=0); [], [], typ
    | Fun(x,typ1,typ2) ->
        if n <= 0
        then [], [], typ
        else
          let exts,typs,typ' = decomp_fun (n-1) typ2 in
            exts, (x,typ1)::typs, typ'
    | ExtArg(x,typ1,typ2) ->
        let exts,typs,typ' = decomp_fun n typ2 in
          (x,typ1)::exts, typs, typ'

let rec arg_num = function
    Base _ -> 0
  | Pair _ -> 0
  | Inter [] -> assert false
  | Inter (typ::_) -> arg_num typ
  | Union [] -> assert false
  | Union (typ::_) -> arg_num typ
  | Fun(_,_,typ2) -> 1 + arg_num typ2
  | ExtArg(_,_,typ2) -> arg_num typ2
  | List _ -> 0

let rec subst x t typ =
  match typ with
      Base(base,y,p) -> Base(base, y, S.subst x t p)
    | Fun(y,typ1,typ2) -> Fun(y, subst x t typ1, subst x t typ2)
    | Pair(y,typ1,typ2) -> Pair(y, subst x t typ1, subst x t typ2)
    | Inter typs -> Inter (List.map (subst x t) typs)
    | Union typs -> Union (List.map (subst x t) typs)
    | ExtArg(y,typ1,typ2) -> ExtArg(y, subst x t typ1, subst x t typ2)
    | List(y,p_len,z,p_i,typ) ->
        List(y, S.subst x t p_len, z, S.subst x t p_i, subst x t typ)

let rec rename var = function
    Base(base, x, p) ->
      let x' =
        match var with
            None -> Id.new_var (Id.name x) (Id.typ x)
          | Some y -> y
      in
        Base(base, x', S.subst x (S.make_var x') p)
  | Fun(x, typ1, (Fun(_, typ, _) as typ2)) when !Flag.web && is_fun_typ typ ->
      let x' = Id.new_var ("@" ^ Id.name x) (Id.typ x) in
      let typ2' = subst x (S.make_var x') typ2 in
        Fun(x', rename (Some x') typ1, rename None typ2')
  | Fun(x,typ1,typ2) ->
      let x' = Id.new_var (Id.name x) (Id.typ x) in
      let typ2' = subst x (S.make_var x') typ2 in
        Fun(x', rename (Some x') typ1, rename None typ2')
  | Pair(x,typ1,typ2) ->
      let x' = Id.new_var (Id.name x) (Id.typ x) in
      let typ2' = subst x (S.make_var x') typ2 in
        Pair(x', rename (Some x') typ1, rename None typ2')
  | Inter typs -> Inter (List.map (rename var) typs)
  | Union typs -> Union (List.map (rename var) typs)
  | ExtArg(x,typ1,typ2) ->
      let x' = Id.new_var (Id.name x) (Id.typ x) in
      let typ2' = subst x (S.make_var x') typ2 in
        ExtArg(x', rename (Some x') typ1, rename None typ2')
  | List(x,p_len,y,p_i,typ) ->
      let x' = Id.new_var (Id.name x) (Id.typ x) in
      let y' = Id.new_var (Id.name y) (Id.typ y) in
      let p_len' = S.subst x (S.make_var x') p_len in
      let p_i' = S.subst y (S.make_var y') p_i in
      let typ' = subst x (S.make_var x') typ in
      let typ'' = subst y (S.make_var y') typ' in
        List(x', p_len', y', p_i', rename None typ'')

let rename typ =
  Id.clear_counter ();
  rename None typ
