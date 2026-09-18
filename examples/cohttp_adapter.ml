(* Between the messages of cohttp and those of Bhttp.

   cohttp 6 takes its types from the http package, as cohttp-eio does, so this
   is all that any of them needs. Another HTTP library needs the same few lines
   over its own types: a Bhttp message is strings and pairs of strings. *)

let fields_of_cohttp headers =
  Bhttp.Field.without_connection_specific
    (Bhttp.Field.lowercase (Http.Header.to_list headers))

(* A request as a server received it. HTTP/1.1 gives the authority in the Host
   field, which moves into the control data. *)
let request_of_cohttp ~scheme (request : Http.Request.t) ~content :
    Bhttp.Request.t =
  let fields = fields_of_cohttp request.headers in
  {
    meth = Http.Method.to_string request.meth;
    scheme;
    authority = Option.value ~default:"" (Bhttp.Field.get "host" fields);
    path = request.resource;
    headers = List.filter (fun (name, _) -> name <> "host") fields;
    content;
    trailers = [];
  }

let response_of_cohttp (response : Http.Response.t) ~content : Bhttp.Response.t
    =
  Bhttp.Response.make
    ~status:(Http.Status.to_int response.status)
    ~headers:(fields_of_cohttp response.headers)
    ~content ()

(* What a client needs to send a request: where to, and with which fields. *)
let uri_of_request ?base (request : Bhttp.Request.t) =
  match base with
  | Some base -> Uri.of_string (Uri.to_string base ^ request.path)
  | None ->
      Uri.of_string
        (Printf.sprintf "%s://%s%s" request.scheme request.authority
           request.path)

let headers_of_request (request : Bhttp.Request.t) =
  let fields = Bhttp.Field.without_connection_specific request.headers in
  let fields =
    if request.authority = "" || Bhttp.Field.get "host" fields <> None then
      fields
    else ("host", request.authority) :: fields
  in
  Http.Header.of_list fields

let headers_of_response (response : Bhttp.Response.t) =
  Http.Header.of_list
    (List.filter
       (* cohttp computes these from the body it is given. *)
       (fun (name, _) -> name <> "content-length")
       (Bhttp.Field.without_connection_specific response.headers))
