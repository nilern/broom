structure Typechecker :> sig
    val elaborateExpr: TypecheckingCst.env -> TypecheckingCst.expr
                     -> TypecheckingCst.typ * TypecheckingCst.typ FAst.Term.expr
end = struct
    datatype predicativity = datatype TypeVars.predicativity
    structure CTerm = FixedCst.Term
    structure CType = FixedCst.Type
    structure TC = TypecheckingCst
    structure FTerm = FAst.Term
    structure FType = FAst.Type

    open TypeError
 
    val subType = Subtyping.subType
    val applyCoercion = Subtyping.applyCoercion

(* Looking up `val` types *)

    (* Get the type of the variable `name`, referenced at `pos`, from `env` by either
       - finding the type annotation (if available) (and elaborating it if not already done)
       - elaborating the expression bound to the variable (if available)
       - returning a fresh unification variable (if neither type annotation nor bound expression
         is available or if a cycle is encountered) *)
    fun lookupValType expr name env: TC.typ option =
        let fun valBindingType env {typ = typRef, value} =
                case !typRef
                of SOME typ => elaborateType env typ
                 | NONE => (case value
                            of SOME exprRef => let val (t, expr) = elaborateExpr env (!exprRef)
                                               in exprRef := TC.OutputExpr expr
                                                ; t
                                               end
                             | NONE => TC.UVar (TC.Expr.pos expr, TypeVars.freshUv env Predicative))

            fun elaborateValType env {shade, binder = binding as {typ = typRef, value = _}} =
                let do shade := TC.Grey
                    val typ = valBindingType env binding
                in case !shade
                   of TC.Grey => ( typRef := SOME typ
                                 ; shade := TC.Black )
                    | TC.Black =>
                       (* So, we went to `elaborateValTypeLoop` inside the `valBindingType` call.
                          `typ` better be a subtype of the type inferred from usage sites: *)
                       ignore (subType env expr (typ, valOf (!typRef)))
                    | TC.White => raise Fail "unreachable"
                 ; typ
                end

            fun elaborateValTypeLoop env {shade, binder = {typ = typRef, value = _}} =
                let val typ = TC.UVar (TC.Expr.pos expr, TypeVars.freshUv env Predicative)
                in typRef := SOME typ
                 ; shade := TC.Black
                 ; typ
                end
        in case env
           of TC.ExprScope scope :: parent =>
               (case TC.Scope.exprFind scope name
                of SOME (binding as {shade, binder}) =>
                    (case !shade
                     of TC.Black => !(#typ binder)
                      | TC.White => SOME (elaborateValType env binding)
                      | TC.Grey => SOME (elaborateValTypeLoop env binding))
                 | NONE => lookupValType expr name parent)
            | [] => NONE
        end

(* Elaborating subtrees *)

    (* Elaborate the type `typ` and return the elaborated version. *)
    and elaborateType env (typ: TC.typ): TC.typ =
        case typ
        of TC.InputType typ =>
            (case typ
             of CType.Arrow (pos, {domain, codomain}) =>
                 TC.OutputType (FType.Arrow (pos, { domain = elaborateType env domain
                                                  , codomain = elaborateType env codomain }))
              | CType.Record (pos, row) => TC.OutputType (FType.Record (pos, elaborateType env row))
              | CType.RowExt (pos, {fields, ext}) =>
                 let fun elaborateField ((label, t), acc) = (label, elaborateType env t) :: acc
                     fun constructStep (field, ext) = TC.OutputType (FType.RowExt (pos, {field, ext}))
                     val revFields = Vector.foldl elaborateField [] fields
                     val ext = elaborateType env ext
                 in List.foldl constructStep ext revFields
                 end
              | CType.EmptyRow pos => TC.OutputType (FType.EmptyRow pos)
              | CType.Path typExpr =>
                 let val (typ, _) = elaborateExpr env typExpr
                 in case typ
                    of TC.OutputType ftyp =>
                        (case ftyp
                         of FType.Type (_, typ) => typ
                          | _ => raise Fail ("Type path " ^ TC.Type.toString typ
                                             ^ "does not denote type at " ^ Pos.toString (TC.Expr.pos typExpr)))
                 end
              | CType.Type pos =>
                 let val def = {var = Name.fresh (), kind = FType.TypeK pos}
                     val body = TC.OutputType (FType.Type (pos, TC.OutputType (FType.UseT (pos, def))))
                 in TC.OutputType (FType.Exists (pos, def, body))
                 end
              | CType.Prim (pos, p) => TC.OutputType (FType.Prim (pos, p)))
         | TC.OutputType _ => typ (* assumes invariant: entire subtree has been elaborated already *)

    (* Elaborate the expression `exprRef` and return its computed type. *)
    and elaborateExpr env (exprRef: TC.expr): TC.typ * TC.typ FTerm.expr =
        case exprRef
        of TC.InputExpr expr =>
            (case expr
             of CTerm.Fn (pos, param, paramType, body) =>
                 let val (typeDefs, domain) =
                         case !paramType
                         of SOME domain =>
                             Pair.second SOME (TC.Type.splitExistentials (elaborateType env domain))
                          | NONE => ([], NONE)
                     val env = let val fnScope :: env = env
                                   fun pushDef ({var, kind}, env) =
                                       let val bindingRef = ref NONE
                                           val scope = TC.TypeScope (TC.Scope.forTFn (var, bindingRef))
                                           val env = scope :: env
                                           val typ = TC.OVar (pos, TypeVars.newOv env (Predicative, var))
                                       in bindingRef := SOME { binder = {kind, typ = ref typ}
                                                             , shade = ref TC.Black }
                                        ; env
                                       end
                               in fnScope :: List.foldr pushDef env typeDefs
                               end
                     val domain = case domain
                                  of SOME domain => domain
                                   | NONE => TC.UVar (pos, TypeVars.freshUv env Predicative)
                     do paramType := SOME domain
                     val codomain = TC.UVar (pos, TypeVars.freshUv env Predicative)
                     val body = elaborateExprAs env codomain body
                     val t = TC.OutputType (FType.Arrow (pos, {domain, codomain}))
                     val f = FTerm.Fn (pos, {var = param, typ = domain}, body)
                 in ( List.foldr (fn (def, t) => TC.OutputType (FType.ForAll (pos, def, t))) t typeDefs
                    , List.foldr (fn (def, f) => FTerm.TFn (pos, def, f)) f typeDefs)
                 end
              | CTerm.Let (pos, stmts, body) =>
                 let val stmts = Vector.map (elaborateStmt env) stmts
                     val (typ, body) = elaborateExpr env body
                 in (typ, FTerm.Let (pos, stmts, body))
                 end
              | CTerm.If (pos, _, _, _) =>
                 let val t = (TC.UVar (pos, TypeVars.freshUv env Predicative))
                 in (t, elaborateExprAs env t exprRef)
                 end
              | CTerm.Record (pos, fields) => elaborateRecord env pos fields
              | CTerm.App (pos, {callee, arg}) =>
                 let val ct as (_, callee) = elaborateExpr env callee
                     val (callee, {domain, codomain}) = coerceCallee env ct 
                     val arg = elaborateExprAs env domain arg
                 in (codomain, FTerm.App (pos, codomain, {callee, arg}))
                 end
              | CTerm.Field (pos, expr, label) =>
                 let val te as (_, expr) = elaborateExpr env expr
                     val fieldType = coerceRecord env te label
                 in (fieldType, FTerm.Field (pos, fieldType, expr, label))
                 end
              | CTerm.Ann (_, expr, t) =>
                 let val t = elaborateType env t
                 in (t, elaborateExprAs env t expr)
                 end
              | CTerm.Type (pos, t) =>
                 let val t = elaborateType env t
                 in (TC.OutputType (FType.Type (pos, t)), FTerm.Type (pos, t))
                 end
              | CTerm.Use (pos, name) =>
                 let val typ = case lookupValType exprRef name env
                               of SOME typ => typ
                                | NONE => raise TypeError (UnboundVal (pos, name))
                     val def = {var = name, typ}
                 in (typ, FTerm.Use (pos, def))
                 end
              | CTerm.Const (pos, c) =>
                 (TC.OutputType (FType.Prim (pos, Const.typeOf c)), FTerm.Const (pos, c)))
         | TC.ScopeExpr {scope, expr} => elaborateExpr (TC.Env.pushExprScope env scope) expr
         | TC.OutputExpr expr => (FTerm.typeOf TC.OutputType expr, expr)

    and elaborateRecord env pos ({fields, ext}: TC.expr CTerm.row): TC.typ * TC.typ FTerm.expr =
        let fun elaborateField (field as (label, expr), (rowType, fieldExprs)) =
                let val pos = TC.Expr.pos expr
                    val (fieldt, expr) = elaborateExpr env expr
                in ( TC.OutputType (FType.RowExt (pos, {field = (label, fieldt), ext = rowType}))
                   , (label, expr) :: fieldExprs )
                end
            val (extType, extExpr) = case ext
                                     of SOME ext => let val (t, ext) = elaborateExpr env ext
                                                    in case t
                                                       of TC.OutputType (FType.Record (_, row)) =>
                                                           (row, SOME ext)
                                                    end
                                      | NONE => (TC.OutputType (FType.EmptyRow pos), NONE)
            val (rowType, fieldExprs) = Vector.foldr elaborateField (extType, []) fields
            val typ = TC.OutputType (FType.Record (pos, rowType))
        in (typ, FTerm.Extend (pos, typ, Vector.fromList fieldExprs, extExpr))
        end

    (* Elaborate the expression `exprRef` to a subtype of `typ`. *)
    and elaborateExprAs env (typ: TC.typ) (expr: TC.expr): TC.typ FTerm.expr =
        case expr
        of TC.InputExpr iexpr =>
            (case iexpr
             of CTerm.Fn (_, param, paramType, body) =>
                 (case typ
                  of TC.OutputType (FType.Arrow (_, {domain, codomain})) =>
                      raise Fail "unimplemented"
                   | _ => coerceExprTo env typ expr)
              | CTerm.If (pos, cond, conseq, alt) =>
                 FTerm.If (pos, elaborateExprAs env 
                                                (TC.OutputType (FType.Prim (pos, FType.Prim.Bool)))
                                                cond
                              , elaborateExprAs env typ conseq
                              , elaborateExprAs env typ alt )
              | _ =>
                (case typ
                 of TC.OutputType (FType.ForAll _) => raise Fail "unimplemented"
                  | _ => coerceExprTo env typ expr))
         | TC.ScopeExpr {scope, expr} => elaborateExprAs (TC.Env.pushExprScope env scope) typ expr
         | TC.OutputExpr expr => expr

    (* Like `elaborateExprAs`, but will always just do subtyping and apply the coercion. *)
    and coerceExprTo env (typ: TC.typ) (expr: TC.expr): TC.typ FTerm.expr =
        let val (t', fexpr) = elaborateExpr env expr
            val coercion = subType env expr (t', typ)
        in applyCoercion coercion fexpr
        end

    (* Elaborate a statement and return the elaborated version. *)
    and elaborateStmt env: (TC.typ, TC.typ option ref, TC.expr, TC.expr ref) Cst.Term.stmt -> TC.typ FTerm.stmt =
        fn CTerm.Val (pos, name, _, exprRef) =>
            let val t = valOf (lookupValType (!exprRef) name env) (* `name` is in `env` by construction *)
                val expr = elaborateExprAs env t (!exprRef)
            in FTerm.Val (pos, {var = name, typ = t}, expr)
            end
         | CTerm.Expr expr => FTerm.Expr (elaborateExprAs env (TC.OutputType (FType.unit (TC.Expr.pos expr))) expr)

    (* Coerce `callee` into a function and return t coerced and its `domain` and `codomain`. *)
    and coerceCallee env (typ: TC.typ, callee: TC.typ FTerm.expr): TC.typ FTerm.expr * {domain: TC.typ, codomain: TC.typ} =
        let fun coerce callee =
                fn TC.OutputType otyp =>
                    (case otyp
                     of FType.ForAll (_, {var, kind}, t) =>
                         let val pos = FTerm.exprPos callee
                             val uv = TC.UVar (pos, TypeVars.newUv env (Predicative, var))
                             val calleeType = TC.Type.substitute (var, uv) t
                         in coerce (FTerm.TApp (pos, calleeType, {callee, arg = uv})) calleeType
                         end
                      | FType.Arrow (_, domains) => (callee, domains)
                      | _ => raise TypeError (UnCallable (callee, typ)))
                 | TC.OVar _ => raise TypeError (UnCallable (callee, typ))
                 | TC.UVar (_, uv) =>
                    (case TypeVars.uvGet uv
                     of Either.Left uv => raise Fail "unimplemented"
                      | Either.Right typ => coerce callee typ)
                 | TC.ScopeType (scope as {typ, ...}) => raise Fail "unimplemented"
                 | TC.InputType _ => raise Fail "Encountered InputType"
        in coerce callee typ
        end
   
    (* Coerce `expr` (in place) into a record with at least `label` and return the `label`:ed type. *)
    and coerceRecord env (typ: TC.typ, expr: TC.typ FTerm.expr) label: TC.typ =
        let val rec coerce =
                fn TC.OutputType otyp =>
                    (case otyp
                     of FType.ForAll _ => raise Fail "unimplemented"
                      | FType.Record (_, row) => coerceRow row
                      | _ => raise TypeError (UnCallable (expr, typ)))
                 | TC.OVar _ => raise TypeError (UnDottable (expr, typ))
                 | TC.UVar (pos, uv) =>
                    (case TypeVars.uvGet uv
                     of Either.Right typ => coerce typ
                      | Either.Left uv => let val fieldType = TC.UVar (pos, TypeVars.freshUv env Predicative)
                                              val ext = TC.UVar (pos, TypeVars.freshUv env Predicative)
                                              val pos = FTerm.exprPos expr
                                              val row = FType.RowExt (pos, {field = (label, fieldType), ext})
                                              val typ = FType.Record (pos, TC.OutputType row)
                                          in TypeVars.uvSet (uv, TC.OutputType typ)
                                           ; fieldType
                                          end)
                 | TC.ScopeType _ => raise Fail "unimplemented"
                 | TC.InputType _ => raise Fail "Encountered InputType"
            and coerceRow =
                fn TC.OutputType (FType.RowExt (_, {field = (label', fieldt), ext})) =>
                    if label' = label
                    then fieldt
                    else coerceRow ext
        in coerce typ
        end
end

