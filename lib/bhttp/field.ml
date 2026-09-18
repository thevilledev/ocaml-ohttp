(* Field lines (RFC 9292 Section 3.6). *)

type t = string * string

let pp fmt (name, value) =
  Format.fprintf fmt "%s: %s" (String.escaped name) (String.escaped value)

let lowercase fields =
  List.map (fun (name, value) -> (String.lowercase_ascii name, value)) fields

(* tchar, RFC 9110 Section 5.6.2. *)
let is_token_char = function
  | '!' | '#' | '$' | '%' | '&' | '\'' | '*' | '+' | '-' | '.' | '^' | '_' | '`'
  | '|' | '~'
  | '0' .. '9'
  | 'a' .. 'z'
  | 'A' .. 'Z' ->
      true
  | _ -> false

let is_token s = s <> "" && String.for_all is_token_char s
let is_pseudo name = name <> "" && name.[0] = ':'

let valid_name name =
  if is_pseudo name then is_token (String.sub name 1 (String.length name - 1))
  else is_token name

let is_whitespace = function ' ' | '\t' -> true | _ -> false

let valid_value value =
  let n = String.length value in
  (not
     (String.exists
        (function '\000' | '\r' | '\n' -> true | _ -> false)
        value))
  && (n = 0 || not (is_whitespace value.[0] || is_whitespace value.[n - 1]))

let forbidden_pseudo_field = function
  | ":method" | ":scheme" | ":authority" | ":path" | ":status" -> true
  | _ -> false

let validate ~trailers fields =
  let rec go ~seen_regular = function
    | [] -> Ok ()
    | (name, value) :: rest ->
        let name = String.lowercase_ascii name in
        if not (valid_name name) then Error (Error.Invalid_field_name name)
        else if forbidden_pseudo_field name then
          Error (Error.Forbidden_pseudo_field name)
        else if is_pseudo name && (trailers || seen_regular) then
          Error (Error.Misplaced_pseudo_field name)
        else if not (valid_value value) then
          Error (Error.Invalid_field_value name)
        else go ~seen_regular:(seen_regular || not (is_pseudo name)) rest
  in
  go ~seen_regular:false fields

let validate_headers fields = validate ~trailers:false fields
let validate_trailers fields = validate ~trailers:true fields

let get_all name fields =
  let name = String.lowercase_ascii name in
  List.filter_map
    (fun (n, value) ->
      if String.equal (String.lowercase_ascii n) name then Some value else None)
    fields

let get name fields =
  match get_all name fields with [] -> None | value :: _ -> Some value

let combined name fields =
  match get_all name fields with
  | [] -> None
  | values ->
      let separator =
        if String.equal (String.lowercase_ascii name) "cookie" then "; "
        else ", "
      in
      Some (String.concat separator values)

let is_connection_specific name =
  match String.lowercase_ascii name with
  | "connection" | "proxy-connection" | "keep-alive" | "te"
  | "transfer-encoding" | "upgrade" ->
      true
  | _ -> false

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

let without_connection_specific fields =
  let nominated =
    get_all "connection" fields
    |> List.concat_map (String.split_on_char ',')
    |> List.map (fun option -> String.lowercase_ascii (trim option))
  in
  List.filter
    (fun (name, _) ->
      let name = String.lowercase_ascii name in
      not (is_connection_specific name || List.mem name nominated))
    fields
