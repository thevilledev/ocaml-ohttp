(* Lowercase hexadecimal encoding helpers used by tests and debugging output. *)

let encode s =
  let n = String.length s in
  let b = Bytes.create (2 * n) in
  let digit x = Char.unsafe_chr (if x < 10 then 48 + x else 87 + x) in
  for i = 0 to n - 1 do
    let c = Char.code (String.unsafe_get s i) in
    Bytes.unsafe_set b (2 * i) (digit (c lsr 4));
    Bytes.unsafe_set b ((2 * i) + 1) (digit (c land 0xf))
  done;
  Bytes.unsafe_to_string b

let decode s =
  let n = String.length s in
  if n mod 2 <> 0 then Error "odd-length hex string"
  else
    let value c =
      match c with
      | '0' .. '9' -> Some (Char.code c - 48)
      | 'a' .. 'f' -> Some (Char.code c - 87)
      | 'A' .. 'F' -> Some (Char.code c - 55)
      | _ -> None
    in
    let b = Bytes.create (n / 2) in
    let rec go i =
      if i >= n then Ok (Bytes.unsafe_to_string b)
      else
        match (value s.[i], value s.[i + 1]) with
        | Some hi, Some lo ->
            Bytes.unsafe_set b (i / 2) (Char.unsafe_chr ((hi lsl 4) lor lo));
            go (i + 2)
        | _ -> Error (Printf.sprintf "invalid hex digit at offset %d" i)
    in
    go 0

let decode_exn s =
  match decode s with
  | Ok v -> v
  | Error msg -> invalid_arg ("Hex.decode: " ^ msg)
