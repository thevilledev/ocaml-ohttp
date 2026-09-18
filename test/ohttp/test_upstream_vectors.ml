(* The vectors that chris-wood/ohttp-go generates for itself, recorded in
   test/vectors/ohttp-go-vectors.json. Its own verification only seals and opens
   again; here its recorded bytes are the known answers. *)

open Ohttp
open Vectors
open Yojson.Safe.Util

let test_vector vector =
  let kem = hpke_ok (Hpke.Kem.of_int (int_field vector "kem_id")) in
  let pair =
    match
      Suite.symmetric_of_ints
        (int_field vector "kdf_id", int_field vector "aead_id")
    with
    | Some pair -> pair
    | None -> Alcotest.fail "the vector uses an algorithm that is not provided"
  in
  let seed = hex_field vector "config_seed" in
  (* NewConfigFromSeed is RFC 9180 DeriveKeyPair, and key identifier 0. *)
  let key =
    ok (Gateway.Key.derive ~key_id:0 ~symmetric:[ pair ] kem ~ikm:seed)
  in
  check_bytes "the seed derives the same key configuration"
    (hex_field vector "config")
    (Key_config.encode (Gateway.Key.config key));
  let gateway = ok (Gateway.create [ key ]) in
  let private_key, _ = hpke_ok (Hpke.derive_key_pair kem ~ikm:seed) in
  vector |> member "transactions" |> to_list
  |> List.iter (fun transaction ->
      let encapsulated_request = hex_field transaction "encapsulatedRequest" in
      let request, _ = ok (Gateway.decapsulate gateway encapsulated_request) in
      check_bytes "request" (hex_field transaction "request") request;
      check_bytes "response"
        (hex_field transaction "response")
        (ok
           (Ohttp_test_support.Replay.open_response ~private_key
              ~encapsulated_request
              (hex_field transaction "encapsulatedResponse"))))

let tests =
  [
    Alcotest.test_case "ohttp-go" `Quick (fun () ->
        let vectors =
          Yojson.Safe.from_file "../vectors/ohttp-go-vectors.json" |> to_list
        in
        Alcotest.(check bool) "there are vectors" true (vectors <> []);
        List.iter test_vector vectors);
  ]
