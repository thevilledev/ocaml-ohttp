(* Helpers for the JSON corpora in test/vectors. *)

open Yojson.Safe.Util

let load name = Yojson.Safe.from_file (Filename.concat "../vectors" name)
let vectors name = load name |> member "vectors" |> to_list
let string_field j k = to_string (member k j)
let int_field j k = to_int (member k j)
let hex_field j k = Bhttp.Hex.decode_exn (string_field j k)

(* Compare as hex so that a failure is readable. *)
let check_bytes name expected actual =
  Alcotest.(check string)
    name
    (Bhttp.Hex.encode expected)
    (Bhttp.Hex.encode actual)

let error = Alcotest.testable Ohttp.Error.pp ( = )

let octets =
  Alcotest.testable
    (fun fmt s -> Format.pp_print_string fmt (Bhttp.Hex.encode s))
    String.equal

let ok = function
  | Ok v -> v
  | Error e -> Alcotest.failf "unexpected error: %a" Ohttp.Error.pp e

let hpke_ok = function
  | Ok v -> v
  | Error e -> Alcotest.failf "unexpected HPKE error: %a" Hpke.Error.pp e

(* A generator that tests can repeat. Nothing here needs real entropy. *)
let rng () =
  Mirage_crypto_rng.create
    ~seed:(String.init 64 (fun i -> Char.chr (i + 1)))
    (module Mirage_crypto_rng.Fortuna)
