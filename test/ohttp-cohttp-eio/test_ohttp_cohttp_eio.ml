(* A client, a relay, a gateway, and a target over cohttp-eio, on this
   machine. *)

module O = Ohttp_cohttp_eio
module Server = Cohttp_eio.Server

let () = Mirage_crypto_rng_unix.use_default ()
let rng = Mirage_crypto_rng.default_generator ()
let read body = Eio.Buf_read.(parse_exn take_all) body ~max_size:max_int

(* An origin server that knows nothing about any of this. *)
let target (request : Http.Request.t) body =
  let content = read body in
  Server.respond_string ~status:`OK
    ~body:
      (Printf.sprintf "%s %s with %d bytes"
         (Http.Method.to_string request.meth)
         request.resource (String.length content))
    ()

let key =
  Result.get_ok (Ohttp.Gateway.Key.generate ~rng ~key_id:1 Hpke.Kem.X25519)

let config = Ohttp.Gateway.Key.config key

let post ?(content = "") ?(authority = "target.example") () =
  Bhttp.Request.make ~meth:"POST" ~authority ~path:"/submit?x=1" ~content ()

let status = function
  | Ok (r : Bhttp.Response.t) -> r.status
  | Error e -> Alcotest.failf "%a" Ohttp.Error.pp e

let () =
  Eio_main.run @@ fun env ->
  let net = Eio.Stdenv.net env in
  let client = Cohttp_eio.Client.make ~https:None net in
  Eio.Switch.run @@ fun sw ->
  (* Each server listens on a port of the system's choosing. *)
  let listen handler =
    let socket =
      Eio.Net.listen ~sw ~backlog:16 ~reuse_addr:true net
        (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0))
    in
    Eio.Fiber.fork_daemon ~sw (fun () ->
        Server.run socket ~on_error:raise
          (Server.make ~callback:(fun _conn -> handler) ()));
    match Eio.Net.listening_addr socket with
    | `Tcp (_, port) -> Printf.sprintf "http://127.0.0.1:%d" port
    | `Unix _ -> assert false
  in
  let local base path = Uri.of_string (base ^ path) in
  let service =
    Ohttp.Service.Gateway.create ~rng
      ~replay:(Ohttp.Replay.create ~tolerance:60. ~capacity:1000 ())
      (Result.get_ok (Ohttp.Gateway.create [ key ]))
  in
  let target_base = listen target in
  (* A target that is not listening: a port that was, and is closed. *)
  let gone =
    let socket =
      Eio.Net.listen ~sw ~backlog:1 net (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0))
    in
    let addr = Eio.Net.listening_addr socket in
    Eio.Net.close socket;
    match addr with
    | `Tcp (_, port) -> Printf.sprintf "http://127.0.0.1:%d" port
    | `Unix _ -> assert false
  in
  let gateway =
    listen
      (O.Gateway.handler service
         (O.Target.forward client
            ~targets:
              [
                ("target.example", Uri.of_string target_base);
                ("gone.example", Uri.of_string gone);
              ]))
  in
  let relay =
    local
      (listen (O.Relay.handler client ~gateway:(local gateway "/gateway")))
      "/"
  in
  let call ?now ?(config = config) request =
    O.Client.call client ~rng ?now ~relay config request
  in
  let test_key_configs () =
    match
      O.Client.key_configs client
        (local gateway Ohttp.Http_binding.well_known_gateway_path)
    with
    | Ok [ c ] ->
        Alcotest.(check bool) "the key" true (Ohttp.Key_config.equal c config)
    | _ -> Alcotest.fail "expected one key configuration"
  in
  let test_call () =
    match call (post ~content:"hello" ()) with
    | Ok r ->
        Alcotest.(check int) "status" 200 r.status;
        Alcotest.(check string)
          "what the target saw" "POST /submit?x=1 with 5 bytes" r.content
    | Error e -> Alcotest.failf "%a" Ohttp.Error.pp e
  in
  let test_other_target () =
    Alcotest.(check int)
      "refused inside the encapsulation" 403
      (status (call (post ~authority:"other.example" ())));
    Alcotest.(check int)
      "no answer" 504
      (status (call (post ~authority:"gone.example" ())))
  in
  let test_wrong_clock () =
    Alcotest.(check int)
      "corrected and retried" 200
      (status (call ~now:(fun () -> Unix.gettimeofday () -. 3600.) (post ())))
  in
  let test_unknown_key () =
    let other =
      Result.get_ok (Ohttp.Gateway.Key.generate ~rng ~key_id:9 Hpke.Kem.X25519)
    in
    Alcotest.(check bool)
      "refused in the clear" true
      (call ~config:(Ohttp.Gateway.Key.config other) (post ())
      = Error (Ohttp.Error.Unexpected_status 400))
  in
  let test_refusals () =
    let status_of uri =
      Eio.Switch.run @@ fun sw ->
      let response, body = Cohttp_eio.Client.get client ~sw uri in
      ignore (read body);
      Http.Status.to_int response.status
    in
    Alcotest.(check int) "a GET to the relay" 405 (status_of relay);
    Alcotest.(check int)
      "a GET to the gateway's resource" 405
      (status_of (local gateway "/gateway"));
    Alcotest.(check int)
      "elsewhere on the gateway" 404
      (status_of (local gateway "/other"))
  in
  Alcotest.run ~and_exit:false "ohttp-cohttp-eio"
    [
      ( "end to end",
        [
          Alcotest.test_case "key configurations" `Quick test_key_configs;
          Alcotest.test_case "call" `Quick test_call;
          Alcotest.test_case "other targets" `Quick test_other_target;
          Alcotest.test_case "a wrong clock" `Quick test_wrong_clock;
          Alcotest.test_case "an unknown key" `Quick test_unknown_key;
          Alcotest.test_case "refusals" `Quick test_refusals;
        ] );
    ]
