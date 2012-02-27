open ExtList
open Term

(** Logical formulas *)

(** {6 Constructors} *)

(** tautology *)
let ttrue = Const([], Const.True)
(** contradiction *)
let tfalse = Const([], Const.False)

let band ts =
  let rec aux ts =
    match ts with
      [] -> Const([], Const.True)
    | [t] -> t
    | (Const(_, Const.True))::ts' -> aux ts'
    | t::ts' ->
        let t' = aux ts' in
        (match t' with
          Const(_, Const.True) ->
            t
        | _ ->
            apply (Const([], Const.And)) [t; t'])
  in
  aux (List.unique ts)

let bor ts =
  let rec aux ts =
    match ts with
      [] -> Const([], Const.False)
    | [t] -> t
    | (Const(_, Const.False))::ts' -> aux ts'
    | t::ts' ->
        let t' = aux ts' in
        (match t' with
          Const(_, Const.False) ->
            t
        | _ ->
            apply (Const([], Const.Or)) [t; t'])
  in
  aux (List.unique ts)

let bnot t =
  match fun_args t with
    Const(a, Const.True), [] -> Const(a, Const.False)
  | Const(a, Const.False), [] -> Const(a, Const.True)
  | Const(a, Const.Not), [t] -> t
  | _ -> apply (Const([], Const.Not)) [t]

let imply t1 t2 =
  if Term.equiv t1 ttrue then
    t2
  else if Term.equiv t1 tfalse then
    ttrue
  else if Term.equiv t2 ttrue then
    ttrue
  else if Term.equiv t2 tfalse then
    bnot t1
  else
    apply (Const([], Const.Imply)) [t1; t2]

let forall env t =
  let xs = fvs t in
(*
  let _ = Format.printf "env: %a@.xs: %a@." (Util.pr_list SimType.pr_bind ",") env (Util.pr_list Var.pr ",") xs in
*)
  let env = List.filter (fun (x, _) -> List.mem x xs) env in
  if env = [] then t else Forall([], env, t)

let exists env t =
  let xs = fvs t in
(*
  let _ = Format.printf "env: %a@.xs: %a@." (Util.pr_list SimType.pr_bind ",") env (Util.pr_list Var.pr ",") xs in
*)
  let env = List.filter (fun (x, _) -> List.mem x xs) env in
  if env = [] then t else Exists([], env, t)
(*
  bnot (forall env (bnot t))
*)

let iff t1 t2 =
  if Term.equiv t1 t2 then
    ttrue
  else
    apply (Const([], Const.Iff)) [t1; t2]

let iff2 t1 t2 =
  if Term.equiv t1 t2 then
    ttrue
  else
    band [imply t1 t2; imply t2 t1]

let eqUnit t1 t2 = apply (Const([], Const.EqUnit)) [t1; t2]
let neqUnit t1 t2 = apply (Const([], Const.NeqUnit)) [t1; t2]
let eqBool t1 t2 = apply (Const([], Const.EqBool)) [t1; t2]
let neqBool t1 t2 = apply (Const([], Const.NeqBool)) [t1; t2]
let eqInt t1 t2 = apply (Const([], Const.EqInt)) [t1; t2]
let neqInt t1 t2 = apply (Const([], Const.NeqInt)) [t1; t2]
(** ignore equalities of functions *)
let eq_ty ty t1 t2 =
  match ty with
    SimType.Unit ->
      eqUnit t1 t2
  | SimType.Bool ->
      eqBool t1 t2
  | SimType.Int ->
      eqInt t1 t2
  | SimType.Fun(_, _) ->
      ttrue(*???assert false*)
(*
  | _ ->
      let _ = Format.printf "%a@." SimType.pr ty in
      assert false
*)
(*let neq t1 t2 = apply (Const([], Const.Not)) [apply (Const([], Const.Eq)) [t1; t2]]*)
let lt t1 t2 = apply (Const([], Const.Lt)) [t1; t2]
let gt t1 t2 = apply (Const([], Const.Gt)) [t1; t2]
let leq t1 t2 = apply (Const([], Const.Leq)) [t1; t2]
let geq t1 t2 = apply (Const([], Const.Geq)) [t1; t2]
(*let gt t1 t2 = apply (Const([], Const.Lt)) [t2; t1]*)
(*let leq t1 t2 = apply (Const([], Const.Or)) [lt t1 t2; eq t1 t2]*)
(*let geq t1 t2 = apply (Const([], Const.Or)) [gt t1 t2; eq t1 t2]*)
let ibrel c t1 t2 = apply (Const([], c)) [t1; t2]

(** ignore equalities of functions *)
let eq_xtty (x, t, ty) =
  eq_ty ty (make_var x) t

let forall_imply conds_envs t =
  List.fold_right
    (fun (cond, env) t ->
      (*
      let _ = Format.printf "cond: %a@.xs: %a@." pr cond (Util.pr_list Var.pr ", ") xs in
      *)
      match cond, env, t with
        App([], App([], Const([], c), Var([], x)), t'), [y, _], _
        when (c = Const.EqBool || c = Const.EqInt) && Var.equiv x y && not (List.mem x (fvs t')) ->
          subst (fun z -> if Var.equiv z x then t' else raise Not_found) t
      (*
      | _, [y], App([], App([], Const([], Const.Eq), t1), App([], App([], Const([], Const.Add), t2), Var([], x)))
        when Var.equiv x y ->
          (* is this sound for any case??? *)
          subst (fun z -> if Var.equiv z x then sub t1 t2 else raise Not_found) cond
        *)
      | _ -> forall env (imply cond t))
    conds_envs t

(** {6 Basic functions} *)

let rec atoms t =
  match fun_args t with
    Var(_, _), [] ->
      [t]
  | Const(_, Const.True), []
  | Const(_, Const.False), [] ->
      []
  | Const(_, Const.And), [t1; t2]
  | Const(_, Const.Or), [t1; t2]
  | Const(_, Const.Imply), [t1; t2]
  | Const(_, Const.Iff), [t1; t2] ->
      atoms t1 @ atoms t2
  | Const(_, Const.Not), [t] -> 
      atoms t
  | Const(_, bop), [_; _] ->
      [t]
  | t, _->
      Format.printf "@.%a@." Term.pr t; assert false

let rec conjuncts t =
  match fun_args t with
    Const(_, Const.And), [t1; t2] ->
      conjuncts t1 @ conjuncts t2
  | _, _ -> [t]

let rec disjuncts t =
  match fun_args t with
    Const(_, Const.Or), [t1; t2] ->
      disjuncts t1 @ disjuncts t2
  | _, _ -> [t]

let of_aif (c, nxs, n) =
  match c with
    Const.EqInt ->
      eqInt (LinArith.term_of (nxs, n)) (tint 0)
  | Const.NeqInt ->
      neqInt (LinArith.term_of (nxs, n)) (tint 0)
  | Const.Lt ->
      lt (LinArith.term_of (nxs, n)) (tint 0)
  | Const.Gt ->
      gt (LinArith.term_of (nxs, n)) (tint 0)
  | Const.Leq ->
      leq (LinArith.term_of (nxs, n)) (tint 0)
  | Const.Geq ->
      geq (LinArith.term_of (nxs, n)) (tint 0)

(** ensure: () is eliminated if a unit variable does not occur in t
    ensure: "t1 =b t2" and "t1 <>b t2" are eliminated by replacing them with "t1 iff t2" and "not (t1 iff t2)" respectively.
    ToDo: check whether they are actually ensured *)
let rec simplify t =
(*
  Format.printf "%a@." Term.pr t;
*)
  match fun_args t with
    Var(_, _), [] ->
      t
  | Const(_, Const.True), [] ->
      ttrue
  | Const(_, Const.False), [] ->
      tfalse
  | Const(attr, Const.Not), [t] ->
      (match fun_args t with
        Var(_, _), [] ->
          bnot t
      | Const(_, Const.True), [] ->
          tfalse
      | Const(_, Const.False), [] ->
          ttrue
      | Const(_, Const.Not), [t] ->
          simplify t
      | Const(attr, Const.And), [t1; t2] ->
          simplify (bor [bnot t1; bnot t2])
      | Const(attr, Const.Or), [t1; t2] ->
          simplify (band [bnot t1; bnot t2])
      | Const(attr, Const.Imply), [t1; t2] ->
          simplify (band [t1; bnot t2])
      | Const(attr, Const.Iff), [t1; t2] ->
          simplify (bor [band [t1; bnot t2]; band [bnot t1; t2]])
      | Const(attr, c), [t1; t2] when Const.is_ibrel c ->
          simplify (ibrel (Const.bnot_ibrel c) t1 t2)
      | Const(attr, Const.EqUnit), [t1; t2] ->
          simplify (neqUnit t1 t2)
      | Const(attr, Const.NeqUnit), [t1; t2] ->
          simplify (eqUnit t1 t2)
      | Const(attr, Const.EqBool), [t1; t2] ->
          simplify (eqBool t1 t2)
      | Const(attr, Const.NeqBool), [t1; t2] ->
          simplify (neqBool t1 t2)
      | Forall(attr, env, t), [] ->
          simplify (exists env (bnot t))
      | Exists(attr, env, t), [] ->
          simplify (forall env (bnot t))
      | _ ->
          let _ = Format.printf "not %a@." pr t in
          assert false)
  | Const(attr, Const.And), [t1; t2] ->
      band (simplify_conjuncts (conjuncts (band [simplify t1; simplify t2])))
  | Const(attr, Const.Or), [t1; t2] ->
      bor (simplify_disjuncts (disjuncts (bor [simplify t1; simplify t2])))
  | Const(attr, Const.Imply), [t1; t2] ->
      simplify (bor [bnot t1; t2])
  | Const(attr, Const.Iff), [t1; t2] ->
      simplify (bor [band [t1; t2]; band [bnot t1; bnot t2]])
  | Const(attr, c), [t1; t2] when Const.is_ibrel c ->
      (try
        LinArith.term_of_aif (LinArith.aif_of t)
      with Invalid_argument _ ->
        try
          ParLinArith.term_of_aif (ParLinArith.aif_of t)
        with Invalid_argument _ ->
          try
            NonLinArith.term_of_aif (NonLinArith.aif_of t)
          with Invalid_argument _ ->
            assert false)
  | Const(attr, Const.EqUnit), [t1; t2] ->
      if t1 = t2 then
        ttrue
      else
        eqUnit t1 t2
  | Const(attr, Const.NeqUnit), [t1; t2] ->
      if t1 = t2 then
        tfalse
      else
        neqUnit t1 t2
  | Const(attr, Const.EqBool), [t1; t2] ->
      let t1 = simplify t1 in
      let t2 = simplify t2 in
      if t1 = t2 then
        ttrue
      else
        iff2 t1 t2
  | Const(attr, Const.NeqBool), [t1; t2] ->
      let t1 = simplify t1 in
      let t2 = simplify t2 in
      if t1 = t2 then
        tfalse
      else
        bnot (iff2 t1 t2)
  | Forall(a, env, t), [] ->
      Forall(a, env, simplify t)
  | Exists(a, env, t), [] ->
      Exists(a, env, simplify t)
  | _ ->
      let _ = Format.printf "%a@." pr t in
      assert false
      (*LinArith.simplify t*)
and simplify_conjuncts ts =
(*
  let _ = Format.printf "%a@." (Util.pr_list Term.pr ",") ts in
*)
  let ts = List.unique ts in
  if List.mem tfalse ts then
    [tfalse]
  else
    let ts = List.filter (fun t -> t <> ttrue) ts in
    let aifs, ts = Util.partition_map (fun t -> try `L(LinArith.aif_of t) with Invalid_argument _ -> `R(t)) ts in
    let aifss =
      Util.classify
        (fun (_, nxs1, n1) (_, nxs2, n2) ->
          LinArith.equiv (nxs1, n1) (nxs2, n2) ||
          LinArith.equiv (nxs1, n1) (LinArith.minus (nxs2, n2)))
        aifs
    in
    let aifs =
		    List.map
		      (fun ((c1, nxs1, n1)::aifs) ->
		        let cs = List.map (fun (c2, nxs2, n2) -> if LinArith.equiv (nxs1, n1) (nxs2, n2) then c2 else Const.minus_ibrel c2) aifs in
		        let c = List.fold_left Const.cand c1 cs in
		        c, nxs1, n1)
		      aifss
    in
    if true then
				  let sub, ts' =
        Util.partition_map
          (function
            (Const.EqInt, [1, x], n) ->
              `L(x, Term.tint (-n))
          | (Const.EqInt, [-1, x], n) ->
              `L(x, Term.tint n)
          | aif ->
              `R(LinArith.term_of_aif aif))
          aifs
      in
				  let ts =
        List.map
          (fun t ->
            let t' = simplify (subst (fun x -> List.assoc x sub) t) in
            (*
            Format.printf "%a@." Term.pr t';
            *)
            if t' = ttrue || t' = tfalse then t' else t)
          (ts' @ ts)
      in
				  let ts = List.map (fun (x, t) -> eqInt (make_var x) t) sub @ ts in
(*
      let _ = Format.printf "%a@." (Util.pr_list Term.pr ",") ts in
*)
      ts
    else
      List.map LinArith.term_of_aif aifs @ ts
and simplify_disjuncts ts =
  let ts = List.unique ts in
  if List.mem ttrue ts then
    [ttrue]
  else
    let ts = List.filter (fun t -> t <> tfalse) ts in
    let aifs, ts = Util.partition_map (fun t -> try `L(LinArith.aif_of t) with Invalid_argument _ -> `R(t)) ts in
    let aifss =
      Util.classify
        (fun (_, nxs1, n1) (_, nxs2, n2) ->
          LinArith.equiv (nxs1, n1) (nxs2, n2) ||
          LinArith.equiv (nxs1, n1) (LinArith.minus (nxs2, n2)))
        aifs
    in
    let aifs =
		    List.map
		      (fun ((c1, nxs1, n1)::aifs) ->
		        let cs = List.map (fun (c2, nxs2, n2) -> if LinArith.equiv (nxs1, n1) (nxs2, n2) then c2 else Const.minus_ibrel c2) aifs in
		        let c = List.fold_left Const.cor c1 cs in
		        c, nxs1, n1)
		      aifss
    in
    List.map LinArith.term_of_aif aifs @ ts

(** {6 Functions on DNF formulas} *)

let rec dnf t =
  match fun_args t with
    Var(_, _), [] ->
      [[t]]
  | Const(_, Const.True), [] ->
      [[]]
  | Const(_, Const.False), [] ->
      []
  | Const(_, Const.And), [t1; t2] ->
      let tss1 = dnf t1 in
      Util.concat_map (fun ts2 -> List.map (fun ts1 -> ts1 @ ts2) tss1) (dnf t2)
  | Const(_, Const.Or), [t1; t2] ->
      dnf t1 @ dnf t2
  | Const(_, Const.Imply), [t1; t2] ->
      dnfn t1 @ dnf t2
  | Const(_, Const.Iff), [t1; t2] ->
      raise (Util.NotImplemented "Formula.dnf")
  | Const(_, Const.Not), [t] -> 
      dnfn t
  | Const(_, bop), [_; _] ->
      [[t]]
  | t, _-> Format.printf "@.%a@." Term.pr t; assert false
and dnfn t =
  match fun_args t with
    Var(_, _), [] ->
      [[t]]
  | Const(_, Const.True), [] ->
      []
  | Const(_, Const.False), [] ->
      [[]]
  | Const(_, Const.And), [t1; t2] ->
      dnfn t1 @ dnfn t2
  | Const(_, Const.Or), [t1; t2] ->
      let tss1 = dnfn t1 in Util.concat_map (fun ts2 -> List.map (fun ts1 -> ts1 @ ts2) tss1) (dnfn t2)
  | Const(_, Const.Imply), [t1; t2] ->
      let tss1 = dnf t1 in Util.concat_map (fun ts2 -> List.map (fun ts1 -> ts1 @ ts2) tss1) (dnfn t2)
  | Const(_, Const.Iff), [t1; t2] ->
      raise (Util.NotImplemented "Formula.dnfn")
  | Const(_, Const.Not), [t] -> 
      dnf t
  | Const(a, bop), [t1; t2] ->
      let c = Const.bnot_ibrel bop in
      (match c with
        Const.NeqInt ->
          [[lt t1 t2]; [gt t1 t2]]
      | _ ->
          [[ibrel c t1 t2]])
  | t, _-> Format.printf "@.%a@." Term.pr t; assert false

let formula_of_dnf tss =
  bor (List.map band tss)

(** {6 Functions on formulas with explicit substitutions} *)

(** ignore equalities on functions *)
let formula_of_fes (ts, xttys) = band (ts @ List.map eq_xtty xttys)

(** eliminate as many existentially quantified variables as possible
    @param p variables not satifying p are existentially quantified
    ignore equalities on functions *)
let eqelim_fes p (ts, xttys) =
  let flag = false in
  let pr_xtty ppf (x, t, _) =
    Format.fprintf ppf "%a -> %a" Var.pr x Term.pr t
  in
  let _ = if flag then Format.printf "sub: %a@." (Util.pr_list pr_xtty ", ") xttys in
  let xttys1, xttys2 = List.partition (fun (x, _, _) -> p x) xttys in
  let sub x = List.assoc x (List.map (fun (x, t, _) -> x, t) xttys2) in
  let ts =
    List.map
      (fun t ->
        Util.fixed_point
          (fun t ->
            let _ = if flag then Format.printf "before: %a@." pr t in
            let t = simplify (subst sub t) in
            let _ = if flag then Format.printf "after: %a@." pr t in
            t)
          (fun t1 t2 -> Term.equiv t1 t2)
          t)
      ts
  in
  let xttys1 =
    List.map
      (fun xtty ->
        Util.fixed_point
          (fun (x, t, ty) ->
            (*Format.printf "%a@." pr t;*)
            x, subst sub t, ty)
          (fun (x1, t1, ty1) (x2, t2, ty2) ->
            x1 = x2 && Term.equiv t1 t2 && ty1 = ty2)
          xtty)
      xttys1
  in
  let rec aux xttys (xttys1, xttys2) =
    match xttys with
      [] ->
        (xttys1, xttys2)
    | (x, t, ty)::xttys ->
        (match t with
          Var(_, y)
            when not (p y) &&
                 not (List.exists (fun (x, _, _ ) -> Var.equiv y x) xttys2) ->
            aux xttys (xttys1, (y, make_var x, ty)::xttys2)
        | _ ->
            aux xttys ((x, t, ty)::xttys1, xttys2))
  in
  let xttys11, xttys12 = aux xttys1 ([], []) in
  let sub x = List.assoc x (List.map (fun (x, t, _) -> x, t) xttys12) in
  let ts =
    List.map
      (fun t ->
        Util.fixed_point
          (fun t ->
            (*Format.printf "%a@." pr t;*)
            subst sub t)
          (fun t1 t2 -> Term.equiv t1 t2)
          t)
      (ts @ List.map eq_xtty xttys11)
  in
  let ts = Util.concat_map conjuncts ts in
  band ts

(*
let eqelim p (ts, xttys) =
  let xttys1, xttys2 = List.partition (fun (x, _, _) -> p x) xttys in
  let sub x = List.assoc x (List.map (fun (x, t, _) -> x, t) xttys2) in
  Util.fixed_point
    (fun t ->
      (*Format.printf "%a@." pr t;*)
      subst sub t)
    (fun t1 t2 -> equiv t1 t2)
    (band (ts @ List.map eq_xtty xttys1))
*)

(** {6 Other functions} *)

(** ensure: the result does not use =u, (), and unit variables *)
let elim_unit t =
  let uvs = List.unique (fvs_ty SimType.Unit t SimType.Bool) in
  if uvs = [] then
    t
  else
    let sub x = if List.mem x uvs then tunit else raise Not_found in
    simplify (subst sub t)

(** require: ts are formulas
    ensure: the result does not use =b *)
let elim_boolean ts =
  let _ = assert (ts <> []) in
  let bvs = List.unique (Util.concat_map (fun t -> fvs_ty SimType.Bool t SimType.Bool) ts) in
  if bvs = [] then
    [ts],
    function [t] -> t | _ -> assert false
  else
    let subs = Util.multiply_list_list (@) (List.map (fun b -> [[b, ttrue]; [b, tfalse]]) bvs) in
    List.map
      (fun sub ->
         List.map (fun t -> simplify (subst (fun x -> List.assoc x sub) t)) ts)
      subs,
    fun ts ->
      bor (List.map2 (fun t sub -> band (t::(List.map (fun (b, t) -> eqBool (make_var b) t) sub))) ts subs)

let rec elim_neq_int t =
  match fun_args t with
    Var(attr, x), [] ->
      Var(attr, x)
  | Const(attr, Const.NeqInt), [t1; t2] ->
      bor [lt t1 t2; gt t1 t2]
  | Const(attr, c), ts ->
      apply (Const(attr, c)) (List.map elim_neq_int ts)

let rec elim_eq_neq_int t =
  match fun_args t with
    Var(attr, x), [] ->
      Var(attr, x)
  | Const(attr, Const.EqInt), [t1; t2] ->
      band [leq t1 t2; geq t1 t2]
  | Const(attr, Const.NeqInt), [t1; t2] ->
      bor [lt t1 t2; gt t1 t2]
  | Const(attr, c), ts ->
      apply (Const(attr, c)) (List.map elim_eq_neq_int ts)

let rec eqelim p ts =
  try
    let ts1, xtty, ts2 =
      Util.find_split_map
        (fun t ->
          try
            (*let c, nxs, n = LinArith.aif_of t in
            if c = Const.EqInt then
              (try
                let nxs1, (n', x), nxs2 = Util.find_split (fun (n, x) -> not (p x) && (n = 1 || n = -1)) nxs in
                if n' = 1 then
                  Some(x, LinArith.term_of (LinArith.minus (nxs1 @ nxs2, n)), SimType.Int)
                else if n' = -1 then
                  Some(x, LinArith.term_of (nxs1 @ nxs2, n), SimType.Int)
                else
                  assert false
              with Not_found ->
                None)
            else
              None*)
            (* the result may be non-linear even if t is not *)
            let c, nxs, n = ParLinArith.aif_of t in
            if c = Const.EqInt then
              (try
                let nxs1, (n', x), nxs2 = Util.find_split (fun (n, x) -> not (p x) && (Term.equiv n (tint 1) || Term.equiv n (tint (-1)))) nxs in
                if int_of n' = 1 then
                  Some(x, ParLinArith.term_of (ParLinArith.minus (nxs1 @ nxs2, n)), SimType.Int)
                else if int_of n' = -1 then
                  Some(x, ParLinArith.term_of (nxs1 @ nxs2, n), SimType.Int)
                else
                  assert false
              with Not_found ->
                None)
            else
              None
          with Invalid_argument _ ->
            (match fun_args t with
              Const(_, Const.EqUnit), [Var(_, x); t] when not (p x) && not (List.mem x (fvs t)) ->
                Some(x, t, SimType.Unit)
            | Const(_, Const.EqUnit), [t; Var(_, x)] when not (p x) && not (List.mem x (fvs t)) ->
                Some(x, t, SimType.Unit)
            | Const(_, Const.EqBool), [Var(_, x); t] when not (p x) && not (List.mem x (fvs t)) ->
                Some(x, t, SimType.Bool)
            | Const(_, Const.EqBool), [t; Var(_, x)] when not (p x) && not (List.mem x (fvs t)) ->
                Some(x, t, SimType.Bool)
            | _ ->
                None))
        ts
    in
    (* simplify possibly makes the return value huge, e.g. ICFP2012 intro3
       ToDo: control size increase*)
    List.map simplify (eqelim p (conjuncts (simplify (eqelim_fes p (ts1 @ ts2, [xtty])))))
  with Not_found ->
    ts

let rec split_ibrel c ts =
  match ts with
    [] -> assert false
  | [t] -> apply (Const([], c)) [t; tint 0]
  | t::ts ->
      (match c with
        Const.EqInt ->
          bor (List.map (fun t -> eqInt t (tint 0)) (t::ts))
      | Const.NeqInt ->
          band (List.map (fun t -> neqInt t (tint 0)) (t::ts))
      | Const.Lt
      | Const.Gt ->
          bor [band [gt t (tint 0); split_ibrel c ts]; band [lt t (tint 0); split_ibrel (Const.minus_ibrel c) ts]]
      | Const.Leq
      | Const.Geq ->
          bor [band [geq t (tint 0); split_ibrel c ts]; band [leq t (tint 0); split_ibrel (Const.minus_ibrel c) ts]]
      | _ -> assert false)

let rec linearize t =
  match fun_args t with
    Const(attr, Const.True), [] ->
      Const(attr, Const.True)
  | Const(attr, Const.False), [] ->
      Const(attr, Const.False)
  | Const(attr, Const.Not), [t] ->
      bnot (linearize t)
  | Const(attr, Const.And), [t1; t2] ->
      band [linearize t1; linearize t2]
  | Const(attr, Const.Or), [t1; t2] ->
      bor [linearize t1; linearize t2]
  | Const(attr, c), [_; _] when Const.is_ibrel c ->
      (try
        let _ = LinArith.aif_of t in
        t
      with Invalid_argument _ ->
        try
          let c, nxs, n = ParLinArith.aif_of t in
          let ts = ParLinArith.factorize (nxs, n) in
          let ts = List.filter (fun t -> not (Term.equiv t (tint 1))) ts in
          split_ibrel c ts
        with Invalid_argument _ ->
          let c, pol = NonLinArith.aif_of t in
          let ts = NonLinArith.factorize pol in
          let ts = List.filter (fun t -> not (Term.equiv t (tint 1))) ts in
          split_ibrel c ts)
  | Forall(a, env, t), [] ->
      Forall(a, env, linearize t)
  | Exists(a, env, t), [] ->
      Exists(a, env, linearize t)
  | _ -> assert false

let rec is_linear t =
  match fun_args t with
    Var(_, _), [] ->
      true
  | Const(_, Const.True), [] ->
      true
  | Const(_, Const.False), [] ->
      true
  | Const(_, Const.Not), [t] ->
      is_linear t
  | Const(_, Const.And), [t1; t2]
  | Const(_, Const.Or), [t1; t2]
  | Const(_, Const.Imply), [t1; t2]
  | Const(_, Const.Iff), [t1; t2] ->
      is_linear t1 && is_linear t2
  | Const(_, c), [_; _] when Const.is_ibrel c ->
      (try
        let _ = LinArith.aif_of t in
        true
      with Invalid_argument _ ->
        false)
  | Const(_, Const.EqUnit), [_; _]
  | Const(_, Const.NeqUnit), [_; _]
  | Const(_, Const.EqBool), [_; _]
  | Const(_, Const.NeqBool), [_; _] ->
      true
  | Forall(_, _, t), []
  | Exists(_, _, t), [] ->
      is_linear t
  | _ ->
      let _ = Format.printf "%a@." pr t in
      assert false

let rec elim_minus t =
  match fun_args t with
    Const(attr, Const.True), [] ->
      Const(attr, Const.True)
  | Const(attr, Const.False), [] ->
      Const(attr, Const.False)
  | Const(attr, Const.Not), [t] ->
      bnot (elim_minus t)
  | Const(attr, Const.And), [t1; t2] ->
      band [elim_minus t1; elim_minus t2]
  | Const(attr, Const.Or), [t1; t2] ->
      bor [elim_minus t1; elim_minus t2]
  | Const(attr, Const.Imply), [t1; t2] ->
      imply (elim_minus t1) (elim_minus t2)
  | Const(attr, Const.Iff), [t1; t2] ->
      iff (elim_minus t1) (elim_minus t2)
  | Const(attr, c), [_; _] when Const.is_ibrel c ->
      (try
        (* assume that the result does not contain Sub, Minus, negative integers *)
        NonLinArith.term_of_aif (NonLinArith.aif_of t)
      with Invalid_argument _ ->
        assert false)
  | Forall(a, env, t), [] ->
      Forall(a, env, elim_minus t)
  | Exists(a, env, t), [] ->
      Exists(a, env, elim_minus t)
  | _ -> assert false
