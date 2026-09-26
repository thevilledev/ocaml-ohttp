(* The four parties of Oblivious HTTP over cohttp-lwt-unix.

   Everything specific to the protocol is a call into Ohttp that takes and
   returns strings; the rest is an ordinary HTTP client and server. *)

open Lwt.Syntax
module Server = Cohttp_lwt_unix.Server
module Client = Cohttp_lwt_unix.Client
module Body = Cohttp_lwt.Body

let respond ?(headers = []) ~status body =
  Server.respond_string
    ~headers:(Http.Header.of_list headers)
    ~status:(Http.Status.of_int status)
    ~body ()

let serve ?stop ~port callback =
  Server.create ?stop
    ~mode:(`TCP (`Port port))
    (Server.make ~callback:(fun _conn request body -> callback request body) ())

let path (request : Http.Request.t) = Uri.path (Uri.of_string request.resource)

(* Target: an origin server that knows nothing about any of this. *)

let target (request : Http.Request.t) body =
  let* content = Body.to_string body in
  respond ~status:200
    ~headers:[ ("content-type", "text/plain") ]
    (Printf.sprintf "%s %s with %d bytes of content"
       (Http.Method.to_string request.meth)
       request.resource (String.length content))

(* Gateway: removes the encapsulation, asks the target, and seals its answer.
   [targets] maps the authorities that it serves to where they are reached; a
   gateway that forwarded anywhere would be an open proxy. *)

let ask_target ~targets (request : Bhttp.Request.t) =
  match List.assoc_opt request.authority targets with
  | None -> Lwt.return (Bhttp.Response.make ~status:403 ())
  | Some base ->
      Lwt.catch
        (fun () ->
          let* response, body =
            Client.call
              ~headers:(Cohttp_adapter.headers_of_request request)
              ~body:(Body.of_string request.content)
              (Http.Method.of_string request.meth)
              (Cohttp_adapter.uri_of_request ~base request)
          in
          let+ content = Body.to_string body in
          Cohttp_adapter.response_of_cohttp response ~content)
        (* No answer from the target is an answer to the client, and is
           encapsulated like any other (RFC 9458 Section 5). *)
        (fun e ->
          prerr_endline ("no answer from the target: " ^ Printexc.to_string e);
          Lwt.return (Bhttp.Response.make ~status:504 ()))

(* Replay: the gateway remembers the encapsulated keys of the requests it
   served, and refuses one whose date is too far from its clock, so that it
   need not remember them for long (RFC 9458 Section 6.5). Only requests that
   are not idempotent need this; the example checks every request. *)

let unreplayed ~replay context request =
  let now = Unix.gettimeofday () in
  match
    Ohttp.Replay.check replay ~now
      ~enc:(Ohttp.Gateway.encapsulated_key context)
      request
  with
  | Ok () -> Ok request
  | Error rejection -> Error (Ohttp.Replay.rejection_response ~now rejection)

let gateway ~rng ~replay ~targets gateway (request : Http.Request.t) body =
  let refuse e =
    let r = Ohttp.Http_binding.Gateway.error_response e in
    respond ~status:r.status ~headers:r.headers r.body
  in
  match (request.meth, path request) with
  | `GET, p when p = Ohttp.Http_binding.well_known_gateway_path ->
      respond ~status:200
        ~headers:Ohttp.Http_binding.Gateway.key_config_response_headers
        (Ohttp.Gateway.encoded_key_configs gateway)
  | _, "/gateway" -> (
      let* encapsulated = Body.to_string body in
      let received =
        Result.bind
          (Ohttp.Http_binding.Gateway.check_request
             ~meth:(Http.Method.to_string request.meth)
             ~headers:(Http.Header.to_list request.headers))
          (fun () ->
            Ohttp.Http_message.decapsulate_request gateway encapsulated)
      in
      match received with
      (* The encapsulation is still on: answer in the clear, with a 4xx. *)
      | Error e -> refuse e
      (* It is off: from here on, every answer goes back sealed. *)
      | Ok (inner, context) -> (
          let* response =
            match Result.bind inner (unreplayed ~replay context) with
            | Ok request -> ask_target ~targets request
            | Error response -> Lwt.return response
          in
          match
            Ohttp.Http_message.encapsulate_response ~rng context response
          with
          | Ok sealed ->
              respond ~status:200
                ~headers:Ohttp.Http_binding.Gateway.response_headers sealed
          | Error e -> refuse e))
  | _ -> respond ~status:404 ""

(* Relay: passes the content on and nothing else, so that the gateway learns
   nothing about the client. It cannot read what it carries. *)

let relay ~gateway_uri (request : Http.Request.t) body =
  match (request.meth, path request) with
  | `POST, "/relay" ->
      let* content = Body.to_string body in
      Lwt.catch
        (fun () ->
          let content_type =
            Option.value ~default:""
              (Http.Header.get request.headers "content-type")
          in
          let* response, body =
            Client.post
              ~headers:(Http.Header.of_list [ ("content-type", content_type) ])
              ~body:(Body.of_string content) gateway_uri
          in
          let* content = Body.to_string body in
          let headers =
            List.filter
              (fun (name, _) -> name = "content-type" || name = "cache-control")
              (Cohttp_adapter.fields_of_cohttp response.headers)
          in
          respond ~status:(Http.Status.to_int response.status) ~headers content)
        (fun _ -> respond ~status:502 "")
  | _ -> respond ~status:404 ""

(* Client *)

let ( let*? ) promise f =
  let* result = promise in
  match result with Ok v -> f v | Error _ as e -> Lwt.return e

let fetch_key_configs uri =
  let* response, body =
    Client.get
      ~headers:
        (Http.Header.of_list
           Ohttp.Http_binding.Client.key_config_request_headers)
      uri
  in
  let+ content = Body.to_string body in
  Result.bind
    (Ohttp.Http_binding.Client.check_key_config_response
       ~status:(Http.Status.to_int response.status)
       ~headers:(Http.Header.to_list response.headers))
    (fun () -> Ohttp.Key_config.decode_list content)

let post ~relay_uri context encapsulated =
  let* response, body =
    Client.post
      ~headers:(Http.Header.of_list Ohttp.Http_binding.Client.request_headers)
      ~body:(Body.of_string encapsulated)
      relay_uri
  in
  let+ content = Body.to_string body in
  Result.bind
    (Ohttp.Http_binding.Client.check_response
       ~status:(Http.Status.to_int response.status)
       ~headers:(Http.Header.to_list response.headers))
    (fun () -> Ohttp.Http_message.decapsulate_response context content)

(* The request goes with the client's date. If the gateway finds it too far
   from its own, it says so with its time, and the request is sent once more,
   encapsulated anew, with a date that its clock would give. [clock] is the
   client's clock, which a test can set wrong. *)
let call ~rng ?(clock = Unix.gettimeofday) ~relay_uri config
    (request : Bhttp.Request.t) =
  let send offset =
    let dated =
      {
        request with
        headers =
          Ohttp.Replay.date_field ~now:(clock () +. offset) :: request.headers;
      }
    in
    let*? encapsulated, context =
      Lwt.return (Ohttp.Http_message.encapsulate_request ~rng config dated)
    in
    post ~relay_uri context encapsulated
  in
  let*? response = send 0. in
  match Ohttp.Replay.date_of_problem response with
  | Some gateway_time -> send (gateway_time -. clock ())
  | None -> Lwt.return (Ok response)
