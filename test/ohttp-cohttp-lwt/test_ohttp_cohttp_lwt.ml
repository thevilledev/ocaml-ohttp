(* A client, a relay, a gateway, and a target over cohttp-lwt-unix, on this
   machine. *)

open Lwt.Syntax
module O = Ohttp_cohttp_lwt
module C = O.Make (Cohttp_lwt_unix.Client)
module Server = Cohttp_lwt_unix.Server
module Body = Cohttp_lwt.Body

let () = Mirage_crypto_rng_unix.use_default ()
let rng = Mirage_crypto_rng.default_generator ()

let free_port () =
  let socket = Unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
  Unix.bind socket (Unix.ADDR_INET (Unix.inet_addr_loopback, 0));
  let port =
    match Unix.getsockname socket with
    | Unix.ADDR_INET (_, port) -> port
    | Unix.ADDR_UNIX _ -> assert false
  in
  Unix.close socket;
  port

let local port path =
  Uri.of_string (Printf.sprintf "http://127.0.0.1:%d%s" port path)

let serve port handler =
  Lwt.async (fun () ->
      Server.create
        ~mode:(`TCP (`Port port))
        (Server.make ~callback:(fun _conn -> handler) ()))

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

let target_port = free_port ()
let gateway_port = free_port ()
let local_gateway_port = free_port ()
let relay_port = free_port ()
let relay = local relay_port "/"

let () =
  let service =
    Ohttp.Service.Gateway.create ~rng
      ~replay:(Ohttp.Replay.create ~tolerance:60. ~capacity:1000 ())
      (Result.get_ok (Ohttp.Gateway.create [ key ]))
  in
  serve target_port target;
  serve gateway_port
    (O.Gateway.handler service
       (C.Target.forward
          ~targets:
            [
              ("target.example", local target_port "");
              ("gone.example", local (free_port ()) "");
            ]));
  serve local_gateway_port
    (O.Gateway.handler service (O.Target.of_handler target));
  serve relay_port (C.Relay.handler ~gateway:(local gateway_port "/gateway"))

(* The servers start with the first test; give them a moment to listen. *)
let rec retry n f =
  Lwt.catch f (fun e ->
      if n = 0 then Lwt.fail e
      else
        let* () = Lwt_unix.sleep 0.05 in
        retry (n - 1) f)

let run f = Lwt_main.run (retry 100 f)
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
    ]
