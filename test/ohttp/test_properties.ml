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
    (Gen.quad
       (pick (List.init (List.length Suite.all_kems) Fun.id))
       (pick Suite.all_symmetric) payload payload)
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

(* Chunked messages. *)

let pieces =
  let open Gen in
  let* non_final = list_size (int_range 0 6) (string_size (int_range 1 200)) in
  let+ final = string_size (int_range 0 200) in
  (non_final, final)

(* Cut a stream into slices at generated points, as a transport might. *)
let slices stream =
  let open Gen in
  let+ cuts = list_size (int_range 0 12) (int_bound (String.length stream)) in
  let cuts = List.sort_uniq compare (0 :: String.length stream :: cuts) in
  let rec go = function
    | a :: (b :: _ as rest) -> String.sub stream a (b - a) :: go rest
    | [ _ ] | [] -> []
  in
  go cuts

let chunked_stream =
  let open Gen in
  let* non_final, final = pieces in
  let config = Gateway.Key.config (List.hd (Lazy.force keys)) in
  let header, sender, _ = ok (Chunked.Client.request ~rng config) in
  (* In this order: the operands of [@] are evaluated right to left. *)
  let chunks =
    List.map (fun piece -> ok (Chunked.Sender.chunk sender piece)) non_final
  in
  let last = ok (Chunked.Sender.final sender final) in
  let stream = header ^ String.concat "" chunks ^ last in
  let+ slices = slices stream in
  (non_final, final, stream, slices)

let receive slices =
  let receiver =
    Chunked.Gateway.receiver (Chunked.Gateway.request (Lazy.force gateway))
  in
  let rec go acc = function
    | [] ->
        Result.map
          (fun final -> (List.concat (List.rev acc), final))
          (Chunked.Receiver.finish receiver)
    | slice :: rest -> (
        match Chunked.Receiver.feed receiver slice with
        | Ok chunks -> go (chunks :: acc) rest
        | Error _ as e -> e)
  in
  go [] slices

let slicing_does_not_matter =
  Test.make ~name:"chunks arrive whole however the stream is cut" ~count:300
    chunked_stream (fun (non_final, final, _, slices) ->
      receive slices = Ok (non_final, final))

(* A changed length prefix can still frame the same chunks, since lengths are
   not authenticated: a 1-byte length and its 2-byte form differ in a bit. But
   then nothing that the receiver returns has changed. *)
let corrupted_stream_is_refused =
  let open Gen in
  let generator =
    let* non_final, final, stream, _ = chunked_stream in
    let* position = int_bound (String.length stream - 1) in
    let* bit = int_bound 7 in
    let bytes = Bytes.of_string stream in
    Bytes.set_uint8 bytes position
      (Bytes.get_uint8 bytes position lxor (1 lsl bit));
    let+ slices = slices (Bytes.unsafe_to_string bytes) in
    (non_final, final, slices)
  in
  Test.make
    ~name:"a chunked stream with one bit changed is refused or unchanged"
    ~count:500 generator (fun (non_final, final, slices) ->
      match receive slices with
      | Error _ -> true
      | Ok received -> received = (non_final, final))

let chunked_receivers_are_total =
  Test.make ~name:"chunked receivers refuse arbitrary streams without raising"
    ~count:1000
    (Gen.pair
       (Gen.oneof [ hostile_request; Gen.string_size (Gen.int_range 0 100) ])
       Gen.bool)
    (fun (input, as_response) ->
      let receiver =
        if as_response then
          let config = Gateway.Key.config (List.hd (Lazy.force keys)) in
          let _, _, context = ok (Chunked.Client.request ~rng config) in
          Chunked.Client.response context
        else
          Chunked.Gateway.receiver
            (Chunked.Gateway.request (Lazy.force gateway))
      in
      Result.is_error (Chunked.open_all receiver input))

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
      slicing_does_not_matter;
      corrupted_stream_is_refused;
      chunked_receivers_are_total;
    ]
