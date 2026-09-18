(* Messages that other implementations encoded, recorded by tools/differential
   and replayed here without them: each must decode to the message that was
   asked for. See test/vectors/PROVENANCE.md. *)

open Yojson.Safe.Util

(* An implementation that keeps fields in a map returns them in its own order,
   which the recording says nothing about. *)
let sorted message =
  let sort fields = List.sort compare (Bhttp.Field.lowercase fields) in
  match message with
  | Bhttp.Message.Request r ->
      Bhttp.Message.Request
        { r with headers = sort r.headers; trailers = sort r.trailers }
  | Bhttp.Message.Response r ->
      Bhttp.Message.Response
        { r with headers = sort r.headers; trailers = sort r.trailers }

let message = Alcotest.testable Bhttp.Message.pp Bhttp.Message.equal

let test_messages peer () =
  let corpus =
    Vectors.load (Printf.sprintf "differential/bhttp-%s.json" peer)
  in
  let messages = corpus |> member "messages" |> to_list in
  Alcotest.(check bool) "the corpus has messages" true (messages <> []);
  List.iter
    (fun json ->
      let expected =
        match
          Bhttp_test_support.Json_message.of_json (member "decoded" json)
        with
        | Ok m -> m
        | Error msg -> Alcotest.failf "unreadable corpus: %s" msg
      in
      match Bhttp.Message.decode (Vectors.hex_field json "message") with
      | Ok decoded ->
          Alcotest.check message
            (Vectors.string_field json "category")
            (sorted expected) (sorted decoded)
      | Error e ->
          Alcotest.failf "a recorded message does not decode: %a" Bhttp.Error.pp
            e)
    messages

let tests =
  List.map
    (fun peer -> Alcotest.test_case peer `Quick (test_messages peer))
    [ "go"; "rust" ]
