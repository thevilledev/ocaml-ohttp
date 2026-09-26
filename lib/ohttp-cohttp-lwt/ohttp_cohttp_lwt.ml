(* Oblivious HTTP over cohttp-lwt. *)

open Lwt.Syntax
module Body = Cohttp_lwt.Body
module Service = Ohttp.Service

type handler = Http.Request.t -> Body.t -> (Http.Response.t * Body.t) Lwt.t
type forward = Bhttp.Request.t -> Bhttp.Response.t Lwt.t

let respond (response : Service.response) =
  let body = response.body in
  Lwt.return
    ( Http.Response.make
        ~status:(Http.Status.of_int response.status)
        ~headers:
          (Http.Header.add_unless_exists
             (Ohttp_cohttp.header response.headers)
             "content-length"
             (string_of_int (String.length body)))
        (),
      Body.of_string body )

let not_found () = respond { status = 404; headers = []; body = "" }

module Gateway = struct
  let key_configs service _request body =
    let* () = Body.drain_body body in
    respond (Service.Gateway.key_configs service)

  let requests ?(now = Unix.gettimeofday) service forward
      (request : Http.Request.t) body =
    let* content = Body.to_string body in
    match
      Service.Gateway.receive service ~now:(now ())
        ~meth:(Http.Method.to_string request.meth)
        ~headers:(Http.Header.to_list request.headers)
        content
    with
    | Respond response -> respond response
    | Forward (inner, seal) ->
        let* response =
          Lwt.catch
            (fun () -> forward inner)
            (fun _ -> Lwt.return (Bhttp.Response.make ~status:500 ()))
        in
        respond (seal response)

  let handler ?path ?now service forward (request : Http.Request.t) body =
    match Ohttp_cohttp.gateway_resource ?path request with
    | `Key_configs -> key_configs service request body
    | `Requests -> requests ?now service forward request body
    | `Not_found ->
        let* () = Body.drain_body body in
        not_found ()
end

module Target = struct
  let of_handler handler (request : Bhttp.Request.t) =
    let* response, body =
      handler
        (Ohttp_cohttp.request_of_bhttp request)
        (Body.of_string request.content)
    in
    let+ content = Body.to_string body in
    Ohttp_cohttp.response_to_bhttp response content
end

module Make (Http_client : Cohttp_lwt.S.Client) = struct
  module Client = struct
    let key_configs ?ctx uri =
      let* response, body =
        Http_client.get ?ctx
          ~headers:
            (Ohttp_cohttp.header
               Ohttp.Http_binding.Client.key_config_request_headers)
          uri
      in
      let+ content = Body.to_string body in
      Service.Client.key_configs
        ~status:(Http.Status.to_int response.status)
        ~headers:(Http.Header.to_list response.headers)
        content

    let post ?ctx ~relay (request : Service.request) =
      let* response, body =
        Http_client.post ?ctx
          ~headers:(Ohttp_cohttp.header request.headers)
          ~body:(Body.of_string request.body)
          relay
      in
      let+ content = Body.to_string body in
      (response, content)

    let call ?ctx ~rng ?preference ?framing ?padding ?(date = true)
        ?(now = Unix.gettimeofday) ~relay config request =
      let rec send (request, exchange) =
        let* (response : Http.Response.t), content = post ?ctx ~relay request in
        match
          Service.Client.finish exchange
            ~status:(Http.Status.to_int response.status)
            ~headers:(Http.Header.to_list response.headers)
            content
        with
        | Error _ as e -> Lwt.return e
        | Ok (Response response) -> Lwt.return (Ok response)
        | Ok (Retry (request, exchange)) -> send (request, exchange)
      in
      match
        Service.Client.start ~rng ?preference ?framing ?padding
          ?now:(if date then Some (now ()) else None)
          config request
      with
      | Error _ as e -> Lwt.return e
      | Ok started -> send started
  end

  module Relay = struct
    let handler ?ctx ~gateway (request : Http.Request.t) body =
      let* content = Body.to_string body in
      match
        Service.Relay.request
          ~meth:(Http.Method.to_string request.meth)
          ~headers:(Http.Header.to_list request.headers)
          content
      with
      | Error response -> respond response
      | Ok forwarded ->
          let* answer =
            Lwt.catch
              (fun () ->
                let+ (response : Http.Response.t), content =
                  Client.post ?ctx ~relay:gateway forwarded
                in
                Service.Relay.response
                  ~status:(Http.Status.to_int response.status)
                  ~headers:(Http.Header.to_list response.headers)
                  content)
              (fun _ -> Lwt.return Service.Relay.unreachable)
          in
          respond answer
  end

  module Target = struct
    let forward ?ctx ~targets (request : Bhttp.Request.t) =
      match Ohttp_cohttp.target ~targets request with
      | Error response -> Lwt.return response
      | Ok uri ->
          Lwt.catch
            (fun () ->
              let* response, body =
                Http_client.call ?ctx
                  ~headers:(Ohttp_cohttp.request_headers request)
                  ~body:(Body.of_string request.content)
                  (Http.Method.of_string request.meth)
                  uri
              in
              let+ content = Body.to_string body in
              Ohttp_cohttp.response_to_bhttp response content)
            (* No answer from the target is an answer to the client, and is
               sealed like any other (RFC 9458 Section 5). *)
            (fun _ -> Lwt.return (Bhttp.Response.make ~status:504 ()))
  end
end
