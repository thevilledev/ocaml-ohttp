(* One exchange between a client and a gateway, with no network in between.

   Run with [dune exec examples/basic.exe]. Every value that would cross the
   network is a string here: the key configuration that the client fetches, the
   Encapsulated Request that it posts to a relay as message/ohttp-req, and the
   Encapsulated Response that comes back as message/ohttp-res. *)

open Ohttp

let ( let* ) = Result.bind

let bhttp_error = function
  | Ok v -> Ok v
  | Error e -> Error (Bhttp.Error.to_string e)

let ohttp_error = function Ok v -> Ok v | Error e -> Error (Error.to_string e)

let run () =
  Mirage_crypto_rng_unix.use_default ();
  let rng = Mirage_crypto_rng.default_generator () in

  (* The gateway creates a key and publishes its configuration. *)
  let* key =
    ohttp_error (Gateway.Key.generate ~rng ~key_id:1 Hpke.Kem.X25519)
  in
  let* gateway = ohttp_error (Gateway.create [ key ]) in
  let published = Gateway.encoded_key_configs gateway in

  (* The client reads the configuration and encapsulates a request. A relay sees
     only [encapsulated]: not the target, and nothing of the request. *)
  let* configs = ohttp_error (Key_config.decode_list published) in
  let* config, _ = ohttp_error (Key_config.select_from_list configs) in
  let request =
    Bhttp.Request.make ~meth:"GET" ~authority:"example.com" ~path:"/hello"
      ~headers:[ ("accept", "text/plain") ]
      ()
  in
  let* encoded = bhttp_error (Bhttp.Request.encode request) in
  let* encapsulated, client_context =
    ohttp_error (Client.encapsulate ~rng config encoded)
  in

  (* The gateway sees the request, but not who sent it. *)
  let* decapsulated, gateway_context =
    ohttp_error (Gateway.decapsulate gateway encapsulated)
  in
  let* received = bhttp_error (Bhttp.Request.decode decapsulated) in
  Format.printf "gateway received %s %s://%s%s@." received.meth received.scheme
    received.authority received.path;
  let response =
    Bhttp.Response.make ~status:200
      ~headers:[ ("content-type", "text/plain") ]
      ~content:"hello from the target" ()
  in
  let* encoded = bhttp_error (Bhttp.Response.encode response) in
  let* encapsulated_response =
    ohttp_error (Gateway.encapsulate ~rng gateway_context encoded)
  in

  (* Only the client that sent the request can open its response. *)
  let* decapsulated =
    ohttp_error (Client.decapsulate client_context encapsulated_response)
  in
  let* response = bhttp_error (Bhttp.Response.decode decapsulated) in
  Format.printf "client received %d: %s@." response.status response.content;
  Ok ()

let () =
  match run () with
  | Ok () -> ()
  | Error msg ->
      prerr_endline msg;
      exit 1
