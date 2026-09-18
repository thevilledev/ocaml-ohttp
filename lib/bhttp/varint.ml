(* Variable-length integers (RFC 9000 Section 16). *)

(* A literal for 2^62 - 1 does not compile where int is 31 or 32 bits wide, so
   every bound here is computed or expressed as a shift. *)
let max_value = if Sys.int_size >= 63 then (1 lsl 62) - 1 else max_int

let size n =
  if n < 0 || n > max_value then invalid_arg "Varint.size"
  else if n lsr 6 = 0 then 1
  else if n lsr 14 = 0 then 2
  else if n lsr 30 = 0 then 4
  else 8

let add_sized b ~size:width n =
  if n < 0 || n > max_value then invalid_arg "Varint.add_sized: out of range";
  match width with
  | 1 when n lsr 6 = 0 -> Buffer.add_uint8 b n
  | 2 when n lsr 14 = 0 -> Buffer.add_uint16_be b (0x4000 lor n)
  | 4 when n lsr 30 = 0 ->
      Buffer.add_int32_be b (Int32.logor 0x8000_0000l (Int32.of_int n))
  | 8 ->
      Buffer.add_int64_be b
        (Int64.logor 0xc000_0000_0000_0000L (Int64.of_int n))
  | 1 | 2 | 4 -> invalid_arg "Varint.add_sized: value does not fit"
  | _ -> invalid_arg "Varint.add_sized: size must be 1, 2, 4, or 8"

let add b n = add_sized b ~size:(size n) n

let encode n =
  let b = Buffer.create 8 in
  add b n;
  Buffer.contents b

let decode s ~pos =
  let length = String.length s in
  if pos < 0 || pos > length then invalid_arg "Varint.decode";
  let remaining = length - pos in
  if remaining = 0 then Error (Error.Truncated "variable-length integer")
  else
    let first = Char.code (String.unsafe_get s pos) in
    let width = 1 lsl first lsr 6 in
    if width > remaining then Error (Error.Truncated "variable-length integer")
    else
      match width with
      | 1 -> Ok (first land 0x3f, pos + 1)
      | 2 -> Ok (String.get_uint16_be s pos land 0x3fff, pos + 2)
      | 4 ->
          let v = Int32.logand (String.get_int32_be s pos) 0x3fff_ffffl in
          Ok (Int32.to_int v, pos + 4)
      | _ ->
          let v =
            Int64.logand (String.get_int64_be s pos) 0x3fff_ffff_ffff_ffffL
          in
          if Int64.compare v (Int64.of_int max_value) > 0 then
            Error (Error.Too_large "variable-length integer")
          else Ok (Int64.to_int v, pos + 8)
