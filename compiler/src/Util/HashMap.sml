functor HashMap (Key : HASH_KEY) :> sig
    type key = Key.hash_key
    type 'v t

    val empty : 'v t
    val insert : 'v t -> key * 'v -> 'v t
    val find : 'v t -> key -> 'v option
    val length : 'v t -> int
    val fold : ((key * 'v) * 'a -> 'a) -> 'a -> 'v t -> 'a
end = struct
    open Word32
    infix 5 << >>

    type key = Key.hash_key
    val hashVal = Key.hashVal
    val eq = Key.sameKey

    datatype 'v trie
        = Bitmapped of {bitmap : word, nodes : 'v trie vector}
        | Collision of {hash : word, kvs : (key * 'v) vector}
        | Leaf of key * 'v

    type 'v t = {root : 'v trie, len : int}

    val length : 'v t -> int = #len

    val bits = 0w5
    val width = 0w1 << bits
    val mask = width - 0w1

    fun hashPart hash shift = andb (hash >> shift, mask)

    fun bitpos hash shift = 0w1 << hashPart hash shift

    fun bitindex bitmap bit = toInt (bitCount (andb (bitmap, bit - 0w1)))

    fun isset bitmap bit = andb (bitmap, bit) <> 0w0

    val empty = {root = Bitmapped {bitmap = 0w0, nodes = #[]}, len = 0}

    fun insert {root, len} (kv as (k, _)) = trieInsert len root 0w0 (hashVal k) kv

    and trieInsert len trie shift hash (kv as (k, _)) =
        case trie
        of Bitmapped {bitmap, nodes} =>
            let val bit = bitpos hash shift
                val index = bitindex bitmap bit
            in  if isset bitmap bit
                then let val node = Vector.sub (nodes, index)
                         val {root = node, len} = trieInsert len node (shift + bits) hash kv
                     in { root = Bitmapped {bitmap, nodes = Vector.update (nodes, index, node)}
                        , len }
                     end
                else { root = Bitmapped { bitmap = andb (bitmap, bit)
                                        , nodes = Vector.pushAt (nodes, index, Leaf kv) }
                     , len = Int.+ (len, 1) }
            end

         | Collision {hash = hash', kvs} => (* If we got here, must be `hash = hash'` *)
            (case Vector.findi (fn (i, (k', _)) => eq (k', k)) kvs
             of SOME (i, _) =>
                 { root = Collision {hash = hash', kvs = Vector.update (kvs, i, kv)}
                 , len }
              | NONE =>
                 { root = Collision {hash = hash', kvs = Vector.append (kvs, kv)}
                 , len = Int.+ (len, 1) })

         | Leaf (kv' as (k', _)) =>
            if eq (k, k')
            then {root = Leaf kv, len}
            else let val hash' = hashVal k'
                     val node = 
                         if hash = hash'
                         then Collision {hash, kvs = #[kv', kv]}
                         else let val node = Bitmapped {bitmap = 0w0, nodes = #[]}
                                  val node = #root (trieInsert len trie shift hash' kv')
                              in #root (trieInsert len trie shift hash kv)
                              end
                 in {root = node, len = Int.+ (len, 1)}
                 end

    fun find {root, len = _} k = trieFind root 0w0 (hashVal k) k

    and trieFind trie shift hash k =
        case trie
        of Bitmapped {bitmap, nodes} =>
            let val bit = bitpos hash shift
            in if isset bitmap bit
               then let val index = bitindex bitmap bit
                        val node = Vector.sub (nodes, index)
                    in trieFind node (shift + bits) hash k
                    end
               else NONE
            end

         | Collision {hash = _, kvs} =>
            Option.map #2 (Vector.find (fn (k', _) => eq (k', k)) kvs)

         | Leaf (k', v) =>
            if eq (k', k) then SOME v else NONE

    fun fold f acc {root, len = _} = foldTrie f acc root

    and foldTrie f acc =
        fn Bitmapped {bitmap = _, nodes} =>
            Vector.foldl (fn (trie, acc) => foldTrie f acc trie) acc nodes
         | Collision {hash = _, kvs} => Vector.foldl f acc kvs
         | Leaf kv => f (kv, acc)
end

