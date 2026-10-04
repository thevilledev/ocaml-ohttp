(* A client, a relay, a gateway, and a target over cohttp-lwt-unix, on this
   machine. *)

open Lwt.Syntax
module O = Ohttp_cohttp_lwt
module C = O.Make (Cohttp_lwt_unix.Client)
module Server = Cohttp_lwt_unix.Server
module Body = Cohttp_lwt.Body

let () = Mirage_crypto_rng_unix.use_default ()
let rng = Mirage_crypto_rng.default_generator ()

(* opam's sandbox on macOS lets a build open no TCP socket, not even on the
   loopback interface, and every test here needs one. *)
let () =
  match
    let socket = Unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
    Fun.protect
      ~finally:(fun () -> Unix.close socket)
      (fun () -> Unix.bind socket (Unix.ADDR_INET (Unix.inet_addr_loopback, 0)))
  with
  | () -> ()
  | exception Unix.Unix_error (((Unix.EPERM | Unix.EACCES) as e), _, _) ->
      Printf.printf "Skipped: no TCP socket on the loopback interface: %s.\n"
        (Unix.error_message e);
      exit 0

(* A socket bound to a port of the system's choosing on the loopback interface,
   and the port. The socket stays open, so that nothing else can take the port:
   a port that is chosen, released, and bound again later can be given to
   another server in between, whose bind then fails. *)
let bound () =
  let socket = Unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
  Unix.bind socket (Unix.ADDR_INET (Unix.inet_addr_loopback, 0));
  match Unix.getsockname socket with
  | Unix.ADDR_INET (_, port) -> (socket, port)
  | Unix.ADDR_UNIX _ -> assert false

let local port path =
  Uri.of_string (Printf.sprintf "http://127.0.0.1:%d%s" port path)

(* A server, listening before this returns its port. *)
let serve handler =
  let socket, port = bound () in
  Unix.listen socket 16;
  Lwt.async (fun () ->
      Server.create
        ~mode:(`TCP (`Socket (Lwt_unix.of_unix_file_descr socket)))
        (Server.make ~callback:(fun _conn -> handler) ()));
  port

(* An origin server that knows nothing about any of this. *)
let target (request : Http.Request.t) body =
  let* content = Body.to_string body in
  Server.respond_string ~status:`OK
    ~body:
      (Printf.sprintf "%s %s with %d bytes"
         (Http.Method.to_string request.meth)
         request.resource (String.length content))
    ()

let key =
  Result.get_ok (Ohttp.Gateway.Key.generate ~rng ~key_id:1 Hpke.Kem.X25519)

(* A request to the strict gateway for this path waits until [release] is woken,
   after waking [entered]: it holds the gateway's one place. *)
let entered, entered_u = Lwt.wait ()
let release, release_u = Lwt.wait ()

let service =
  Ohttp.Service.Gateway.create ~rng
    ~replay:(Ohttp.Replay.create ~tolerance:60. ~capacity:1000 ())
    (Result.get_ok (Ohttp.Gateway.create [ key ]))

let target_port = serve target

(* A port on which nothing listens, so that connections to it are refused. It
   stays bound until every server has its own port. *)
let gone_socket, gone_port = bound ()

let gateway_port =
  serve
    (O.Gateway.handler service
       (C.Target.forward
          ~targets:
            [
              ("target.example", local target_port "");
              ("gone.example", local gone_port "");
            ]))

let local_gateway_port =
  serve (O.Gateway.handler service (O.Target.of_handler target))

let relay_port =
  serve
    (C.Relay.handler
       (Ohttp.Service.Relay.create ())
       ~gateway:(local gateway_port "/gateway"))

let strict_gateway_port =
  (* Room for a short request, one at a time, and a short answer. *)
  let strict =
    Ohttp.Service.Gateway.create ~rng ~max_request_size:256 ~max_in_flight:1
      (Result.get_ok (Ohttp.Gateway.create [ key ]))
  in
  let forward =
    C.Target.forward ~max_response_size:16
      ~targets:[ ("target.example", local target_port "") ]
  in
  serve
    (O.Gateway.handler strict (fun (request : Bhttp.Request.t) ->
         if request.path = "/wait" then (
           if Lwt.is_sleeping entered then Lwt.wakeup_later entered_u ();
           let* () = release in
           Lwt.return (Bhttp.Response.make ~status:200 ()))
         else forward request))

let strict_relay_port =
  serve
    (C.Relay.handler
       (Ohttp.Service.Relay.create ~max_request_size:256 ~max_response_size:16
          ())
       ~gateway:(local gateway_port "/gateway"))

let () = Unix.close gone_socket
let relay = local relay_port "/"
let strict_relay = local strict_relay_port "/"

(* Every server listens already, and accepts once the first test runs. *)
let run f = Lwt_main.run (f ())
let config = Ohttp.Gateway.Key.config key

let post ?(headers = []) ?(content = "") ?(authority = "target.example")
    ?(path = "/submit?x=1") () =
  Bhttp.Request.make ~meth:"POST" ~authority ~path ~headers ~content ()

let call ?now ?(relay = relay) ?(config = config) request =
  run (fun () -> C.Client.call ~rng ?now ~relay config request)

let status = function
  | Ok (r : Bhttp.Response.t) -> r.status
  | Error e -> Alcotest.failf "%a" Ohttp.Error.pp e

let test_key_configs () =
  let configs =
    run (fun () ->
        C.Client.key_configs
          (local gateway_port Ohttp.Http_binding.well_known_gateway_path))
  in
  match configs with
  | Ok [ c ] ->
      Alcotest.(check bool) "the key" true (Ohttp.Key_config.equal c config)
  | _ -> Alcotest.fail "expected one key configuration"

let test_call () =
  match call (post ~content:"hello" ()) with
  | Ok r ->
      Alcotest.(check int) "status" 200 r.status;
      Alcotest.(check string)
        "what the target saw" "POST /submit?x=1 with 5 bytes" r.content
  | Error e -> Alcotest.failf "%a" Ohttp.Error.pp e

let test_other_target () =
  Alcotest.(check int)
    "refused inside the encapsulation" 403
    (status (call (post ~authority:"other.example" ())));
  Alcotest.(check int)
    "no answer" 504
    (status (call (post ~authority:"gone.example" ())))

let test_wrong_clock () =
  Alcotest.(check int)
    "corrected and retried" 200
    (status (call ~now:(fun () -> Unix.gettimeofday () -. 3600.) (post ())))

let test_unknown_key () =
  let other =
    Result.get_ok (Ohttp.Gateway.Key.generate ~rng ~key_id:9 Hpke.Kem.X25519)
  in
  Alcotest.(check bool)
    "refused in the clear" true
    (call ~config:(Ohttp.Gateway.Key.config other) (post ())
    = Error (Ohttp.Error.Unexpected_status 400))

let test_in_process () =
  (* No relay: the client posts to the gateway itself. *)
  match
    call ~relay:(local local_gateway_port "/gateway") (post ~content:"hi" ())
  with
  | Ok r ->
      Alcotest.(check string)
        "answered by the handler" "POST /submit?x=1 with 2 bytes" r.content
  | Error e -> Alcotest.failf "%a" Ohttp.Error.pp e

let test_refusals () =
  let status_of meth uri =
    run (fun () ->
        let* response, body = Cohttp_lwt_unix.Client.call meth uri in
        let+ () = Body.drain_body body in
        Http.Status.to_int response.status)
  in
  Alcotest.(check int) "a GET to the relay" 405 (status_of `GET relay);
  Alcotest.(check int)
    "a GET to the gateway's resource" 405
    (status_of `GET (local gateway_port "/gateway"));
  Alcotest.(check int)
    "elsewhere on the gateway" 404
    (status_of `GET (local gateway_port "/other"))

let strict_gateway = local strict_gateway_port "/gateway"

(* The status of a POST of [chunks] as an Encapsulated Request, sent without a
   content-length, so that only counting can find it too long. *)
let post_chunks uri chunks =
  run (fun () ->
      let* response, body =
        Cohttp_lwt_unix.Client.post
          ~headers:
            (Http.Header.of_list Ohttp.Http_binding.Client.request_headers)
          ~body:(Body.of_stream (Lwt_stream.of_list chunks))
          uri
      in
      let+ () = Body.drain_body body in
      Http.Status.to_int response.status)

let unexpected status = Error (Ohttp.Error.Unexpected_status status)

let test_request_size () =
  let long = post ~content:(String.make 1000 'x') () in
  Alcotest.(check bool)
    "a gateway refuses it in the clear" true
    (call ~relay:strict_gateway long = unexpected 413);
  Alcotest.(check bool)
    "a relay refuses it" true
    (call ~relay:strict_relay long = unexpected 413);
  Alcotest.(check int)
    "a gateway counts what is not declared" 413
    (post_chunks strict_gateway (List.init 10 (fun _ -> String.make 100 'x')));
  Alcotest.(check int)
    "a relay too" 413
    (post_chunks strict_relay (List.init 10 (fun _ -> String.make 100 'x')));
  Alcotest.(check int)
    "what fits is read" 400
    (post_chunks strict_gateway [ String.make 200 'x'; String.make 56 'x' ]);
  Alcotest.(check int)
    "one byte more is not" 413
    (post_chunks strict_gateway [ String.make 200 'x'; String.make 57 'x' ])

let test_response_size () =
  Alcotest.(check bool)
    "a client refuses a long answer" true
    (run (fun () ->
         C.Client.call ~max_response_size:16 ~rng ~relay config (post ()))
    = Error (Ohttp.Error.Content_too_large 16));
  Alcotest.(check int)
    "a gateway seals a 502 for a target's long answer" 502
    (status (call ~relay:strict_gateway (post ())));
  Alcotest.(check bool)
    "a relay answers a gateway's long answer with a 502" true
    (call ~relay:strict_relay (post ()) = unexpected 502)

(* Not retried: a second request that is let in waits for good. *)
let test_in_flight () =
  Lwt_main.run
    (let first =
       C.Client.call ~rng ~relay:strict_gateway config (post ~path:"/wait" ())
     in
     let* () = entered in
     let* second =
       Lwt_unix.with_timeout 5. (fun () ->
           C.Client.call ~rng ~relay:strict_gateway config
             (post ~path:"/wait" ()))
     in
     Alcotest.(check bool) "one too many" true (second = unexpected 503);
     Lwt.wakeup_later release_u ();
     let* first = first in
     Alcotest.(check int) "the first is answered" 200 (status first);
     let+ third =
       C.Client.call ~rng ~relay:strict_gateway config (post ~path:"/wait" ())
     in
     Alcotest.(check int) "and its place is free again" 200 (status third))

let () =
  Alcotest.run "ohttp-cohttp-lwt"
    [
      ( "end to end",
        [
          Alcotest.test_case "key configurations" `Quick test_key_configs;
          Alcotest.test_case "call" `Quick test_call;
          Alcotest.test_case "other targets" `Quick test_other_target;
          Alcotest.test_case "a wrong clock" `Quick test_wrong_clock;
          Alcotest.test_case "an unknown key" `Quick test_unknown_key;
          Alcotest.test_case "a target in the same process" `Quick
            test_in_process;
          Alcotest.test_case "refusals" `Quick test_refusals;
        ] );
      ( "limits",
        [
          Alcotest.test_case "request size" `Quick test_request_size;
          Alcotest.test_case "response size" `Quick test_response_size;
          Alcotest.test_case "requests in flight" `Quick test_in_flight;
        ] );
    ]
