(* Chunked Oblivious HTTP (draft-ietf-ohai-chunked-ohttp-08). The example of the
   draft's Appendix A comes from test/vectors/chunked-ohttp-08.json, which
   tools/extract_rfc_vectors.py extracts from the draft. *)

open Ohttp
open Vectors
open Yojson.Safe.Util

let vector = lazy (List.hd (vectors "chunked-ohttp-08.json"))
let value name = hex_field (Lazy.force vector) name

let values name =
  Lazy.force vector |> member name |> to_list
  |> List.map (fun v -> Bhttp.Hex.decode_exn (to_string v))

let kem = Hpke.Kem.X25519

let aes : Suite.symmetric =
  { kdf = Hpke.Kdf.Hkdf_sha256; aead = Hpke.Aead.Aes_128_gcm }

let chacha : Suite.symmetric =
  { kdf = Hpke.Kdf.Hkdf_sha256; aead = Hpke.Aead.Chacha20_poly1305 }

let suite = Suite.make kem aes
let chunks_result = Alcotest.(result (list octets) error)
let bytes_result = Alcotest.(result octets error)

let published_gateway () =
  let private_key = hpke_ok (Hpke.Private_key.of_bytes ~kem (value "skR")) in
  let key =
    ok
      (Gateway.Key.of_private_key ~key_id:1 ~symmetric:[ aes; chacha ]
         private_key)
  in
  check_bytes "key configuration" (value "key_config")
    (Key_config.encode (Gateway.Key.config key));
  ok (Gateway.create [ key ])

let published_ephemeral : Client.sender_setup =
 fun hpke_suite ~recipient ~info ->
  let ephemeral = hpke_ok (Hpke.Private_key.of_bytes ~kem (value "skE")) in
  Hpke_for_testing.setup_base_sender hpke_suite ~ephemeral ~recipient ~info

let published_request () =
  ok
    (Chunked.Client.request_with ~setup:published_ephemeral
       (ok (Key_config.decode (value "key_config"))))

(* Seal [pieces], of which the last is the final chunk. *)
let seal sender pieces =
  let rec go = function
    | [] -> []
    | [ last ] -> [ ok (Chunked.Sender.final sender last) ]
    | piece :: rest ->
        let sealed = ok (Chunked.Sender.chunk sender piece) in
        sealed :: go rest
  in
  go pieces

let test_client () =
  let header, sender, context = published_request () in
  (* "a header, the encapsulated secret, and three encrypted chunks", one to a
     line in the draft. *)
  let expected = values "encapsulated_request" in
  check_bytes "header and encapsulated key"
    (List.nth expected 0 ^ List.nth expected 1)
    header;
  List.iteri
    (fun i sealed ->
      check_bytes
        (Printf.sprintf "request chunk %d" i)
        (List.nth expected (i + 2))
        sealed)
    (seal sender (values "request_chunks"));
  let receiver = Chunked.Client.response context in
  Alcotest.check chunks_result "response chunks"
    (Ok [ "\x01"; "\x40\xc8" ])
    (Chunked.Receiver.feed receiver
       (String.concat "" (values "encapsulated_response")));
  Alcotest.check bytes_result "final response chunk" (Ok "")
    (Chunked.Receiver.finish receiver)

let test_gateway () =
  let request = Chunked.Gateway.request (published_gateway ()) in
  let receiver = Chunked.Gateway.receiver request in
  Alcotest.check chunks_result "request chunks"
    (Ok
       [
         List.nth (values "request_chunks") 0;
         List.nth (values "request_chunks") 1;
       ])
    (Chunked.Receiver.feed receiver
       (String.concat "" (values "encapsulated_request")));
  Alcotest.check bytes_result "final request chunk" (Ok "")
    (Chunked.Receiver.finish receiver);
  let nonce, sender =
    ok
      (Chunked.Gateway.response
         ~rng:(Fixed_rng.of_string (value "response_nonce"))
         request)
  in
  let expected = values "encapsulated_response" in
  check_bytes "response nonce" (List.nth expected 0) nonce;
  List.iteri
    (fun i sealed ->
      check_bytes
        (Printf.sprintf "response chunk %d" i)
        (List.nth expected (i + 1))
        sealed)
    (seal sender (values "response_chunks"))

let test_intermediate_values () =
  let header = List.hd (values "encapsulated_request") in
  check_bytes "info" (value "info")
    (Encapsulation.info ~label:Chunked.labels.request ~header);
  let private_key = hpke_ok (Hpke.Private_key.of_bytes ~kem (value "skR")) in
  let receiver =
    hpke_ok
      (Hpke.Rfc9180.setup_base_receiver (Suite.hpke suite)
         ~recipient:private_key ~encapsulated_key:(value "pkE")
         ~info:(value "info"))
  in
  let secret =
    hpke_ok
      (Hpke.Rfc9180.Receiver.export receiver ~context:Chunked.labels.response
         ~length:16)
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
  check_bytes "base nonce" (value "aead_nonce") keys.nonce;
  (* The third nonce ends in 44, not 48: the counter is XORed, not added. *)
  List.iteri
    (fun counter expected ->
      check_bytes
        (Printf.sprintf "nonce of chunk %d" counter)
        expected
        (Chunked.chunk_nonce ~nonce:keys.nonce ~counter))
    (values "chunk_nonces")

let test_chunk_nonce () =
  let nonce = String.make 12 '\000' in
  let check counter expected =
    check_bytes (string_of_int counter)
      (Bhttp.Hex.decode_exn expected)
      (Chunked.chunk_nonce ~nonce ~counter)
  in
  check 0 "000000000000000000000000";
  check 255 "0000000000000000000000ff";
  check 256 "000000000000000000000100";
  check 0x01020304 "000000000000000001020304";
  if Sys.int_size >= 63 then check max_int "000000003fffffffffffffff";
  check_bytes "XOR"
    (Bhttp.Hex.decode_exn "ffffffffffffffffffff00fe")
    (Chunked.chunk_nonce ~nonce:(String.make 12 '\xff') ~counter:0xff01);
  Alcotest.check_raises "negative counter"
    (Invalid_argument "Chunked.chunk_nonce: negative counter") (fun () ->
      ignore (Chunked.chunk_nonce ~nonce ~counter:(-1)))

(* The transport may split a stream anywhere, down to single bytes. *)
let test_byte_by_byte () =
  let request = Chunked.Gateway.request (published_gateway ()) in
  let receiver = Chunked.Gateway.receiver request in
  let stream = String.concat "" (values "encapsulated_request") in
  let chunks =
    List.concat
      (List.init (String.length stream) (fun i ->
           ok (Chunked.Receiver.feed receiver (String.make 1 stream.[i]))))
  in
  Alcotest.(check (list octets))
    "request chunks"
    [
      List.nth (values "request_chunks") 0; List.nth (values "request_chunks") 1;
    ]
    chunks;
  Alcotest.check bytes_result "final request chunk" (Ok "")
    (Chunked.Receiver.finish receiver)

let key ?(symmetric = Suite.all_symmetric) kem =
  ok (Gateway.Key.derive ~key_id:5 ~symmetric kem ~ikm:(String.make 66 '\x77'))

(* A whole exchange, with the response started before the request is over. *)
let test_round_trips () =
  let rng = rng () in
  List.iter
    (fun kem ->
      let key = key kem in
      let gateway = ok (Gateway.create [ key ]) in
      List.iter
        (fun pair ->
          let header, sender, context =
            ok
              (Chunked.Client.request ~rng ~preference:[ pair ]
                 (Gateway.Key.config key))
          in
          let request = Chunked.Gateway.request gateway in
          let receiver = Chunked.Gateway.receiver request in
          Alcotest.check chunks_result "the header holds no data" (Ok [])
            (Chunked.Receiver.feed receiver header);
          let nonce, response_sender =
            ok (Chunked.Gateway.response ~rng request)
          in
          let response_receiver = Chunked.Client.response context in
          Alcotest.check chunks_result "the nonce holds no data" (Ok [])
            (Chunked.Receiver.feed response_receiver nonce);
          List.iter
            (fun piece ->
              Alcotest.check chunks_result "request chunk" (Ok [ piece ])
                (Chunked.Receiver.feed receiver
                   (ok (Chunked.Sender.chunk sender piece)));
              Alcotest.check chunks_result "response chunk"
                (Ok [ "re: " ^ piece ])
                (Chunked.Receiver.feed response_receiver
                   (ok (Chunked.Sender.chunk response_sender ("re: " ^ piece)))))
            [
              "a";
              String.make 300 'b';
              String.make (Chunked.max_chunk_size - 4) 'c';
            ];
          Alcotest.check chunks_result "the final chunk waits for the end"
            (Ok [])
            (Chunked.Receiver.feed receiver
               (ok (Chunked.Sender.final sender "end")));
          Alcotest.check bytes_result "final request chunk" (Ok "end")
            (Chunked.Receiver.finish receiver);
          Alcotest.check chunks_result "the final chunk waits for the end"
            (Ok [])
            (Chunked.Receiver.feed response_receiver
               (ok (Chunked.Sender.final response_sender "")));
          Alcotest.check bytes_result "final response chunk" (Ok "")
            (Chunked.Receiver.finish response_receiver))
        [
          aes;
          chacha;
          { kdf = Hpke.Kdf.Hkdf_sha512; aead = Hpke.Aead.Aes_256_gcm };
        ])
    Suite.all_kems

let test_whole_messages () =
  let rng = rng () in
  let key = key kem in
  let gateway = ok (Gateway.create [ key ]) in
  List.iter
    (fun (size, chunk_size) ->
      let message = String.init size (fun i -> Char.chr (i land 0xff)) in
      let header, sender, context =
        ok (Chunked.Client.request ~rng (Gateway.Key.config key))
      in
      let sealed = ok (Chunked.seal_all ~chunk_size sender message) in
      let request = Chunked.Gateway.request gateway in
      Alcotest.check bytes_result
        (Printf.sprintf "%d bytes in chunks of %d" size chunk_size)
        (Ok message)
        (Chunked.open_all (Chunked.Gateway.receiver request) (header ^ sealed));
      let nonce, response_sender = ok (Chunked.Gateway.response ~rng request) in
      let sealed = ok (Chunked.seal_all ~chunk_size response_sender message) in
      Alcotest.check bytes_result "response" (Ok message)
        (Chunked.open_all (Chunked.Client.response context) (nonce ^ sealed)))
    [
      (0, 10);
      (1, 10);
      (10, 10);
      (11, 10);
      (25, 12);
      (100_000, 16384);
      (5_000, 1);
    ]

(* An exchange whose parts the tests can take apart. *)
type exchange = {
  gateway : Gateway.t;
  header : string;
  request_chunks : string list;
  context : Chunked.Client.response_context;
}

let exchange ?(pieces = [ "one"; "two"; "three"; "last" ]) () =
  let key = key kem in
  let header, sender, context =
    ok (Chunked.Client.request ~rng:(rng ()) (Gateway.Key.config key))
  in
  {
    gateway = ok (Gateway.create [ key ]);
    header;
    request_chunks = seal sender pieces;
    context;
  }

let open_request e stream =
  Chunked.open_all
    (Chunked.Gateway.receiver (Chunked.Gateway.request e.gateway))
    stream

let test_truncation () =
  let e = exchange () in
  let stream = e.header ^ String.concat "" e.request_chunks in
  Alcotest.check bytes_result "complete" (Ok "onetwothreelast")
    (open_request e stream);
  (* "endpoints that depend on having a complete message MUST ensure that they
     do not consider a message complete until having received a chunk with a
     0-valued length prefix, which was successfully decrypted using the expected
     sentinel value" *)
  for length = 0 to String.length stream - 1 do
    match open_request e (String.sub stream 0 length) with
    | Ok _ -> Alcotest.failf "a stream cut at %d bytes was accepted" length
    | Error (Error.Truncated_message _ | Error.Decapsulation_failed) -> ()
    | Error err -> Alcotest.failf "cut at %d bytes: %a" length Error.pp err
  done;
  Alcotest.check bytes_result "nothing at all"
    (Error (Error.Truncated_message "header")) (open_request e "");
  Alcotest.check bytes_result "no final chunk"
    (Error (Error.Truncated_message "final chunk"))
    (open_request e (e.header ^ List.hd e.request_chunks));
  (* The data of a truncated stream is still returned as it arrives, which is
     why a receiver has to wait for [finish]. *)
  let receiver = Chunked.Gateway.receiver (Chunked.Gateway.request e.gateway) in
  Alcotest.check chunks_result "early data" (Ok [ "one" ])
    (Chunked.Receiver.feed receiver (e.header ^ List.hd e.request_chunks));
  Alcotest.check bytes_result "but no end"
    (Error (Error.Truncated_message "final chunk"))
    (Chunked.Receiver.finish receiver)

let test_tampering () =
  let e = exchange () in
  let rejects name chunks =
    Alcotest.check bytes_result name (Error Error.Decapsulation_failed)
      (open_request e (e.header ^ String.concat "" chunks))
  in
  let one, two, three, last =
    match e.request_chunks with
    | [ a; b; c; d ] -> (a, b, c, d)
    | _ -> assert false
  in
  rejects "reordered" [ two; one; three; last ];
  rejects "dropped" [ one; three; last ];
  rejects "repeated" [ one; one; two; three; last ];
  rejects "final chunk moved forward" [ one; last ];
  (* The length prefix is not authenticated, but what it implies is: a final
     chunk is sealed with other additional data than the rest. *)
  let as_final chunk = "\000" ^ String.sub chunk 1 (String.length chunk - 1) in
  let as_non_final chunk =
    Bhttp.Varint.encode (String.length chunk - 1)
    ^ String.sub chunk 1 (String.length chunk - 1)
  in
  rejects "a non-final chunk presented as the final one"
    [ one; two; as_final three ];
  Alcotest.check bytes_result "the final chunk presented as a non-final one"
    (Error Error.Decapsulation_failed)
    (Result.map (String.concat "")
       (Chunked.Receiver.feed
          (Chunked.Gateway.receiver (Chunked.Gateway.request e.gateway))
          (e.header ^ one ^ two ^ three ^ as_non_final last)));
  let stream = e.header ^ String.concat "" e.request_chunks in
  let header_length = String.length e.header in
  for i = header_length to String.length stream - 1 do
    let flipped = Bytes.of_string stream in
    Bytes.set_uint8 flipped i (Bytes.get_uint8 flipped i lxor 0x80);
    match open_request e (Bytes.unsafe_to_string flipped) with
    | Ok _ -> Alcotest.failf "bit flip in byte %d was accepted" i
    | Error _ -> ()
  done;
  (* "the variable-length encoding used for lengths allows for different
     expressions of the same value" *)
  let reframed chunk =
    let b = Buffer.create 64 in
    Bhttp.Varint.add_sized b ~size:4 (String.length chunk - 1);
    Buffer.add_string b (String.sub chunk 1 (String.length chunk - 1));
    Buffer.contents b
  in
  Alcotest.check bytes_result "lengths on any number of bytes"
    (Ok "onetwothreelast")
    (open_request e
       (e.header ^ reframed one ^ reframed two ^ reframed three ^ "\x40\x00"
       ^ String.sub last 1 (String.length last - 1)))

(* "A receiver MUST treat the receipt of a chunk that contains no data as
   equivalent to a decryption error, unless that chunk is the final chunk." The
   keys of the draft's example seal such a chunk for this test. *)
let test_empty_chunk () =
  let _, _, context = published_request () in
  let sealed_empty ~aad =
    let key =
      hpke_ok (Hpke.Aead.key Hpke.Aead.Aes_128_gcm (value "aead_key"))
    in
    hpke_ok (Hpke.Aead.seal key ~nonce:(value "aead_nonce") ~aad ~plaintext:"")
  in
  let receiver = Chunked.Client.response context in
  Alcotest.check chunks_result "an empty non-final chunk"
    (Error Error.Decapsulation_failed)
    (Chunked.Receiver.feed receiver
       (value "response_nonce" ^ "\x10" ^ sealed_empty ~aad:""));
  Alcotest.check chunks_result "a failed receiver stays failed"
    (Error Error.Decapsulation_failed)
    (Chunked.Receiver.feed receiver "");
  Alcotest.check bytes_result "to the end" (Error Error.Decapsulation_failed)
    (Chunked.Receiver.finish receiver);
  Alcotest.check bytes_result "an empty final chunk" (Ok "")
    (Chunked.open_all
       (Chunked.Client.response context)
       (value "response_nonce" ^ "\x00" ^ sealed_empty ~aad:"final"))

let test_limits () =
  let rng = rng () in
  let key = key kem in
  let gateway = ok (Gateway.create [ key ]) in
  let config = Gateway.Key.config key in
  let header, sender, _ = ok (Chunked.Client.request ~rng config) in
  let at_limit = String.make Chunked.max_chunk_size 'x' in
  let sealed = ok (Chunked.Sender.chunk sender at_limit) in
  Alcotest.check bytes_result "a sender refuses more than its limit"
    (Error (Error.Chunk_too_large (Chunked.max_chunk_size + 1)))
    (Chunked.Sender.chunk sender (at_limit ^ "x"));
  let receiver = Chunked.Gateway.receiver (Chunked.Gateway.request gateway) in
  Alcotest.check chunks_result "a receiver accepts 2^14 bytes of data"
    (Ok [ at_limit ])
    (Chunked.Receiver.feed receiver (header ^ sealed));
  (* A larger chunk is refused from its length alone, before it is buffered. *)
  let header, sender, _ =
    ok (Chunked.Client.request ~rng ~max_chunk_size:20000 config)
  in
  let sealed = ok (Chunked.Sender.chunk sender (at_limit ^ "x")) in
  let prefix = String.sub (header ^ sealed) 0 (String.length header + 4) in
  Alcotest.check chunks_result "a receiver refuses more"
    (Error (Error.Chunk_too_large (Chunked.max_chunk_size + 1 + 16)))
    (Chunked.Receiver.feed
       (Chunked.Gateway.receiver (Chunked.Gateway.request gateway))
       prefix);
  Alcotest.check chunks_result "unless it is set to accept it"
    (Ok [ at_limit ^ "x" ])
    (Chunked.Receiver.feed
       (Chunked.Gateway.receiver
          (Chunked.Gateway.request ~max_chunk_size:20000 gateway))
       (header ^ sealed));
  (* The final chunk has no length to judge it by, so it is judged as it
     grows. *)
  let header, sender, _ =
    ok (Chunked.Client.request ~rng ~max_chunk_size:20000 config)
  in
  let sealed = ok (Chunked.Sender.final sender (at_limit ^ "x")) in
  Alcotest.check chunks_result "a final chunk that grows too large"
    (Error (Error.Chunk_too_large (Chunked.max_chunk_size + 1 + 16)))
    (Chunked.Receiver.feed
       (Chunked.Gateway.receiver (Chunked.Gateway.request gateway))
       (header ^ sealed))

let test_gateway_errors () =
  let rng = rng () in
  let key = key ~symmetric:[ aes ] kem in
  let gateway = ok (Gateway.create [ key ]) in
  let header, sender, _ =
    ok (Chunked.Client.request ~rng (Gateway.Key.config key))
  in
  let stream = header ^ ok (Chunked.seal_all sender "request") in
  let with_byte i byte =
    let b = Bytes.of_string stream in
    Bytes.set_uint8 b i byte;
    Bytes.unsafe_to_string b
  in
  let opened stream =
    Chunked.open_all
      (Chunked.Gateway.receiver (Chunked.Gateway.request gateway))
      stream
  in
  Alcotest.check bytes_result "an unknown key" (Error (Error.Unknown_key_id 6))
    (opened (with_byte 0 6));
  Alcotest.check bytes_result "an AEAD that the key does not offer"
    (Error (Error.Unsupported_suite { kem = 0x0020; kdf = 1; aead = 3 }))
    (opened (with_byte 6 3));
  (* The errors come as soon as the header is there to be judged. *)
  Alcotest.check chunks_result "from the first seven bytes"
    (Error (Error.Unknown_key_id 6))
    (Chunked.Receiver.feed
       (Chunked.Gateway.receiver (Chunked.Gateway.request gateway))
       (String.sub (with_byte 0 6) 0 7));
  (* The labels keep the two variants apart. *)
  Alcotest.check bytes_result "a chunked request is not a plain one"
    (Error Error.Decapsulation_failed)
    (Result.map fst (Gateway.decapsulate gateway stream));
  let plain, _ =
    ok (Client.encapsulate ~rng (Gateway.Key.config key) "request")
  in
  Alcotest.(check bool)
    "a plain request is not a chunked one" true
    (Result.is_error (opened plain));
  let request = Chunked.Gateway.request gateway in
  Alcotest.(check bool)
    "no response before the header" true
    (Chunked.Gateway.response ~rng request
    |> Result.map (fun _ -> ())
    = Error (Error.Truncated_message "header"));
  ignore (ok (Chunked.Receiver.feed (Chunked.Gateway.receiver request) header));
  ignore (ok (Chunked.Gateway.response ~rng request));
  Alcotest.check_raises "one response to a request"
    (Invalid_argument "Chunked.Gateway.response: called twice") (fun () ->
      ignore (Chunked.Gateway.response ~rng request))

let test_misuse () =
  let _, sender, context = published_request () in
  Alcotest.check_raises "an empty non-final chunk"
    (Invalid_argument "Chunked.Sender.chunk: empty non-final chunk") (fun () ->
      ignore (Chunked.Sender.chunk sender ""));
  ignore (ok (Chunked.Sender.final sender ""));
  Alcotest.check_raises "a chunk after the final one"
    (Invalid_argument "Chunked.Sender: the final chunk was sent") (fun () ->
      ignore (Chunked.Sender.chunk sender "more"));
  Alcotest.check_raises "a second final chunk"
    (Invalid_argument "Chunked.Sender: the final chunk was sent") (fun () ->
      ignore (Chunked.Sender.final sender ""));
  let receiver = Chunked.Client.response context in
  ignore
    (ok
       (Chunked.open_all receiver
          (String.concat "" (values "encapsulated_response"))));
  Alcotest.check_raises "data after the end"
    (Invalid_argument "Chunked.Receiver: the stream was finished") (fun () ->
      ignore (Chunked.Receiver.feed receiver "more"));
  Alcotest.check_raises "a second end"
    (Invalid_argument "Chunked.Receiver: the stream was finished") (fun () ->
      ignore (Chunked.Receiver.finish receiver));
  Alcotest.check_raises "no chunk size"
    (Invalid_argument "Chunked.seal_all: chunk_size") (fun () ->
      let _, sender, _ = published_request () in
      ignore (Chunked.seal_all ~chunk_size:0 sender "message"))

let tests =
  [
    Alcotest.test_case "draft example, client" `Quick test_client;
    Alcotest.test_case "draft example, gateway" `Quick test_gateway;
    Alcotest.test_case "draft example, intermediate values" `Quick
      test_intermediate_values;
    Alcotest.test_case "chunk nonces" `Quick test_chunk_nonce;
    Alcotest.test_case "byte by byte" `Quick test_byte_by_byte;
    Alcotest.test_case "round trips" `Quick test_round_trips;
    Alcotest.test_case "whole messages" `Quick test_whole_messages;
    Alcotest.test_case "truncation" `Quick test_truncation;
    Alcotest.test_case "tampering" `Quick test_tampering;
    Alcotest.test_case "empty chunks" `Quick test_empty_chunk;
    Alcotest.test_case "limits" `Quick test_limits;
    Alcotest.test_case "gateway errors" `Quick test_gateway_errors;
    Alcotest.test_case "misuse" `Quick test_misuse;
  ]
