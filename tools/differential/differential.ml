(* Differential testing of bhttp and ohttp against other implementations.

   Each implementation runs as a peer process that speaks the line protocol of
   README.md. For every peer the driver plays both roles of every exchange,
   compares what comes back with what it sent or with its own verdict, prints a
   summary per category, and can record what the peer produced as a corpus for
   test/bhttp and test/ohttp to replay without the peer.

   differential.exe --peer NAME=PATH [--peer ...] [--require NAME] [--count N]
   [--seed N] [--only PREFIX] [--timeout SECONDS] [--output-dir DIR] [--source
   KEY=VALUE ...]

   Exit status: 0 if every peer agrees, 1 on an unexpected difference or an
   expectation that no longer holds, 2 on a usage error, 3 if no peer could be
   started or a required one is missing. *)

open Ohttp
module Json = Bhttp_test_support.Json_message

let hex = Bhttp.Hex.encode
let json_hex s = `String (hex s)

let get_hex name answer =
  match Peer.member name answer with
  | `String s -> (
      match Bhttp.Hex.decode s with Ok v -> Some v | Error _ -> None)
  | _ -> None

(* Outcomes *)

type outcome =
  | Agree
  | Skipped of string  (** The peer lacks what the case needs. *)
  | Differ of string

type row = { peer : string; category : string; outcome : outcome }

let rows : row list ref = ref []
let only = ref ""

let report (peer : Peer.t) category outcome =
  rows := { peer = peer.name; category; outcome } :: !rows

let selected category =
  let prefix = !only in
  String.length category >= String.length prefix
  && String.sub category 0 (String.length prefix) = prefix

(* Differences that are known, with the reason for each. A rule covers the
   differences of one peer in the categories that start with [category] whose
   description contains [contains].

   A rule that is [pinned] belongs to a category of fixed cases, where it must
   still apply: if the peer stops differing, the run fails, so the list cannot
   go stale. The others cover generated input, which may or may not hit them in
   a given run. *)
type rule = {
  peer : string;
  category : string;
  contains : string;
  pinned : bool;
  reason : string;
}

let rules =
  [
    {
      peer = "go";
      category = "bhttp/";
      contains = "rejected by the peer (EOF)";
      pinned = false;
      reason =
        "ohttp-go requires every length prefix, and so rejects the truncation \
         of RFC 9292 Section 3.8";
    };
    {
      peer = "go";
      category = "bhttp/rfc-truncation";
      contains = "Figure 8 less";
      pinned = true;
      reason =
        "ohttp-go rejects Figure 8 of RFC 9292 without its last two bytes, \
         which Section 5.1 says can each be removed";
    };
    {
      peer = "go";
      category = "bhttp/rfc-examples";
      contains = "both accept, but differently";
      pinned = true;
      reason =
        "ohttp-go reads a request into net/http types, which fill an empty \
         authority from the Host field; Figure 8 of RFC 9292 keeps the two \
         apart, \"as is required for ensuring that the request is reproduced \
         accurately\"";
    };
    {
      peer = "go";
      category = "bhttp/invalid";
      contains = "non-zero padding";
      pinned = true;
      reason =
        "ohttp-go ignores what follows a message, which RFC 9292 Section 3.8 \
         permits: \"a processor MAY decide not to validate the value of \
         padding bytes\"";
    };
    {
      peer = "go";
      category = "config/derive-draft";
      contains = "MLKEM768-X25519: the peer derives another key pair";
      pinned = true;
      reason =
        "CIRCL derives an X-Wing key pair from SHAKE256 of the seed, where \
         draft-ietf-hpke-pq-05 has DeriveKeyPair use LabeledDerive, with the \
         label and the suite identifier; the recorded keys follow CIRCL";
    };
    {
      peer = "rust";
      category = "chunked/peer-client";
      contains = "panic: range end index 32 out of range for slice of length 16";
      pinned = true;
      reason =
        "the ohttp crate keeps the nonce of a chunked response in 16 bytes, \
         but max(Nn, Nk) is 32 for ChaCha20Poly1305, so its client panics on \
         every chunked response under that AEAD (src/stream.rs, \
         ClientResponseState::Header)";
    };
    {
      peer = "rust";
      category = "bhttp/";
      contains = "rejected by the peer (a field was truncated), indeterminate";
      pinned = false;
      reason =
        "the bhttp crate reads a missing section as empty only in known-length \
         messages; RFC 9292 Section 3.2 allows the same for \
         indeterminate-length ones";
    };
    {
      peer = "rust";
      category = "bhttp/rfc-truncation";
      contains = "Figure 9 less 1";
      pinned = true;
      reason =
        "the bhttp crate rejects Figure 9 of RFC 9292 without its last 11 or \
         12 bytes, although Section 5.1 says that anything up to 12 bytes can \
         be removed";
    };
    {
      peer = "rust";
      category = "bhttp/";
      contains = "accepted by the peer";
      pinned = false;
      reason =
        "the bhttp crate does not check field names, field values, \
         pseudo-fields, or padding when it reads a message, which RFC 9292 \
         Sections 3.6 and 3.8 make invalid";
    };
    {
      peer = "rust";
      category = "bhttp/invalid";
      contains = "accepted by the peer";
      pinned = true;
      reason = "as above, on the fixed list of invalid messages";
    };
  ]

let applies rule ~peer ~category ~detail =
  let has_prefix prefix s =
    String.length s >= String.length prefix
    && String.sub s 0 (String.length prefix) = prefix
  in
  let contains sub s =
    let n = String.length sub in
    let rec go i =
      i + n <= String.length s && (String.sub s i n = sub || go (i + 1))
    in
    go 0
  in
  rule.peer = peer
  && has_prefix rule.category category
  && contains rule.contains detail

(* What an answer means for a case in which both sides should succeed. *)
let answer_or_skip (peer : Peer.t) category = function
  | Ok answer -> Some answer
  | Error { Peer.kind = Peer.Unsupported; message } ->
      report peer category (Skipped message);
      None
  | Error { Peer.kind = Peer.Rejected; message } ->
      report peer category (Differ ("the peer rejected it: " ^ message));
      None
  | Error { Peer.kind = Peer.Internal; message } ->
      report peer category (Differ ("the peer failed: " ^ message));
      None

let expect_bytes peer category ~what expected = function
  | Some actual when String.equal actual expected -> true
  | Some actual ->
      report peer category
        (Differ
           (Printf.sprintf "%s: expected %s, got %s" what (hex expected)
              (hex actual)));
      false
  | None ->
      report peer category (Differ (what ^ ": missing from the answer"));
      false

(* A case in which the peer should refuse. *)
let expect_rejection peer category = function
  | Error { Peer.kind = Peer.Rejected; _ } -> report peer category Agree
  | Error { Peer.kind = Peer.Unsupported; message } ->
      report peer category (Skipped message)
  | Error { Peer.kind = Peer.Internal; message } ->
      report peer category (Differ ("the peer failed: " ^ message))
  | Ok _ -> report peer category (Differ "the peer accepted it")

(* Keys and suites *)

let common ours theirs to_int =
  List.filter (fun id -> List.mem (to_int id) theirs) ours

let suites (peer : Peer.t) =
  let kems = common Suite.all_kems peer.kems Hpke.Kem.to_int in
  let symmetric =
    List.filter
      (fun (pair : Suite.symmetric) ->
        List.mem (Hpke.Kdf.to_int pair.kdf) peer.kdfs
        && List.mem (Hpke.Aead.to_int pair.aead) peer.aeads)
      Suite.all_symmetric
  in
  List.concat_map (fun kem -> List.map (fun pair -> (kem, pair)) symmetric) kems

type key = {
  key_id : int;
  kem : Hpke.Kem.id;
  symmetric : Suite.symmetric list;
  seed : string;
  key : Gateway.Key.t;
}

let ok = function Ok v -> v | Error e -> failwith (Error.to_string e)

(* The key that the peer derives from the seed, which for X-Wing is not the one
   of draft-ietf-hpke-pq: see test/ohttp/support/peer_key.ml, and the category
   config/derive-draft. *)
let make_key g kem symmetric =
  let key_id = Cases.int g 256 in
  let seed = Cases.bytes g (Hpke.Kem.private_key_size kem) in
  let key =
    match Ohttp_test_support.Peer_key.derive_key_pair kem ~ikm:seed with
    | Ok (private_key, _) ->
        Gateway.Key.of_private_key ~key_id ~symmetric private_key
    | Error e -> Error (Error.Hpke e)
  in
  match key with
  | Ok key -> Some { key_id; kem; symmetric; seed; key }
  (* Rejection sampling for a NIST curve can fail for one seed in 2^32. *)
  | Error _ -> None

let key_fields k =
  [
    ("key_id", `Int k.key_id);
    ("kem", `Int (Hpke.Kem.to_int k.kem));
    ( "symmetric",
      `List
        (List.map
           (fun pair ->
             let kdf, aead = Suite.symmetric_to_ints pair in
             `List [ `Int kdf; `Int aead ])
           k.symmetric) );
    ("seed", json_hex k.seed);
  ]

let encoded_config k = Key_config.encode (Gateway.Key.config k.key)
let payload g = Cases.bytes g (Cases.pick g [ 0; 1; 32; 200; 4000 ])

let flip g s =
  let b = Bytes.of_string s in
  let i = Cases.int g (Bytes.length b) in
  Bytes.set_uint8 b i (Bytes.get_uint8 b i lxor (1 lsl Cases.int g 8));
  Bytes.unsafe_to_string b

(* Corpus *)

let configs_corpus : (string * Yojson.Safe.t) list ref = ref []
let exchanges_corpus : (string * Yojson.Safe.t) list ref = ref []
let messages_corpus : (string * Yojson.Safe.t) list ref = ref []

(* A replay proves as much with two short exchanges for each suite as with
   hundreds of long ones, and the corpus is checked in. *)
let small parts = List.for_all (fun s -> String.length s <= 256) parts
let recorded : (string, int) Hashtbl.t = Hashtbl.create 64

let room ~limit key =
  let n = Option.value ~default:0 (Hashtbl.find_opt recorded key) in
  if n < limit then begin
    Hashtbl.replace recorded key (n + 1);
    true
  end
  else false

let record_exchange (peer : Peer.t) ~category k ~request ~response ~enc_request
    ~enc_response ~request_by ~response_by =
  let suite =
    String.concat "/"
      (string_of_int (Hpke.Kem.to_int k.kem)
      :: List.map
           (fun pair ->
             let kdf, aead = Suite.symmetric_to_ints pair in
             Printf.sprintf "%d-%d" kdf aead)
           k.symmetric)
  in
  if
    small [ request; response ]
    && room ~limit:2 (String.concat " " [ peer.name; category; suite ])
  then
    exchanges_corpus :=
      ( peer.name,
        `Assoc
          ([ ("category", `String category) ]
          @ key_fields k
          @ [
              ("request", json_hex request);
              ("response", json_hex response);
              ("enc_request", json_hex enc_request);
              ("enc_response", json_hex enc_response);
              ("request_by", `String request_by);
              ("response_by", `String response_by);
            ]) )
      :: !exchanges_corpus

(* Categories *)

let config_cases g count (peer : Peer.t) =
  let category = "config/derive" in
  if selected category then
    List.iter
      (fun (kem, pair) ->
        for _ = 1 to max 1 (count / 4) do
          match make_key g kem [ pair ] with
          | None -> ()
          | Some k -> (
              match
                answer_or_skip peer category
                  (Peer.ask peer "config_derive" (key_fields k))
              with
              | None -> ()
              | Some answer ->
                  let ours = encoded_config k in
                  if
                    expect_bytes peer category ~what:"key configuration" ours
                      (get_hex "config" answer)
                  then begin
                    report peer category Agree;
                    let kdf, aead = Suite.symmetric_to_ints pair in
                    if
                      room ~limit:1
                        (Printf.sprintf "%s config %d %d %d" peer.name
                           (Hpke.Kem.to_int kem) kdf aead)
                    then
                      configs_corpus :=
                        ( peer.name,
                          `Assoc (key_fields k @ [ ("config", json_hex ours) ])
                        )
                        :: !configs_corpus
                  end)
        done)
      (suites peer);
  (* The same, against the derivation of RFC 9180 and draft-ietf-hpke-pq, once
     for each KEM. *)
  let category = "config/derive-draft" in
  if selected category then
    List.iter
      (fun kem ->
        let pair = List.assoc kem (suites peer) in
        match make_key g kem [ pair ] with
        | None -> ()
        | Some k -> (
            match
              answer_or_skip peer category
                (Peer.ask peer "config_derive" (key_fields k))
            with
            | None -> ()
            | Some answer -> (
                match
                  Gateway.Key.derive ~key_id:k.key_id ~symmetric:[ pair ] kem
                    ~ikm:k.seed
                with
                | Error _ -> ()
                | Ok key ->
                    let ours = Key_config.encode (Gateway.Key.config key) in
                    if get_hex "config" answer = Some ours then
                      report peer category Agree
                    else
                      report peer category
                        (Differ
                           (Format.asprintf
                              "%a: the peer derives another key pair"
                              Hpke.Kem.pp kem)))))
      (List.sort_uniq compare (List.map fst (suites peer)));
  let category = "config/parse" in
  if selected category then
    List.iter
      (fun (kem, pair) ->
        match make_key g kem [ pair ] with
        | None -> ()
        | Some k -> (
            let ours = encoded_config k in
            match
              answer_or_skip peer category
                (Peer.ask peer "config_parse" [ ("config", json_hex ours) ])
            with
            | None -> ()
            | Some answer ->
                if Peer.member "configs" answer = `List [ json_hex ours ] then
                  report peer category Agree
                else
                  report peer category
                    (Differ "the peer re-encodes the configuration differently")
            ))
      (suites peer);
  (* A key that offers several pairs, served as application/ohttp-keys. *)
  let category = "config/list" in
  (if selected category then
     if not (Peer.has peer "config-list" && Peer.has peer "multi-suite-config")
     then
       report peer category
         (Skipped "no list form or no multi-suite configurations")
     else
       let kems = List.sort_uniq compare (List.map fst (suites peer)) in
       let pairs = List.sort_uniq compare (List.map snd (suites peer)) in
       let keys = List.filter_map (fun kem -> make_key g kem pairs) kems in
       let ours =
         Key_config.encode_list
           (List.map (fun k -> Gateway.Key.config k.key) keys)
       in
       match
         answer_or_skip peer category
           (Peer.ask peer "config_parse" [ ("config_list", json_hex ours) ])
       with
       | None -> ()
       | Some answer ->
           if
             Peer.member "configs" answer
             = `List (List.map (fun k -> json_hex (encoded_config k)) keys)
           then report peer category Agree
           else
             report peer category (Differ "the peer reads the list differently"));
  let category = "config/parse-invalid" in
  if selected category then
    match suites peer with
    | [] -> ()
    | (kem, pair) :: _ -> (
        match make_key g kem [ pair ] with
        | None -> ()
        | Some k ->
            let ours = encoded_config k in
            List.iter
              (fun invalid ->
                expect_rejection peer category
                  (Peer.ask peer "config_parse"
                     [ ("config", json_hex invalid) ]))
              [
                String.sub ours 0 (String.length ours - 1);
                String.sub ours 0 3;
                "";
              ])

let exchange_cases g count (peer : Peer.t) =
  List.iter
    (fun (kem, pair) ->
      match make_key g kem [ pair ] with
      | None -> ()
      | Some k ->
          let config = Gateway.Key.config k.key in
          let gateway = ok (Gateway.create [ k.key ]) in
          for _ = 1 to count do
            let request = payload g and response = payload g in
            (* This library as the client, the peer as the gateway. *)
            let category = "ohttp/ocaml-client" in
            (if selected category then
               let enc_request, context =
                 ok (Client.encapsulate ~rng:g config request)
               in
               match
                 answer_or_skip peer category
                   (Peer.ask peer "gateway_decapsulate"
                      (key_fields k @ [ ("enc_request", json_hex enc_request) ]))
               with
               | None -> ()
               | Some answer -> (
                   if
                     expect_bytes peer category ~what:"request" request
                       (get_hex "request" answer)
                   then
                     match
                       answer_or_skip peer category
                         (Peer.ask peer "gateway_encapsulate"
                            [
                              ("handle", Peer.member "handle" answer);
                              ("response", json_hex response);
                            ])
                     with
                     | None -> ()
                     | Some answer -> (
                         match get_hex "enc_response" answer with
                         | None ->
                             report peer category (Differ "no enc_response")
                         | Some enc_response -> (
                             match Client.decapsulate context enc_response with
                             | Ok opened when String.equal opened response ->
                                 report peer category Agree;
                                 record_exchange peer ~category k ~request
                                   ~response ~enc_request ~enc_response
                                   ~request_by:"ocaml" ~response_by:"peer"
                             | Ok _ ->
                                 report peer category
                                   (Differ "the response opened to other bytes")
                             | Error e ->
                                 report peer category
                                   (Differ
                                      ("the peer's response does not open: "
                                     ^ Error.to_string e))))));
            (* The peer as the client, this library as the gateway. *)
            let category = "ohttp/peer-client" in
            if selected category then
              match
                answer_or_skip peer category
                  (Peer.ask peer "client_encapsulate"
                     [
                       ("config", json_hex (Key_config.encode config));
                       ("request", json_hex request);
                     ])
              with
              | None -> ()
              | Some answer -> (
                  match get_hex "enc_request" answer with
                  | None -> report peer category (Differ "no enc_request")
                  | Some enc_request -> (
                      match Gateway.decapsulate gateway enc_request with
                      | Error e ->
                          report peer category
                            (Differ
                               ("the peer's request does not open: "
                              ^ Error.to_string e))
                      | Ok (opened, _) when not (String.equal opened request) ->
                          report peer category
                            (Differ "the request opened to other bytes")
                      | Ok (_, context) -> (
                          let enc_response =
                            ok (Gateway.encapsulate ~rng:g context response)
                          in
                          match
                            answer_or_skip peer category
                              (Peer.ask peer "client_decapsulate"
                                 [
                                   ("handle", Peer.member "handle" answer);
                                   ("enc_response", json_hex enc_response);
                                 ])
                          with
                          | None -> ()
                          | Some answer ->
                              if
                                expect_bytes peer category ~what:"response"
                                  response
                                  (get_hex "response" answer)
                              then begin
                                report peer category Agree;
                                record_exchange peer ~category k ~request
                                  ~response ~enc_request ~enc_response
                                  ~request_by:"peer" ~response_by:"ocaml"
                              end)))
          done)
    (suites peer)

(* Whatever this library refuses, the peer must refuse too. *)
let tampering_cases g count (peer : Peer.t) =
  match suites peer with
  | [] -> ()
  | (kem, pair) :: _ -> (
      match make_key g kem [ pair ] with
      | None -> ()
      | Some k ->
          let config = Gateway.Key.config k.key in
          for _ = 1 to count do
            let request = payload g and response = payload g in
            let enc_request, context =
              ok (Client.encapsulate ~rng:g config request)
            in
            let category = "ohttp/tampered-request" in
            (if selected category then
               let tampered =
                 String.sub enc_request 0 7
                 ^ flip g
                     (String.sub enc_request 7 (String.length enc_request - 7))
               in
               expect_rejection peer category
                 (Peer.ask peer "gateway_decapsulate"
                    (key_fields k @ [ ("enc_request", json_hex tampered) ])));
            let category = "ohttp/unknown-key-id" in
            if selected category then (
              let other = Bytes.of_string enc_request in
              Bytes.set_uint8 other 0 ((k.key_id + 1) land 0xff);
              expect_rejection peer category
                (Peer.ask peer "gateway_decapsulate"
                   (key_fields k
                   @ [
                       ("enc_request", json_hex (Bytes.unsafe_to_string other));
                     ])));
            let category = "ohttp/tampered-response" in
            if selected category then begin
              (* A response from the peer, changed on its way back. *)
              (match
                 Peer.ask peer "gateway_decapsulate"
                   (key_fields k @ [ ("enc_request", json_hex enc_request) ])
               with
              | Ok answer -> (
                  match
                    Peer.ask peer "gateway_encapsulate"
                      [
                        ("handle", Peer.member "handle" answer);
                        ("response", json_hex response);
                      ]
                  with
                  | Ok answer -> (
                      match get_hex "enc_response" answer with
                      | Some enc_response ->
                          if
                            Result.is_error
                              (Client.decapsulate context (flip g enc_response))
                          then report peer category Agree
                          else
                            report peer category
                              (Differ "a changed response was accepted here")
                      | None -> ())
                  | Error _ -> ())
              | Error _ -> ());
              (* A response from here, changed on its way to the peer. *)
              match
                Peer.ask peer "client_encapsulate"
                  [
                    ("config", json_hex (Key_config.encode config));
                    ("request", json_hex request);
                  ]
              with
              | Error _ -> ()
              | Ok answer -> (
                  match get_hex "enc_request" answer with
                  | None -> ()
                  | Some enc_request -> (
                      match
                        Gateway.decapsulate
                          (ok (Gateway.create [ k.key ]))
                          enc_request
                      with
                      | Error _ -> ()
                      | Ok (_, context) ->
                          let enc_response =
                            ok (Gateway.encapsulate ~rng:g context response)
                          in
                          expect_rejection peer category
                            (Peer.ask peer "client_decapsulate"
                               [
                                 ("handle", Peer.member "handle" answer);
                                 ("enc_response", json_hex (flip g enc_response));
                               ])))
            end
          done)

(* Binary HTTP *)

(* Field names are compared without their case, which a peer may keep where
   [Bhttp] lowercases them. A peer that keeps fields in a map returns them in
   its own order. *)
let normalize (peer : Peer.t) message =
  let fields =
    if Peer.has peer "bhttp-field-order" then Bhttp.Field.lowercase
    else fun fields -> List.sort compare (Bhttp.Field.lowercase fields)
  in
  match message with
  | Bhttp.Message.Request r ->
      Bhttp.Message.Request
        { r with headers = fields r.headers; trailers = fields r.trailers }
  | Bhttp.Message.Response r ->
      let informational (i : Bhttp.Response.informational) =
        { i with headers = fields i.headers }
      in
      Bhttp.Message.Response
        {
          r with
          informational = List.map informational r.informational;
          headers = fields r.headers;
          trailers = fields r.trailers;
        }

let record_message (peer : Peer.t) ~category ~encoded_by encoded message =
  if
    small [ encoded ]
    && room ~limit:24 (String.concat " " [ peer.name; category ])
  then
    messages_corpus :=
      ( peer.name,
        `Assoc
          [
            ("category", `String category);
            ("encoded_by", `String encoded_by);
            ("message", json_hex encoded);
            ("decoded", Json.to_json message);
          ] )
      :: !messages_corpus

let peer_decodes (peer : Peer.t) category encoded expected =
  match
    answer_or_skip peer category
      (Peer.ask peer "bhttp_decode" [ ("message", json_hex encoded) ])
  with
  | None -> false
  | Some answer -> (
      match Json.of_json (Peer.member "decoded" answer) with
      | Error msg ->
          report peer category (Differ ("unreadable answer: " ^ msg));
          false
      | Ok decoded ->
          if
            Bhttp.Message.equal (normalize peer decoded)
              (normalize peer expected)
          then true
          else begin
            report peer category
              (Differ
                 (Format.asprintf "the peer decoded@ %a@ and not@ %a"
                    Bhttp.Message.pp decoded Bhttp.Message.pp expected));
            false
          end)

let label name = if name = "" then "" else name ^ ": "

let framing_name input =
  match Bhttp.Framing.peek input with
  | Ok (_, Bhttp.Framing.Indeterminate_length) -> "indeterminate-length"
  | Ok (_, Bhttp.Framing.Known_length) -> "known-length"
  | Error _ -> "unknown framing"

(* Accept or reject: whatever one side takes for a message, the other should
   too, and they should take it for the same message. Only a peer that reads
   every form of the format is a fair judge. *)
let judge ?(name = "") (peer : Peer.t) category input =
  if selected category then
    let ours = Bhttp.Message.decode input in
    match Peer.ask peer "bhttp_decode" [ ("message", json_hex input) ] with
    | Error { Peer.kind = Peer.Unsupported; message } ->
        report peer category (Skipped message)
    | Error { Peer.kind = Peer.Internal; message } ->
        report peer category (Differ ("the peer failed: " ^ message))
    | Error { Peer.kind = Peer.Rejected; message } -> (
        match ours with
        | Error _ -> report peer category Agree
        | Ok _ ->
            report peer category
              (Differ
                 (Printf.sprintf
                    "%saccepted here, rejected by the peer (%s), %s: %s"
                    (label name) message (framing_name input) (hex input))))
    | Ok answer -> (
        match (ours, Json.of_json (Peer.member "decoded" answer)) with
        | Ok mine, Ok theirs
          when Bhttp.Message.equal (normalize peer mine) (normalize peer theirs)
          ->
            report peer category Agree
        | Ok _, Ok _ ->
            report peer category
              (Differ (label name ^ "both accept, but differently: " ^ hex input))
        | Error e, Ok _ ->
            report peer category
              (Differ
                 (Printf.sprintf
                    "%srejected here (%s), accepted by the peer: %s"
                    (label name) (Bhttp.Error.to_string e) (hex input)))
        | _, Error msg ->
            report peer category (Differ ("unreadable answer: " ^ msg)))

let bhttp_cases g count (peer : Peer.t) =
  let shape = if Peer.has peer "bhttp-rich" then Cases.Rich else Cases.Plain in
  let framings =
    Bhttp.Framing.Known_length
    ::
    (if Peer.has peer "bhttp-indeterminate" then
       [ Bhttp.Framing.Indeterminate_length ]
     else [])
  in
  for _ = 1 to count do
    let message = Cases.message g shape in
    List.iter
      (fun framing ->
        let category = "bhttp/ocaml-encode" in
        (if selected category then
           match Bhttp.Message.encode ~framing message with
           | Error e -> failwith (Bhttp.Error.to_string e)
           | Ok encoded ->
               if peer_decodes peer category encoded message then
                 report peer category Agree);
        let category = "bhttp/padded" in
        (if selected category then
           let encoded =
             Result.get_ok
               (Bhttp.Message.encode ~framing
                  ~padding:(1 + Cases.int g 40)
                  message)
           in
           if peer_decodes peer category encoded message then
             report peer category Agree);
        (let encoded =
           Result.get_ok (Bhttp.Message.encode ~framing ~truncate:true message)
         in
         let full = Result.get_ok (Bhttp.Message.encode ~framing message) in
         (* Only a message with something to omit is a test of truncation. *)
         if String.length encoded < String.length full then
           judge peer "bhttp/truncated" encoded);
        let category = "bhttp/peer-encode" in
        if selected category then
          match
            answer_or_skip peer category
              (Peer.ask peer "bhttp_encode"
                 [
                   ("decoded", Json.to_json message);
                   ( "framing",
                     `String
                       (match framing with
                       | Bhttp.Framing.Known_length -> "known"
                       | Bhttp.Framing.Indeterminate_length -> "indeterminate")
                   );
                 ])
          with
          | None -> ()
          | Some answer -> (
              match get_hex "message" answer with
              | None -> report peer category (Differ "no message")
              | Some encoded -> (
                  match Bhttp.Message.decode encoded with
                  | Error e ->
                      report peer category
                        (Differ
                           ("the peer's message does not decode: "
                          ^ Bhttp.Error.to_string e))
                  | Ok decoded ->
                      if
                        Bhttp.Message.equal (normalize peer decoded)
                          (normalize peer message)
                      then begin
                        report peer category Agree;
                        record_message peer ~category ~encoded_by:"peer" encoded
                          decoded
                      end
                      else
                        report peer category
                          (Differ
                             (Format.asprintf
                                "the peer's message decoded to@ %a@ and not@ %a"
                                Bhttp.Message.pp decoded Bhttp.Message.pp
                                message)))))
      framings
  done

let verdict_cases g count (peer : Peer.t) =
  if Peer.has peer "bhttp-rich" && Peer.has peer "bhttp-indeterminate" then
    for _ = 1 to count do
      let message = Cases.message g Cases.Rich in
      let framing =
        if Cases.bool g then Bhttp.Framing.Known_length
        else Bhttp.Framing.Indeterminate_length
      in
      let encoded = Result.get_ok (Bhttp.Message.encode ~framing message) in
      (* Every prefix of a short message, and a few of a long one. *)
      let n = String.length encoded in
      let lengths =
        if n <= 64 then List.init n Fun.id
        else List.init 24 (fun _ -> Cases.int g n)
      in
      List.iter
        (fun length -> judge peer "bhttp/prefix" (String.sub encoded 0 length))
        lengths;
      for _ = 1 to 8 do
        judge peer "bhttp/mutation" (flip g encoded)
      done
    done

(* The examples of RFC 9292 Section 5, whole and with as many bytes removed as
   the RFC says can be, and one more. These are fixed cases, so the rules that
   cover them are pinned. *)
let rfc_cases ~vectors (peer : Peer.t) =
  let figure n =
    List.find_map
      (fun v ->
        if Peer.member "figure" v = `Int n then
          Option.map Bhttp.Hex.decode_exn
            (Peer.to_string (Peer.member "message" v))
        else None)
      vectors
  in
  let less name message removed =
    judge peer "bhttp/rfc-truncation"
      ~name:(Printf.sprintf "%s less %d" name removed)
      (String.sub message 0 (String.length message - removed))
  in
  List.iter
    (fun n -> Option.iter (judge peer "bhttp/rfc-examples") (figure n))
    [ 8; 9; 11; 13 ];
  Option.iter (fun m -> List.iter (less "Figure 8" m) [ 1; 2; 3 ]) (figure 8);
  if Peer.has peer "bhttp-indeterminate" then
    Option.iter
      (fun m -> List.iter (less "Figure 9" m) [ 10; 11; 12; 13 ])
      (figure 9)

(* Messages that RFC 9292 makes invalid, one reason each. *)
let invalid_cases (peer : Peer.t) =
  let open Bhttp_test_support.Build in
  let request lines = concat [ v 0; control (); known lines ] in
  List.iter
    (fun (name, message) -> judge peer "bhttp/invalid" ~name message)
    ([
       ("framing indicator 4", v 4);
       ("status code 99", concat [ v 1; v 99 ]);
       ("status code 600", concat [ v 1; v 600 ]);
       ("no final status code", concat [ v 1; v 100; known [] ]);
       ( "a section longer than the message",
         concat [ v 0; control (); v 9; line "a" "1" ] );
       ( "non-zero padding",
         concat [ v 0; control (); known []; str ""; known []; "\001" ] );
       ("an empty field name", request [ line "" "1" ]);
       ("a space in a field name", request [ line "a b" "1" ]);
       ("a non-ASCII field name", request [ line "caf\xc3\xa9" "1" ]);
       ("a line break in a field value", request [ line "a" "1\r\nb: 2" ]);
       ("a NUL in a field value", request [ line "a" "\000" ]);
       ("a field value that starts with a space", request [ line "a" " 1" ]);
       ("the :path pseudo-field", request [ line ":path" "/" ]);
       ( "the :status pseudo-field",
         concat [ v 1; v 200; known [ line ":status" "200" ] ] );
       ( "a pseudo-field after a regular field",
         request [ line "a" "1"; line ":protocol" "x" ] );
       ( "a pseudo-field in the trailers",
         concat
           [ v 0; control (); known []; str ""; known [ line ":protocol" "x" ] ]
       );
     ]
    @
    if Peer.has peer "bhttp-indeterminate" then
      [
        ( "header lines without a terminator",
          concat [ v 2; control (); line "a" "1" ] );
        ( "chunks without a terminator",
          concat [ v 2; control (); indeterminate []; str "x" ] );
      ]
    else [])

(* Chunked OHTTP. A peer writes one chunk for each piece it is given, and an
   empty final chunk; what it reads comes back in one piece. *)
let chunked_cases g count (peer : Peer.t) =
  if Peer.has peer "chunked" then
    List.iter
      (fun (kem, pair) ->
        match make_key g kem [ pair ] with
        | None -> ()
        | Some k ->
            let config = Gateway.Key.config k.key in
            let gateway = ok (Gateway.create [ k.key ]) in
            for _ = 1 to max 1 (count / 2) do
              let pieces () =
                List.init
                  (1 + Cases.int g 4)
                  (fun _ -> Cases.bytes g (1 + Cases.int g 60))
              in
              let request = pieces () and response = pieces () in
              let chunks_json l = `List (List.map json_hex l) in
              (* In this order: the operands of [^] are evaluated right to
                 left. *)
              let seal sender l =
                let chunks =
                  List.map (fun c -> ok (Chunked.Sender.chunk sender c)) l
                in
                let final = ok (Chunked.Sender.final sender "") in
                String.concat "" chunks ^ final
              in
              let category = "chunked/ocaml-client" in
              (if selected category then
                 let header, sender, context =
                   ok (Chunked.Client.request ~rng:g config)
                 in
                 let enc_request = header ^ seal sender request in
                 match
                   answer_or_skip peer category
                     (Peer.ask peer "chunked_gateway_decapsulate"
                        (key_fields k
                        @ [ ("enc_request", json_hex enc_request) ]))
                 with
                 | None -> ()
                 | Some answer -> (
                     if
                       expect_bytes peer category ~what:"request"
                         (String.concat "" request) (get_hex "request" answer)
                     then
                       match
                         answer_or_skip peer category
                           (Peer.ask peer "chunked_gateway_encapsulate"
                              [
                                ("handle", Peer.member "handle" answer);
                                ("chunks", chunks_json response);
                              ])
                       with
                       | None -> ()
                       | Some answer -> (
                           match get_hex "enc_response" answer with
                           | None ->
                               report peer category (Differ "no enc_response")
                           | Some enc_response -> (
                               match
                                 Chunked.open_all
                                   (Chunked.Client.response context)
                                   enc_response
                               with
                               | Ok opened
                                 when String.equal opened
                                        (String.concat "" response) ->
                                   report peer category Agree;
                                   record_exchange peer ~category k
                                     ~request:(String.concat "" request)
                                     ~response:(String.concat "" response)
                                     ~enc_request ~enc_response
                                     ~request_by:"ocaml" ~response_by:"peer"
                               | Ok _ ->
                                   report peer category
                                     (Differ
                                        "the response opened to other bytes")
                               | Error e ->
                                   report peer category
                                     (Differ
                                        ("the peer's response does not open: "
                                       ^ Error.to_string e))))));
              let category = "chunked/peer-client" in
              if selected category then
                match
                  answer_or_skip peer category
                    (Peer.ask peer "chunked_client_encapsulate"
                       [
                         ("config", json_hex (Key_config.encode config));
                         ("chunks", chunks_json request);
                       ])
                with
                | None -> ()
                | Some answer ->
                    (match get_hex "enc_request" answer with
                    | None -> report peer category (Differ "no enc_request")
                    | Some enc_request -> (
                        let incoming = Chunked.Gateway.request gateway in
                        match
                          Chunked.open_all
                            (Chunked.Gateway.receiver incoming)
                            enc_request
                        with
                        | Error e ->
                            report peer category
                              (Differ
                                 ("the peer's request does not open: "
                                ^ Error.to_string e))
                        | Ok opened
                          when not
                                 (String.equal opened (String.concat "" request))
                          ->
                            report peer category
                              (Differ "the request opened to other bytes")
                        | Ok _ -> (
                            let nonce, sender =
                              ok (Chunked.Gateway.response ~rng:g incoming)
                            in
                            let enc_response = nonce ^ seal sender response in
                            match
                              answer_or_skip peer category
                                (Peer.ask peer "chunked_client_decapsulate"
                                   [
                                     ("handle", Peer.member "handle" answer);
                                     ("enc_response", json_hex enc_response);
                                   ])
                            with
                            | None -> ()
                            | Some answer ->
                                if
                                  expect_bytes peer category ~what:"response"
                                    (String.concat "" response)
                                    (get_hex "response" answer)
                                then begin
                                  report peer category Agree;
                                  record_exchange peer ~category k
                                    ~request:(String.concat "" request)
                                    ~response:(String.concat "" response)
                                    ~enc_request ~enc_response
                                    ~request_by:"peer" ~response_by:"ocaml"
                                end)));
                    (* A chunked stream that loses its end must not pass. *)
                    let category = "chunked/truncated" in
                    if selected category then begin
                      let header, sender, _ =
                        ok (Chunked.Client.request ~rng:g config)
                      in
                      let enc_request = header ^ seal sender request in
                      let cut =
                        String.sub enc_request 0 (String.length enc_request - 17)
                      in
                      expect_rejection peer category
                        (Peer.ask peer "chunked_gateway_decapsulate"
                           (key_fields k @ [ ("enc_request", json_hex cut) ]))
                    end
            done)
      (suites peer)

(* Driver *)

let write_corpus ~dir ~seed ~count ~sources (peer : Peer.t) =
  let mine corpus =
    List.rev
      (List.filter_map
         (fun (p, j) -> if p = peer.name then Some j else None)
         !corpus)
  in
  let source =
    `Assoc
      ([
         ("peer", `String peer.name);
         ("version", `String peer.version);
         ("seed", `Int seed);
         ("count", `Int count);
         ("ocaml", `String Sys.ocaml_version);
       ]
      @ sources)
  in
  let write name members =
    let path =
      Filename.concat dir (Printf.sprintf "%s-%s.json" name peer.name)
    in
    let oc = open_out path in
    output_string oc
      (Yojson.Safe.pretty_to_string (`Assoc (("source", source) :: members)));
    output_char oc '\n';
    close_out oc;
    Printf.printf "wrote %s\n" path
  in
  write "ohttp"
    [
      ("configs", `List (mine configs_corpus));
      ("exchanges", `List (mine exchanges_corpus));
    ];
  write "bhttp" [ ("messages", `List (mine messages_corpus)) ]

let () =
  let specs = ref []
  and required = ref []
  and count = ref 8
  and seed = ref 9458 in
  let timeout = ref 60.0 and output_dir = ref None and sources = ref [] in
  let vectors = ref [] in
  Arg.parse
    [
      ( "--peer",
        Arg.String (fun s -> specs := s :: !specs),
        "NAME=PATH a peer executable" );
      ( "--require",
        Arg.String (fun s -> required := s :: !required),
        "NAME fail unless this peer runs" );
      ( "--count",
        Arg.Set_int count,
        "N random cases per category and suite (default 8)" );
      ("--seed", Arg.Set_int seed, "N seed of the case generator (default 9458)");
      ( "--only",
        Arg.Set_string only,
        "PREFIX run only the categories that start with it" );
      ( "--timeout",
        Arg.Set_float timeout,
        "SECONDS to wait for an answer (default 60)" );
      ( "--output-dir",
        Arg.String (fun s -> output_dir := Some s),
        "DIR record a corpus per peer" );
      ( "--rfc9292",
        Arg.String
          (fun path ->
            match Peer.member "vectors" (Yojson.Safe.from_file path) with
            | `List l -> vectors := l
            | _ -> raise (Arg.Bad (path ^ ": no vectors"))),
        "FILE test/vectors/rfc9292.json, for the cases drawn from the RFC" );
      ( "--source",
        Arg.String
          (fun s ->
            match String.index_opt s '=' with
            | Some i ->
                sources :=
                  ( String.sub s 0 i,
                    `String (String.sub s (i + 1) (String.length s - i - 1)) )
                  :: !sources
            | None -> raise (Arg.Bad ("--source expects KEY=VALUE, got " ^ s))),
        "KEY=VALUE provenance recorded in the corpus" );
    ]
    (fun arg -> raise (Arg.Bad ("unexpected argument " ^ arg)))
    "differential.exe --peer NAME=PATH [...]";
  let peers =
    List.filter_map
      (fun spec ->
        match Peer.spawn ~timeout:!timeout spec with
        | Ok peer ->
            Printf.printf "peer %s %s\n%!" peer.name peer.version;
            Some peer
        | Error msg ->
            Printf.printf "SKIP %s\n%!" msg;
            None)
      (List.rev !specs)
  in
  let missing =
    List.filter
      (fun name -> not (List.exists (fun (p : Peer.t) -> p.name = name) peers))
      !required
  in
  if peers = [] || missing <> [] then begin
    List.iter (Printf.eprintf "required peer %s is not running\n") missing;
    if peers = [] then prerr_endline "no peer is running";
    exit 3
  end;
  List.iter
    (fun peer ->
      (* The same cases for every peer, whatever ran before it. *)
      let g = Cases.create !seed in
      config_cases g !count peer;
      exchange_cases g !count peer;
      tampering_cases g !count peer;
      bhttp_cases g (4 * !count) peer;
      verdict_cases g !count peer;
      rfc_cases ~vectors:!vectors peer;
      invalid_cases peer;
      chunked_cases g !count peer)
    peers;
  let rows = List.rev !rows in
  let categories =
    List.sort_uniq compare (List.map (fun (r : row) -> r.category) rows)
  in
  Printf.printf "\n%-28s" "category";
  List.iter (fun (p : Peer.t) -> Printf.printf " %18s" p.name) peers;
  print_newline ();
  List.iter
    (fun category ->
      Printf.printf "%-28s" category;
      List.iter
        (fun (p : Peer.t) ->
          let mine =
            List.filter
              (fun (r : row) -> r.peer = p.name && r.category = category)
              rows
          in
          let n f = List.length (List.filter f mine) in
          let agree = n (fun (r : row) -> r.outcome = Agree)
          and skipped =
            n (fun (r : row) ->
                match r.outcome with Skipped _ -> true | _ -> false)
          in
          let known =
            n (fun (r : row) ->
                match r.outcome with
                | Differ detail ->
                    List.exists
                      (fun rule ->
                        applies rule ~peer:r.peer ~category:r.category ~detail)
                      rules
                | Agree | Skipped _ -> false)
          in
          let differ = List.length mine - agree - skipped in
          Printf.printf " %18s"
            (if mine = [] then "-"
             else if skipped = List.length mine then "unsupported"
             else
               Printf.sprintf "%d/%d%s" agree (agree + differ)
                 (if differ > known then " !"
                  else if known > 0 then " *"
                  else "")))
        peers;
      print_newline ())
    categories;
  (* Differences, told apart from the ones that are known. *)
  let failed = ref false in
  let applied = Hashtbl.create 8 in
  List.iter
    (fun (r : row) ->
      match r.outcome with
      | Differ detail -> (
          match
            List.find_opt
              (fun rule ->
                applies rule ~peer:r.peer ~category:r.category ~detail)
              rules
          with
          | Some rule ->
              List.iter
                (fun rule ->
                  if applies rule ~peer:r.peer ~category:r.category ~detail then
                    Hashtbl.replace applied rule
                      (1
                      + Option.value ~default:0 (Hashtbl.find_opt applied rule)
                      ))
                rules;
              ignore rule
          | None ->
              failed := true;
              Printf.printf "\nUNEXPECTED %s %s\n  %s\n" r.peer r.category
                detail)
      | Agree | Skipped _ -> ())
    rows;
  List.iter
    (fun rule ->
      if List.exists (fun (p : Peer.t) -> p.name = rule.peer) peers then
        match Hashtbl.find_opt applied rule with
        | Some n ->
            Printf.printf "\nexpected, %d times: %s %s*\n  %s\n" n rule.peer
              rule.category rule.reason
        | None when rule.pinned && selected rule.category ->
            failed := true;
            Printf.printf "\nSTALE: %s no longer differs in %s\n  %s\n"
              rule.peer rule.category rule.reason
        | None -> ())
    rules;
  (match !output_dir with
  | None -> ()
  | Some dir ->
      List.iter
        (write_corpus ~dir ~seed:!seed ~count:!count
           ~sources:(List.rev !sources))
        peers);
  List.iter Peer.close peers;
  if !failed then exit 1
