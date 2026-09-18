(* The parts shared by request and response encodings (RFC 9292 Sections 3.1,
   3.2, 3.6, and 3.8). *)

exception Decode_error of Error.t

let fail e = raise (Decode_error e)

module Decoder = struct
  type t = { s : string; mutable pos : int }

  let of_string s = { s; pos = 0 }
  let remaining t = String.length t.s - t.pos
  let at_end t = remaining t = 0

  let varint ~what t =
    match Varint.decode t.s ~pos:t.pos with
    | Ok (v, next) ->
        t.pos <- next;
        v
    | Error (Error.Truncated _) -> fail (Error.Truncated what)
    | Error e -> fail e

  (* Compare against what is left, never [pos + n]: a length near max_int would
     overflow the sum. *)
  let take ~what t n =
    if n > remaining t then fail (Error.Truncated what);
    let v = String.sub t.s t.pos n in
    t.pos <- t.pos + n;
    v

  let bytes ~what t =
    let n = varint ~what t in
    take ~what t n

  let padding t =
    for i = t.pos to String.length t.s - 1 do
      if String.unsafe_get t.s i <> '\000' then fail Error.Invalid_padding
    done;
    t.pos <- String.length t.s
end

let decode reader s =
  match reader (Decoder.of_string s) with
  | v -> Ok v
  | exception Decode_error e -> Error e

(* The Name Length has already been read: it is what tells a field line from the
   terminator of an indeterminate-length section. *)
let read_field_line d ~name_length =
  let name = Decoder.take ~what:"field name" d name_length in
  let value = Decoder.bytes ~what:"field value" d in
  (String.lowercase_ascii name, value)

let read_fields framing ~what d =
  match framing with
  | Framing.Known_length ->
      let section = Decoder.of_string (Decoder.bytes ~what d) in
      let rec lines acc =
        if Decoder.at_end section then List.rev acc
        else
          match Decoder.varint ~what:"field name" section with
          | 0 -> fail (Error.Invalid_field_name "")
          | name_length -> lines (read_field_line section ~name_length :: acc)
      in
      lines []
  | Framing.Indeterminate_length ->
      let rec lines acc =
        match Decoder.varint ~what:(what ^ " terminator") d with
        | 0 -> List.rev acc
        | name_length -> lines (read_field_line d ~name_length :: acc)
      in
      lines []

let read_content framing d =
  match framing with
  | Framing.Known_length -> Decoder.bytes ~what:"content" d
  | Framing.Indeterminate_length ->
      let content = Buffer.create 256 in
      let rec chunks () =
        match Decoder.varint ~what:"content terminator" d with
        | 0 -> Buffer.contents content
        | length ->
            Buffer.add_string content
              (Decoder.take ~what:"content chunk" d length);
            chunks ()
      in
      chunks ()

(* RFC 9292 Section 3.8: the input may end before a section, which is then
   empty, and at no other point. Once a section has begun it must be complete,
   so an indeterminate-length section that holds anything needs its
   terminator. *)
let read_sections framing d =
  let headers =
    if Decoder.at_end d then []
    else read_fields framing ~what:"header section" d
  in
  let content = if Decoder.at_end d then "" else read_content framing d in
  let trailers =
    if Decoder.at_end d then []
    else read_fields framing ~what:"trailer section" d
  in
  Decoder.padding d;
  (headers, content, trailers)

let add_bytes b s =
  Varint.add b (String.length s);
  Buffer.add_string b s

let add_field_line b (name, value) =
  add_bytes b (String.lowercase_ascii name);
  add_bytes b value

let add_fields framing b fields =
  match framing with
  | Framing.Known_length ->
      let section = Buffer.create 256 in
      List.iter (add_field_line section) fields;
      add_bytes b (Buffer.contents section)
  | Framing.Indeterminate_length ->
      List.iter (add_field_line b) fields;
      Varint.add b 0

let add_content framing b content =
  match framing with
  | Framing.Known_length -> add_bytes b content
  | Framing.Indeterminate_length ->
      (* A chunk is never empty: a zero length is the terminator. *)
      if content <> "" then add_bytes b content;
      Varint.add b 0

let add_sections framing ~truncate ~padding b ~headers ~content ~trailers =
  if padding < 0 then invalid_arg "Bhttp: negative padding";
  let omit_trailers = truncate && trailers = [] in
  let omit_content = omit_trailers && content = "" in
  let omit_headers = omit_content && headers = [] in
  if not omit_headers then add_fields framing b headers;
  if not omit_content then add_content framing b content;
  if not omit_trailers then add_fields framing b trailers;
  Buffer.add_string b (String.make padding '\000')
