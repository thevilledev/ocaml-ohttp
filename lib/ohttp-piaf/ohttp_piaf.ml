(* Oblivious HTTP over Piaf. *)

module Service = Ohttp.Service

type 'ctx handler = 'ctx Piaf.Server.ctx -> Piaf.Response.t
type forward = Bhttp.Request.t -> Bhttp.Response.t
type error = [ `Ohttp of Ohttp.Error.t | `Piaf of Piaf.Error.t ]

let pp_error ppf = function
  | `Ohttp e -> Ohttp.Error.pp ppf e
  | `Piaf e -> Piaf.Error.pp_hum ppf e

let fields headers =
  Bhttp.Field.without_connection_specific
    (Bhttp.Field.lowercase (Piaf.Headers.to_list headers))

let respond (response : Service.response) =
  Piaf.Response.of_string
    ~headers:(Piaf.Headers.of_list response.headers)
    ~body:response.body
    (Piaf.Status.of_code response.status)

let plain status = respond { status; headers = []; body = "" }

(* What failed is answered, unless the fiber is being cancelled. *)
let or_else f ~default =
  try f () with Eio.Cancel.Cancelled _ as e -> raise e | _ -> default ()

module Gateway = struct
  let key_configs service (_ : _ Piaf.Server.ctx) =
    respond (Service.Gateway.key_configs service)

  let requests ?(now = Unix.gettimeofday) service forward
      ({ request; _ } : _ Piaf.Server.ctx) =
    match Piaf.Body.to_string request.body with
    | Error _ -> plain 400
    | Ok content -> (
        match
          Service.Gateway.receive service ~now:(now ())
            ~meth:(Piaf.Method.to_string request.meth)
            ~headers:(Piaf.Headers.to_list request.headers)
            content
        with
        | Respond response -> respond response
        | Forward (inner, seal) ->
            respond
              (seal
                 (or_else
                    (fun () -> forward inner)
                    ~default:(fun () -> Bhttp.Response.make ~status:500 ()))))

  let handler ?(path = "/gateway") ?now service forward
      ({ request; _ } as ctx : _ Piaf.Server.ctx) =
    let requested = Uri.path (Uri.of_string request.target) in
    if
      request.meth = `GET
      && requested = Ohttp.Http_binding.well_known_gateway_path
    then key_configs service ctx
    else if requested = path then requests ?now service forward ctx
    else plain 404
end

(* A request that is over when its response has been read. *)
let fetch ?config ?(headers = []) ?body env ~meth uri =
  Eio.Switch.run @@ fun sw ->
  match
    Piaf.Client.Oneshot.request ?config ~headers ?body ~sw env ~meth uri
  with
  | Error e -> Error (`Piaf e)
  | Ok (response : Piaf.Response.t) -> (
      match Piaf.Body.to_string response.body with
      | Error e -> Error (`Piaf e)
      | Ok content -> Ok (response, content))

let post ?config env uri (request : Service.request) =
  fetch ?config ~headers:request.headers
    ~body:(Piaf.Body.of_string request.body)
    env ~meth:`POST uri

let ohttp r = Result.map_error (fun e -> `Ohttp e) r

module Client = struct
  let key_configs ?config env uri =
    Result.bind
      (fetch ?config
         ~headers:Ohttp.Http_binding.Client.key_config_request_headers env
         ~meth:`GET uri) (fun ((response : Piaf.Response.t), content) ->
        ohttp
          (Service.Client.key_configs
             ~status:(Piaf.Status.to_code response.status)
             ~headers:(Piaf.Headers.to_list response.headers)
             content))

  let call ?config env ~rng ?preference ?framing ?padding ?(date = true)
      ?(now = Unix.gettimeofday) ~relay key_config request =
    let rec send (request, exchange) =
      Result.bind (post ?config env relay request)
        (fun ((response : Piaf.Response.t), content) ->
          match
            Service.Client.finish exchange
              ~status:(Piaf.Status.to_code response.status)
              ~headers:(Piaf.Headers.to_list response.headers)
              content
          with
          | Error e -> Error (`Ohttp e)
          | Ok (Response response) -> Ok response
          | Ok (Retry (request, exchange)) -> send (request, exchange))
    in
    Result.bind
      (ohttp
         (Service.Client.start ~rng ?preference ?framing ?padding
            ?now:(if date then Some (now ()) else None)
            key_config request))
      send
end

module Relay = struct
  let handler ?config env ~gateway ({ request; _ } : _ Piaf.Server.ctx) =
    match Piaf.Body.to_string request.body with
    | Error _ -> plain 400
    | Ok content -> (
        match
          Service.Relay.request
            ~meth:(Piaf.Method.to_string request.meth)
            ~headers:(Piaf.Headers.to_list request.headers)
            content
        with
        | Error response -> respond response
        | Ok forwarded ->
            respond
              (match
                 or_else
                   (fun () -> post ?config env gateway forwarded)
                   ~default:(fun () -> Error (`Piaf (`Msg "no answer")))
               with
              | Ok ((response : Piaf.Response.t), content) ->
                  Service.Relay.response
                    ~status:(Piaf.Status.to_code response.status)
                    ~headers:(Piaf.Headers.to_list response.headers)
                    content
              | Error _ -> Service.Relay.unreachable))
end

module Target = struct
  let request_headers (request : Bhttp.Request.t) =
    let fields = Bhttp.Field.without_connection_specific request.headers in
    if request.authority = "" || Bhttp.Field.get "host" fields <> None then
      fields
    else ("host", request.authority) :: fields

  let forward ?config env ~targets (request : Bhttp.Request.t) =
    let targets = List.map (fun (a, uri) -> (a, Uri.to_string uri)) targets in
    match Service.Gateway.target ~targets request with
    | Error response -> response
    | Ok uri -> (
        match
          or_else
            (fun () ->
              fetch ?config ~headers:(request_headers request)
                ~body:(Piaf.Body.of_string request.content)
                env
                ~meth:(Piaf.Method.of_string request.meth)
                (Uri.of_string uri))
            ~default:(fun () -> Error (`Piaf (`Msg "no answer")))
        with
        | Ok ((response : Piaf.Response.t), content) ->
            Bhttp.Response.make
              ~status:(Piaf.Status.to_code response.status)
              ~headers:(fields response.headers) ~content ()
        (* No answer from the target is an answer to the client, and is sealed
           like any other (RFC 9458 Section 5). *)
        | Error _ -> Bhttp.Response.make ~status:504 ())
end
