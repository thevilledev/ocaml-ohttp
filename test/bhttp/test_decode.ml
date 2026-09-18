(* What a decoder must accept and must reject (RFC 9292 Sections 3 and 4).
   Messages are assembled by hand so that the tests reach encodings the
   library's own encoder never produces. *)

open Bhttp
open Bhttp_test_support.Build

let request_result = Alcotest.(result Vectors.request Vectors.error)
let response_result = Alcotest.(result Vectors.response Vectors.error)
let headers = [ ("a", "1"); ("b", "2") ]
let header_lines = [ line "a" "1"; line "b" "2" ]
let trailers = [ ("t", "3") ]
let trailer_lines = [ line "t" "3" ]

let request =
  Request.make ~meth:"POST" ~authority:"example.com" ~path:"/" ~headers
    ~content:"content" ~trailers ()

let known_request =
  concat
    [
      v 0;
      control ~meth:"POST" ();
      known header_lines;
      str "content";
      known trailer_lines;
    ]

let indeterminate_request =
  concat
    [
      v 2;
      control ~meth:"POST" ();
      indeterminate header_lines;
      chunks [ "content" ];
      indeterminate trailer_lines;
    ]

let test_framings () =
  Alcotest.check request_result "known-length" (Ok request)
    (Request.decode known_request);
  Alcotest.check request_result "indeterminate-length" (Ok request)
    (Request.decode indeterminate_request);
  Alcotest.check request_result "content in several chunks" (Ok request)
    (Request.decode
       (concat
          [
            v 2;
            control ~meth:"POST" ();
            indeterminate header_lines;
            chunks [ "con"; "t"; "ent" ];
            indeterminate trailer_lines;
          ]))

(* RFC 9292 Section 3: integers need not use their shortest encoding. *)
let test_non_minimal_integers () =
  List.iter
    (fun size ->
      let n = sized ~size in
      let str s = n (String.length s) ^ s in
      let line name value = str name ^ str value in
      let known lines = str (concat lines) in
      Alcotest.check request_result
        (Printf.sprintf "every integer on %d bytes" size)
        (Ok request)
        (Request.decode
           (concat
              [
                n 0;
                concat [ str "POST"; str "https"; str "example.com"; str "/" ];
                known [ line "a" "1"; line "b" "2" ];
                str "content";
                known [ line "t" "3" ];
              ]));
      if size > 1 then
        Alcotest.check response_result
          (Printf.sprintf "status code on %d bytes" size)
          (Ok (Response.make ~status:200 ()))
          (Response.decode (concat [ n 1; n 200 ])))
    [ 1; 2; 4; 8 ]

(* RFC 9292 Section 3.8: the input may end before any section, which is then
   empty. *)
let test_truncation () =
  let check name expected parts =
    Alcotest.check request_result name (Ok expected)
      (Request.decode (concat parts))
  in
  let bare = Request.make ~meth:"POST" ~authority:"example.com" ~path:"/" () in
  List.iter
    (fun (framing, fields, content) ->
      let name s = Format.asprintf "%a: %s" Framing.pp framing s in
      let prefix =
        [
          v (Framing.indicator Framing.Request framing); control ~meth:"POST" ();
        ]
      in
      check (name "after control data") bare prefix;
      check
        (name "after the header section")
        { bare with headers }
        (prefix @ [ fields header_lines ]);
      check (name "after the content")
        { bare with headers; content = "content" }
        (prefix @ [ fields header_lines; content ]);
      check (name "after an empty header section") bare (prefix @ [ fields [] ]);
      check (name "after empty content") bare (prefix @ [ fields []; v 0 ]))
    [
      (Framing.Known_length, known, str "content");
      (Framing.Indeterminate_length, indeterminate, chunks [ "content" ]);
    ];
  Alcotest.check response_result "a response after its status code"
    (Ok (Response.make ~status:200 ()))
    (Response.decode (concat [ v 1; v 200 ]));
  Alcotest.check response_result
    "an indeterminate-length response after its status code"
    (Ok (Response.make ~status:200 ()))
    (Response.decode (concat [ v 3; v 200 ]))

let test_padding () =
  List.iter
    (fun padding ->
      List.iter
        (fun message ->
          Alcotest.check request_result
            (Printf.sprintf "%d bytes of padding" padding)
            (Ok request)
            (Request.decode (message ^ String.make padding '\000')))
        [ known_request; indeterminate_request ])
    [ 1; 10; 1000 ];
  (* Zero bytes after a truncated message read as empty sections. *)
  Alcotest.check request_result "padding after truncation"
    (Ok (Request.make ~meth:"GET" ~authority:"example.com" ~path:"/" ()))
    (Request.decode (concat [ v 0; control (); String.make 7 '\000' ]));
  List.iter
    (fun message ->
      Alcotest.check request_result "non-zero padding"
        (Error Error.Invalid_padding)
        (Request.decode (message ^ "\000\001"));
      Alcotest.check request_result "a second message as padding"
        (Error Error.Invalid_padding)
        (Request.decode (message ^ message)))
    [ known_request; indeterminate_request ]

let test_request_targets () =
  (* RFC 9292 Section 3.4: an authority that HTTP/2 would omit is empty, and a
     Host field is not copied into it. *)
  let r =
    Request.make ~meth:"GET" ~path:"/" ~headers:[ ("host", "example.com") ] ()
  in
  Alcotest.check request_result "empty authority" (Ok r)
    (Request.decode
       (concat
          [ v 0; control ~authority:"" (); known [ line "host" "example.com" ] ]));
  (* RFC 9292 Section 6 does not prohibit CONNECT, which has neither a scheme
     nor a path. *)
  let connect =
    Request.make ~meth:"CONNECT" ~scheme:"" ~authority:"example.com:443"
      ~path:"" ()
  in
  Alcotest.check request_result "CONNECT" (Ok connect)
    (Request.decode
       (concat
          [
            v 0;
            control ~meth:"CONNECT" ~scheme:"" ~authority:"example.com:443"
              ~path:"" ();
          ]))

let test_fields () =
  let decode_headers lines =
    Result.map
      (fun (r : Request.t) -> r.headers)
      (Request.decode (concat [ v 0; control (); known lines ]))
  in
  let fields = Alcotest.(result (list (pair string string)) Vectors.error) in
  (* RFC 9292 Section 3.6 invalidates only bytes that a field name cannot hold,
     and uppercase letters are not among them. *)
  Alcotest.check fields "names are lowercased, values are not"
    (Ok [ ("content-type", "Text/Plain") ])
    (decode_headers [ line "Content-Type" "Text/Plain" ]);
  Alcotest.check fields "an empty value"
    (Ok [ ("a", "") ])
    (decode_headers [ line "a" "" ]);
  Alcotest.check fields "obs-text and inner whitespace"
    (Ok [ ("a", "caf\xc3\xa9 \t au lait") ])
    (decode_headers [ line "a" "caf\xc3\xa9 \t au lait" ]);
  Alcotest.check fields "repeated names keep their order"
    (Ok [ ("cookie", "a=1"); ("x", "y"); ("cookie", "b=2") ])
    (decode_headers [ line "cookie" "a=1"; line "x" "y"; line "cookie" "b=2" ]);
  Alcotest.check fields "an extension pseudo-field comes first"
    (Ok [ (":protocol", "websocket"); ("a", "1") ])
    (decode_headers [ line ":protocol" "websocket"; line "a" "1" ]);
  (* "they do not cause a message to be invalid" *)
  Alcotest.check fields "connection-specific fields"
    (Ok [ ("connection", "keep-alive"); ("transfer-encoding", "chunked") ])
    (decode_headers
       [ line "connection" "keep-alive"; line "transfer-encoding" "chunked" ])

let test_informational () =
  let expected =
    Response.make ~status:204
      ~informational:
        [
          Response.informational ~status:100 [];
          Response.informational ~status:199 [ ("a", "1") ];
        ]
      ()
  in
  Alcotest.check response_result "known-length" (Ok expected)
    (Response.decode
       (concat [ v 1; v 100; known []; v 199; known [ line "a" "1" ]; v 204 ]));
  Alcotest.check response_result "indeterminate-length" (Ok expected)
    (Response.decode
       (concat
          [
            v 3;
            v 100;
            indeterminate [];
            v 199;
            indeterminate [ line "a" "1" ];
            v 204;
          ]))

let test_large_content () =
  let content = String.make (1 lsl 20) 'x' in
  let expected =
    Request.make ~meth:"PUT" ~authority:"example.com" ~path:"/" ~content ()
  in
  Alcotest.check request_result "known-length" (Ok expected)
    (Request.decode
       (concat [ v 0; control ~meth:"PUT" (); known []; str content ]));
  let half = String.sub content 0 (1 lsl 19) in
  Alcotest.check request_result "indeterminate-length" (Ok expected)
    (Request.decode
       (concat
          [
            v 2; control ~meth:"PUT" (); indeterminate []; chunks [ half; half ];
          ]))

let rejects_request name expected parts =
  Alcotest.check request_result name (Error expected)
    (Request.decode (concat parts))

let rejects_response name expected parts =
  Alcotest.check response_result name (Error expected)
    (Response.decode (concat parts))

let test_invalid_framing () =
  rejects_request "empty input" (Error.Truncated "framing indicator") [];
  rejects_request "indicator 4" (Error.Invalid_framing_indicator 4) [ v 4 ];
  rejects_request "indicator 5 on eight bytes"
    (Error.Invalid_framing_indicator 5)
    [ sized ~size:8 5 ];
  rejects_request "half an indicator" (Error.Truncated "framing indicator")
    [ "\x40" ];
  rejects_request "a response"
    (Error.Unexpected_message { expected = "request"; actual = "response" })
    [ v 1; v 200 ];
  rejects_response "a request"
    (Error.Unexpected_message { expected = "response"; actual = "request" })
    [ v 0; control () ];
  Alcotest.(check (result reject Vectors.error))
    "either kind" (Error (Error.Invalid_framing_indicator 4))
    (Message.decode (v 4))

(* "A message that is truncated at any other point is invalid." *)
let test_invalid_truncation () =
  rejects_request "no control data" (Error.Truncated "method") [ v 0 ];
  rejects_request "a short method" (Error.Truncated "method") [ v 0; v 3; "GE" ];
  rejects_request "no scheme" (Error.Truncated "scheme") [ v 0; str "GET" ];
  rejects_request "no authority" (Error.Truncated "authority")
    [ v 0; str "GET"; str "https" ];
  rejects_request "no path" (Error.Truncated "path")
    [ v 0; str "GET"; str "https"; str "example.com" ];
  rejects_request "a short path" (Error.Truncated "path")
    [ v 0; str "GET"; str "https"; str "example.com"; v 2; "/" ];
  rejects_request "a section longer than the input"
    (Error.Truncated "header section")
    [ v 0; control (); v 9; line "a" "1" ];
  rejects_request "a field overrunning its section"
    (Error.Truncated "field value")
    [ v 0; control (); v 3; line "a" "1" ];
  rejects_request "a name overrunning its section"
    (Error.Truncated "field name")
    [ v 0; control (); v 2; v 5; "a" ];
  rejects_request "content longer than the input" (Error.Truncated "content")
    [ v 0; control (); known []; v 8; "content" ];
  rejects_request "a trailer section longer than the input"
    (Error.Truncated "trailer section")
    [ v 0; control (); known []; str ""; v 1 ];
  rejects_request "half a length" (Error.Truncated "header section")
    [ v 0; control (); "\x40" ];
  rejects_request "header lines without a terminator"
    (Error.Truncated "header section terminator")
    [ v 2; control (); line "a" "1" ];
  rejects_request "half a field line" (Error.Truncated "field value")
    [ v 2; control (); str "a" ];
  rejects_request "chunks without a terminator"
    (Error.Truncated "content terminator")
    [ v 2; control (); indeterminate []; str "content" ];
  rejects_request "a chunk longer than the input"
    (Error.Truncated "content chunk")
    [ v 2; control (); indeterminate []; v 8; "content" ];
  rejects_request "trailer lines without a terminator"
    (Error.Truncated "trailer section terminator")
    [ v 2; control (); indeterminate []; chunks []; line "t" "3" ];
  rejects_response "no status code" (Error.Truncated "status code") [ v 1 ];
  rejects_response "half a status code" (Error.Truncated "status code")
    [ v 1; "\x40" ];
  (* A final status code must follow an informational response. *)
  rejects_response "only an informational status code"
    (Error.Truncated "informational response")
    [ v 1; v 100 ];
  rejects_response "no final status code" (Error.Truncated "status code")
    [ v 1; v 100; known [] ];
  rejects_response "no final status code, indeterminate-length"
    (Error.Truncated "status code")
    [ v 3; v 100; indeterminate [] ];
  rejects_response "an unterminated informational response"
    (Error.Truncated "informational response terminator")
    [ v 3; v 100; line "a" "1" ]

let test_invalid_status () =
  List.iter
    (fun status ->
      rejects_response
        (Printf.sprintf "status %d" status)
        (Error.Invalid_status status)
        [ v 1; v status ])
    [ 0; 99; 600; 1000; Varint.max_value ];
  (* The status code alone tells a final response from an informational one, so
     a second final status code reads as the header section. *)
  rejects_response "an informational response after the final one"
    (Error.Truncated "header section")
    [ v 1; v 200; v 100; known [] ]

let test_invalid_fields () =
  let headers name expected lines =
    rejects_request name expected [ v 0; control (); known lines ];
    rejects_request
      (name ^ ", indeterminate-length")
      expected
      [ v 2; control (); indeterminate lines ]
  in
  rejects_request "an empty name" (Error.Invalid_field_name "")
    [ v 0; control (); known [ line "" "1" ] ];
  List.iter
    (fun name ->
      headers (String.escaped name) (Error.Invalid_field_name name)
        [ line name "1" ])
    [ "a b"; "a(b"; "a\x7f"; "a\x80"; "a\000"; "a:b"; ":"; "::a"; "a\r\nb" ];
  List.iter
    (fun name ->
      headers name (Error.Forbidden_pseudo_field name) [ line name "1" ];
      headers
        (String.uppercase_ascii name)
        (Error.Forbidden_pseudo_field name)
        [ line (String.uppercase_ascii name) "1" ])
    [ ":method"; ":scheme"; ":authority"; ":path"; ":status" ];
  headers "a pseudo-field after a regular field"
    (Error.Misplaced_pseudo_field ":protocol")
    [ line "a" "1"; line ":protocol" "websocket" ];
  List.iter
    (fun value ->
      headers
        (Printf.sprintf "value %S" value)
        (Error.Invalid_field_value "a")
        [ line "a" value ])
    [
      "\000";
      "a\000b";
      "a\rb";
      "a\nb";
      "a\r\nb: c";
      " a";
      "a ";
      "\ta";
      "a\t";
      " ";
    ];
  rejects_request "a pseudo-field in the trailers"
    (Error.Misplaced_pseudo_field ":protocol")
    [ v 0; control (); known []; str ""; known [ line ":protocol" "x" ] ];
  rejects_request "an invalid trailer value" (Error.Invalid_field_value "t")
    [ v 0; control (); known []; str ""; known [ line "t" "a\nb" ] ];
  rejects_response "an invalid informational field"
    (Error.Invalid_field_name "a b")
    [ v 1; v 100; known [ line "a b" "1" ]; v 200 ]

(* Beyond RFC 9292: control data that would split a request line. *)
let test_invalid_control_data () =
  let method_error = Error.Invalid_control_data "method is not a token" in
  rejects_request "an empty method" method_error [ v 0; control ~meth:"" () ];
  rejects_request "a space in the method" method_error
    [ v 0; control ~meth:"GE T" () ];
  List.iter
    (fun (what, message) ->
      rejects_request
        (what ^ " with a line break")
        (Error.Invalid_control_data (what ^ " contains a forbidden byte"))
        [ v 0; message ])
    [
      ("scheme", control ~scheme:"https\r\n" ());
      ("authority", control ~authority:"example.com\r\nx: y" ());
      ("path", control ~path:"/ HTTP/1.1\r\nx: y" ());
      ("path", control ~path:"/a b" ());
      ("path", control ~path:"/\x7f" ());
    ]

let tests =
  [
    Alcotest.test_case "both framings" `Quick test_framings;
    Alcotest.test_case "non-minimal integers" `Quick test_non_minimal_integers;
    Alcotest.test_case "truncation" `Quick test_truncation;
    Alcotest.test_case "padding" `Quick test_padding;
    Alcotest.test_case "request targets" `Quick test_request_targets;
    Alcotest.test_case "fields" `Quick test_fields;
    Alcotest.test_case "informational responses" `Quick test_informational;
    Alcotest.test_case "large content" `Quick test_large_content;
    Alcotest.test_case "invalid framing" `Quick test_invalid_framing;
    Alcotest.test_case "invalid truncation" `Quick test_invalid_truncation;
    Alcotest.test_case "invalid status codes" `Quick test_invalid_status;
    Alcotest.test_case "invalid fields" `Quick test_invalid_fields;
    Alcotest.test_case "invalid control data" `Quick test_invalid_control_data;
  ]
