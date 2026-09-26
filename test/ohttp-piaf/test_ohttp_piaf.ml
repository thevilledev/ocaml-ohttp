(* A client, a relay, a gateway, and a target over Piaf, on this machine. *)

module O = Ohttp_piaf

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

(* An origin server that knows nothing about any of this. *)
let target ({ request; _ } : _ Piaf.Server.ctx) =
  let content = Result.get_ok (Piaf.Body.to_string request.body) in
  Piaf.Response.of_string
    ~body:
      (Printf.sprintf "%s %s with %d bytes"
         (Piaf.Method.to_string request.meth)
         request.target (String.length content))
    `OK

let key =
  Result.get_ok (Ohttp.Gateway.Key.generate ~rng ~key_id:1 Hpke.Kem.X25519)

let config = Ohttp.Gateway.Key.config key

let post ?(content = "") ?(authority = "target.example") () =
  Bhttp.Request.make ~meth:"POST" ~authority ~path:"/submit?x=1" ~content ()

let fail e = Alcotest.failf "%a" O.pp_error e

let status = function
  | Ok (r : Bhttp.Response.t) -> r.status
  | Error e -> fail e

let () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let local port path =
    Uri.of_string (Printf.sprintf "http://127.0.0.1:%d%s" port path)
  in
  let servers = ref [] in
  let listen handler =
    let port = free_port () in
    let config =
      Piaf.Server.Config.create (`Tcp (Eio.Net.Ipaddr.V4.loopback, port))
    in
    servers :=
      Piaf.Server.Command.start ~sw env (Piaf.Server.create ~config handler)
      :: !servers;
    port
  in
  let service =
    Ohttp.Service.Gateway.create ~rng
      ~replay:(Ohttp.Replay.create ~tolerance:60. ~capacity:1000 ())
      (Result.get_ok (Ohttp.Gateway.create [ key ]))
  in
  let target_port = listen target in
  let gateway =
    listen
      (O.Gateway.handler service
         (O.Target.forward env
            ~targets:
              [
                ("target.example", local target_port "");
                ("gone.example", local (free_port ()) "");
              ]))
  in
  let relay =
    local (listen (O.Relay.handler env ~gateway:(local gateway "/gateway"))) "/"
  in
  let call ?now ?(config = config) request =
    O.Client.call env ~rng ?now ~relay config request
  in
  let test_key_configs () =
    match
      O.Client.key_configs env
        (local gateway Ohttp.Http_binding.well_known_gateway_path)
    with
    | Ok [ c ] ->
        Alcotest.(check bool) "the key" true (Ohttp.Key_config.equal c config)
    | Ok _ -> Alcotest.fail "expected one key configuration"
    | Error e -> fail e
  in
  let test_call () =
    match call (post ~content:"hello" ()) with
    | Ok r ->
        Alcotest.(check int) "status" 200 r.status;
        Alcotest.(check string)
          "what the target saw" "POST /submit?x=1 with 5 bytes" r.content
    | Error e -> fail e
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
    match call ~config:(Ohttp.Gateway.Key.config other) (post ()) with
    | Error (`Ohttp (Ohttp.Error.Unexpected_status 400)) -> ()
    | _ -> Alcotest.fail "expected a 400 in the clear"
  in
  let test_refusals () =
    let status_of uri =
      Eio.Switch.run @@ fun sw ->
      match Piaf.Client.Oneshot.get ~sw env uri with
      | Ok response ->
          ignore (Piaf.Body.drain response.body);
          Piaf.Status.to_code response.status
      | Error e -> Alcotest.failf "%a" Piaf.Error.pp_hum e
    in
    Alcotest.(check int) "a GET to the relay" 405 (status_of relay);
    Alcotest.(check int)
      "a GET to the gateway's resource" 405
      (status_of (local gateway "/gateway"));
    Alcotest.(check int)
      "elsewhere on the gateway" 404
      (status_of (local gateway "/other"))
  in
  Alcotest.run ~and_exit:false "ohttp-piaf"
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
    ];
  List.iter Piaf.Server.Command.shutdown !servers
