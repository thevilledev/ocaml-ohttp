module Varint = Bhttp.Varint

let decode s = Varint.decode s ~pos:0

(* Values above 2^30 - 1 exist only where int is 63 bits wide. The tests avoid
   literals that would not compile elsewhere. *)
let wide = Sys.int_size >= 63

(* RFC 9000 Section 16 and Appendix A.1. *)
let test_rfc9000_examples () =
  List.iter
    (fun (hex, expected) ->
      let encoded = Bhttp.Hex.decode_exn hex in
      if wide || String.length encoded < 8 then
        match decode encoded with
        | Ok (value, next) ->
            Alcotest.(check string) hex expected (string_of_int value);
            Alcotest.(check int) "consumed" (String.length encoded) next
        | Error e -> Alcotest.failf "%s: %a" hex Bhttp.Error.pp e)
    [
      ("c2197c5eff14e88c", "151288809941952652");
      ("9d7f3e7d", "494878333");
      ("7bbd", "15293");
      ("25", "37");
      ("4025", "37");
    ]

let boundaries =
  [ (0, 1); (63, 1); (64, 2); (16_383, 2); (16_384, 4); (0x3fff_ffff, 4) ]
  @ if wide then [ (0x3fff_ffff + 1, 8); (Varint.max_value, 8) ] else []

let test_boundaries () =
  List.iter
    (fun (n, size) ->
      Alcotest.(check int) (Printf.sprintf "size of %d" n) size (Varint.size n);
      let encoded = Varint.encode n in
      Alcotest.(check int) "encoded length" size (String.length encoded);
      Alcotest.(check (result (pair int int) Vectors.error))
        "round trip"
        (Ok (n, size))
        (decode encoded))
    boundaries

(* RFC 9292 Section 3: "Integer values do not need to be encoded on the minimum
   number of bytes necessary." *)
let test_non_minimal () =
  List.iter
    (fun (n, minimal) ->
      List.iter
        (fun size ->
          if size >= minimal then
            Alcotest.(check (result (pair int int) Vectors.error))
              (Printf.sprintf "%d on %d bytes" n size)
              (Ok (n, size))
              (decode (Build.sized ~size n)))
        [ 1; 2; 4; 8 ])
    boundaries

let test_position () =
  let s = "\xff" ^ Varint.encode 300 ^ "\xff" in
  Alcotest.(check (result (pair int int) Vectors.error))
    "reads at the position"
    (Ok (300, 3))
    (Varint.decode s ~pos:1);
  Alcotest.check_raises "position outside the string"
    (Invalid_argument "Varint.decode") (fun () ->
      ignore (Varint.decode s ~pos:5))

let test_truncated () =
  let truncated = Error (Bhttp.Error.Truncated "variable-length integer") in
  Alcotest.(check (result (pair int int) Vectors.error))
    "empty" truncated (decode "");
  List.iter
    (fun (n, _) ->
      let encoded = Varint.encode n in
      for length = 1 to String.length encoded - 1 do
        Alcotest.(check (result (pair int int) Vectors.error))
          "missing bytes" truncated
          (decode (String.sub encoded 0 length))
      done)
    boundaries

let test_invalid_arguments () =
  let raises name f =
    match f () with
    | exception Invalid_argument _ -> ()
    | _ -> Alcotest.failf "%s did not raise" name
  in
  raises "negative" (fun () -> Varint.encode (-1));
  raises "negative size" (fun () -> Varint.size (-1));
  raises "bad width" (fun () -> Build.sized ~size:3 1);
  raises "does not fit one byte" (fun () -> Build.sized ~size:1 64);
  raises "does not fit two bytes" (fun () -> Build.sized ~size:2 16_384);
  if wide then
    raises "does not fit four bytes" (fun () ->
        Build.sized ~size:4 (0x3fff_ffff + 1))

let tests =
  [
    Alcotest.test_case "RFC 9000 examples" `Quick test_rfc9000_examples;
    Alcotest.test_case "size boundaries" `Quick test_boundaries;
    Alcotest.test_case "non-minimal encodings" `Quick test_non_minimal;
    Alcotest.test_case "position" `Quick test_position;
    Alcotest.test_case "truncated" `Quick test_truncated;
    Alcotest.test_case "invalid arguments" `Quick test_invalid_arguments;
  ]
