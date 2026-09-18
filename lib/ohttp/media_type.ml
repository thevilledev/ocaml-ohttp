(* Media types of Oblivious HTTP (RFC 9458 Section 9) and Binary HTTP (RFC 9292
   Section 7). *)

let ohttp_request = "message/ohttp-req"
let ohttp_response = "message/ohttp-res"
let ohttp_chunked_request = "message/ohttp-chunked-req"
let ohttp_chunked_response = "message/ohttp-chunked-res"
let ohttp_keys = "application/ohttp-keys"
let bhttp = "message/bhttp"
let problem_json = "application/problem+json"
let is_whitespace = function ' ' | '\t' -> true | _ -> false

let trim s =
  let n = String.length s in
  let first = ref 0 and last = ref n in
  while !first < n && is_whitespace s.[!first] do
    incr first
  done;
  while !last > !first && is_whitespace s.[!last - 1] do
    decr last
  done;
  String.sub s !first (!last - !first)

let matches media_type content_type =
  let essence =
    match String.index_opt content_type ';' with
    | None -> content_type
    | Some i -> String.sub content_type 0 i
  in
  String.equal
    (String.lowercase_ascii (trim essence))
    (String.lowercase_ascii media_type)
