open Bhttp

let fields =
  [
    ("Cookie", "a=1");
    ("accept", "text/html");
    ("cookie", "b=2");
    ("Accept", "*/*");
  ]

let test_lookup () =
  Alcotest.(check (option string))
    "first value" (Some "a=1")
    (Field.get "cookie" fields);
  Alcotest.(check (option string))
    "names compare without case" (Some "text/html")
    (Field.get "ACCEPT" fields);
  Alcotest.(check (option string)) "absent" None (Field.get "host" fields);
  Alcotest.(check (list string))
    "every value, in order" [ "text/html"; "*/*" ]
    (Field.get_all "accept" fields);
  Alcotest.(check (option string))
    "values combine with a comma" (Some "text/html, */*")
    (Field.combined "accept" fields);
  (* RFC 9292 Section 3.6 keeps the cookie exception of HTTP/2. *)
  Alcotest.(check (option string))
    "cookies combine with a semicolon" (Some "a=1; b=2")
    (Field.combined "Cookie" fields);
  Alcotest.(check (option string))
    "nothing to combine" None
    (Field.combined "host" fields)

let test_lowercase () =
  Alcotest.(check (list (pair string string)))
    "names only"
    [ ("cookie", "A=1"); ("x-y", "Z") ]
    (Field.lowercase [ ("Cookie", "A=1"); ("X-Y", "Z") ])

let test_token () =
  List.iter
    (fun s -> Alcotest.(check bool) s true (Field.is_token s))
    [ "GET"; "a"; "x-y_z.0"; "!#$%&'*+-.^_`|~" ];
  List.iter
    (fun s -> Alcotest.(check bool) (String.escaped s) false (Field.is_token s))
    [ ""; "a b"; "a:b"; "a/b"; "a\000"; "caf\xc3\xa9"; "(a)"; "a=b"; "\"a\"" ]

let test_connection_specific () =
  List.iter
    (fun name ->
      Alcotest.(check bool) name true (Field.is_connection_specific name))
    [
      "connection";
      "Proxy-Connection";
      "keep-alive";
      "TE";
      "transfer-encoding";
      "upgrade";
    ];
  Alcotest.(check bool) "host" false (Field.is_connection_specific "host");
  Alcotest.(check (list (pair string string)))
    "nominated fields go too"
    [ ("host", "example.com"); ("accept", "*/*") ]
    (Field.without_connection_specific
       [
         ("host", "example.com");
         ("Connection", "X-Hop , close");
         ("x-hop", "1");
         ("Keep-Alive", "timeout=5");
         ("accept", "*/*");
         ("transfer-encoding", "chunked");
         ("connection", "x-other");
         ("X-Other", "2");
       ])

let test_validate () =
  let ok = Ok () in
  Alcotest.(check (result unit Vectors.error))
    "headers" ok
    (Field.validate_headers
       [ (":protocol", "websocket"); ("A", "1"); ("b", "") ]);
  Alcotest.(check (result unit Vectors.error))
    "trailers" ok
    (Field.validate_trailers [ ("a", "1") ]);
  Alcotest.(check (result unit Vectors.error))
    "empty sections" ok
    (Field.validate_headers []);
  Alcotest.(check (result unit Vectors.error))
    "a pseudo-field in trailers"
    (Error (Error.Misplaced_pseudo_field ":protocol"))
    (Field.validate_trailers [ (":protocol", "websocket") ])

let tests =
  [
    Alcotest.test_case "lookup" `Quick test_lookup;
    Alcotest.test_case "lowercase" `Quick test_lowercase;
    Alcotest.test_case "tokens" `Quick test_token;
    Alcotest.test_case "connection-specific fields" `Quick
      test_connection_specific;
    Alcotest.test_case "validate" `Quick test_validate;
  ]
