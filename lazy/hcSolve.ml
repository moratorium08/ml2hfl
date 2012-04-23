open ExtList
open ExtString
open Zipper
open CallTree
open HornClause

(** Horn clause solving *)

exception NoSolution

(** {6 Functions on solutions} *)

let pr_sol_elem ppf (pid, (xs, t)) =
  Format.fprintf ppf "@[<hov>%a =@ %a@]" Pred.pr (pid, List.map Term.make_var xs) Term.pr t

let pr_sol ppf sol =
  Format.fprintf ppf "@[<v>%a@]" (Util.pr_list pr_sol_elem "@,") sol


let lookup_sol (pid, ts) sol =
  Formula.simplify
    (Formula.band
		    (List.map
		      (fun (_, (xs, t)) ->
		        let sub = List.combine xs ts in
		        Term.subst (fun x -> List.assoc x sub) t)
		      (List.filter (fun (pid', _) -> pid = pid') sol)))

let merge_sol sol =
  List.map
    (fun (pid, xs) ->
      pid, (xs, lookup_sol (pid, List.map Term.make_var xs) sol))
    (List.map (fun ((pid, (xs, _))::_) -> pid, xs)
      (Util.classify (fun (pid1, _) (pid2, _) -> pid1 = pid2) sol))

(** {6 Functions for solving Horn clauses} *)

let lookup_lbs (pid, ts) lbs =
		let xs, t = List.assoc pid lbs in

		let fvs = Util.diff (List.unique (Term.fvs t)) xs in
		let sub = List.map (fun x -> x, Term.make_var (Var.new_var ())) fvs in
		let t = Term.subst (fun x -> List.assoc x sub) t in

		let sub = List.combine xs ts in
		Term.subst (fun x -> List.assoc x sub) t

let subst_lbs lbs (Hc(popt, ps, t)) =
  let _ = Global.log_begin "subst_lbs" in
  let t =
    let ts = List.map (fun (pid, ts) -> lookup_lbs (pid, ts) lbs) ps in
    Formula.band (t :: ts)
  in

  let t =
    let _ = Global.log_begin "simplifying formula" in
    let _ = Global.log (fun () -> Format.printf "input:@,  @[<v>%a@]@," Term.pr t) in

    let bvs = match popt with None -> [] | Some(_, xs) -> xs in

    let sub, t =
      Tsubst.extract_from
        (match popt with None -> [] | Some(pid, _) -> [pid])
        (fun x -> List.mem x bvs || Var.is_coeff x) t
    in
    let t = Term.subst sub t in
(*
    let t = Term.simplify (AtpInterface.qelim_fes (diff bvs (fvs ps)) t) in
*)
    let [], t = subst_formula (fun x -> List.mem x bvs || Var.is_coeff x) [] t in
    let _ = Global.log (fun () -> Format.printf "output:@,  @[<v>%a@]" Term.pr t) in
    let _ = Global.log_end "simplifying formula" in
    t
  in
  let _ = Global.log_end "subst_lbs" in
  Hc(popt, [], t)



let compute_lb lbs (Hc(Some(pid, xs), ps, t)) =
  let Hc(_, [], t) = subst_lbs lbs (Hc(Some(pid, xs), ps, t)) in
  pid, (xs, t)

let compute_lbs hcs =
  let _ = Global.log_begin "compute_lbs" in
  let rec aux hcs lbs =
    let hcs1, hcs2 =
      List.partition
       (function (Hc(Some(_), ps, _)) ->
         List.for_all (fun (pid, _) -> List.mem_assoc pid lbs) ps
       | (Hc(None, _, _)) -> false)
       hcs
    in
    if hcs1 = [] then
      lbs (* hcs2 are all false *)
    else
      let lbs' =
        List.map
          (fun hc ->
            let lb = compute_lb lbs hc in
            let _ = Global.log (fun () -> Format.printf "%a@," pr_sol_elem lb) in
            lb)
        hcs1
      in
      aux hcs2 (lbs @ (* need to merge? *)lbs')
  in
  let res = aux hcs [] in
  let _ = Global.log_end "compute_lbs" in
  res



(** makes verification of file.ml too slow... why? *)
let general_interpolate pid p t1 t2 =
		let xns, ts2 =
		  Util.partition_map
		    (fun t ->
		      try
				      match LinArith.aif_of t with
						      (Const.EqInt, [1, x], n) ->
						        `L(x, -n)
						    | (Const.EqInt, [-1, x], n) ->
						        `L(x, n)
						    | aif ->
						        `R(LinArith.term_of_aif aif)
		      with Invalid_argument _ ->
		        `R(t))
		    (Formula.conjuncts t1)
		in
		try
		  (match xns with
		    [] -> raise Not_found
		  | _ ->
		      let xns1, (x, n), xns2 = Util.find_split (fun (x, _) -> pid = x) xns in
		      let t = Formula.eqInt (Term.make_var x) (Term.tint n) in
		      let ts1 =
				      List.map (fun (x', n') -> Formula.eqInt (Term.make_var x') (Term.add (Term.make_var x) (Term.tint (n' - n)))) (xns1 @ xns2)
		      in
								try
          let t1 = Formula.band (ts1 @ ts2) in
								  CsisatInterface.interpolate_bvs p t1 t2
		      with CsisatInterface.No_interpolant ->
          let t1 = Formula.band (t :: ts1 @ ts2) in
		        CsisatInterface.interpolate_bvs p t1 t2)
		with Not_found ->
		  if false then
		    CsisatInterface.interpolate_bvs p t1 t2
		  else
		    (*List.map (fun (x, n) -> Formula.eqInt (Term.make_var x) (Term.tint n)) xns*)
				  (let xns = List.sort ~cmp:(fun (_, n1) (_, n2) -> n1 - n2) xns in
				  match xns with
				    [] -> CsisatInterface.interpolate_bvs p t1 t2
				  | (x, n)::xns ->
		        let ts1 =
						      (Formula.eqInt (Term.make_var x) (Term.tint n))::
						      List.map (fun (x', n') -> Formula.eqInt (Term.make_var x') (Term.add (Term.make_var x) (Term.tint (n' - n)))) xns
		        in
          let t1 = Formula.band (ts1 @ ts2) in
		        CsisatInterface.interpolate_bvs p t1 t2)


let solve_hc_aux prog lbs ps t =
  let _ = Global.log_begin "solve_hc_aux" in
		let _ =
		  Global.log (fun () ->
		    Format.printf "horn clause:@,  @[<v>%a@]@,"
		      (*(Util.pr_list pr "@,") (List.map2 (fun lb p -> Hc(Some(p), [], Fes.make [] [lb])) lbs ps)*)
		      pr (Hc(None, ps, t)))
		in
  if false && List.length ps = 1 then
    (* ToDo: optimization *)
    assert false
  else
		  let rec aux ps t =
						match ps with
						  [] -> []
						| (pid, ts)::ps ->
		        let xs = List.map (fun _ -> Var.new_var ()) ts in
          let tys = List.map (Prog.type_of prog) (RefType.visible_vars (Prog.type_of prog) pid) in
          let sub = Util.map3 (fun x t ty -> x, t, ty) xs ts tys in
				      let _ = Global.log (fun () -> Format.printf "finding a solution to %a@," Pred.pr (pid, List.map Term.make_var xs)) in
						    let interp =
						      let t1 =
						        try
                let t = lookup_lbs (pid, List.map Term.make_var xs) lbs in
						          let sub, t = Tsubst.extract_from [pid] (fun x -> List.mem x xs || Var.is_coeff x) t in
						          let t = Term.subst sub t in
                let [], t = subst_formula (fun x -> List.mem x xs || Var.is_coeff x) [] t in
                t
						        with Not_found -> assert false
						      in
						      let t2 =
              try
                let t =
										        Formula.band
                    (t :: List.map (fun (pid, ts) -> lookup_lbs (pid, ts) lbs) ps @ List.map Tsubst.formula_of_elem sub)
                in
						          let sub, t = Tsubst.extract_from [pid] (fun x -> List.mem x xs || Var.is_coeff x) t in
						          let t = Term.subst sub t in
                let [], t = subst_formula (fun x -> List.mem x xs || Var.is_coeff x) [] t in
                t
              with Not_found -> assert false
						      in
												if true then
              general_interpolate pid (fun x -> List.mem x xs || Var.is_coeff x) t1 t2
												else
												  CsisatInterface.interpolate_bvs (fun x -> List.mem x xs || Var.is_coeff x) t1 t2
						    in
						    let sol = pid, (xs, interp)	in
						    let _ = Global.log (fun () -> Format.printf "solution:@,  @[<v>%a@]@," pr_sol_elem sol) in
						    sol :: aux ps (Formula.band (t :: interp :: List.map Tsubst.formula_of_elem sub))
		  in
		  let sol = aux ps t in
				let _ = Global.log_end "solve_hc_aux" in
		  sol

let solve_hc prog lbs sol (Hc(popt, ps, t)) =
  let t =
    match popt with
      None -> t
    | Some(pid, xs) ->
        try
          Formula.band [t; Formula.bnot (lookup_sol (pid, List.map Term.make_var xs) sol)]
        with Not_found ->
          Formula.tfalse
  in
  if Cvc3Interface.is_valid (Formula.bnot t) then
    []
  else if ps = [] then
    raise NoSolution
  else
    solve_hc_aux prog lbs ps t

let solve_aux prog lbs hcs =
  let rec aux hcs sol =
    let lhs_pids = get_lhs_pids hcs in
    (* hcs1: immediately solvable Horn clauses *)
    let hcs1, hcs2 =
      List.partition
        (function
          (Hc(None, _, _)) ->
            true
        | (Hc(Some(pid, _), _, _)) ->
            not (List.mem pid lhs_pids))
        hcs
    in
    if hcs1 = [] && hcs2 = [] then
      merge_sol sol
    else if hcs1 = [] && hcs2 <> [] then
      assert false
    else
      aux hcs2 (sol @ (Util.concat_map (solve_hc prog lbs sol) hcs1))
  in
  aux hcs []

(** @returns sol
    each predicate not in sol must be true *)
let solve prog ctrs hcs =
  let _ = Global.log_begin "solving Horn clauses" in
  let lbs = compute_lbs hcs in
  let _ = Global.log (fun () -> Format.printf "lower bounds:@,  %a@," pr_sol lbs) in
  let sol = solve_aux prog lbs hcs in
  let _ = Global.log (fun () -> Format.printf "solution:@,  @[<v>%a@]" pr_sol sol) in
  let _ = Global.log_end "solving Horn clauses" in
  sol



(***)

let formula_of_forward hcs =
  let lbs = compute_lbs hcs in
  let _ = Format.printf "lower bounds:@.  %a@." pr_sol lbs in
  let hcs = List.filter (function (Hc(None, _, _)) -> true | _ -> false) hcs in
  Formula.simplify
    (Formula.bor
				  (List.map
				    (fun hc ->
				      let Hc(None, [], t) = subst_lbs lbs hc in
				      t)
				    hcs))

let formula_of_backward hcs =
  let hcs1, hcs2 = List.partition (function Hc(None, _, _) -> true | _ -> false) hcs in
  let hcs =
		  List.map
						(Util.fixed_point
						  (fun hc ->
		        subst_hcs hcs2 hc)
						  (fun hc1 hc2 ->
		        match hc1, hc2 with
		          Hc(_, ps1, _), Hc(_, ps2, _) -> ps1 = ps2))
						hcs1
  in
  Formula.simplify
    (Formula.bor
      (List.map
        (fun (Hc(None, ps, t)) ->
          if ps = [] then
            t
          else
            let _ = Format.printf "%a@." pr (Hc(None, ps, t)) in
            assert false)
        hcs))
