open Bhttp

let hex s = `String (Hex.encode s)

let fields_to_json fields =
  `List (List.map (fun (name, value) -> `List [ hex name; hex value ]) fields)

let to_json = function
  | Message.Request (r : Request.t) ->
      `Assoc
        [
          ("kind", `String "request");
          ("method", hex r.meth);
          ("scheme", hex r.scheme);
          ("authority", hex r.authority);
          ("path", hex r.path);
          ("headers", fields_to_json r.headers);
          ("content", hex r.content);
          ("trailers", fields_to_json r.trailers);
        ]
  | Message.Response (r : Response.t) ->
      `Assoc
        [
          ("kind", `String "response");
          ( "informational",
            `List
              (List.map
                 (fun (i : Response.informational) ->
                   `Assoc
                     [
                       ("status", `Int i.status);
                       ("headers", fields_to_json i.headers);
                     ])
                 r.informational) );
          ("status", `Int r.status);
          ("headers", fields_to_json r.headers);
          ("content", hex r.content);
          ("trailers", fields_to_json r.trailers);
        ]

exception Invalid of string

let invalid fmt = Printf.ksprintf (fun s -> raise (Invalid s)) fmt

(* Never match a JSON value exhaustively: Yojson 2 and 3 differ in their
   constructors. *)
let member name json =
  match json with
  | `Assoc members -> List.assoc_opt name members
  | _ -> invalid "expected an object around %S" name

let unhex name = function
  | `String s -> (
      match Hex.decode s with
      | Ok v -> v
      | Error msg -> invalid "%s: %s" name msg)
  | _ -> invalid "%s: expected a string" name

let string_member name json =
  match member name json with Some v -> unhex name v | None -> ""

let int_member name json =
  match member name json with
  | Some (`Int n) -> n
  | _ -> invalid "%s: expected an integer" name

let fields_member name json =
  match member name json with
  | None | Some `Null -> []
  | Some (`List fields) ->
      List.map
        (function
          | `List [ n; v ] -> (unhex name n, unhex name v)
          | _ -> invalid "%s: expected pairs" name)
        fields
  | Some _ -> invalid "%s: expected a list" name

let of_json json =
  try
    match member "kind" json with
    | Some (`String "request") ->
        Ok
          (Message.Request
             {
               meth = string_member "method" json;
               scheme = string_member "scheme" json;
               authority = string_member "authority" json;
               path = string_member "path" json;
               headers = fields_member "headers" json;
               content = string_member "content" json;
               trailers = fields_member "trailers" json;
             })
    | Some (`String "response") ->
        let informational =
          match member "informational" json with
          | None | Some `Null -> []
          | Some (`List l) ->
              List.map
                (fun i ->
                  Response.informational ~status:(int_member "status" i)
                    (fields_member "headers" i))
                l
          | Some _ -> invalid "informational: expected a list"
        in
        Ok
          (Message.Response
             {
               informational;
               status = int_member "status" json;
               headers = fields_member "headers" json;
               content = string_member "content" json;
               trailers = fields_member "trailers" json;
             })
    | _ -> invalid "kind: expected \"request\" or \"response\""
  with Invalid msg -> Error msg
