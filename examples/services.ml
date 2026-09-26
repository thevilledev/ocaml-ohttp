(* The four parties of Oblivious HTTP over cohttp-lwt-unix.

   The client, the relay, and the gateway come from the ohttp-cohttp-lwt
   package; the rest is an ordinary HTTP server. *)

open Lwt.Syntax
module Server = Cohttp_lwt_unix.Server
module Body = Cohttp_lwt.Body
module Ohttp_client = Ohttp_cohttp_lwt.Make (Cohttp_lwt_unix.Client)

let serve ?stop ~port handler =
  Server.create ?stop
    ~mode:(`TCP (`Port port))
    (Server.make ~callback:(fun _conn -> handler) ())

(* Target: an origin server that knows nothing about any of this. *)

let target (request : Http.Request.t) body =
  let* content = Body.to_string body in
  Server.respond_string ~status:`OK
    ~headers:(Http.Header.of_list [ ("content-type", "text/plain") ])
    ~body:
      (Printf.sprintf "%s %s with %d bytes of content"
         (Http.Method.to_string request.meth)
         request.resource (String.length content))
    ()

(* Gateway: removes the encapsulation, asks the target, and seals its answer.
   [targets] maps the authorities that it serves to where they are reached; a
   gateway that forwarded anywhere would be an open proxy.

   [replay] remembers the encapsulated keys of the requests it served, and
   refuses one whose date is too far from its clock, so that it need not
   remember them for long (RFC 9458 Section 6.5). Only requests that are not
   idempotent need this; the example checks every request. *)

let gateway ~rng ~replay ~targets gateway =
  Ohttp_cohttp_lwt.Gateway.handler
    (Ohttp.Service.Gateway.create ~rng ~replay gateway)
    (Ohttp_client.Target.forward ~targets)

(* Relay: passes the content on and nothing else, so that the gateway learns
   nothing about the client. It cannot read what it carries. Like the gateway,
   it refuses requests beyond the default limits of Ohttp.Service on their
   length and on how many it forwards at once. *)

let relay ~gateway_uri =
  Ohttp_client.Relay.handler
    (Ohttp.Service.Relay.create ())
    ~gateway:gateway_uri

(* Client *)

let fetch_key_configs uri = Ohttp_client.Client.key_configs uri

(* The request goes with the client's date. If the gateway finds it too far from
   its own, it says so with its time, and the request is sent once more,
   encapsulated anew, with a date that its clock would give. [clock] is the
   client's clock, which a test can set wrong. *)
let call ~rng ?clock ~relay_uri config request =
  Ohttp_client.Client.call ~rng ?now:clock ~relay:relay_uri config request

(* One Encapsulated Request, as it is, to the relay: what [call] does, without
   the retry, for an example that sends the same request twice. *)
let post ~relay_uri context encapsulated =
  let* response, body =
    Cohttp_lwt_unix.Client.post
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
