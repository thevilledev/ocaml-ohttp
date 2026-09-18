(* RFC 9292 Section 5. The encodings come from test/vectors/rfc9292.json, which
   tools/extract_rfc_vectors.py extracts from the RFC text. The messages they
   stand for are Figures 7, 10, and 12 of the RFC. *)

open Bhttp

let vectors = lazy (Vectors.vectors "rfc9292.json")

let message name =
  Vectors.hex_field (Vectors.find name (Lazy.force vectors)) "message"

(* Figure 7. The Host field is deliberately not copied into the authority. *)
let figure_7 =
  Request.make ~meth:"GET" ~path:"/hello.txt"
    ~headers:
      [
        ("user-agent", "curl/7.16.3 libcurl/7.16.3 OpenSSL/0.9.7l zlib/1.2.3");
        ("host", "www.example.com");
        ("accept-language", "en, mi");
      ]
    ()

(* Figure 10. Reason phrases are not retained, and only names are lowercased:
   the value of vary keeps its capitals. *)
let figure_10 =
  Response.make ~status:200
    ~informational:
      [
        Response.informational ~status:102 [ ("running", "\"sleep 15\"") ];
        Response.informational ~status:103
          [
            ("link", "</style.css>; rel=preload; as=style");
            ("link", "</script.js>; rel=preload; as=script");
          ];
      ]
    ~headers:
      [
        ("date", "Mon, 27 Jul 2009 12:28:53 GMT");
        ("server", "Apache");
        ("last-modified", "Wed, 22 Jul 2009 19:15:56 GMT");
        ("etag", "\"34aa387-d-1568eb00\"");
        ("accept-ranges", "bytes");
        ("content-length", "51");
        ("vary", "Accept-Encoding");
        ("content-type", "text/plain");
      ]
    ~content:"Hello World! My content includes a trailing CRLF.\r\n" ()

(* Figure 12. Transfer-Encoding is removed, and chunk boundaries and chunk
   extensions are not retained. *)
let figure_12 =
  Response.make ~status:200 ~content:"This content contains CRLF.\r\n"
    ~trailers:[ ("trailer", "text") ]
    ()

let test_known_length_request () =
  let encoded = message "known-length request" in
  Alcotest.(check (result Vectors.request Vectors.error))
    "decodes to Figure 7" (Ok figure_7) (Request.decode encoded);
  Vectors.check_bytes "Figure 7 encodes to Figure 8" encoded
    (Request.encode_exn figure_7)

let test_indeterminate_length_request () =
  let encoded = message "indeterminate-length request" in
  Alcotest.(check (result Vectors.request Vectors.error))
    "decodes to Figure 7" (Ok figure_7) (Request.decode encoded);
  Vectors.check_bytes "Figure 7 encodes to Figure 9" encoded
    (Request.encode_exn ~framing:Framing.Indeterminate_length ~padding:10
       figure_7)

(* "anything up to 12 bytes can be removed from this message without affecting
   its meaning": the padding and the terminators of the two empty sections that
   end the message, but not the terminator of the header section. *)
let test_request_truncation () =
  let encoded = message "indeterminate-length request" in
  let length = String.length encoded in
  for removed = 0 to 12 do
    Alcotest.(check (result Vectors.request Vectors.error))
      (Printf.sprintf "%d bytes removed" removed)
      (Ok figure_7)
      (Request.decode (String.sub encoded 0 (length - removed)))
  done;
  Alcotest.(check (result Vectors.request Vectors.error))
    "13 bytes removed" (Error (Error.Truncated "header section terminator"))
    (Request.decode (String.sub encoded 0 (length - 13)));
  (* "the last two bytes -- corresponding to content and a trailer section --
     can each be removed without altering the semantics of the message" *)
  let encoded = message "known-length request" in
  let length = String.length encoded in
  for removed = 0 to 2 do
    Alcotest.(check (result Vectors.request Vectors.error))
      (Printf.sprintf "known-length, %d bytes removed" removed)
      (Ok figure_7)
      (Request.decode (String.sub encoded 0 (length - removed)))
  done;
  Vectors.check_bytes "the encoder truncates to the same bytes"
    (String.sub encoded 0 (length - 2))
    (Request.encode_exn ~truncate:true figure_7)

let test_indeterminate_length_response () =
  let encoded = message "indeterminate-length response" in
  Alcotest.(check (result Vectors.response Vectors.error))
    "decodes to Figure 10" (Ok figure_10) (Response.decode encoded);
  Vectors.check_bytes "Figure 10 encodes to Figure 11" encoded
    (Response.encode_exn ~framing:Framing.Indeterminate_length figure_10)

let test_known_length_response () =
  let encoded = message "known-length response" in
  Alcotest.(check (result Vectors.response Vectors.error))
    "decodes to Figure 12" (Ok figure_12) (Response.decode encoded);
  Vectors.check_bytes "Figure 12 encodes to Figure 13" encoded
    (Response.encode_exn figure_12)

let test_message () =
  List.iter
    (fun vector ->
      let encoded = Vectors.hex_field vector "message" in
      match (Message.decode encoded, Framing.peek encoded) with
      | Ok (Message.Request r), Ok (Framing.Request, _) ->
          Alcotest.(check Vectors.request) "a request" figure_7 r
      | Ok (Message.Response _), Ok (Framing.Response, _) -> ()
      | _ ->
          Alcotest.failf "%s: kind and framing indicator disagree"
            (Vectors.string_field vector "name"))
    (Lazy.force vectors)

let tests =
  [
    Alcotest.test_case "known-length request" `Quick test_known_length_request;
    Alcotest.test_case "indeterminate-length request" `Quick
      test_indeterminate_length_request;
    Alcotest.test_case "truncation of the examples" `Quick
      test_request_truncation;
    Alcotest.test_case "indeterminate-length response" `Quick
      test_indeterminate_length_response;
    Alcotest.test_case "known-length response" `Quick test_known_length_response;
    Alcotest.test_case "either kind" `Quick test_message;
  ]
