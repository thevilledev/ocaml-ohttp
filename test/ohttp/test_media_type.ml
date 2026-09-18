module Media_type = Ohttp.Media_type

let test_constants () =
  (* RFC 9458 Section 9 and RFC 9292 Section 7. *)
  Alcotest.(check string) "request" "message/ohttp-req" Media_type.ohttp_request;
  Alcotest.(check string)
    "response" "message/ohttp-res" Media_type.ohttp_response;
  Alcotest.(check string) "keys" "application/ohttp-keys" Media_type.ohttp_keys;
  Alcotest.(check string) "bhttp" "message/bhttp" Media_type.bhttp;
  Alcotest.(check string)
    "chunked request" "message/ohttp-chunked-req"
    Media_type.ohttp_chunked_request;
  Alcotest.(check string)
    "chunked response" "message/ohttp-chunked-res"
    Media_type.ohttp_chunked_response;
  Alcotest.(check string)
    "problem" "application/problem+json" Media_type.problem_json

let test_matches () =
  let matches = Media_type.matches Media_type.ohttp_request in
  Alcotest.(check bool) "exact" true (matches "message/ohttp-req");
  Alcotest.(check bool) "case-insensitive" true (matches "Message/OHTTP-Req");
  Alcotest.(check bool)
    "parameters are ignored" true
    (matches "message/ohttp-req; charset=utf-8");
  Alcotest.(check bool)
    "surrounding whitespace is ignored" true
    (matches " \tmessage/ohttp-req\t ;q=1");
  Alcotest.(check bool) "other subtype" false (matches "message/ohttp-res");
  Alcotest.(check bool) "prefix only" false (matches "message/ohttp-request");
  Alcotest.(check bool) "suffix only" false (matches "x-message/ohttp-req");
  Alcotest.(check bool) "empty" false (matches "");
  Alcotest.(check bool) "parameters only" false (matches ";message/ohttp-req")

let tests =
  [
    Alcotest.test_case "constants" `Quick test_constants;
    Alcotest.test_case "matches" `Quick test_matches;
  ]
