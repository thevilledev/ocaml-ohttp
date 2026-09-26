(* The programs of this directory: what ohttp_gateway.exe, ohttp_relay.exe,
   ohttp_client.exe, and e2e.exe run where cohttp-lwt-unix is installed. *)

open Lwt.Syntax

(* Gateway *)

let gateway () =
  match Array.to_list Sys.argv with
  | _ :: port :: (_ :: _ as targets) ->
      let targets =
        List.map
          (fun target ->
            match String.index_opt target '=' with
            | Some i ->
                ( String.sub target 0 i,
                  Uri.of_string
                    (String.sub target (i + 1) (String.length target - i - 1))
                )
            | None -> failwith ("expected AUTHORITY=URL, got " ^ target))
          targets
      in
      Mirage_crypto_rng_unix.use_default ();
      let rng = Mirage_crypto_rng.default_generator () in
      let key =
        match Ohttp.Gateway.Key.generate ~rng ~key_id:1 Hpke.Kem.X25519 with
        | Ok key -> key
        | Error e -> failwith (Ohttp.Error.to_string e)
      in
      let gateway = Result.get_ok (Ohttp.Gateway.create [ key ]) in
      let replay = Ohttp.Replay.create ~tolerance:60. ~capacity:100_000 () in
      Printf.printf "gateway on port %s\n%!" port;
      Lwt_main.run
        (Services.serve ~port:(int_of_string port)
           (Services.gateway ~rng ~replay ~targets gateway))
  | _ ->
      prerr_endline
        "usage: ohttp_gateway PORT AUTHORITY=URL [AUTHORITY=URL ...]";
      exit 2

(* Relay *)

let relay () =
  match Sys.argv with
  | [| _; port; gateway |] ->
      Printf.printf "relay on port %s\n%!" port;
      Lwt_main.run
        (Services.serve ~port:(int_of_string port)
           (Services.relay ~gateway_uri:(Uri.of_string gateway)))
  | _ ->
      prerr_endline "usage: ohttp_relay PORT GATEWAY-URL";
      exit 2

(* Client *)

let run_client keys relay target =
  let target = Uri.of_string target in
  let* configs = Services.fetch_key_configs (Uri.of_string keys) in
  match Result.bind configs Ohttp.Key_config.select_from_list with
  | Error e -> Lwt.return (Error e)
  | Ok (config, _) ->
      let authority =
        match (Uri.host target, Uri.port target) with
        | Some host, Some port -> Printf.sprintf "%s:%d" host port
        | Some host, None -> host
        | None, _ -> ""
      in
      let request =
        Bhttp.Request.make ~meth:"GET"
          ~scheme:(Option.value ~default:"https" (Uri.scheme target))
          ~authority
          ~path:(match Uri.path_and_query target with "" -> "/" | p -> p)
          ()
      in
      Services.call
        ~rng:(Mirage_crypto_rng.default_generator ())
        ~relay_uri:(Uri.of_string relay) config request

let client () =
  match Sys.argv with
  | [| _; keys; relay; target |] -> (
      Mirage_crypto_rng_unix.use_default ();
      match Lwt_main.run (run_client keys relay target) with
      | Ok response ->
          Printf.printf "%d\n" response.status;
          List.iter
            (fun (n, v) -> Printf.printf "%s: %s\n" n v)
            response.headers;
          print_newline ();
          print_string response.content
      | Error e ->
          prerr_endline (Ohttp.Error.to_string e);
          exit 1)
  | _ ->
      prerr_endline "usage: ohttp_client KEYS-URL RELAY-URL TARGET-URL";
      exit 2

(* End to end *)

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

(* The servers start in the background; give them a moment to listen. *)
let rec retry n f =
  Lwt.catch f (fun e ->
      if n = 0 then Lwt.fail e
      else
        let* () = Lwt_unix.sleep 0.05 in
        retry (n - 1) f)

let check name condition =
  if condition then Printf.printf "ok    %s\n%!" name
  else begin
    Printf.printf "FAIL  %s\n%!" name;
    exit 1
  end

let run_e2e () =
  let rng = Mirage_crypto_rng.default_generator () in
  let key =
    Result.get_ok (Ohttp.Gateway.Key.generate ~rng ~key_id:1 Hpke.Kem.X25519)
  in
  let gateway = Result.get_ok (Ohttp.Gateway.create [ key ]) in
  let target_port = free_port () and gateway_port = free_port () in
  let relay_port = free_port () in
  let stop, stopper = Lwt.wait () in
  let servers =
    Lwt.join
      [
        Services.serve ~stop ~port:target_port Services.target;
        Services.serve ~stop ~port:gateway_port
          (Services.gateway ~rng
             ~replay:(Ohttp.Replay.create ~tolerance:60. ~capacity:1000 ())
             ~targets:[ ("target.example", local target_port "") ]
             gateway);
        Services.serve ~stop ~port:relay_port
          (Services.relay ~gateway_uri:(local gateway_port "/gateway"));
      ]
  in
  let relay_uri = local relay_port "/relay" in
  let* configs =
    retry 100 (fun () ->
        Services.fetch_key_configs
          (local gateway_port Ohttp.Http_binding.well_known_gateway_path))
  in
  let config, _ =
    Result.get_ok (Result.bind configs Ohttp.Key_config.select_from_list)
  in
  check "the client fetched the key configuration" true;
  let request =
    Bhttp.Request.make ~meth:"POST" ~authority:"target.example"
      ~path:"/submit?x=1"
      ~headers:[ ("content-type", "text/plain") ]
      ~content:"hello" ()
  in
  let* response =
    retry 100 (fun () -> Services.call ~rng ~relay_uri config request)
  in
  (match response with
  | Ok response ->
      check "the target answered through the relay and the gateway"
        (response.status = 200
        && response.content = "POST /submit?x=1 with 5 bytes of content")
  | Error e -> check (Ohttp.Error.to_string e) false);
  (* A target that the gateway does not serve: the refusal comes back sealed. *)
  let* response =
    Services.call ~rng ~relay_uri config
      { request with authority = "other.example" }
  in
  check "the gateway refuses other targets, inside the encapsulation"
    (match response with Ok r -> r.status = 403 | Error _ -> false);
  (* The same Encapsulated Request, sent again by the relay or anyone who saw
     it, is refused inside the encapsulation. *)
  let dated =
    {
      request with
      headers =
        Ohttp.Replay.date_field ~now:(Unix.gettimeofday ()) :: request.headers;
    }
  in
  let encapsulated, context =
    Result.get_ok (Ohttp.Http_message.encapsulate_request ~rng config dated)
  in
  let* first = Services.post ~relay_uri context encapsulated in
  let* second = Services.post ~relay_uri context encapsulated in
  check "a replayed request is refused"
    (match (first, second) with
    | Ok first, Ok second -> first.status = 200 && second.status = 400
    | _ -> false);
  (* A client whose clock is an hour slow is told the gateway's time, and
     succeeds when it retries. *)
  let* response =
    Services.call ~rng
      ~clock:(fun () -> Unix.gettimeofday () -. 3600.)
      ~relay_uri config request
  in
  check "a client with a wrong clock corrects it and retries"
    (match response with Ok r -> r.status = 200 | Error _ -> false);
  (* A key that the gateway does not hold: the refusal cannot be sealed. *)
  let other =
    Result.get_ok (Ohttp.Gateway.Key.generate ~rng ~key_id:9 Hpke.Kem.X25519)
  in
  let* response =
    Services.call ~rng ~relay_uri (Ohttp.Gateway.Key.config other) request
  in
  check "an unknown key is refused in the clear, with a 400"
    (response = Error (Ohttp.Error.Unexpected_status 400));
  Lwt.wakeup stopper ();
  servers

let e2e () =
  Mirage_crypto_rng_unix.use_default ();
  Lwt_main.run (run_e2e ())
