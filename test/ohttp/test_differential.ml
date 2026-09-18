(* What other implementations produced, recorded by tools/differential and
   replayed here without them. A recording holds the seed of the gateway's key,
   so everything that a peer sealed is a known answer: its requests must open,
   and its responses must open under the secret that the rebuilt gateway context
   exports. See test/vectors/PROVENANCE.md. *)

open Ohttp
open Vectors
open Yojson.Safe.Util
module Replay = Ohttp_test_support.Replay

let key_of json =
  let kem = hpke_ok (Hpke.Kem.of_int (int_field json "kem")) in
  let symmetric =
    json |> member "symmetric" |> to_list
    |> List.map (fun pair ->
        match to_list pair with
        | [ kdf; aead ] -> (
            match Suite.symmetric_of_ints (to_int kdf, to_int aead) with
            | Some pair -> pair
            | None ->
                Alcotest.fail
                  "the corpus uses an algorithm that is not provided")
        | _ -> Alcotest.fail "symmetric: expected pairs")
  in
  let seed = hex_field json "seed" in
  let key =
    ok
      (Gateway.Key.derive ~key_id:(int_field json "key_id") ~symmetric kem
         ~ikm:seed)
  in
  let private_key, _ = hpke_ok (Hpke.derive_key_pair kem ~ikm:seed) in
  (key, private_key)

let has_prefix prefix s =
  String.length s >= String.length prefix
  && String.sub s 0 (String.length prefix) = prefix

let test_configs corpus () =
  let configs = corpus |> member "configs" |> to_list in
  Alcotest.(check bool) "the corpus has key configurations" true (configs <> []);
  List.iter
    (fun json ->
      let key, _ = key_of json in
      (* The peer derived this configuration from the same seed. *)
      check_bytes "key configuration" (hex_field json "config")
        (Key_config.encode (Gateway.Key.config key)))
    configs

let test_exchanges corpus () =
  let exchanges = corpus |> member "exchanges" |> to_list in
  Alcotest.(check bool) "the corpus has exchanges" true (exchanges <> []);
  let from_peer = ref 0 in
  List.iter
    (fun json ->
      let key, private_key = key_of json in
      let gateway = ok (Gateway.create [ key ]) in
      let encapsulated_request = hex_field json "enc_request" in
      let encapsulated_response = hex_field json "enc_response" in
      if string_field json "request_by" = "peer" then incr from_peer;
      if string_field json "response_by" = "peer" then incr from_peer;
      if has_prefix "chunked/" (string_field json "category") then begin
        let receiver =
          Chunked.Gateway.receiver (Chunked.Gateway.request gateway)
        in
        check_bytes "chunked request" (hex_field json "request")
          (ok (Chunked.open_all receiver encapsulated_request));
        check_bytes "chunked response"
          (hex_field json "response")
          (String.concat ""
             (ok
                (Replay.open_chunked_response ~private_key ~encapsulated_request
                   encapsulated_response)))
      end
      else begin
        let request, _ =
          ok (Gateway.decapsulate gateway encapsulated_request)
        in
        check_bytes "request" (hex_field json "request") request;
        check_bytes "response"
          (hex_field json "response")
          (ok
             (Replay.open_response ~private_key ~encapsulated_request
                encapsulated_response))
      end)
    exchanges;
  (* Every exchange has one side that the peer sealed. *)
  Alcotest.(check int) "sealed by the peer" (List.length exchanges) !from_peer

let tests =
  List.concat_map
    (fun peer ->
      let corpus =
        lazy (load (Printf.sprintf "differential/ohttp-%s.json" peer))
      in
      [
        Alcotest.test_case (peer ^ ", key configurations") `Quick (fun () ->
            test_configs (Lazy.force corpus) ());
        Alcotest.test_case (peer ^ ", exchanges") `Quick (fun () ->
            test_exchanges (Lazy.force corpus) ());
      ])
    [ "go"; "rust" ]
