(* Assemble messages byte by byte, so that tests can produce encodings that the
   library's own encoder never emits. *)

let concat = String.concat ""
let v = Bhttp.Varint.encode

(* An integer on exactly [size] bytes, which need not be the shortest. *)
let sized ~size n =
  let b = Buffer.create 8 in
  Bhttp.Varint.add_sized b ~size n;
  Buffer.contents b

let str s = v (String.length s) ^ s
let line name value = str name ^ str value
let known lines = str (concat lines)
let indeterminate lines = concat lines ^ v 0
let chunks parts = concat (List.map str parts) ^ v 0

let control ?(meth = "GET") ?(scheme = "https") ?(authority = "example.com")
    ?(path = "/") () =
  concat [ str meth; str scheme; str authority; str path ]
