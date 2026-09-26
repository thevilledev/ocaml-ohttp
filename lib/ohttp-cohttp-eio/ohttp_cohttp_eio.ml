(* Oblivious HTTP over cohttp-eio. *)

module Body = Cohttp_eio.Body
module Server = Cohttp_eio.Server
module Service = Ohttp.Service

type handler = Http.Request.t -> Body.t -> Server.response
type forward = Bhttp.Request.t -> Bhttp.Response.t

(* The content of a body, unless it is longer than [max_size]: then the rest is
   left unread. A client leaves its switch, which closes the connection; a
   server drains it with [refuse_too_large]. *)
let read ~max_size headers body =
  if Service.exceeds ~max_size (Http.Header.to_list headers) then None
  else
    (* [take_all] asks for a byte more than it holds, to find the end. *)
    let max_size = if max_size < max_int then max_size + 1 else max_size in
    try Some (Eio.Buf_read.take_all (Eio.Buf_read.of_flow ~max_size body))
    with Eio.Buf_read.Buffer_limit_exceeded -> None

let respond (response : Service.response) =
  Server.respond_string
    ~headers:(Ohttp_cohttp.header response.headers)
    ~status:(Http.Status.of_int response.status)
    ~body:response.body ()

(* The rest of a request that is too long is read, without being kept, so that
   the connection can carry the next one. *)
let refuse_too_large body =
  let rest = Eio.Buf_read.of_flow ~max_size:4096 body in
  let rec drain () =
    match Eio.Buf_read.ensure rest 1 with
    | () ->
        Eio.Buf_read.consume rest (Eio.Buf_read.buffered_bytes rest);
        drain ()
    | exception End_of_file -> ()
  in
  drain ();
  respond Service.content_too_large

(* [f ()], if [admit] lets it in, and [busy] otherwise. *)
let admitted ~admit ~release f =
  if admit () then Fun.protect f ~finally:release else respond Service.busy

(* What failed is answered, unless the fiber is being cancelled. *)
let or_else f ~default =
  try f () with Eio.Cancel.Cancelled _ as e -> raise e | _ -> default ()

module Gateway = struct
  let key_configs service _request _body =
    respond (Service.Gateway.key_configs service)

  let requests ?(now = Unix.gettimeofday) service forward
      (request : Http.Request.t) body =
    admitted
      ~admit:(fun () -> Service.Gateway.admit service)
      ~release:(fun () -> Service.Gateway.release service)
    @@ fun () ->
    match
      read
        ~max_size:(Service.Gateway.max_request_size service)
        request.headers body
    with
    | None -> refuse_too_large body
    | Some content -> (
        match
          Service.Gateway.receive service ~now:(now ())
            ~meth:(Http.Method.to_string request.meth)
            ~headers:(Http.Header.to_list request.headers)
            content
        with
        | Respond response -> respond response
        | Forward (inner, seal) ->
            respond
              (seal
                 (or_else
                    (fun () -> forward inner)
                    ~default:(fun () -> Bhttp.Response.make ~status:500 ()))))

  let handler ?path ?now service forward (request : Http.Request.t) body =
    match Ohttp_cohttp.gateway_resource ?path request with
    | `Key_configs -> key_configs service request body
    | `Requests -> requests ?now service forward request body
    | `Not_found -> respond { status = 404; headers = []; body = "" }
end

(* A request that is over when its response has been read, or found too long:
   leaving the switch closes the connection. *)
let fetch client ~max_size ?headers ?body meth uri =
  Eio.Switch.run @@ fun sw ->
  let (response : Http.Response.t), body =
    Cohttp_eio.Client.call client ~sw ?headers ?body meth uri
  in
  (response, read ~max_size response.headers body)

let post client ~max_size uri (request : Service.request) =
  fetch client ~max_size
    ~headers:(Ohttp_cohttp.header request.headers)
    ~body:(Body.of_string request.body)
    `POST uri

module Client = struct
  let too_large max_size = Error (Ohttp.Error.Content_too_large max_size)

  let key_configs ?(max_response_size = Service.default_max_response_size)
      client uri =
    match
      fetch client ~max_size:max_response_size
        ~headers:
          (Ohttp_cohttp.header
             Ohttp.Http_binding.Client.key_config_request_headers)
        `GET uri
    with
    | _, None -> too_large max_response_size
    | response, Some content ->
        Service.Client.key_configs
          ~status:(Http.Status.to_int response.status)
          ~headers:(Http.Header.to_list response.headers)
          content

  let call ?(max_response_size = Service.default_max_response_size) client ~rng
      ?preference ?framing ?padding ?(date = true) ?(now = Unix.gettimeofday)
      ~relay config request =
    let rec send (request, exchange) =
      match post client ~max_size:max_response_size relay request with
      | _, None -> too_large max_response_size
      | response, Some content -> (
          match
            Service.Client.finish exchange
              ~status:(Http.Status.to_int response.status)
              ~headers:(Http.Header.to_list response.headers)
              content
          with
          | Error _ as e -> e
          | Ok (Response response) -> Ok response
          | Ok (Retry (request, exchange)) -> send (request, exchange))
    in
    Result.bind
      (Service.Client.start ~rng ?preference ?framing ?padding
         ?now:(if date then Some (now ()) else None)
         config request)
      send
end

module Relay = struct
  let handler client relay ~gateway (request : Http.Request.t) body =
    admitted
      ~admit:(fun () -> Service.Relay.admit relay)
      ~release:(fun () -> Service.Relay.release relay)
    @@ fun () ->
    match
      read ~max_size:(Service.Relay.max_request_size relay) request.headers body
    with
    | None -> refuse_too_large body
    | Some content -> (
        match
          Service.Relay.request
            ~meth:(Http.Method.to_string request.meth)
            ~headers:(Http.Header.to_list request.headers)
            content
        with
        | Error response -> respond response
        | Ok forwarded ->
            respond
              (or_else
                 (fun () ->
                   match
                     post client
                       ~max_size:(Service.Relay.max_response_size relay)
                       gateway forwarded
                   with
                   | _, None -> Service.Relay.unreachable
                   | response, Some content ->
                       Service.Relay.response
                         ~status:(Http.Status.to_int response.status)
                         ~headers:(Http.Header.to_list response.headers)
                         content)
                 ~default:(fun () -> Service.Relay.unreachable)))
end

module Target = struct
  let forward ?(max_response_size = Service.default_max_response_size) client
      ~targets (request : Bhttp.Request.t) =
    match Ohttp_cohttp.target ~targets request with
    | Error response -> response
    | Ok uri ->
        or_else
          (fun () ->
            match
              fetch client ~max_size:max_response_size
                ~headers:(Ohttp_cohttp.request_headers request)
                ~body:(Body.of_string request.content)
                (Http.Method.of_string request.meth)
                uri
            with
            (* Too long to seal whole: the target failed to answer. *)
            | _, None -> Bhttp.Response.make ~status:502 ()
            | response, Some content ->
                Ohttp_cohttp.response_to_bhttp response content)
            (* No answer from the target is an answer to the client, and is
               sealed like any other (RFC 9458 Section 5). *)
          ~default:(fun () -> Bhttp.Response.make ~status:504 ())
end
