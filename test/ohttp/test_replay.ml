(* Defences against replay (RFC 9458 Section 6.5). *)

open Ohttp
open Vectors

(* Sun, 06 Nov 1994 08:49:37 GMT, the example of RFC 9110 Section 5.6.7. *)
let example = 784111777.
let date_option = Alcotest.(option (float 0.))

let test_date_formats () =
  List.iter
    (fun s -> Alcotest.check date_option s (Some example) (Replay.Date.parse s))
    [
      "Sun, 06 Nov 1994 08:49:37 GMT";
      "Sunday, 06-Nov-94 08:49:37 GMT";
      "Sun Nov  6 08:49:37 1994";
    ];
  Alcotest.(check string)
    "IMF-fixdate" "Sun, 06 Nov 1994 08:49:37 GMT"
    (Replay.Date.format example);
  Alcotest.(check string)
    "rounded down" "Sun, 06 Nov 1994 08:49:37 GMT"
    (Replay.Date.format (example +. 0.999));
  Alcotest.(check string)
    "the epoch" "Thu, 01 Jan 1970 00:00:00 GMT" (Replay.Date.format 0.);
  Alcotest.(check string)
    "before the epoch" "Wed, 31 Dec 1969 23:59:59 GMT"
    (Replay.Date.format (-1.));
  Alcotest.(check string)
    "a leap day" "Thu, 29 Feb 2024 12:00:00 GMT"
    (Replay.Date.format 1709208000.);
  Alcotest.check_raises "beyond 9999"
    (Invalid_argument "Replay.Date.format: outside the years 0 to 9999")
    (fun () -> ignore (Replay.Date.format 253402300800.));
  (* Every day for two centuries survives formatting and parsing. *)
  let start = -2208988800. (* 1900-01-01 *) in
  for day = 0 to 73048 do
    let t =
      start +. (float_of_int day *. 86400.) +. float_of_int (day mod 86400)
    in
    let formatted = Replay.Date.format t in
    Alcotest.check date_option formatted (Some t) (Replay.Date.parse formatted)
  done

let test_two_digit_years () =
  let at year =
    Replay.Date.parse (Printf.sprintf "Thu, 01 Jan %d 00:00:00 GMT" year)
  in
  let now = Option.get (at 2026) in
  let parse s = Replay.Date.parse ~now s in
  (* Every expected date is valid, so that no comparison is of two [None]. *)
  let imf s = Some (Option.get (Replay.Date.parse s)) in
  Alcotest.check date_option "30 is 2030"
    (imf "Mon, 01 Apr 2030 00:00:00 GMT")
    (parse "Monday, 01-Apr-30 00:00:00 GMT");
  Alcotest.check date_option "90 is 1990, more than 50 years ahead otherwise"
    (imf "Sun, 01 Apr 1990 00:00:00 GMT")
    (parse "Sunday, 01-Apr-90 00:00:00 GMT");
  Alcotest.check date_option "without the time, 69 is 2069"
    (imf "Mon, 01 Apr 2069 00:00:00 GMT")
    (Replay.Date.parse "Monday, 01-Apr-69 00:00:00 GMT")

let test_invalid_dates () =
  List.iter
    (fun s -> Alcotest.check date_option s None (Replay.Date.parse s))
    [
      "";
      "Sun";
      "Mon, 06 Nov 1994 08:49:37 GMT" (* the wrong day of the week *);
      "sun, 06 Nov 1994 08:49:37 GMT" (* dates are case-sensitive *);
      "Sun, 06 nov 1994 08:49:37 GMT";
      "Sun, 06 Nov 1994 08:49:37 UTC";
      "Sun, 06 Nov 1994 08:49:37 GMT ";
      "Sun, 6 Nov 1994 08:49:37 GMT";
      "Sun, 06 Nov 94 08:49:37 GMT";
      "Sun, 06 Nov 1994 24:00:00 GMT";
      "Sun, 06 Nov 1994 08:60:00 GMT";
      "Sun, 06 Nov 1994 08:49:61 GMT";
      "Sun, 06 Nov 1994 08-49-37 GMT";
      "Thu, 29 Feb 2001 00:00:00 GMT" (* not a leap year *);
      "Sun, 31 Apr 1994 00:00:00 GMT";
      "Sun, 00 Nov 1994 08:49:37 GMT";
      "Sun, +6 Nov 1994 08:49:37 GMT";
      "Sun, 06 Nov 1994 08:49:3 GMT";
      "Sun,06 Nov 1994 08:49:37 GMT";
      "Sun, 06 Nov 1994 08:49:37 GMT\000";
      "Sunday, 06-Nov-1994 08:49:37 GMT";
      "Sun, 06-Nov-94 08:49:37 GMT";
      "Sunday 06-Nov-94 08:49:37 GMT";
      "Sunday, 06-Nov-94 08:49:37";
      "Sun Nov 6 08:49:37 1994";
      "Sun Nov  6 08:49:37 1994 ";
      "Sun Nov 06 08:49:37 94";
      "Sun Nov  6 08:49:37 GMT";
    ]

let request ?date () =
  Bhttp.Request.make ~meth:"GET" ~authority:"example.com" ~path:"/"
    ~headers:(Option.to_list (Option.map (fun t -> ("date", t)) date))
    ()

let rejection =
  Alcotest.testable Replay.pp_rejection (fun a b ->
      match (a, b) with
      | Replay.Date_skewed a, Replay.Date_skewed b -> Float.equal a b
      | a, b -> a = b)

let result = Alcotest.(result unit rejection)

let test_cache () =
  let cache = Replay.Cache.create ~window:10. ~capacity:2 in
  let add now key = Replay.Cache.add cache ~now key in
  Alcotest.(check bool) "new" true (add 0. "a" = `New);
  Alcotest.(check bool) "replayed" true (add 1. "a" = `Replayed);
  Alcotest.(check bool) "another" true (add 2. "b" = `New);
  Alcotest.(check bool) "full" true (add 3. "c" = `Full);
  Alcotest.(check int) "a refusal adds nothing" 2 (Replay.Cache.length cache);
  Alcotest.(check bool)
    "just before it expires" true
    (add 9.999 "a" = `Replayed);
  Alcotest.(check bool) "room once the first expires" true (add 10. "c" = `New);
  Alcotest.(check bool) "which is forgotten" true (add 10. "a" = `Full);
  Alcotest.(check bool) "until the second expires" true (add 12. "a" = `New);
  Alcotest.(check int) "length" 2 (Replay.Cache.length cache);
  Alcotest.check_raises "a window"
    (Invalid_argument "Replay.Cache.create: window") (fun () ->
      ignore (Replay.Cache.create ~window:0. ~capacity:1));
  Alcotest.check_raises "a capacity"
    (Invalid_argument "Replay.Cache.create: capacity") (fun () ->
      ignore (Replay.Cache.create ~window:1. ~capacity:0))

let test_check () =
  let now = example in
  let at offset = Replay.Date.format (now +. offset) in
  let t = Replay.create ~tolerance:60. ~capacity:16 () in
  Alcotest.check result "fresh" (Ok ())
    (Replay.check t ~now ~enc:"a" (request ~date:(at 0.) ()));
  Alcotest.check result "replayed" (Error Replay.Replayed)
    (Replay.check t ~now ~enc:"a" (request ~date:(at 0.) ()));
  Alcotest.check result "at the edge of the tolerance" (Ok ())
    (Replay.check t ~now ~enc:"b" (request ~date:(at (-60.)) ()));
  Alcotest.check result "beyond it" (Error (Replay.Date_skewed (-61.)))
    (Replay.check t ~now ~enc:"c" (request ~date:(at (-61.)) ()));
  Alcotest.check result "ahead" (Error (Replay.Date_skewed 61.))
    (Replay.check t ~now ~enc:"c" (request ~date:(at 61.) ()));
  Alcotest.check result "with space around it" (Ok ())
    (Replay.check t ~now ~enc:"c" (request ~date:(" " ^ at 0. ^ "\t") ()));
  Alcotest.check result "no date" (Error Replay.Date_missing)
    (Replay.check t ~now ~enc:"d" (request ()));
  Alcotest.check result "an invalid date" (Error Replay.Date_missing)
    (Replay.check t ~now ~enc:"d" (request ~date:"yesterday" ()));
  Alcotest.check result "two dates" (Error Replay.Date_missing)
    (Replay.check t ~now ~enc:"d"
       {
         (request ~date:(at 0.) ()) with
         headers = [ ("date", at 0.); ("date", at 0.) ];
       });
  (* A request is acceptable while its date is within the tolerance, so its key
     is remembered for as long: from 60 seconds before its date to 60 after. *)
  let date = at 60. in
  Alcotest.check result "first seen as early as it can be" (Ok ())
    (Replay.check t ~now ~enc:"e" (request ~date ()));
  Alcotest.check result "and replayed as late as it can be"
    (Error Replay.Replayed)
    (Replay.check t ~now:(now +. 119.999) ~enc:"e" (request ~date ()));
  let lenient =
    Replay.create ~require_date:false ~tolerance:60. ~capacity:1 ()
  in
  Alcotest.check result "no date, when none is required" (Ok ())
    (Replay.check lenient ~now ~enc:"a" (request ()));
  Alcotest.check result "still remembered" (Error Replay.Replayed)
    (Replay.check lenient ~now ~enc:"a" (request ()));
  Alcotest.check result "a skewed date is not remembered"
    (Error (Replay.Date_skewed 3600.))
    (Replay.check lenient ~now ~enc:"b" (request ~date:(at 3600.) ()));
  Alcotest.check result "full" (Error Replay.Full)
    (Replay.check lenient ~now ~enc:"b" (request ()))

(* The client's clock is an hour behind. The gateway answers through the
   encapsulation with its own time, and the client retries with a corrected
   date and a new encapsulation. *)
let test_date_problem () =
  let rng = rng () in
  let key =
    ok
      (Gateway.Key.derive ~key_id:1 Hpke.Kem.X25519
         ~ikm:(String.make 32 '\x07'))
  in
  let gateway = ok (Gateway.create [ key ]) in
  let config = Gateway.Key.config key in
  let replay = Replay.create ~tolerance:30. ~capacity:16 () in
  let gateway_now = example and client_now = example -. 3600. in
  let send now =
    let request =
      Bhttp.Request.make ~meth:"GET" ~authority:"example.com" ~path:"/"
        ~headers:[ Replay.date_field ~now ]
        ()
    in
    let encapsulated, client_context =
      ok (Http_message.encapsulate_request ~rng config request)
    in
    let inner, gateway_context =
      ok (Http_message.decapsulate_request gateway encapsulated)
    in
    let response =
      match
        Replay.check replay ~now:gateway_now
          ~enc:(Gateway.encapsulated_key gateway_context)
          (Result.get_ok inner)
      with
      | Ok () -> Bhttp.Response.make ~status:200 ()
      | Error rejection -> Replay.rejection_response ~now:gateway_now rejection
    in
    ok
      (Http_message.decapsulate_response client_context
         (ok (Http_message.encapsulate_response ~rng gateway_context response)))
  in
  let first = send client_now in
  Alcotest.(check int) "refused" 400 first.status;
  let gateway_time = Option.get (Replay.date_of_problem first) in
  Alcotest.(check (float 0.)) "the gateway's time" gateway_now gateway_time;
  let offset = gateway_time -. client_now in
  Alcotest.(check int) "accepted" 200 (send (client_now +. offset)).status;
  (* Only a date problem carries a time to correct with. *)
  List.iter
    (fun (name, response) ->
      Alcotest.check date_option name None (Replay.date_of_problem response))
    [
      ("a replay", Replay.rejection_response ~now:gateway_now Replay.Replayed);
      ("a full cache", Replay.rejection_response ~now:gateway_now Replay.Full);
      ( "another problem",
        { first with content = {|{"type":"about:blank"}|} } );
      ("another status", { first with status = 403 });
      ( "no date",
        {
          first with
          headers = [ ("content-type", "application/problem+json") ];
        } );
    ]

let test_encapsulated_key () =
  let rng = rng () in
  let key =
    ok
      (Gateway.Key.derive ~key_id:1 Hpke.Kem.X25519
         ~ikm:(String.make 32 '\x08'))
  in
  let gateway = ok (Gateway.create [ key ]) in
  let encapsulated, _ =
    ok (Client.encapsulate ~rng (Gateway.Key.config key) "request")
  in
  let _, context = ok (Gateway.decapsulate gateway encapsulated) in
  check_bytes "the bytes after the header"
    (String.sub encapsulated Encapsulation.header_length 32)
    (Gateway.encapsulated_key context);
  let header, sender, _ =
    ok (Chunked.Client.request ~rng (Gateway.Key.config key))
  in
  let request = Chunked.Gateway.request gateway in
  Alcotest.(check (option string))
    "no chunked key before the header" None
    (Chunked.Gateway.encapsulated_key request);
  let sealed = ok (Chunked.seal_all sender "request") in
  ignore
    (ok (Chunked.open_all (Chunked.Gateway.receiver request) (header ^ sealed)));
  Alcotest.(check (option string))
    "the chunked key"
    (Some (String.sub header Encapsulation.header_length 32))
    (Chunked.Gateway.encapsulated_key request)

let tests =
  [
    Alcotest.test_case "date formats" `Quick test_date_formats;
    Alcotest.test_case "two-digit years" `Quick test_two_digit_years;
    Alcotest.test_case "invalid dates" `Quick test_invalid_dates;
    Alcotest.test_case "cache" `Quick test_cache;
    Alcotest.test_case "check" `Quick test_check;
    Alcotest.test_case "date problem" `Quick test_date_problem;
    Alcotest.test_case "encapsulated key" `Quick test_encapsulated_key;
  ]
