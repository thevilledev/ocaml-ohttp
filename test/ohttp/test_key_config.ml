(* Key configurations and their two encodings (RFC 9458 Section 3). *)

open Ohttp
open Vectors

let config_result =
  Alcotest.(result (testable Key_config.pp Key_config.equal) error)

let configs_result =
  Alcotest.(result (list (testable Key_config.pp Key_config.equal)) error)

let invalid = function
  | Error (Error.Invalid_key_config _) -> true
  | Ok _ | Error _ -> false

let public_key kem =
  let _, public_key =
    hpke_ok (Hpke.derive_key_pair kem ~ikm:(String.make 66 '\x2a'))
  in
  public_key

let config ?(key_id = 7) ?(symmetric = Suite.default_symmetric) kem =
  ok (Key_config.create ~key_id (public_key kem) symmetric)

let u16 n =
  String.init 2 (function
    | 0 -> Char.chr (n lsr 8)
    | _ -> Char.chr (n land 0xff))

(* A configuration assembled by hand, for what [create] refuses to build. *)
let raw ?(key_id = 7) ?(kem_id = 0x0020)
    ?(public_key = public_key Hpke.Kem.X25519 |> Hpke.Public_key.to_bytes)
    symmetric =
  String.concat ""
    ([
       String.make 1 (Char.chr key_id);
       u16 kem_id;
       public_key;
       u16 (4 * List.length symmetric);
     ]
    @ List.map (fun (kdf, aead) -> u16 kdf ^ u16 aead) symmetric)

(* X25519Kyber768Draft00 (0x0030), which ohttp-go and CIRCL know, and [hpke]
   does not: the Kyber of the NIST competition's third round, which ML-KEM
   replaced. Its public key is 1216 bytes. *)
let kyber_draft ~key_id =
  raw ~key_id ~kem_id:0x0030 ~public_key:(String.make 1216 '\x01') [ (1, 1) ]

let test_create () =
  let c = config Hpke.Kem.X25519 in
  Alcotest.(check int) "key identifier" 7 (Key_config.key_id c);
  Alcotest.(check bool) "KEM" true (Key_config.kem c = Hpke.Kem.X25519);
  Alcotest.(check bool)
    "symmetric" true
    (Key_config.symmetric c = Suite.default_symmetric);
  Alcotest.(check (list (pair int int)))
    "identifiers"
    [ (1, 1); (1, 3) ]
    (Key_config.symmetric_ids c);
  List.iter
    (fun key_id ->
      Alcotest.check config_result
        (Printf.sprintf "key identifier %d" key_id)
        (Error (Error.Invalid_key_id key_id))
        (Key_config.create ~key_id
           (public_key Hpke.Kem.X25519)
           Suite.default_symmetric))
    [ -1; 256 ];
  Alcotest.(check bool)
    "no symmetric algorithms" true
    (invalid (Key_config.create ~key_id:0 (public_key Hpke.Kem.X25519) []));
  Alcotest.(check bool)
    "more symmetric algorithms than the length field counts" true
    (invalid
       (Key_config.create ~key_id:0
          (public_key Hpke.Kem.X25519)
          (List.init 16384 (fun _ -> List.hd Suite.default_symmetric))));
  Alcotest.(check bool)
    "as many as it counts" true
    (Result.is_ok
       (Key_config.create ~key_id:255
          (public_key Hpke.Kem.X25519)
          (List.init 16383 (fun _ -> List.hd Suite.default_symmetric))))

let test_round_trip () =
  List.iter
    (fun kem ->
      let c = config ~symmetric:Suite.all_symmetric kem in
      let encoded = Key_config.encode c in
      Alcotest.(check int)
        "length"
        (3 + Hpke.Kem.public_key_size kem + 2 + (4 * 9))
        (String.length encoded);
      Alcotest.check config_result "single" (Ok c) (Key_config.decode encoded);
      check_bytes "hand-assembled" encoded
        (raw ~kem_id:(Hpke.Kem.to_int kem)
           ~public_key:(Hpke.Public_key.to_bytes (public_key kem))
           (List.map Suite.symmetric_to_ints Suite.all_symmetric)))
    Suite.all_kems

(* Identifiers that this library does not know are kept, so that a decoded
   configuration encodes to the bytes it came from, but never selected. *)
let test_unknown_symmetric () =
  let encoded =
    raw
      [ (0xffff, 0xffff); (0x0001, 0x0042); (0x0001, 0x0003); (0x0001, 0x0001) ]
  in
  let c = ok (Key_config.decode encoded) in
  Alcotest.(check (list (pair int int)))
    "every identifier"
    [ (0xffff, 0xffff); (0x0001, 0x0042); (0x0001, 0x0003); (0x0001, 0x0001) ]
    (Key_config.symmetric_ids c);
  check_bytes "encodes to the same bytes" encoded (Key_config.encode c);
  let chacha : Suite.symmetric =
    { kdf = Hpke.Kdf.Hkdf_sha256; aead = Hpke.Aead.Chacha20_poly1305 }
  and aes : Suite.symmetric =
    { kdf = Hpke.Kdf.Hkdf_sha256; aead = Hpke.Aead.Aes_128_gcm }
  and aes256 : Suite.symmetric =
    { kdf = Hpke.Kdf.Hkdf_sha256; aead = Hpke.Aead.Aes_256_gcm }
  in
  Alcotest.(check bool)
    "provided pairs" true
    (Key_config.symmetric c = [ chacha; aes ]);
  let selected ?preference c =
    Result.map Suite.symmetric (Key_config.select ?preference c)
  in
  Alcotest.(check bool)
    "the configuration's order decides" true
    (selected c = Ok chacha);
  Alcotest.(check bool)
    "unless the caller has a preference" true
    (selected ~preference:[ aes256; aes; chacha ] c = Ok aes);
  Alcotest.(check bool)
    "which the configuration must offer" true
    (selected ~preference:[ aes256 ] c = Error Error.No_supported_suite);
  Alcotest.(check bool) "offers" true (Key_config.offers c aes);
  Alcotest.(check bool) "does not offer" false (Key_config.offers c aes256);
  let unusable = ok (Key_config.decode (raw [ (0xffff, 0xffff) ])) in
  Alcotest.(check bool)
    "nothing to select" true
    (selected unusable = Error Error.No_supported_suite);
  Alcotest.(check bool)
    "the first usable configuration of a list" true
    (Result.map
       (fun (chosen, suite) ->
         (Key_config.equal chosen c, Suite.symmetric suite))
       (Key_config.select_from_list [ unusable; c ])
    = Ok (true, chacha));
  Alcotest.(check bool)
    "no usable configuration" true
    (Result.is_error (Key_config.select_from_list [ unusable ])
    && Result.is_error (Key_config.select_from_list []))

let test_invalid () =
  let valid = raw [ (1, 1) ] in
  (* "Clients MUST discard incorrectly encoded key configuration collections":
     no prefix of a configuration is one. *)
  for length = 0 to String.length valid - 1 do
    Alcotest.(check bool)
      (Printf.sprintf "prefix of %d bytes" length)
      true
      (invalid (Key_config.decode (String.sub valid 0 length)))
  done;
  Alcotest.(check bool)
    "trailing byte" true
    (invalid (Key_config.decode (valid ^ "\000")));
  Alcotest.check config_result "unknown KEM"
    (Error (Error.Unsupported_kem 0x0030))
    (Key_config.decode (kyber_draft ~key_id:7));
  let with_length n = String.sub valid 0 35 ^ u16 n ^ String.make n '\001' in
  List.iter
    (fun n ->
      Alcotest.(check bool)
        (Printf.sprintf "symmetric algorithms length %d" n)
        true
        (invalid (Key_config.decode (with_length n))))
    [ 0; 1; 2; 3; 5; 6; 7 ];
  Alcotest.(check bool)
    "length beyond the input" true
    (invalid
       (Key_config.decode
          (String.sub valid 0 35 ^ u16 8 ^ String.make 4 '\001')));
  (* An uncompressed P-256 point that is not on the curve. *)
  Alcotest.(check bool)
    "invalid public key" true
    (invalid
       (Key_config.decode
          (raw ~kem_id:0x0010
             ~public_key:("\004" ^ String.make 64 '\x01')
             [ (1, 1) ])));
  Alcotest.(check bool)
    "compressed public key" true
    (invalid
       (Key_config.decode
          (raw ~kem_id:0x0010
             ~public_key:("\002" ^ String.make 64 '\x01')
             [ (1, 1) ])))

let prefixed encoded = u16 (String.length encoded) ^ encoded

(* The one-stage SHAKE KDFs of draft-ietf-hpke-pq (0x0010 and 0x0011) have no
   Extract and Expand, which the response of RFC 9458 Section 4.4 needs, so a
   configuration that offers them is read, and they are never chosen. *)
let test_one_stage_kdfs () =
  let encoded = raw [ (0x0010, 0x0001); (0x0011, 0x0003); (0x0001, 0x0001) ] in
  let c = ok (Key_config.decode encoded) in
  check_bytes "encodes to the same bytes" encoded (Key_config.encode c);
  Alcotest.(check bool)
    "only the HKDF pair is provided" true
    (Key_config.symmetric c
    = [ { kdf = Hpke.Kdf.Hkdf_sha256; aead = Hpke.Aead.Aes_128_gcm } ]);
  Alcotest.(check bool)
    "nothing else to select" true
    (Result.is_error
       (Key_config.select (ok (Key_config.decode (raw [ (0x0010, 0x0001) ])))))

(* Post-quantum keys are more than a kilobyte, which a configuration and the
   length prefix of a list both carry. *)
let test_post_quantum () =
  List.iter
    (fun (kem, size) ->
      Alcotest.(check int)
        (Format.asprintf "%a public key" Hpke.Kem.pp kem)
        size
        (String.length (Hpke.Public_key.to_bytes (public_key kem))))
    Hpke.Kem.
      [
        (X448, 56);
        (Mlkem768_x25519, 1216);
        (Mlkem768_p256, 1249);
        (Mlkem1024_p384, 1665);
        (Mlkem768, 1184);
      ];
  let configs =
    List.mapi
      (fun key_id kem -> config ~key_id ~symmetric:Suite.all_symmetric kem)
      Suite.all_kems
  in
  Alcotest.check configs_result "a list of every KEM" (Ok configs)
    (Key_config.decode_list (Key_config.encode_list configs));
  let xwing = Key_config.encode (config Hpke.Kem.Mlkem768_x25519) in
  (* An ML-KEM encapsulation key whose coefficients are 4095, beyond the
     modulus: FIPS 203 has it rejected, and with it the whole list. *)
  let beyond_modulus =
    raw ~key_id:8 ~kem_id:0x0041 ~public_key:(String.make 1184 '\xff')
      [ (1, 1) ]
  in
  Alcotest.(check bool)
    "an ML-KEM key beyond the modulus" true
    (invalid (Key_config.decode beyond_modulus));
  Alcotest.(check bool)
    "discards the list that holds it" true
    (invalid
       (Key_config.decode_list (prefixed xwing ^ prefixed beyond_modulus)))

let test_list () =
  let a = config ~key_id:1 Hpke.Kem.X25519
  and b = config ~key_id:2 ~symmetric:Suite.all_symmetric Hpke.Kem.P256 in
  let encoded = Key_config.encode_list [ a; b ] in
  check_bytes "every configuration has a length prefix"
    (prefixed (Key_config.encode a) ^ prefixed (Key_config.encode b))
    encoded;
  Alcotest.check configs_result "round trip"
    (Ok [ a; b ])
    (Key_config.decode_list encoded);
  (* The two encodings are not interchangeable. *)
  Alcotest.(check bool)
    "a list is not a configuration" true
    (Result.is_error (Key_config.decode (Key_config.encode_list [ a ])));
  Alcotest.(check bool)
    "a configuration is not a list" true
    (Result.is_error (Key_config.decode_list (Key_config.encode a)));
  (* The length prefix is what lets a client step over a KEM it does not know,
     such as X25519Kyber768Draft00 here. *)
  let unknown = kyber_draft ~key_id:3 in
  Alcotest.check configs_result "an unknown KEM is skipped"
    (Ok [ a; b ])
    (Key_config.decode_list
       (prefixed (Key_config.encode a)
       ^ prefixed unknown
       ^ prefixed (Key_config.encode b)));
  Alcotest.check configs_result "even when nothing else is left" (Ok [])
    (Key_config.decode_list (prefixed unknown));
  check_bytes "an empty list encodes to nothing" "" (Key_config.encode_list [])

let test_invalid_list () =
  let a = Key_config.encode (config Hpke.Kem.X25519) in
  let rejects name encoded =
    Alcotest.(check bool) name true (invalid (Key_config.decode_list encoded))
  in
  rejects "empty" "";
  rejects "half a length prefix" (prefixed a ^ "\000");
  rejects "a trailing byte" (prefixed a ^ "\000\001");
  rejects "a zero-length configuration" (prefixed a ^ u16 0);
  rejects "a length beyond the input" (u16 (String.length a + 1) ^ a);
  rejects "trailing bytes inside a configuration" (prefixed (a ^ "\000"));
  rejects "a truncated configuration" (prefixed (String.sub a 0 20));
  rejects "too short to name a KEM" (prefixed "\001\000");
  (* One malformed configuration discards the whole collection. *)
  rejects "a malformed configuration after a valid one"
    (prefixed a ^ prefixed (String.sub a 0 (String.length a - 1)));
  let every_prefix =
    Key_config.encode_list [ config Hpke.Kem.X25519; config Hpke.Kem.P256 ]
  in
  for length = 1 to String.length every_prefix - 1 do
    if length <> 2 + String.length a then
      rejects
        (Printf.sprintf "prefix of %d bytes" length)
        (String.sub every_prefix 0 length)
  done

let tests =
  [
    Alcotest.test_case "create" `Quick test_create;
    Alcotest.test_case "round trip" `Quick test_round_trip;
    Alcotest.test_case "unknown symmetric algorithms" `Quick
      test_unknown_symmetric;
    Alcotest.test_case "one-stage KDFs" `Quick test_one_stage_kdfs;
    Alcotest.test_case "post-quantum KEMs" `Quick test_post_quantum;
    Alcotest.test_case "invalid configurations" `Quick test_invalid;
    Alcotest.test_case "lists" `Quick test_list;
    Alcotest.test_case "invalid lists" `Quick test_invalid_list;
  ]
