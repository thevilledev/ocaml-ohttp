(* A client, a relay, a gateway, and a target over cohttp-eio, on this
   machine. *)

module O = Ohttp_cohttp_eio
module Server = Cohttp_eio.Server

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

let post ?(content = "") ?(authority = "target.example") ?(path = "/submit?x=1")
    () =
  Bhttp.Request.make ~meth:"POST" ~authority ~path ~content ()

let unexpected status = Error (Ohttp.Error.Unexpected_status status)

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
  (* A target that is not listening: a port that was, and is closed once every
     server has its own port, so that none of them can be given it. *)
  let gone_socket, gone =
    let socket =
      Eio.Net.listen ~sw ~backlog:1 net (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0))
    in
    match Eio.Net.listening_addr socket with
    | `Tcp (_, port) -> (socket, Printf.sprintf "http://127.0.0.1:%d" port)
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
      (listen
         (O.Relay.handler client
            (Ohttp.Service.Relay.create ())
            ~gateway:(local gateway "/gateway")))
      "/"
  in
  (* Room for a short request, one at a time, and a short answer. A request for
     /wait resolves [entered], and holds the one place until [release] is. *)
  let entered, entered_r = Eio.Promise.create () in
  let release, release_r = Eio.Promise.create () in
  let strict_gateway =
    let forward =
      O.Target.forward ~max_response_size:16 client
        ~targets:[ ("target.example", Uri.of_string target_base) ]
    in
    local
      (listen
         (O.Gateway.handler
            (Ohttp.Service.Gateway.create ~rng ~max_request_size:256
               ~max_in_flight:1
               (Result.get_ok (Ohttp.Gateway.create [ key ])))
            (fun (request : Bhttp.Request.t) ->
              if request.path = "/wait" then (
                ignore (Eio.Promise.try_resolve entered_r ());
                Eio.Promise.await release;
                Bhttp.Response.make ~status:200 ())
              else forward request)))
      "/gateway"
  in
  let strict_relay =
    local
      (listen
         (O.Relay.handler client
            (Ohttp.Service.Relay.create ~max_request_size:256
               ~max_response_size:16 ())
            ~gateway:(local gateway "/gateway")))
      "/"
  in
  Eio.Net.close gone_socket;
  let call ?now ?(relay = relay) ?(config = config) request =
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
  (* The status of a POST of [chunks] as an Encapsulated Request, sent without a
     content-length, so that only counting can find it too long. *)
  let post_chunks uri chunks =
    Eio.Switch.run @@ fun sw ->
    let response, body =
      Cohttp_eio.Client.post client ~sw
        ~headers:(Http.Header.of_list Ohttp.Http_binding.Client.request_headers)
        ~body:(Eio.Flow.cstruct_source (List.map Cstruct.of_string chunks))
        uri
    in
    ignore (read body);
    Http.Status.to_int response.status
  in
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
  in
  let test_response_size () =
    Alcotest.(check bool)
      "a client refuses a long answer" true
      (O.Client.call ~max_response_size:16 client ~rng ~relay config (post ())
      = Error (Ohttp.Error.Content_too_large 16));
    Alcotest.(check int)
      "a gateway seals a 502 for a target's long answer" 502
      (status (call ~relay:strict_gateway (post ())));
    Alcotest.(check bool)
      "a relay answers a gateway's long answer with a 502" true
      (call ~relay:strict_relay (post ()) = unexpected 502)
  in
  let test_in_flight () =
    let wait () = call ~relay:strict_gateway (post ~path:"/wait" ()) in
    Eio.Fiber.both
      (fun () ->
        Alcotest.(check int) "the first is answered" 200 (status (wait ())))
      (fun () ->
        Eio.Promise.await entered;
        (* A second request that is let in waits for good. *)
        Alcotest.(check bool)
          "one too many" true
          (Eio.Time.with_timeout_exn (Eio.Stdenv.clock env) 5. wait
          = unexpected 503);
        Eio.Promise.resolve release_r ());
    Alcotest.(check int) "and its place is free again" 200 (status (wait ()))
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
      ( "limits",
        [
          Alcotest.test_case "request size" `Quick test_request_size;
          Alcotest.test_case "response size" `Quick test_response_size;
          Alcotest.test_case "requests in flight" `Quick test_in_flight;
        ] );
    ]
