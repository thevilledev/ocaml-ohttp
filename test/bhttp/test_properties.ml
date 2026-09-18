(* Properties of the codec over generated messages and hostile input. *)

open Bhttp
open QCheck2

let token_chars = "abcdefghijklmnopqrstuvwxyz0123456789!#$%&'*+-.^_`|~"

let token_char =
  Gen.map (String.get token_chars)
    (Gen.int_bound (String.length token_chars - 1))

let token = Gen.string_size ~gen:token_char (Gen.int_range 1 12)

(* Any byte a value may hold: everything but NUL, CR, and LF. *)
let value_char =
  Gen.map Char.chr
    (Gen.oneof
       [ Gen.int_range 0x20 0x7e; Gen.int_range 0x80 0xff; Gen.return 0x09 ])

let is_whitespace = function ' ' | '\t' -> true | _ -> false

let trim s =
  let n = String.length s in
  let first = ref 0 and last = ref n in
  while !first < n && is_whitespace s.[!first] do
    incr first
  done;
  while !last > !first && is_whitespace s.[!last - 1] do
    decr last
  done;
  String.sub s !first (!last - !first)

let value = Gen.map trim (Gen.string_size ~gen:value_char (Gen.int_range 0 24))
let regular_fields = Gen.list_size (Gen.int_range 0 5) (Gen.pair token value)

let headers =
  let open Gen in
  let* pseudo =
    list_size (int_range 0 2)
      (pair (map (fun name -> ":x-" ^ name) token) value)
  in
  let+ regular = regular_fields in
  pseudo @ regular

let content = Gen.string_size (Gen.int_range 0 300)

let target_char =
  Gen.map Char.chr
    (Gen.oneof [ Gen.int_range 0x21 0x7e; Gen.int_range 0x80 0xff ])

let target = Gen.string_size ~gen:target_char (Gen.int_range 0 24)

let request =
  let open Gen in
  let* meth = map String.uppercase_ascii token in
  let* scheme = target and* authority = target and* path = target in
  let* headers = headers
  and* content = content
  and* trailers = regular_fields in
  return { Request.meth; scheme; authority; path; headers; content; trailers }

let response =
  let open Gen in
  let* informational =
    list_size (int_range 0 3)
      (map2
         (fun status headers -> Response.informational ~status headers)
         (int_range 100 199) headers)
  in
  let* status = int_range 200 599 in
  let* headers = headers
  and* content = content
  and* trailers = regular_fields in
  return { Response.informational; status; headers; content; trailers }

(* Written without oneofl, which newer QCheck releases deprecate, and without
   its replacement, which older ones lack. *)
let framing =
  Gen.map
    (fun known ->
      if known then Framing.Known_length else Framing.Indeterminate_length)
    Gen.bool

let options = Gen.triple framing (Gen.int_range 0 8) Gen.bool

let varint_value =
  let wide = Sys.int_size >= 63 in
  Gen.oneof
    ([ Gen.int_bound 63; Gen.int_bound 16_383; Gen.int_bound 0x3fff_ffff ]
    @ if wide then [ Gen.int_bound Varint.max_value ] else [])

let varint_round_trip =
  Test.make ~name:"integers round trip on every size that holds them"
    ~count:1000 varint_value (fun n ->
      List.for_all
        (fun size ->
          size < Varint.size n
          || Varint.decode (Bhttp_test_support.Build.sized ~size n) ~pos:0
             = Ok (n, size))
        [ 1; 2; 4; 8 ]
      && Varint.decode (Varint.encode n) ~pos:0 = Ok (n, Varint.size n))

let request_round_trip =
  Test.make ~name:"requests round trip" ~count:500
    ~print:(fun (r, _) -> Format.asprintf "%a" Request.pp r)
    (Gen.pair request options)
    (fun (r, (framing, padding, truncate)) ->
      Request.decode (Request.encode_exn ~framing ~padding ~truncate r) = Ok r)

let response_round_trip =
  Test.make ~name:"responses round trip" ~count:500
    ~print:(fun (r, _) -> Format.asprintf "%a" Response.pp r)
    (Gen.pair response options)
    (fun (r, (framing, padding, truncate)) ->
      Response.decode (Response.encode_exn ~framing ~padding ~truncate r) = Ok r)

let framings_agree =
  Test.make ~name:"both framings carry the same message" ~count:300 request
    (fun r ->
      Request.decode (Request.encode_exn r)
      = Request.decode
          (Request.encode_exn ~framing:Framing.Indeterminate_length r))

let capitalize_names (r : Request.t) =
  let capitalize = List.map (fun (n, v) -> (String.uppercase_ascii n, v)) in
  { r with headers = capitalize r.headers; trailers = capitalize r.trailers }

let names_are_lowercased =
  Test.make ~name:"the case of field names does not reach the wire" ~count:300
    request (fun r -> Request.encode (capitalize_names r) = Request.encode r)

(* Decoding never raises, and whatever it accepts survives re-encoding: a
   decoded message is a fixed point even though the bytes it came from, with
   their padding, truncation, and integer sizes, need not be. *)
let stable input =
  match Message.decode input with
  | Error _ -> true
  | Ok message -> (
      match Message.encode message with
      | Error _ -> false
      | Ok encoded -> Message.decode encoded = Ok message)

let arbitrary_input =
  Test.make ~name:"arbitrary input never raises" ~count:2000
    ~print:Bhttp.Hex.encode
    (Gen.string_size (Gen.int_range 0 64))
    stable

let encoded_message =
  let open Gen in
  let* options = options in
  let framing, padding, truncate = options in
  oneof
    [
      map (Request.encode_exn ~framing ~padding ~truncate) request;
      map (Response.encode_exn ~framing ~padding ~truncate) response;
    ]

let every_prefix =
  Test.make ~name:"every prefix of a message is handled" ~count:100
    ~print:Bhttp.Hex.encode encoded_message (fun encoded ->
      let ok = ref true in
      for length = 0 to String.length encoded do
        ok := !ok && stable (String.sub encoded 0 length)
      done;
      !ok)

let mutation =
  let open Gen in
  let* encoded = encoded_message in
  let* position = int_bound (max 0 (String.length encoded - 1)) in
  let+ byte = map Char.chr (int_bound 255) in
  let bytes = Bytes.of_string encoded in
  if Bytes.length bytes > 0 then Bytes.set bytes position byte;
  Bytes.unsafe_to_string bytes

let mutated_messages =
  Test.make ~name:"a corrupted message is handled" ~count:2000
    ~print:Bhttp.Hex.encode mutation stable

let tests =
  List.map
    (QCheck_alcotest.to_alcotest ~speed_level:`Quick)
    [
      varint_round_trip;
      request_round_trip;
      response_round_trip;
      framings_agree;
      names_are_lowercased;
      arbitrary_input;
      every_prefix;
      mutated_messages;
    ]
