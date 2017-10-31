(*  This file is part of the ppx_tools package.  It is released  *)
(*  under the terms of the MIT license (see LICENSE file).       *)
(*  Copyright 2013  Alain Frisch and LexiFi                      *)

(* A -ppx rewriter to be used to write Parsetree-generating code
   (including other -ppx rewriters) using concrete syntax.

   We support the following extensions in expression position:

   [%expr ...]  maps to code which creates the expression represented by ...
   [%pat? ...] maps to code which creates the pattern represented by ...
   [%str ...] maps to code which creates the structure represented by ...
   [%stri ...] maps to code which creates the structure item represented by ...
   [%type: ...] maps to code which creates the core type represented by ...

   Quoted code can refer to expressions representing AST fragments,
   using the following extensions:

     [%e ...] where ... is an expression of type Parsetree.expression
     [%t ...] where ... is an expression of type Parsetree.core_type
     [%p ...] where ... is an expression of type Parsetree.pattern


   All locations generated by the meta quotation are by default set
   to [Ast_helper.default_loc].  This can be overriden by providing a custom
   expression which will be inserted whereever a location is required
   in the generated AST.  This expression can be specified globally
   (for the current structure) as a structure item attribute:

     ;;[@@metaloc ...]

   or locally for the scope of an expression:

     e [@metaloc ...]



   Support is also provided to use concrete syntax in pattern
   position.  The location and attribute fields are currently ignored
   by patterns generated from meta quotations.

   We support the following extensions in pattern position:

   [%expr ...]  maps to code which creates the expression represented by ...
   [%pat? ...] maps to code which creates the pattern represented by ...
   [%str ...] maps to code which creates the structure represented by ...
   [%type: ...] maps to code which creates the core type represented by ...

   Quoted code can refer to expressions representing AST fragments,
   using the following extensions:

     [%e? ...] where ... is a pattern of type Parsetree.expression
     [%t? ...] where ... is a pattern of type Parsetree.core_type
     [%p? ...] where ... is a pattern of type Parsetree.pattern

*)

module Main : sig end = struct
  open Asttypes
  open Parsetree
  open Ast_helper
  open Ast_convenience

  let prefix ty s =
    let open Longident in
    match parse ty with
    | Ldot(m, _) -> String.concat "." (Longident.flatten m) ^ "." ^ s
    | _ -> s

  class exp_builder =
    object
      method record ty x = record (List.map (fun (l, e) -> prefix ty l, e) x)
      method constr ty (c, args) = constr (prefix ty c) args
      method list l = list l
      method tuple l = tuple l
      method int i = int i
      method string s = str s
      method char c = char c
      method int32 x = Exp.constant (Const_int32 x)
      method int64 x = Exp.constant (Const_int64 x)
      method nativeint x = Exp.constant (Const_nativeint x)
    end

  class pat_builder =
    object
      method record ty x = precord ~closed:Closed (List.map (fun (l, e) -> prefix ty l, e) x)
      method constr ty (c, args) = pconstr (prefix ty c) args
      method list l = plist l
      method tuple l = ptuple l
      method int i = pint i
      method string s = pstr s
      method char c = pchar c
      method int32 x = Pat.constant (Const_int32 x)
      method int64 x = Pat.constant (Const_int64 x)
      method nativeint x = Pat.constant (Const_nativeint x)
    end


  let get_exp loc = function
    | PStr [ {pstr_desc=Pstr_eval (e, _); _} ] -> e
    | _ ->
        Format.eprintf "%aExpression expected@."
          Location.print_error loc;
        exit 2

  let get_typ loc = function
    | PTyp t -> t
    | _ ->
        Format.eprintf "%aType expected@."
          Location.print_error loc;
        exit 2

  let get_pat loc = function
    | PPat (t, None) -> t
    | _ ->
        Format.eprintf "%aPattern expected@."
          Location.print_error loc;
        exit 2

  let exp_lifter loc map =
    let map = map.Ast_mapper.expr map in
    object
      inherit [_] Ast_lifter.lifter as super
      inherit exp_builder

      (* Special support for location in the generated AST *)
      method! lift_Location_t _ = loc

      (* Support for antiquotations *)
      method! lift_Parsetree_expression = function
        | {pexp_desc=Pexp_extension({txt="e";loc}, e); _} -> map (get_exp loc e)
        | x -> super # lift_Parsetree_expression x

      method! lift_Parsetree_pattern = function
        | {ppat_desc=Ppat_extension({txt="p";loc}, e); _} -> map (get_exp loc e)
        | x -> super # lift_Parsetree_pattern x

      method! lift_Parsetree_core_type = function
        | {ptyp_desc=Ptyp_extension({txt="t";loc}, e); _} -> map (get_exp loc e)
        | x -> super # lift_Parsetree_core_type x
    end

  let pat_lifter map =
    let map = map.Ast_mapper.pat map in
    object
      inherit [_] Ast_lifter.lifter as super
      inherit pat_builder

      (* Special support for location and attributes in the generated AST *)
      method! lift_Location_t _ = Pat.any ()
      method! lift_Parsetree_attributes _ = Pat.any ()

      (* Support for antiquotations *)
      method! lift_Parsetree_expression = function
        | {pexp_desc=Pexp_extension({txt="e";loc}, e); _} -> map (get_pat loc e)
        | x -> super # lift_Parsetree_expression x

      method! lift_Parsetree_pattern = function
        | {ppat_desc=Ppat_extension({txt="p";loc}, e); _} -> map (get_pat loc e)
        | x -> super # lift_Parsetree_pattern x

      method! lift_Parsetree_core_type = function
        | {ptyp_desc=Ptyp_extension({txt="t";loc}, e); _} -> map (get_pat loc e)
        | x -> super # lift_Parsetree_core_type x
    end

  let loc = ref (app (evar "Pervasives.!") [evar "Ast_helper.default_loc"])

  let handle_attr = function
    | {txt="metaloc";loc=l}, e -> loc := get_exp l e
    | _ -> ()

  let with_loc ?(attrs = []) f =
    let old_loc = !loc in
    List.iter handle_attr attrs;
    let r = f () in
    loc := old_loc;
    r

  let expander _args =
    let open Ast_mapper in
    let super = default_mapper in
    let expr this e =
      with_loc ~attrs:e.pexp_attributes
        (fun () ->
           match e.pexp_desc with
           | Pexp_extension({txt="expr";loc=l}, e) ->
               (exp_lifter !loc this) # lift_Parsetree_expression (get_exp l e)
           | Pexp_extension({txt="pat";loc=l}, e) ->
               (exp_lifter !loc this) # lift_Parsetree_pattern (get_pat l e)
           | Pexp_extension({txt="str";_}, PStr e) ->
               (exp_lifter !loc this) # lift_Parsetree_structure e
           | Pexp_extension({txt="stri";_}, PStr [e]) ->
               (exp_lifter !loc this) # lift_Parsetree_structure_item e
           | Pexp_extension({txt="type";loc=l}, e) ->
               (exp_lifter !loc this) # lift_Parsetree_core_type (get_typ l e)
           | _ ->
               super.expr this e
        )
    and pat this p =
      with_loc ~attrs:p.ppat_attributes
        (fun () ->
           match p.ppat_desc with
           | Ppat_extension({txt="expr";loc=l}, e) ->
               (pat_lifter this) # lift_Parsetree_expression (get_exp l e)
           | Ppat_extension({txt="pat";loc=l}, e) ->
               (pat_lifter this) # lift_Parsetree_pattern (get_pat l e)
           | Ppat_extension({txt="str";_}, PStr e) ->
               (pat_lifter this) # lift_Parsetree_structure e
           | Ppat_extension({txt="stri";_}, PStr [e]) ->
               (pat_lifter this) # lift_Parsetree_structure_item e
           | Ppat_extension({txt="type";loc=l}, e) ->
               (pat_lifter this) # lift_Parsetree_core_type (get_typ l e)
           | _ ->
               super.pat this p
        )
    and structure this l =
      with_loc
        (fun () -> super.structure this l)

    and structure_item this x =
      begin match x.pstr_desc with
      | Pstr_attribute x -> handle_attr x
      | _ -> ()
      end;
      super.structure_item this x

    in
    {super with expr; pat; structure; structure_item}

  let () = Ast_mapper.run_main expander
end
