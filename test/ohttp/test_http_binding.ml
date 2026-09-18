(* Binary HTTP exchanges and the HTTP binding (RFC 9458 Section 5). *)

open Ohttp
open Vectors

let key =
  lazy
    (ok
       (Gateway.Key.derive ~key_id:1 Hpke.Kem.X25519
          ~ikm:(String.make 32 '\x61')))

let gateway = lazy (ok (Gateway.create [ Lazy.force key ]))
let config = lazy (Gateway.Key.config (Lazy.force key))
let request = Alcotest.testable Bhttp.Request.pp Bhttp.Request.equal
let response = Alcotest.testable Bhttp.Response.pp Bhttp.Response.equal

let get =
  Bhttp.Request.make ~meth:"GET" ~authority:"example.com" ~path:"/"
    ~headers:[ ("accept", "*/*") ]
    ()

let test_exchange () =
  let rng = rng () in
  let encapsulated, client_context =
    ok (Http_message.encapsulate_request ~rng (Lazy.force config) get)
  in
  let inner, gateway_context =
    ok (Http_message.decapsulate_request (Lazy.force gateway) encapsulated)
  in
  Alcotest.(check (result request response)) "request" (Ok get) inner;
  let answer =
    Bhttp.Response.make ~status:200
      ~headers:[ ("content-type", "text/plain") ]
      ~content:"hello" ()
  in
  let encapsulated =
    ok (Http_message.encapsulate_response ~rng gateway_context answer)
  in
  Alcotest.(check (result response error))
    "response" (Ok answer)
    (Http_message.decapsulate_response client_context encapsulated)

(* RFC 9458 Section 6.2.3: padding hides the length of a message. *)
let test_padding () =
  let rng = rng () in
  let plain, _ =
    ok (Http_message.encapsulate_request ~rng (Lazy.force config) get)
  in
  let padded, _ =
    ok
      (Http_message.encapsulate_request ~rng ~padding:100 (Lazy.force config)
         get)
  in
  Alcotest.(check int)
    "the padding is sealed with the message"
    (String.length plain + 100)
    (String.length padded);
  let inner, _ =
    ok (Http_message.decapsulate_request (Lazy.force gateway) padded)
  in
  Alcotest.(check (result request response))
    "and ignored when read" (Ok get) inner

(* RFC 9458 Section 5.1. *)
let test_continue_expectation () =
  let rng = rng () in
  let expecting value = { get with headers = [ ("Expect", value) ] } in
  List.iter
    (fun value ->
      Alcotest.(check bool)
        value true
        (Http_message.expects_continue (expecting value));
      Alcotest.(check bool)
        "a client must not send it" true
        (Http_message.encapsulate_request ~rng (Lazy.force config)
           (expecting value)
        |> Result.map (fun _ -> ())
        = Error Error.Continue_expectation))
    [ "100-continue"; "100-Continue"; " 100-continue "; "x, 100-continue" ];
  Alcotest.(check bool)
    "other expectations" false
    (Http_message.expects_continue (expecting "200-ok"));
  (* A client that sends it anyway gets an error, and gets it encapsulated. *)
  let encoded = Bhttp.Request.encode_exn (expecting "100-continue") in
  let encapsulated, _ =
    ok (Client.encapsulate ~rng (Lazy.force config) encoded)
  in
  let inner, _ =
    ok (Http_message.decapsulate_request (Lazy.force gateway) encapsulated)
  in
  Alcotest.(check (result request response))
    "a gateway must refuse it"
    (Error (Bhttp.Response.make ~status:417 ()))
    inner

(* RFC 9458 Section 5.2: once the encapsulation is removed, every failure is
   answered through it. *)
let test_malformed_inner_request () =
  let rng = rng () in
  let send content =
    let encapsulated, client_context =
      ok (Client.encapsulate ~rng (Lazy.force config) content)
    in
    let inner, gateway_context =
      ok (Http_message.decapsulate_request (Lazy.force gateway) encapsulated)
    in
    (inner, client_context, gateway_context)
  in
  let inner, client_context, gateway_context = send "not binary http" in
  let answer = Bhttp.Response.make ~status:400 () in
  Alcotest.(check (result request response))
    "not a message" (Error answer) inner;
  let encapsulated =
    ok (Http_message.encapsulate_response ~rng gateway_context answer)
  in
  Alcotest.(check (result response error))
    "the client reads the error" (Ok answer)
    (Http_message.decapsulate_response client_context encapsulated);
  let inner, _, _ =
    send (Bhttp.Response.encode_exn (Bhttp.Response.make ~status:200 ()))
  in
  Alcotest.(check (result request response))
    "a response in place of a request" (Error answer) inner;
  (* What the gateway seals need not be a message either. *)
  let _, client_context, gateway_context =
    send (Bhttp.Request.encode_exn get)
  in
  let encapsulated =
    ok (Gateway.encapsulate ~rng gateway_context "not binary http")
  in
  Alcotest.(check bool)
    "a response that is not a message" true
    (match Http_message.decapsulate_response client_context encapsulated with
    | Error (Error.Bhttp _) -> true
    | Ok _ | Error _ -> false);
  Alcotest.(check bool)
    "an invalid request is not sent" true
    (match
       Http_message.encapsulate_request ~rng (Lazy.force config)
         { get with meth = "GE T" }
     with
    | Error (Error.Bhttp _) -> true
    | Ok _ | Error _ -> false)

let test_client_checks () =
  let check = Http_binding.Client.check_response in
  Alcotest.(check (list (pair string string)))
    "request fields"
    [ ("content-type", "message/ohttp-req") ]
    Http_binding.Client.request_headers;
  Alcotest.(check (result unit error))
    "an encapsulated response" (Ok ())
    (check ~status:200 ~headers:[ ("Content-Type", "message/ohttp-res") ]);
  Alcotest.(check (result unit error))
    "an error from the relay or the gateway"
    (Error (Error.Unexpected_status 400))
    (check ~status:400
       ~headers:[ ("content-type", "application/problem+json") ]);
  Alcotest.(check (result unit error))
    "a 200 of another type"
    (Error (Error.Unexpected_content_type (Some "text/html")))
    (check ~status:200 ~headers:[ ("content-type", "text/html") ]);
  Alcotest.(check (result unit error))
    "a 200 without a type" (Error (Error.Unexpected_content_type None))
    (check ~status:200 ~headers:[]);
  Alcotest.(check (result unit error))
    "key configurations" (Ok ())
    (Http_binding.Client.check_key_config_response ~status:200
       ~headers:[ ("content-type", "application/ohttp-keys") ]);
  Alcotest.(check (result unit error))
    "a request in place of key configurations"
    (Error (Error.Unexpected_content_type (Some "message/ohttp-req")))
    (Http_binding.Client.check_key_config_response ~status:200
       ~headers:[ ("content-type", "message/ohttp-req") ]);
  Alcotest.(check string)
    "well-known path" "/.well-known/ohttp-gateway"
    Http_binding.well_known_gateway_path

let test_gateway_checks () =
  let check = Http_binding.Gateway.check_request in
  let headers = [ ("content-type", "message/ohttp-req") ] in
  Alcotest.(check (result unit error))
    "a request" (Ok ())
    (check ~meth:"POST" ~headers);
  Alcotest.(check (result unit error))
    "another method" (Error (Error.Method_not_allowed "GET"))
    (check ~meth:"GET" ~headers);
  Alcotest.(check (result unit error))
    "another type"
    (Error (Error.Unsupported_media_type (Some "message/ohttp-res")))
    (check ~meth:"POST" ~headers:[ ("content-type", "message/ohttp-res") ]);
  Alcotest.(check (result unit error))
    "no type" (Error (Error.Unsupported_media_type None))
    (check ~meth:"POST" ~headers:[])

let test_error_responses () =
  let status e = (Http_binding.Gateway.error_response e).status in
  (* What an outdated key configuration runs into is answered alike. *)
  List.iter
    (fun e ->
      let r = Http_binding.Gateway.error_response e in
      Alcotest.(check int) "status" 400 r.status;
      Alcotest.(check (list (pair string string)))
        "problem document"
        [ ("content-type", "application/problem+json") ]
        r.headers;
      Alcotest.(check string)
        "problem type"
        {|{"type":"https://iana.org/assignments/http-problem-types#ohttp-key","title":"key configuration not acceptable"}|}
        r.body)
    [
      Error.Unknown_key_id 3;
      Error.Unsupported_suite { kem = 0x20; kdf = 1; aead = 3 };
      Error.Decapsulation_failed;
    ];
  Alcotest.(check int)
    "truncated" 400
    (status (Error.Truncated_message "header"));
  Alcotest.(check int) "method" 405 (status (Error.Method_not_allowed "GET"));
  Alcotest.(check (list (pair string string)))
    "allowed method"
    [ ("allow", "POST") ]
    (Http_binding.Gateway.error_response (Error.Method_not_allowed "GET"))
      .headers;
  Alcotest.(check int) "type" 415 (status (Error.Unsupported_media_type None));
  Alcotest.(check int)
    "not the client's doing" 500
    (status (Error.Hpke Hpke.Error.Message_limit_reached));
  (* Whatever a gateway refuses, it refuses with a 4xx (Section 5.2). *)
  let refused = function
    | Error e -> status e
    | Ok _ -> Alcotest.fail "accepted"
  in
  let gateway = Lazy.force gateway in
  Alcotest.(check int)
    "garbage" 400
    (refused (Gateway.decapsulate gateway "garbage"));
  Alcotest.(check int) "nothing" 400 (refused (Gateway.decapsulate gateway ""));
  let encapsulated, _ =
    ok (Client.encapsulate ~rng:(rng ()) (Lazy.force config) "x")
  in
  Alcotest.(check int)
    "tampered" 400
    (refused (Gateway.decapsulate gateway (encapsulated ^ "\000")))

let tests =
  [
    Alcotest.test_case "exchange" `Quick test_exchange;
    Alcotest.test_case "padding" `Quick test_padding;
    Alcotest.test_case "100-continue" `Quick test_continue_expectation;
    Alcotest.test_case "malformed inner messages" `Quick
      test_malformed_inner_request;
    Alcotest.test_case "client checks" `Quick test_client_checks;
    Alcotest.test_case "gateway checks" `Quick test_gateway_checks;
    Alcotest.test_case "error responses" `Quick test_error_responses;
  ]
