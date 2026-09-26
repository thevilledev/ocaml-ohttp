(* Between the messages of the http package and those of Bhttp. *)

let fields = Alcotest.(list (pair string string))

let test_request_to_bhttp () =
  let request =
    Http.Request.make ~meth:`PUT
      ~headers:
        (Http.Header.of_list
           [
             ("Host", "example.com");
             ("Connection", "keep-alive, x-hop");
             ("X-Hop", "1");
             ("Content-Type", "text/plain");
           ])
      "/a?b=c"
  in
  let r = Ohttp_cohttp.request_to_bhttp ~scheme:"https" request "body" in
  Alcotest.(check string) "method" "PUT" r.meth;
  Alcotest.(check string) "authority, from host" "example.com" r.authority;
  Alcotest.(check string) "path" "/a?b=c" r.path;
  Alcotest.check fields "lowercase, without the fields of the connection"
    [ ("content-type", "text/plain") ]
    r.headers;
  Alcotest.(check string) "content" "body" r.content

let test_request_of_bhttp () =
  let request =
    Bhttp.Request.make ~meth:"DELETE" ~authority:"example.com" ~path:"/x"
      ~headers:[ ("accept", "*/*"); ("transfer-encoding", "chunked") ]
      ()
  in
  let r = Ohttp_cohttp.request_of_bhttp request in
  Alcotest.(check string) "method" "DELETE" (Http.Method.to_string r.meth);
  Alcotest.(check string) "target" "/x" r.resource;
  Alcotest.check fields "host from the authority"
    [ ("host", "example.com"); ("accept", "*/*") ]
    (Http.Header.to_list r.headers);
  let own =
    Ohttp_cohttp.request_headers
      { request with headers = [ ("host", "other.example") ] }
  in
  Alcotest.check fields "its own host"
    [ ("host", "other.example") ]
    (Http.Header.to_list own)

let test_response_to_bhttp () =
  let response =
    Http.Response.make ~status:`Not_found
      ~headers:(Http.Header.of_list [ ("Content-Type", "text/plain") ])
      ()
  in
  let r = Ohttp_cohttp.response_to_bhttp response "gone" in
  Alcotest.(check int) "status" 404 r.status;
  Alcotest.check fields "fields" [ ("content-type", "text/plain") ] r.headers;
  Alcotest.(check string) "content" "gone" r.content

let test_resources () =
  let resource ?path meth target =
    Ohttp_cohttp.gateway_resource ?path (Http.Request.make ~meth target)
  in
  let check name expected actual =
    Alcotest.(check bool) name true (expected = actual)
  in
  check "key configurations" `Key_configs
    (resource `GET "/.well-known/ohttp-gateway");
  check "not with a POST" `Not_found
    (resource `POST "/.well-known/ohttp-gateway");
  check "requests" `Requests (resource `POST "/gateway");
  check "requests, with a query" `Requests (resource `POST "/gateway?x");
  check "requests, elsewhere" `Requests (resource ~path:"/o" `POST "/o");
  check "anything else" `Not_found (resource `POST "/other")

let test_target () =
  let targets = [ ("example.com", Uri.of_string "http://127.0.0.1:8000") ] in
  let target authority path =
    Result.map_error
      (fun (r : Bhttp.Response.t) -> r.status)
      (Result.map Uri.to_string
         (Ohttp_cohttp.target ~targets
            (Bhttp.Request.make ~meth:"GET" ~authority ~path ())))
  in
  Alcotest.(check (result string int))
    "appended" (Ok "http://127.0.0.1:8000/a?b")
    (target "example.com" "/a?b");
  Alcotest.(check (result string int))
    "refused" (Error 403)
    (target "other.example" "/")

let () =
  Alcotest.run "ohttp-cohttp"
    [
      ( "conversions",
        [
          Alcotest.test_case "request to Bhttp" `Quick test_request_to_bhttp;
          Alcotest.test_case "request of Bhttp" `Quick test_request_of_bhttp;
          Alcotest.test_case "response to Bhttp" `Quick test_response_to_bhttp;
          Alcotest.test_case "gateway resources" `Quick test_resources;
          Alcotest.test_case "targets" `Quick test_target;
        ] );
    ]
