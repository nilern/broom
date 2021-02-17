module T = GraphType.Type
module E = ComplexFc.Term.Expr

module Make
    (Env : TyperSigs.ENV)
    (K : TyperSigs.KINDING with type env = Env.t)
: TyperSigs.EXPAND_PATS with type env = Env.t

