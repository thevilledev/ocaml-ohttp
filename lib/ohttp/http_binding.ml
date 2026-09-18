(* How encapsulated messages travel over HTTP (RFC 9458 Section 5, and RFC 9540
   for finding a gateway). *)

let well_known_gateway_path = "/.well-known/ohttp-gateway"

let content_type headers =
  List.find_map
    (fun (name, value) ->
      if String.equal (String.lowercase_ascii name) "content-type" then
        Some value
      else None)
    headers

let check_content ~status ~headers media_type =
  if status <> 200 then Error (Error.Unexpected_status status)
  else
    match content_type headers with
    | Some t when Media_type.matches media_type t -> Ok ()
    | t -> Error (Error.Unexpected_content_type t)

module Client = struct
  let request_headers = [ ("content-type", Media_type.ohttp_request) ]
  let key_config_request_headers = [ ("accept", Media_type.ohttp_keys) ]

  let check_response ~status ~headers =
    check_content ~status ~headers Media_type.ohttp_response

  let check_key_config_response ~status ~headers =
    check_content ~status ~headers Media_type.ohttp_keys
end

module Gateway = struct
  let check_request ~meth ~headers =
    if not (String.equal meth "POST") then Error (Error.Method_not_allowed meth)
    else
      match content_type headers with
      | Some t when Media_type.matches Media_type.ohttp_request t -> Ok ()
      | t -> Error (Error.Unsupported_media_type t)

  let response_headers =
    [
      ("content-type", Media_type.ohttp_response); ("cache-control", "no-store");
    ]

  let key_config_response_headers = [ ("content-type", Media_type.ohttp_keys) ]

  type error_response = {
    status : int;
    headers : (string * string) list;
    body : string;
  }

  let key_problem =
    {
      status = 400;
      headers = [ ("content-type", Media_type.problem_json) ];
      body =
        {|{"type":"https://iana.org/assignments/http-problem-types#ohttp-key","title":"key configuration not acceptable"}|};
    }

  let plain status = { status; headers = []; body = "" }

  let error_response = function
    | Error.Unknown_key_id _ | Error.Unsupported_suite _
    | Error.Decapsulation_failed ->
        key_problem
    | Error.Method_not_allowed _ ->
        { (plain 405) with headers = [ ("allow", "POST") ] }
    | Error.Unsupported_media_type _ -> plain 415
    | Error.Truncated_message _ | Error.Chunk_too_large _ | Error.Bhttp _
    | Error.Continue_expectation ->
        plain 400
    | Error.Invalid_key_config _ | Error.Invalid_key_id _
    | Error.Unsupported_kem _ | Error.No_supported_suite
    | Error.Unexpected_status _ | Error.Unexpected_content_type _ | Error.Hpke _
      ->
        plain 500
end
