(* Oblivious HTTP over cohttp-eio. *)

module Body = Cohttp_eio.Body
module Server = Cohttp_eio.Server
module Service = Ohttp.Service

type handler = Http.Request.t -> Body.t -> Server.response
type forward = Bhttp.Request.t -> Bhttp.Response.t

let read body = Eio.Buf_read.(parse_exn take_all) body ~max_size:max_int

let respond (response : Service.response) =
  Server.respond_string
    ~headers:(Ohttp_cohttp.header response.headers)
    ~status:(Http.Status.of_int response.status)
    ~body:response.body ()

(* What failed is answered, unless the fiber is being cancelled. *)
let or_else f ~default =
  try f () with Eio.Cancel.Cancelled _ as e -> raise e | _ -> default ()

module Gateway = struct
  let key_configs service _request _body =
    respond (Service.Gateway.key_configs service)

  let requests ?(now = Unix.gettimeofday) service forward
      (request : Http.Request.t) body =
    match
      Service.Gateway.receive service ~now:(now ())
        ~meth:(Http.Method.to_string request.meth)
        ~headers:(Http.Header.to_list request.headers)
        (read body)
    with
    | Respond response -> respond response
    | Forward (inner, seal) ->
        respond
          (seal
             (or_else
                (fun () -> forward inner)
                ~default:(fun () -> Bhttp.Response.make ~status:500 ())))

  let handler ?path ?now service forward (request : Http.Request.t) body =
    match Ohttp_cohttp.gateway_resource ?path request with
    | `Key_configs -> key_configs service request body
    | `Requests -> requests ?now service forward request body
    | `Not_found -> respond { status = 404; headers = []; body = "" }
end

(* A request that is over when its response has been read. *)
let fetch client ?headers ?body meth uri =
  Eio.Switch.run @@ fun sw ->
  let response, body =
    Cohttp_eio.Client.call client ~sw ?headers ?body meth uri
  in
  (response, read body)

let post client uri (request : Service.request) =
  fetch client
    ~headers:(Ohttp_cohttp.header request.headers)
    ~body:(Body.of_string request.body)
    `POST uri

module Client = struct
  let key_configs client uri =
    let (response : Http.Response.t), content =
      fetch client
        ~headers:
          (Ohttp_cohttp.header
             Ohttp.Http_binding.Client.key_config_request_headers)
        `GET uri
    in
    Service.Client.key_configs
      ~status:(Http.Status.to_int response.status)
      ~headers:(Http.Header.to_list response.headers)
      content

  let call client ~rng ?preference ?framing ?padding ?(date = true)
      ?(now = Unix.gettimeofday) ~relay config request =
    let rec send (request, exchange) =
      let (response : Http.Response.t), content = post client relay request in
      match
        Service.Client.finish exchange
          ~status:(Http.Status.to_int response.status)
          ~headers:(Http.Header.to_list response.headers)
          content
      with
      | Error _ as e -> e
      | Ok (Response response) -> Ok response
      | Ok (Retry (request, exchange)) -> send (request, exchange)
    in
    Result.bind
      (Service.Client.start ~rng ?preference ?framing ?padding
         ?now:(if date then Some (now ()) else None)
         config request)
      send
end

module Relay = struct
  let handler client ~gateway (request : Http.Request.t) body =
    match
      Service.Relay.request
        ~meth:(Http.Method.to_string request.meth)
        ~headers:(Http.Header.to_list request.headers)
        (read body)
    with
    | Error response -> respond response
    | Ok forwarded ->
        respond
          (or_else
             (fun () ->
               let (response : Http.Response.t), content =
                 post client gateway forwarded
               in
               Service.Relay.response
                 ~status:(Http.Status.to_int response.status)
                 ~headers:(Http.Header.to_list response.headers)
                 content)
             ~default:(fun () -> Service.Relay.unreachable))
end

module Target = struct
  let forward client ~targets (request : Bhttp.Request.t) =
    match Ohttp_cohttp.target ~targets request with
    | Error response -> response
    | Ok uri ->
        or_else
          (fun () ->
            let response, content =
              fetch client
                ~headers:(Ohttp_cohttp.request_headers request)
                ~body:(Body.of_string request.content)
                (Http.Method.of_string request.meth)
                uri
            in
            Ohttp_cohttp.response_to_bhttp response content)
            (* No answer from the target is an answer to the client, and is
               sealed like any other (RFC 9458 Section 5). *)
          ~default:(fun () -> Bhttp.Response.make ~status:504 ())
end
