(* Properties of encapsulation over generated payloads and hostile input. *)

open Ohttp
open QCheck2

let ok = Vectors.ok
let rng = Vectors.rng ()

let keys =
  lazy
    (List.map
       (fun kem ->
         ok
           (Gateway.Key.derive
              ~key_id:(Hpke.Kem.to_int kem land 0xff)
              ~symmetric:Suite.all_symmetric kem ~ikm:(String.make 66 '\x51')))
       Suite.all_kems)

let gateway = lazy (ok (Gateway.create (Lazy.force keys)))
let pick list = Gen.map (List.nth list) (Gen.int_bound (List.length list - 1))
let payload = Gen.string_size (Gen.int_range 0 512)

let round_trip =
  Test.make ~name:"an exchange returns what was sent" ~count:200
    (Gen.quad (pick [ 0; 1; 2; 3 ]) (pick Suite.all_symmetric) payload payload)
    (fun (key, pair, request, response) ->
      let config = Gateway.Key.config (List.nth (Lazy.force keys) key) in
      let encapsulated, client_context =
        ok (Client.encapsulate ~rng ~preference:[ pair ] config request)
      in
      let received, gateway_context =
        ok (Gateway.decapsulate (Lazy.force gateway) encapsulated)
      in
      let encapsulated_response =
        ok (Gateway.encapsulate ~rng gateway_context response)
      in
      String.equal request received
      && Client.decapsulate client_context encapsulated_response = Ok response)

let corrupted =
  let open Gen in
  let* request = payload in
  let config = Gateway.Key.config (List.hd (Lazy.force keys)) in
  let encapsulated, _ = ok (Client.encapsulate ~rng config request) in
  let* position = int_bound (String.length encapsulated - 1) in
  let+ bit = int_bound 7 in
  let bytes = Bytes.of_string encapsulated in
  Bytes.set_uint8 bytes position
    (Bytes.get_uint8 bytes position lxor (1 lsl bit));
  Bytes.unsafe_to_string bytes

let no_bit_can_change =
  Test.make ~name:"a request with one bit changed is refused" ~count:500
    ~print:Bhttp.Hex.encode corrupted (fun encapsulated ->
      Result.is_error (Gateway.decapsulate (Lazy.force gateway) encapsulated))

(* A header that reaches the HPKE code, followed by anything at all. *)
let hostile_request =
  let open Gen in
  let* key = pick (Lazy.force keys) in
  let* pair = pick Suite.all_symmetric in
  let suite = Suite.make (Key_config.kem (Gateway.Key.config key)) pair in
  let+ rest = string_size (int_range 0 200) in
  Encapsulation.header ~key_id:(Gateway.Key.key_id key) suite ^ rest

let gateway_is_total =
  Test.make ~name:"the gateway refuses arbitrary requests without raising"
    ~count:1000 ~print:Bhttp.Hex.encode
    (Gen.oneof [ hostile_request; Gen.string_size (Gen.int_range 0 100) ])
    (fun input ->
      Result.is_error (Gateway.decapsulate (Lazy.force gateway) input))

let client_is_total =
  let config = lazy (Gateway.Key.config (List.hd (Lazy.force keys))) in
  Test.make ~name:"the client refuses arbitrary responses without raising"
    ~count:1000 ~print:Bhttp.Hex.encode
    (Gen.string_size (Gen.int_range 0 100))
    (fun input ->
      let _, context =
        ok (Client.encapsulate ~rng (Lazy.force config) "request")
      in
      Result.is_error (Client.decapsulate context input))

let u16 n =
  String.init 2 (function
    | 0 -> Char.chr (n lsr 8)
    | _ -> Char.chr (n land 0xff))

(* A well-formed configuration with any identifiers at all, most of them unknown
   to this library. *)
let raw_config =
  let open Gen in
  let public_key =
    Hpke.Public_key.to_bytes
      (Key_config.public_key (Gateway.Key.config (List.hd (Lazy.force keys))))
  in
  let* key_id = int_bound 255 in
  let+ pairs =
    list_size (int_range 1 8) (pair (int_bound 0xffff) (int_bound 0xffff))
  in
  String.concat ""
    ([
       String.make 1 (Char.chr key_id);
       u16 0x0020;
       public_key;
       u16 (4 * List.length pairs);
     ]
    @ List.map (fun (kdf, aead) -> u16 kdf ^ u16 aead) pairs)

let configurations_are_canonical =
  Test.make ~name:"a decoded configuration encodes to the same bytes" ~count:500
    ~print:Bhttp.Hex.encode raw_config (fun encoded ->
      match Key_config.decode encoded with
      | Ok config ->
          String.equal (Key_config.encode config) encoded
          && Key_config.decode_list (Key_config.encode_list [ config; config ])
             |> Result.map (List.map Key_config.encode)
             = Ok [ encoded; encoded ]
      | Error _ -> false)

let configurations_are_total =
  Test.make ~name:"arbitrary configurations never raise" ~count:2000
    ~print:Bhttp.Hex.encode
    (Gen.string_size (Gen.int_range 0 120))
    (fun input ->
      let canonical decoded =
        match decoded with
        | Error _ -> true
        | Ok config -> String.equal (Key_config.encode config) input
      in
      canonical (Key_config.decode input)
      &&
      match Key_config.decode_list input with
      | Error _ -> true
      | Ok configs ->
          (* Skipped configurations make the list shorter, never different. *)
          String.length (Key_config.encode_list configs) <= String.length input)

let tests =
  List.map
    (QCheck_alcotest.to_alcotest ~speed_level:`Quick)
    [
      round_trip;
      no_bit_can_change;
      gateway_is_total;
      client_is_total;
      configurations_are_canonical;
      configurations_are_total;
    ]
