(* Exchanges between a client and a gateway, and everything a peer can do to
   break one (RFC 9458 Sections 4.3, 4.4, and 5.2). *)

open Ohttp
open Vectors

let aes : Suite.symmetric =
  { kdf = Hpke.Kdf.Hkdf_sha256; aead = Hpke.Aead.Aes_128_gcm }

let chacha : Suite.symmetric =
  { kdf = Hpke.Kdf.Hkdf_sha256; aead = Hpke.Aead.Chacha20_poly1305 }

let key ?(key_id = 1) ?symmetric kem =
  ok
    (Gateway.Key.derive ~key_id ?symmetric kem
       ~ikm:(String.make 66 (Char.chr ((0x40 + key_id) land 0xff))))

let flip s i =
  let b = Bytes.of_string s in
  Bytes.set_uint8 b i (Bytes.get_uint8 b i lxor 0x01);
  Bytes.unsafe_to_string b

let bytes_result = Alcotest.(result octets error)

let exchange ?labels ~rng gateway config ?preference request response =
  let encapsulated, client_context =
    ok (Client.encapsulate ~rng ?labels ?preference config request)
  in
  let received, gateway_context =
    ok (Gateway.decapsulate ?labels gateway encapsulated)
  in
  check_bytes "request" request received;
  let encapsulated_response =
    ok (Gateway.encapsulate ~rng gateway_context response)
  in
  check_bytes "response" response
    (ok (Client.decapsulate client_context encapsulated_response));
  (encapsulated, encapsulated_response)

(* Every KEM with every KDF and AEAD. *)
let test_all_suites () =
  let rng = rng () in
  List.iter
    (fun kem ->
      let key = key ~symmetric:Suite.all_symmetric kem in
      let gateway = ok (Gateway.create [ key ]) in
      List.iter
        (fun (pair : Suite.symmetric) ->
          let request, response =
            exchange ~rng gateway (Gateway.Key.config key) ~preference:[ pair ]
              "request" "response"
          in
          let enc = Hpke.Kem.encapsulated_key_size kem in
          Alcotest.(check int)
            "Encapsulated Request length"
            (Encapsulation.header_length + enc + 7 + 16)
            (String.length request);
          (* The response nonce is max(Nn, Nk) bytes: 16 for AES-128-GCM, and 32
             for the AEADs with longer keys. *)
          Alcotest.(check int)
            "Encapsulated Response length"
            (Suite.response_nonce_length pair.aead + 8 + 16)
            (String.length response);
          Alcotest.(check int)
            "response nonce length"
            (if pair.aead = Hpke.Aead.Aes_128_gcm then 16 else 32)
            (Suite.response_nonce_length pair.aead))
        Suite.all_symmetric)
    Suite.all_kems

let test_payload_sizes () =
  let rng = rng () in
  let key = key Hpke.Kem.X25519 in
  let gateway = ok (Gateway.create [ key ]) in
  List.iter
    (fun size ->
      ignore
        (exchange ~rng gateway (Gateway.Key.config key) (String.make size 'q')
           (String.make size 'r')))
    [ 0; 1; 1 lsl 20 ]

let test_fresh_contexts () =
  let rng = rng () in
  let key = key Hpke.Kem.X25519 in
  let gateway = ok (Gateway.create [ key ]) in
  let config = Gateway.Key.config key in
  let first, first_response = exchange ~rng gateway config "same" "same" in
  let second, second_response = exchange ~rng gateway config "same" "same" in
  Alcotest.(check bool) "requests differ" false (String.equal first second);
  Alcotest.(check bool)
    "responses differ" false
    (String.equal first_response second_response);
  (* Even a replayed request gets a response under a new key and nonce. *)
  let _, context = ok (Gateway.decapsulate gateway first) in
  let replayed = ok (Gateway.encapsulate ~rng context "same") in
  Alcotest.(check bool)
    "responses to a replay differ" false
    (String.equal first_response replayed)

let test_response_nonce_draw () =
  let key = key Hpke.Kem.X25519 in
  let gateway = ok (Gateway.create [ key ]) in
  let encapsulated, _ =
    ok (Client.encapsulate ~rng:(rng ()) (Gateway.Key.config key) "request")
  in
  let _, context = ok (Gateway.decapsulate gateway encapsulated) in
  let nonce = String.init 16 (fun i -> Char.chr (0xa0 + i)) in
  let response =
    ok
      (Gateway.encapsulate
         ~rng:(Ohttp_test_support.Fixed_rng.of_string nonce)
         context "response")
  in
  check_bytes "the response starts with what was drawn" nonce
    (String.sub response 0 16);
  Alcotest.check_raises "and draws all of it"
    (Invalid_argument "fixed test RNG exhausted") (fun () ->
      ignore
        (Gateway.encapsulate
           ~rng:(Ohttp_test_support.Fixed_rng.of_string (String.sub nonce 0 15))
           context "response"))

let test_gateway_keys () =
  let rng = rng () in
  let x25519 = key ~key_id:1 Hpke.Kem.X25519
  and p256 = key ~key_id:2 Hpke.Kem.P256
  and p521 = key ~key_id:255 ~symmetric:[ chacha ] Hpke.Kem.P521 in
  let gateway = ok (Gateway.create [ x25519; p256; p521 ]) in
  List.iter
    (fun key ->
      ignore
        (exchange ~rng gateway (Gateway.Key.config key) "request" "response"))
    [ x25519; p256; p521 ];
  Alcotest.(check int)
    "configurations" 3
    (List.length (Gateway.key_configs gateway));
  Alcotest.(check bool)
    "served as a list" true
    (Result.map
       (List.map Key_config.key_id)
       (Key_config.decode_list (Gateway.encoded_key_configs gateway))
    = Ok [ 1; 2; 255 ]);
  let is_invalid = function
    | Error (Error.Invalid_key_config _) -> true
    | Ok _ | Error _ -> false
  in
  Alcotest.(check bool) "no key" true (is_invalid (Gateway.create []));
  Alcotest.(check bool)
    "two keys with one identifier" true
    (is_invalid (Gateway.create [ x25519; key ~key_id:1 Hpke.Kem.P256 ]));
  (* A seed derives the same key everywhere. *)
  Alcotest.(check bool)
    "derivation is deterministic" true
    (Key_config.equal
       (Gateway.Key.config x25519)
       (Gateway.Key.config (key ~key_id:1 Hpke.Kem.X25519)));
  let generated = ok (Gateway.Key.generate ~rng ~key_id:9 Hpke.Kem.P384) in
  Alcotest.(check int) "generated" 9 (Gateway.Key.key_id generated);
  ignore
    (exchange ~rng
       (ok (Gateway.create [ generated ]))
       (Gateway.Key.config generated)
       "request" "response")

(* RFC 9458 Section 4.6: another protocol reuses the encapsulation with labels
   of its own, which keep its messages apart from these. *)
let test_labels () =
  let rng = rng () in
  let key = key Hpke.Kem.X25519 in
  let gateway = ok (Gateway.create [ key ]) in
  let config = Gateway.Key.config key in
  let labels : Encapsulation.labels =
    {
      request = "message/example request";
      response = "message/example response";
    }
  in
  ignore (exchange ~labels ~rng gateway config "request" "response");
  let encapsulated, client_context =
    ok (Client.encapsulate ~labels ~rng config "request")
  in
  Alcotest.check bytes_result "a request under other labels"
    (Error Error.Decapsulation_failed)
    (Result.map fst (Gateway.decapsulate gateway encapsulated));
  let response_label_only : Encapsulation.labels =
    { labels with response = Encapsulation.bhttp_labels.response }
  in
  let _, gateway_context =
    ok (Gateway.decapsulate ~labels:response_label_only gateway encapsulated)
  in
  Alcotest.check bytes_result "a response under other labels"
    (Error Error.Decapsulation_failed)
    (Client.decapsulate client_context
       (ok (Gateway.encapsulate ~rng gateway_context "response")))

let test_invalid_requests () =
  let rng = rng () in
  let key = key ~symmetric:[ aes ] Hpke.Kem.X25519 in
  let gateway = ok (Gateway.create [ key ]) in
  let config = Gateway.Key.config key in
  let encapsulated, _ = ok (Client.encapsulate ~rng config "request") in
  let decapsulate s = Result.map fst (Gateway.decapsulate gateway s) in
  let rejects name expected s =
    Alcotest.check bytes_result name (Error expected) (decapsulate s)
  in
  for length = 0 to Encapsulation.header_length - 1 do
    rejects "part of a header" (Error.Truncated_message "header")
      (String.sub encapsulated 0 length)
  done;
  for
    length = Encapsulation.header_length to Encapsulation.header_length + 31
  do
    rejects "part of an encapsulated key"
      (Error.Truncated_message "encapsulated key")
      (String.sub encapsulated 0 length)
  done;
  (* Anything shorter than a tag cannot be a ciphertext, and what remains of a
     longer one does not authenticate. *)
  for
    length = Encapsulation.header_length + 32 to String.length encapsulated - 1
  do
    rejects "part of a ciphertext" Error.Decapsulation_failed
      (String.sub encapsulated 0 length)
  done;
  rejects "a trailing byte" Error.Decapsulation_failed (encapsulated ^ "\000");
  let with_header ~key_id ~kem ~kdf ~aead =
    let b = Bytes.of_string encapsulated in
    Bytes.set_uint8 b 0 key_id;
    Bytes.set_uint16_be b 1 kem;
    Bytes.set_uint16_be b 3 kdf;
    Bytes.set_uint16_be b 5 aead;
    Bytes.unsafe_to_string b
  in
  rejects "an unknown key" (Error.Unknown_key_id 2)
    (with_header ~key_id:2 ~kem:0x0020 ~kdf:1 ~aead:1);
  rejects "another KEM"
    (Error.Unsupported_suite { kem = 0x0010; kdf = 1; aead = 1 })
    (with_header ~key_id:1 ~kem:0x0010 ~kdf:1 ~aead:1);
  (* This library provides ChaCha20Poly1305, but this key does not offer it. *)
  rejects "an AEAD that the key does not offer"
    (Error.Unsupported_suite { kem = 0x0020; kdf = 1; aead = 3 })
    (with_header ~key_id:1 ~kem:0x0020 ~kdf:1 ~aead:3);
  rejects "a KDF that the key does not offer"
    (Error.Unsupported_suite { kem = 0x0020; kdf = 3; aead = 1 })
    (with_header ~key_id:1 ~kem:0x0020 ~kdf:3 ~aead:1);
  rejects "the export-only AEAD"
    (Error.Unsupported_suite { kem = 0x0020; kdf = 1; aead = 0xffff })
    (with_header ~key_id:1 ~kem:0x0020 ~kdf:1 ~aead:0xffff);
  (* The header is part of the HPKE info, the encapsulated key feeds the key
     schedule, and the rest is authenticated ciphertext: no bit can change. *)
  for i = 0 to String.length encapsulated - 1 do
    match decapsulate (flip encapsulated i) with
    | Ok _ -> Alcotest.failf "bit flip in byte %d was accepted" i
    | Error Error.Decapsulation_failed -> ()
    | Error (Error.Unknown_key_id _ | Error.Unsupported_suite _)
      when i < Encapsulation.header_length ->
        ()
    | Error e -> Alcotest.failf "bit flip in byte %d: %a" i Error.pp e
  done;
  (* A low-order point, which X25519 maps to an all-zero shared secret. *)
  rejects "an all-zero encapsulated key" Error.Decapsulation_failed
    (String.sub encapsulated 0 Encapsulation.header_length
    ^ String.make 32 '\000'
    ^ String.sub encapsulated 39 (String.length encapsulated - 39))

(* ML-KEM decapsulates any ciphertext of the right length, to an unrelated
   secret when it was changed, so a tampered request fails only when it is
   opened. A hybrid also refuses an ephemeral element that is not one. Either
   way, the gateway reports the one error. *)
let test_post_quantum_requests () =
  let rng = rng () in
  List.iter
    (fun kem ->
      let key = key ~symmetric:[ aes ] kem in
      let gateway = ok (Gateway.create [ key ]) in
      let encapsulated, _ =
        ok (Client.encapsulate ~rng (Gateway.Key.config key) "request")
      in
      let enc_end =
        Encapsulation.header_length + Hpke.Kem.encapsulated_key_size kem
      in
      let decapsulate s = Result.map fst (Gateway.decapsulate gateway s) in
      let rec every i =
        if i < String.length encapsulated then (
          Alcotest.check bytes_result
            (Format.asprintf "%a: bit flip in byte %d" Hpke.Kem.pp kem i)
            (Error Error.Decapsulation_failed)
            (decapsulate (flip encapsulated i));
          (* Every byte of the last element and the ciphertext, and a sample of
             the ML-KEM ciphertext before them. *)
          every (if i < enc_end - 133 then i + 37 else i + 1))
      in
      every Encapsulation.header_length;
      let replace_end_of_enc element =
        let at = enc_end - String.length element in
        String.sub encapsulated 0 at
        ^ element
        ^ String.sub encapsulated enc_end (String.length encapsulated - enc_end)
      in
      match kem with
      | Hpke.Kem.Mlkem768_x25519 ->
          Alcotest.check bytes_result "a low-order X25519 element"
            (Error Error.Decapsulation_failed)
            (decapsulate (replace_end_of_enc (String.make 32 '\000')))
      | Hpke.Kem.Mlkem768_p256 ->
          Alcotest.check bytes_result "a P-256 element off the curve"
            (Error Error.Decapsulation_failed)
            (decapsulate (replace_end_of_enc ("\004" ^ String.make 64 '\x01')))
      | _ -> ())
    Hpke.Kem.
      [
        Mlkem768_x25519;
        Mlkem768_p256;
        Mlkem1024_p384;
        Mlkem512;
        Mlkem768;
        Mlkem1024;
      ]

let test_invalid_responses () =
  let rng = rng () in
  let key = key Hpke.Kem.X25519 in
  let gateway = ok (Gateway.create [ key ]) in
  let config = Gateway.Key.config key in
  let request, client_context = ok (Client.encapsulate ~rng config "request") in
  let _, gateway_context = ok (Gateway.decapsulate gateway request) in
  let response = ok (Gateway.encapsulate ~rng gateway_context "response") in
  let rejects name expected s =
    Alcotest.check bytes_result name (Error expected)
      (Client.decapsulate client_context s)
  in
  for length = 0 to 15 do
    rejects "part of a response nonce"
      (Error.Truncated_message "response nonce")
      (String.sub response 0 length)
  done;
  for length = 16 to String.length response - 1 do
    rejects "part of a ciphertext" Error.Decapsulation_failed
      (String.sub response 0 length)
  done;
  rejects "a trailing byte" Error.Decapsulation_failed (response ^ "\000");
  for i = 0 to String.length response - 1 do
    rejects
      (Printf.sprintf "bit flip in byte %d" i)
      Error.Decapsulation_failed (flip response i)
  done;
  rejects "a request in place of a response" Error.Decapsulation_failed request;
  (* A response answers one request only. *)
  let _, other_context = ok (Client.encapsulate ~rng config "request") in
  Alcotest.check bytes_result "the response to another request"
    (Error Error.Decapsulation_failed)
    (Client.decapsulate other_context response)

let test_invalid_key () =
  (* X25519 public keys are not validated when parsed; a low-order one is
     refused when it is used. *)
  let public_key =
    hpke_ok
      (Hpke.Public_key.of_bytes ~kem:Hpke.Kem.X25519 (String.make 32 '\000'))
  in
  let config = ok (Key_config.create ~key_id:1 public_key [ aes ]) in
  match Client.encapsulate ~rng:(rng ()) config "request" with
  | Error (Error.Hpke _) -> ()
  | Ok _ -> Alcotest.fail "a low-order public key was used"
  | Error e -> Alcotest.failf "unexpected error: %a" Error.pp e

let test_invalid_hybrid_key () =
  (* An X-Wing key whose X25519 half is of low order is read, as for X25519, and
     refused when it is used. *)
  let valid =
    Hpke.Public_key.to_bytes
      (Key_config.public_key
         (Gateway.Key.config (key Hpke.Kem.Mlkem768_x25519)))
  in
  let public_key =
    hpke_ok
      (Hpke.Public_key.of_bytes ~kem:Hpke.Kem.Mlkem768_x25519
         (String.sub valid 0 1184 ^ String.make 32 '\000'))
  in
  let config = ok (Key_config.create ~key_id:1 public_key [ aes ]) in
  match Client.encapsulate ~rng:(rng ()) config "request" with
  | Error (Error.Hpke _) -> ()
  | Ok _ -> Alcotest.fail "a low-order X25519 half was used"
  | Error e -> Alcotest.failf "unexpected error: %a" Error.pp e

let tests =
  [
    Alcotest.test_case "every suite" `Quick test_all_suites;
    Alcotest.test_case "payload sizes" `Quick test_payload_sizes;
    Alcotest.test_case "fresh contexts" `Quick test_fresh_contexts;
    Alcotest.test_case "response nonce draw" `Quick test_response_nonce_draw;
    Alcotest.test_case "gateway keys" `Quick test_gateway_keys;
    Alcotest.test_case "labels" `Quick test_labels;
    Alcotest.test_case "invalid requests" `Quick test_invalid_requests;
    Alcotest.test_case "post-quantum requests" `Quick test_post_quantum_requests;
    Alcotest.test_case "invalid responses" `Quick test_invalid_responses;
    Alcotest.test_case "invalid public key" `Quick test_invalid_key;
    Alcotest.test_case "invalid hybrid public key" `Quick
      test_invalid_hybrid_key;
  ]
