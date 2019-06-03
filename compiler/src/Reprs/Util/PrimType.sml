signature PRIM_TYPE = sig
    datatype t = Unit | I32

    val toString: t -> string
    val toDoc: t -> PPrint.t
end

structure PrimType :> PRIM_TYPE = struct
    datatype t = Unit | I32
    
    val toString = fn Unit => "()"
                    | I32 => "I32"
    
    structure ToDoc = ToDocFromToString(struct type t = t val toString = toString end)
    val toDoc = ToDoc.toDoc
end
