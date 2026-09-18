(* Binary HTTP requests (RFC 9292 Sections 3.1, 3.2, and 3.4). *)

type t = {
  meth : string;
  scheme : string;
  authority : string;
  path : string;
  headers : Field.t list;
  content : string;
  trailers : Field.t list;
}

let ( let* ) = Result.bind

let make ?(scheme = "https") ?(authority = "") ?(headers = []) ?(content = "")
    ?(trailers = []) ~meth ~path () =
  { meth; scheme; authority; path; headers; content; trailers }

(* Control data is copied into an HTTP/1.1 request line or into HTTP/2
   pseudo-header fields by whatever forwards the request. *)
let is_target_char c = c > ' ' && c <> '\x7f'

let validate t =
  let target what value =
    if String.for_all is_target_char value then Ok ()
    else
      Error (Error.Invalid_control_data (what ^ " contains a forbidden byte"))
  in
  let* () =
    if Field.is_token t.meth then Ok ()
    else Error (Error.Invalid_control_data "method is not a token")
  in
  let* () = target "scheme" t.scheme in
  let* () = target "authority" t.authority in
  let* () = target "path" t.path in
  let* () = Field.validate_headers t.headers in
  Field.validate_trailers t.trailers

let encode ?(framing = Framing.Known_length) ?(padding = 0) ?(truncate = false)
    t =
  let* () = validate t in
  let b = Buffer.create 512 in
  Varint.add b (Framing.indicator Framing.Request framing);
  Wire.add_bytes b t.meth;
  Wire.add_bytes b t.scheme;
  Wire.add_bytes b t.authority;
  Wire.add_bytes b t.path;
  Wire.add_sections framing ~truncate ~padding b ~headers:t.headers
    ~content:t.content ~trailers:t.trailers;
  Ok (Buffer.contents b)

let encode_exn ?framing ?padding ?truncate t =
  match encode ?framing ?padding ?truncate t with
  | Ok v -> v
  | Error e -> invalid_arg (Error.to_string e)

let read framing d =
  let meth = Wire.Decoder.bytes ~what:"method" d in
  let scheme = Wire.Decoder.bytes ~what:"scheme" d in
  let authority = Wire.Decoder.bytes ~what:"authority" d in
  let path = Wire.Decoder.bytes ~what:"path" d in
  let headers, content, trailers = Wire.read_sections framing d in
  let t = { meth; scheme; authority; path; headers; content; trailers } in
  match validate t with Ok () -> t | Error e -> Wire.fail e

let decode message =
  let* kind, framing = Framing.peek message in
  match kind with
  | Framing.Response ->
      Error
        (Error.Unexpected_message { expected = "request"; actual = "response" })
  | Framing.Request ->
      Wire.decode
        (fun d ->
          ignore (Wire.Decoder.varint ~what:"framing indicator" d);
          read framing d)
        message

let equal (a : t) (b : t) = a = b

let pp_fields fmt fields =
  List.iter (fun field -> Format.fprintf fmt "@,%a" Field.pp field) fields

let pp fmt t =
  Format.fprintf fmt "@[<v>%s %s://%s%s" (String.escaped t.meth)
    (String.escaped t.scheme)
    (String.escaped t.authority)
    (String.escaped t.path);
  pp_fields fmt t.headers;
  Format.fprintf fmt "@,content: %d bytes" (String.length t.content);
  if t.trailers <> [] then (
    Format.fprintf fmt "@,trailers:";
    pp_fields fmt t.trailers);
  Format.fprintf fmt "@]"
