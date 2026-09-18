(* RFC 9458 Appendix A, from test/vectors/rfc9458.json, which
   tools/extract_rfc_vectors.py extracts from the RFC text. Every value of the
   appendix is reproduced, in both directions. *)

open Ohttp
open Vectors

let vector = lazy (List.hd (vectors "rfc9458.json"))
let value name = hex_field (Lazy.force vector) name
let kem = Hpke.Kem.X25519

let aes : Suite.symmetric =
  { kdf = Hpke.Kdf.Hkdf_sha256; aead = Hpke.Aead.Aes_128_gcm }

let chacha : Suite.symmetric =
  { kdf = Hpke.Kdf.Hkdf_sha256; aead = Hpke.Aead.Chacha20_poly1305 }

let suite = Suite.make kem aes
let config () = ok (Key_config.decode (value "key_config"))

let gateway_key () =
  let private_key = hpke_ok (Hpke.Private_key.of_bytes ~kem (value "skR")) in
  ok
    (Gateway.Key.of_private_key ~key_id:1 ~symmetric:[ aes; chacha ] private_key)

(* "This context is constructed from the following ephemeral secret key". The
   appendix gives the key itself, which only hpke.for_testing can use. *)
let published_ephemeral : Client.sender_setup =
 fun hpke_suite ~recipient ~info ->
  let ephemeral = hpke_ok (Hpke.Private_key.of_bytes ~kem (value "skE")) in
  Hpke_for_testing.setup_base_sender hpke_suite ~ephemeral ~recipient ~info

let test_key_config () =
  let config = config () in
  Alcotest.(check int) "key identifier" 1 (Key_config.key_id config);
  Alcotest.(check bool) "KEM" true (Key_config.kem config = kem);
  Alcotest.(check bool)
    "symmetric algorithms" true
    (Key_config.symmetric config = [ aes; chacha ]);
  check_bytes "encodes to the same bytes" (value "key_config")
    (Key_config.encode config);
  (* "a key configuration that includes the corresponding public key" *)
  check_bytes "the secret key has this configuration" (value "key_config")
    (Key_config.encode (Gateway.Key.config (gateway_key ())));
  Alcotest.(check bool)
    "the client selects HKDF-SHA256 and AES-128-GCM" true
    (ok (Key_config.select config) = suite)

let test_header_and_info () =
  let header = Encapsulation.header ~key_id:1 suite in
  check_bytes "header"
    (String.sub (value "encapsulated_request") 0 Encapsulation.header_length)
    header;
  check_bytes "info" (value "info")
    (Encapsulation.info ~label:Encapsulation.bhttp_labels.request ~header);
  Alcotest.(check (result (pair int (pair int (pair int int))) error))
    "parsed header"
    (Ok (1, (0x0020, (0x0001, 0x0001))))
    (Result.map
       (fun (key_id, kem, kdf, aead) -> (key_id, (kem, (kdf, aead))))
       (Encapsulation.parse_header (value "encapsulated_request")))

let test_client () =
  let encapsulated, context =
    ok
      (Client.encapsulate_with ~setup:published_ephemeral (config ())
         (value "request"))
  in
  check_bytes "Encapsulated Request" (value "encapsulated_request") encapsulated;
  check_bytes "response" (value "response")
    (ok (Client.decapsulate context (value "encapsulated_response")))

let test_gateway () =
  let gateway = ok (Gateway.create [ gateway_key () ]) in
  let request, context =
    ok (Gateway.decapsulate gateway (value "encapsulated_request"))
  in
  check_bytes "request" (value "request") request;
  (* "a randomly selected nonce": replay the one that the appendix selected. *)
  check_bytes "Encapsulated Response"
    (value "encapsulated_response")
    (ok
       (Gateway.encapsulate
          ~rng:(Ohttp_test_support.Fixed_rng.of_string (value "response_nonce"))
          context (value "response")))

let test_intermediate_values () =
  let private_key = hpke_ok (Hpke.Private_key.of_bytes ~kem (value "skR")) in
  let receiver =
    hpke_ok
      (Hpke.Rfc9180.setup_base_receiver (Suite.hpke suite)
         ~recipient:private_key ~encapsulated_key:(value "pkE")
         ~info:(value "info"))
  in
  let secret =
    hpke_ok
      (Hpke.Rfc9180.Receiver.export receiver
         ~context:Encapsulation.bhttp_labels.response
         ~length:(Suite.response_nonce_length suite.aead))
  in
  check_bytes "exported secret" (value "secret") secret;
  let keys =
    ok
      (Encapsulation.response_keys suite ~enc:(value "pkE") ~secret
         ~response_nonce:(value "response_nonce"))
  in
  check_bytes "salt" (value "salt") keys.salt;
  check_bytes "pseudorandom key" (value "prk") keys.prk;
  check_bytes "AEAD key" (value "aead_key") keys.key;
  check_bytes "AEAD nonce" (value "aead_nonce") keys.nonce;
  check_bytes "sealed response"
    (value "encapsulated_response")
    (ok
       (Encapsulation.seal_response suite ~enc:(value "pkE") ~secret
          ~response_nonce:(value "response_nonce") (value "response")));
  check_bytes "opened response" (value "response")
    (ok
       (Encapsulation.open_response suite ~enc:(value "pkE") ~secret
          (value "encapsulated_response")))

(* The messages of the appendix are Binary HTTP, truncated as far as RFC 9292
   Section 3.8 allows: the request ends after its control data. *)
let test_binary_http () =
  let request =
    Bhttp.Request.make ~meth:"GET" ~authority:"example.com" ~path:"/" ()
  in
  Alcotest.(check bool)
    "the request is GET https://example.com/" true
    (Bhttp.Request.decode (value "request") = Ok request);
  check_bytes "the request encodes to the same bytes" (value "request")
    (Bhttp.Request.encode_exn ~truncate:true request);
  let response = Bhttp.Response.make ~status:200 () in
  Alcotest.(check bool)
    "the response is a 200" true
    (Bhttp.Response.decode (value "response") = Ok response);
  check_bytes "the response encodes to the same bytes" (value "response")
    (Bhttp.Response.encode_exn ~truncate:true response)

let tests =
  [
    Alcotest.test_case "key configuration" `Quick test_key_config;
    Alcotest.test_case "header and info" `Quick test_header_and_info;
    Alcotest.test_case "client" `Quick test_client;
    Alcotest.test_case "gateway" `Quick test_gateway;
    Alcotest.test_case "intermediate values" `Quick test_intermediate_values;
    Alcotest.test_case "binary http messages" `Quick test_binary_http;
  ]
