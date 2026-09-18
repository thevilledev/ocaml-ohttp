module Hex = Bhttp.Hex

let test_round_trip () =
  let all_bytes = String.init 256 Char.chr in
  let encoded = Hex.encode all_bytes in
  Alcotest.(check int) "two digits per byte" 512 (String.length encoded);
  Alcotest.(check string) "lowercase" encoded (String.lowercase_ascii encoded);
  Alcotest.(check (result string string))
    "round trip" (Ok all_bytes) (Hex.decode encoded);
  Alcotest.(check (result string string))
    "uppercase digits are accepted" (Ok all_bytes)
    (Hex.decode (String.uppercase_ascii encoded));
  Alcotest.(check string) "empty" "" (Hex.decode_exn "")

let test_malformed () =
  let rejects s = Result.is_error (Hex.decode s) in
  Alcotest.(check bool) "odd length" true (rejects "abc");
  Alcotest.(check bool) "invalid digit" true (rejects "0g");
  Alcotest.(check bool) "whitespace" true (rejects "00 11");
  Alcotest.check_raises "decode_exn raises"
    (Invalid_argument "Hex.decode: odd-length hex string") (fun () ->
      ignore (Hex.decode_exn "0"))

let tests =
  [
    Alcotest.test_case "round trip" `Quick test_round_trip;
    Alcotest.test_case "malformed input" `Quick test_malformed;
  ]
