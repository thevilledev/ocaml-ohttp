(* Between the messages of the http package and those of Bhttp. *)

let fields headers =
  Bhttp.Field.without_connection_specific
    (Bhttp.Field.lowercase (Http.Header.to_list headers))

let header = Http.Header.of_list

let request_to_bhttp ~scheme (request : Http.Request.t) content :
    Bhttp.Request.t =
  let fields = fields request.headers in
  {
    meth = Http.Method.to_string request.meth;
    scheme;
    authority = Option.value ~default:"" (Bhttp.Field.get "host" fields);
    path = request.resource;
    headers = List.filter (fun (name, _) -> name <> "host") fields;
    content;
    trailers = [];
  }

let request_headers (request : Bhttp.Request.t) =
  let fields = Bhttp.Field.without_connection_specific request.headers in
  let fields =
    if request.authority = "" || Bhttp.Field.get "host" fields <> None then
      fields
    else ("host", request.authority) :: fields
  in
  header fields

let request_of_bhttp (request : Bhttp.Request.t) =
  Http.Request.make
    ~meth:(Http.Method.of_string request.meth)
    ~headers:(request_headers request) request.path

let response_to_bhttp (response : Http.Response.t) content =
  Bhttp.Response.make
    ~status:(Http.Status.to_int response.status)
    ~headers:(fields response.headers) ~content ()

let request_path (request : Http.Request.t) =
  Uri.path (Uri.of_string request.resource)

let path = request_path

let gateway_resource ?(path = "/gateway") (request : Http.Request.t) =
  let requested = request_path request in
  if
    request.meth = `GET
    && requested = Ohttp.Http_binding.well_known_gateway_path
  then `Key_configs
  else if requested = path then `Requests
  else `Not_found

let target ~targets request =
  Result.map Uri.of_string
    (Ohttp.Service.Gateway.target
       ~targets:(List.map (fun (a, uri) -> (a, Uri.to_string uri)) targets)
       request)
