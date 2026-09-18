(* Exchanges of Binary HTTP messages. *)

let ( let* ) = Result.bind
let bhttp_error = function Ok v -> Ok v | Error e -> Error (Error.Bhttp e)
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

let expects_continue (request : Bhttp.Request.t) =
  Bhttp.Field.get_all "expect" request.headers
  |> List.concat_map (String.split_on_char ',')
  |> List.exists (fun expectation ->
      String.equal (String.lowercase_ascii (trim expectation)) "100-continue")

let encapsulate_request ~rng ?preference ?framing ?padding config request =
  if expects_continue request then Error Error.Continue_expectation
  else
    let* encoded =
      bhttp_error (Bhttp.Request.encode ?framing ?padding request)
    in
    Client.encapsulate ~rng ?preference config encoded

let decapsulate_response context encapsulated =
  let* encoded = Client.decapsulate context encapsulated in
  bhttp_error (Bhttp.Response.decode encoded)

let decapsulate_request gateway encapsulated =
  let* encoded, context = Gateway.decapsulate gateway encapsulated in
  let request =
    match Bhttp.Request.decode encoded with
    | Error _ -> Error (Bhttp.Response.make ~status:400 ())
    | Ok request when expects_continue request ->
        Error (Bhttp.Response.make ~status:417 ())
    | Ok request -> Ok request
  in
  Ok (request, context)

let encapsulate_response ~rng ?framing ?padding context response =
  let* encoded =
    bhttp_error (Bhttp.Response.encode ?framing ?padding response)
  in
  Gateway.encapsulate ~rng context encoded
