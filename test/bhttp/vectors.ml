(* Helpers for the JSON corpora in test/vectors. *)

open Yojson.Safe.Util

let load name = Yojson.Safe.from_file (Filename.concat "../vectors" name)
let vectors name = load name |> member "vectors" |> to_list
let string_field j k = to_string (member k j)
let int_field j k = to_int (member k j)
let hex_field j k = Bhttp.Hex.decode_exn (string_field j k)

let find name vectors =
  match List.find_opt (fun v -> string_field v "name" = name) vectors with
  | Some v -> v
  | None -> Alcotest.failf "no vector named %S" name

(* Compare as hex so that a failure is readable. *)
let check_bytes name expected actual =
  Alcotest.(check string)
    name
    (Bhttp.Hex.encode expected)
    (Bhttp.Hex.encode actual)

let request = Alcotest.testable Bhttp.Request.pp Bhttp.Request.equal
let response = Alcotest.testable Bhttp.Response.pp Bhttp.Response.equal
let error = Alcotest.testable Bhttp.Error.pp ( = )
