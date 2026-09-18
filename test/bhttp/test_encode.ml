(* The encoder's options, and its refusal to emit what a decoder rejects. *)

open Bhttp
open Build

let headers = [ ("a", "1") ]
let trailers = [ ("t", "3") ]
let bare = Request.make ~meth:"GET" ~authority:"example.com" ~path:"/" ()

let prefix framing =
  concat [ v (Framing.indicator Framing.Request framing); control () ]

let test_defaults () =
  Vectors.check_bytes "known-length, every section present"
    (concat [ prefix Framing.Known_length; known []; str ""; known [] ])
    (Request.encode_exn bare);
  Vectors.check_bytes "indeterminate-length, every terminator present"
    (concat [ prefix Framing.Indeterminate_length; v 0; v 0; v 0 ])
    (Request.encode_exn ~framing:Framing.Indeterminate_length bare);
  Vectors.check_bytes "indeterminate-length content is one chunk"
    (concat
       [
         prefix Framing.Indeterminate_length;
         indeterminate [ line "a" "1" ];
         chunks [ "content" ];
         indeterminate [ line "t" "3" ];
       ])
    (Request.encode_exn ~framing:Framing.Indeterminate_length
       { bare with headers; content = "content"; trailers });
  let request = Request.make ~meth:"GET" ~path:"/" () in
  Alcotest.(check string) "the scheme defaults to https" "https" request.scheme;
  Alcotest.(check string) "the authority defaults to empty" "" request.authority

(* RFC 9292 Section 3.8: trailing empty sections may be omitted, and only
   those. *)
let test_truncate () =
  List.iter
    (fun (framing, fields, content) ->
      let check name expected request =
        Vectors.check_bytes
          (Format.asprintf "%a: %s" Framing.pp framing name)
          (concat (prefix framing :: expected))
          (Request.encode_exn ~framing ~truncate:true request)
      in
      check "nothing but control data" [] bare;
      check "headers only" [ fields [ line "a" "1" ] ] { bare with headers };
      check "content keeps an empty header section"
        [ fields []; content "content" ]
        { bare with content = "content" };
      check "trailers keep every section"
        [ fields []; content ""; fields [ line "t" "3" ] ]
        { bare with trailers })
    [
      (Framing.Known_length, known, str);
      ( Framing.Indeterminate_length,
        indeterminate,
        fun s -> chunks (if s = "" then [] else [ s ]) );
    ];
  Vectors.check_bytes "a response"
    (concat [ v 1; v 200 ])
    (Response.encode_exn ~truncate:true (Response.make ~status:200 ()))

let test_padding () =
  let encoded = Request.encode_exn bare in
  Vectors.check_bytes "zero bytes are appended"
    (encoded ^ String.make 16 '\000')
    (Request.encode_exn ~padding:16 bare);
  Vectors.check_bytes "padding follows truncation"
    (prefix Framing.Known_length ^ String.make 3 '\000')
    (Request.encode_exn ~truncate:true ~padding:3 bare);
  Alcotest.check_raises "negative padding"
    (Invalid_argument "Bhttp: negative padding") (fun () ->
      ignore (Request.encode ~padding:(-1) bare))

let test_lowercase () =
  Vectors.check_bytes "field names are lowercased, values are not"
    (Request.encode_exn
       { bare with headers = [ ("content-type", "Text/Plain") ] })
    (Request.encode_exn
       { bare with headers = [ ("Content-Type", "Text/Plain") ] })

let test_informational () =
  let response =
    Response.make ~status:200
      ~informational:[ Response.informational ~status:103 [ ("a", "1") ] ]
      ()
  in
  Vectors.check_bytes "known-length"
    (concat
       [ v 1; v 103; known [ line "a" "1" ]; v 200; known []; str ""; known [] ])
    (Response.encode_exn response);
  Vectors.check_bytes "indeterminate-length"
    (concat
       [ v 3; v 103; indeterminate [ line "a" "1" ]; v 200; v 0; v 0; v 0 ])
    (Response.encode_exn ~framing:Framing.Indeterminate_length response);
  (* An informational response is never truncated. *)
  Vectors.check_bytes "truncation leaves informational responses whole"
    (concat [ v 1; v 100; known []; v 200 ])
    (Response.encode_exn ~truncate:true
       (Response.make ~status:200
          ~informational:[ Response.informational ~status:100 [] ]
          ()))

(* Whatever the decoder rejects, the encoder refuses to produce. *)
let test_invalid () =
  let request name expected r =
    Alcotest.(check (result string Vectors.error))
      name (Error expected) (Request.encode r);
    Alcotest.(check (result unit Vectors.error))
      (name ^ ", validate") (Error expected) (Request.validate r)
  in
  let response name expected r =
    Alcotest.(check (result string Vectors.error))
      name (Error expected) (Response.encode r)
  in
  request "method" (Error.Invalid_control_data "method is not a token")
    { bare with meth = "GE T" };
  request "empty method" (Error.Invalid_control_data "method is not a token")
    { bare with meth = "" };
  request "path" (Error.Invalid_control_data "path contains a forbidden byte")
    { bare with path = "/\r\n" };
  request "field name" (Error.Invalid_field_name "a b")
    { bare with headers = [ ("A b", "1") ] };
  request "field value" (Error.Invalid_field_value "a")
    { bare with headers = [ ("a", "1\r\nb: 2") ] };
  request "forbidden pseudo-field" (Error.Forbidden_pseudo_field ":path")
    { bare with headers = [ (":Path", "/") ] };
  request "misplaced pseudo-field" (Error.Misplaced_pseudo_field ":protocol")
    { bare with headers = [ ("a", "1"); (":protocol", "x") ] };
  request "pseudo-field in trailers" (Error.Misplaced_pseudo_field ":protocol")
    { bare with trailers = [ (":protocol", "x") ] };
  response "status too small" (Error.Invalid_status 199)
    (Response.make ~status:199 ());
  response "status too large" (Error.Invalid_status 600)
    (Response.make ~status:600 ());
  response "informational status" (Error.Invalid_status 200)
    (Response.make ~status:200
       ~informational:[ Response.informational ~status:200 [] ]
       ());
  response "informational field" (Error.Invalid_field_value "a")
    (Response.make ~status:200
       ~informational:[ Response.informational ~status:100 [ ("a", " 1") ] ]
       ());
  Alcotest.check_raises "encode_exn"
    (Invalid_argument "invalid status code 600") (fun () ->
      ignore (Response.encode_exn (Response.make ~status:600 ())))

let test_message () =
  Alcotest.(check (result string Vectors.error))
    "a request" (Request.encode bare)
    (Message.encode (Message.Request bare));
  let response = Response.make ~status:404 () in
  Alcotest.(check (result string Vectors.error))
    "a response"
    (Response.encode ~truncate:true response)
    (Message.encode ~truncate:true (Message.Response response));
  Alcotest.(check bool)
    "kinds differ" false
    (Message.equal (Message.Request bare) (Message.Response response))

let tests =
  [
    Alcotest.test_case "defaults" `Quick test_defaults;
    Alcotest.test_case "truncate" `Quick test_truncate;
    Alcotest.test_case "padding" `Quick test_padding;
    Alcotest.test_case "lowercase names" `Quick test_lowercase;
    Alcotest.test_case "informational responses" `Quick test_informational;
    Alcotest.test_case "invalid messages" `Quick test_invalid;
    Alcotest.test_case "either kind" `Quick test_message;
  ]
