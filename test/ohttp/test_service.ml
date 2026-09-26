(* The client, relay, and gateway as steps between HTTP messages. *)

open Ohttp
open Vectors

let now = 1_700_000_000.

let key =
  lazy
    (ok
       (Gateway.Key.derive ~key_id:1 Hpke.Kem.X25519
          ~ikm:(String.make 32 '\x53')))

let gateway = lazy (ok (Gateway.create [ Lazy.force key ]))
let config = lazy (Gateway.Key.config (Lazy.force key))

let service ?replay ?checks_replay () =
  Service.Gateway.create ~rng:(rng ()) ?replay ?checks_replay
    (Lazy.force gateway)

let get ?(headers = []) () =
  Bhttp.Request.make ~meth:"GET" ~authority:"example.com" ~path:"/x" ~headers ()

let ok_answer = Bhttp.Response.make ~status:200 ~content:"hello" ()

(* The gateway's side of one exchange: the step, and the answer that it gives,
   with [answer] for a request that it forwards. *)
let serve ?(now = now) ?(answer = fun _ -> ok_answer) service
    (request : Service.request) =
  match
    Service.Gateway.receive service ~now ~meth:"POST" ~headers:request.headers
      request.body
  with
  | Respond response -> (None, response)
  | Forward (inner, seal) -> (Some inner, seal (answer inner))

let finish exchange (response : Service.response) =
  Service.Client.finish exchange ~status:response.status
    ~headers:response.headers response.body

let response exchange answer =
  match finish exchange answer with
  | Ok (Response r) -> r
  | Ok (Retry _) -> Alcotest.fail "unexpected retry"
  | Error e -> Alcotest.failf "%a" Error.pp e

let test_exchange () =
  let service = service () in
  let request, exchange =
    ok (Service.Client.start ~rng:(rng ()) (Lazy.force config) (get ()))
  in
  Alcotest.(check (list (pair string string)))
    "the fields of the POST" Http_binding.Client.request_headers request.headers;
  let inner, answer = serve service request in
  Alcotest.(check bool)
    "forwarded unchanged" true
    (Option.equal Bhttp.Request.equal inner (Some (get ())));
  Alcotest.(check int) "sealed" 200 answer.status;
  Alcotest.(check (list (pair string string)))
    "the fields of the answer" Http_binding.Gateway.response_headers
    answer.headers;
  let r = response exchange answer in
  Alcotest.(check string) "opened" "hello" r.content

let test_date () =
  let request, _ =
    ok
      (Service.Client.start ~rng:(rng ()) ~now (Lazy.force config)
         (get ~headers:[ ("date", "yesterday"); ("accept", "*/*") ] ()))
  in
  let inner, _ = serve (service ()) request in
  Alcotest.(check (option (list (pair string string))))
    "one date, in place of the old"
    (Some [ Replay.date_field ~now; ("accept", "*/*") ])
    (Option.map (fun (r : Bhttp.Request.t) -> r.headers) inner)

(* The client's clock is an hour behind. The gateway says so, sealed, and the
   client retries once, encapsulated anew, with the gateway's time. *)
let test_retry () =
  let replay = Replay.create ~tolerance:60. ~capacity:16 () in
  let service = service ~replay () in
  let first, exchange =
    ok
      (Service.Client.start ~rng:(rng ()) ~now:(now -. 3600.)
         (Lazy.force config) (get ()))
  in
  let inner, answer = serve service first in
  Alcotest.(check bool) "not forwarded" true (inner = None);
  match finish exchange answer with
  | Ok (Retry (second, exchange)) -> (
      Alcotest.(check bool)
        "encapsulated anew" false
        (String.equal first.body second.body);
      let inner, answer = serve service second in
      Alcotest.(check bool) "forwarded" true (inner <> None);
      Alcotest.(check string)
        "answered" "hello" (response exchange answer).content;
      (* The same request once more is a replay, and gets no second retry. *)
      let _, answer = serve service second in
      match finish exchange answer with
      | Ok (Response r) -> Alcotest.(check int) "replayed" 400 r.status
      | _ -> Alcotest.fail "expected a response")
  | _ -> Alcotest.fail "expected a retry"

(* Without a date the client cannot correct one, and does not retry. *)
let test_no_retry_without_date () =
  let replay = Replay.create ~tolerance:60. ~capacity:16 () in
  let request, exchange =
    ok (Service.Client.start ~rng:(rng ()) (Lazy.force config) (get ()))
  in
  let _, answer = serve (service ~replay ()) request in
  let r = response exchange answer in
  Alcotest.(check int) "refused" 400 r.status

let test_checks_replay () =
  let replay = Replay.create ~tolerance:60. ~capacity:16 () in
  let service =
    service ~replay
      ~checks_replay:(fun (r : Bhttp.Request.t) -> r.meth <> "GET")
      ()
  in
  let request, _ =
    ok (Service.Client.start ~rng:(rng ()) (Lazy.force config) (get ()))
  in
  let first, _ = serve service request and second, _ = serve service request in
  Alcotest.(check bool)
    "a GET is not checked" true
    (first <> None && second <> None)

let test_in_the_clear () =
  let service = service () in
  let receive ~meth ~headers body =
    match Service.Gateway.receive service ~now ~meth ~headers body with
    | Respond r -> r.status
    | Forward _ -> Alcotest.fail "forwarded"
  in
  Alcotest.(check int) "a GET" 405 (receive ~meth:"GET" ~headers:[] "");
  Alcotest.(check int)
    "another type" 415
    (receive ~meth:"POST" ~headers:[ ("content-type", "text/plain") ] "");
  let request, _ =
    ok
      (Service.Client.start ~rng:(rng ())
         (Gateway.Key.config
            (ok
               (Gateway.Key.derive ~key_id:9 Hpke.Kem.X25519
                  ~ikm:(String.make 32 '\x09'))))
         (get ()))
  in
  let _, answer = serve service request in
  Alcotest.(check int) "an unknown key" 400 answer.status;
  (* The client learns that it was not sealed. *)
  let _, exchange =
    ok (Service.Client.start ~rng:(rng ()) (Lazy.force config) (get ()))
  in
  Alcotest.(check (result reject error))
    "an unsealed answer" (Error (Error.Unexpected_status 400))
    (Result.map ignore (finish exchange answer))

let test_sealed_errors () =
  let service = service () in
  let request, exchange =
    ok (Service.Client.start ~rng:(rng ()) (Lazy.force config) (get ()))
  in
  let _, answer =
    serve service request ~answer:(fun _ -> Bhttp.Response.make ~status:504 ())
  in
  Alcotest.(check int) "sealed" 200 answer.status;
  Alcotest.(check int)
    "the gateway's own answer" 504 (response exchange answer).status

(* It cannot work through an encapsulation (RFC 9458 Section 5.1). *)
let test_continue () =
  let expects =
    Bhttp.Request.make ~meth:"POST" ~authority:"example.com" ~path:"/"
      ~headers:[ ("expect", "100-continue") ]
      ()
  in
  Alcotest.(check (result reject error))
    "refused" (Error Error.Continue_expectation)
    (Result.map ignore
       (Service.Client.start ~rng:(rng ()) (Lazy.force config) expects))

let test_key_configs () =
  let r = Service.Gateway.key_configs (service ()) in
  Alcotest.(check int) "status" 200 r.status;
  match
    Service.Client.key_configs ~status:r.status ~headers:r.headers r.body
  with
  | Ok [ c ] ->
      Alcotest.(check bool)
        "the key" true
        (Key_config.equal c (Lazy.force config))
  | _ -> Alcotest.fail "expected one key configuration"

let test_relay () =
  let content_type = ("content-type", Media_type.ohttp_request) in
  (match
     Service.Relay.request ~meth:"POST"
       ~headers:
         [
           ("Content-Type", Media_type.ohttp_request);
           ("cookie", "id=1");
           ("x-forwarded-for", "192.0.2.1");
         ]
       "sealed"
   with
  | Ok forwarded ->
      Alcotest.(check (list (pair string string)))
        "only the content type" [ content_type ] forwarded.headers;
      Alcotest.(check string) "the content" "sealed" forwarded.body
  | Error _ -> Alcotest.fail "refused");
  let status = function
    | Ok _ -> 0
    | Error (r : Service.response) -> r.status
  in
  Alcotest.(check int)
    "a GET" 405
    (status (Service.Relay.request ~meth:"GET" ~headers:[] ""));
  Alcotest.(check int)
    "another type" 415
    (status
       (Service.Relay.request ~meth:"POST"
          ~headers:[ ("content-type", "text/html") ]
          ""));
  let back =
    Service.Relay.response ~status:200
      ~headers:
        [
          ("Content-Type", Media_type.ohttp_response);
          ("cache-control", "no-store");
          ("set-cookie", "id=2");
          ("server", "gateway");
        ]
      "sealed"
  in
  Alcotest.(check (list (pair string string)))
    "only what describes the content"
    [
      ("content-type", Media_type.ohttp_response); ("cache-control", "no-store");
    ]
    back.headers

let test_target () =
  let targets =
    [ ("example.com", "http://127.0.0.1:8000/"); ("a.example", "http://a") ]
  in
  let target ?(authority = "example.com") path =
    Result.map_error
      (fun (r : Bhttp.Response.t) -> r.status)
      (Service.Gateway.target ~targets
         (Bhttp.Request.make ~meth:"GET" ~authority ~path ()))
  in
  let check = Alcotest.(check (result string int)) in
  check "appended" (Ok "http://127.0.0.1:8000/x?y=1") (target "/x?y=1");
  check "another target" (Ok "http://a/") (target ~authority:"a.example" "/");
  check "an authority it does not serve" (Error 403)
    (target ~authority:"b.example" "/");
  check "a path that would change the authority" (Error 400)
    (target "@evil.example/");
  check "an empty path" (Error 400) (target "")

let tests =
  [
    Alcotest.test_case "exchange" `Quick test_exchange;
    Alcotest.test_case "date" `Quick test_date;
    Alcotest.test_case "retry with the gateway's time" `Quick test_retry;
    Alcotest.test_case "no retry without a date" `Quick
      test_no_retry_without_date;
    Alcotest.test_case "requests left out of the replay check" `Quick
      test_checks_replay;
    Alcotest.test_case "answers in the clear" `Quick test_in_the_clear;
    Alcotest.test_case "the gateway's own answers" `Quick test_sealed_errors;
    Alcotest.test_case "100-continue" `Quick test_continue;
    Alcotest.test_case "key configurations" `Quick test_key_configs;
    Alcotest.test_case "relay" `Quick test_relay;
    Alcotest.test_case "targets" `Quick test_target;
  ]
