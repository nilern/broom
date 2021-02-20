module rec Typ : (ComplexFcSigs.TYPE
    with type uv = Uv.t
    with type bound = Uv.bound
    with type binder = Uv.binder
    with type scope = Uv.scope
    with type ov = Ov.t)

and Uv : (ComplexFcSigs.UV
    with type typ = Typ.t
    with type kind = Typ.kind
    with type ov = Ov.t)

and Ov : ComplexFcSigs.OV
    with type kind = Typ.kind
    with type scope = Uv.scope

