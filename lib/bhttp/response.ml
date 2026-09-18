(* Binary HTTP responses (RFC 9292 Sections 3.1, 3.2, and 3.5). *)

type informational = { status : int; headers : Field.t list }

type t = {
  informational : informational list;
  status : int;
  headers : Field.t list;
  content : string;
  trailers : Field.t list;
}

let ( let* ) = Result.bind
let informational ~status headers : informational = { status; headers }

let make ?(informational = []) ?(headers = []) ?(content = "") ?(trailers = [])
    ~status () =
  { informational; status; headers; content; trailers }

let is_informational status = status >= 100 && status <= 199
let is_final status = status >= 200 && status <= 599

let validate t =
  let rec interim = function
    | [] -> Ok ()
    | (i : informational) :: rest ->
        if not (is_informational i.status) then
          Error (Error.Invalid_status i.status)
        else
          let* () = Field.validate_headers i.headers in
          interim rest
  in
  let* () = interim t.informational in
  let* () =
    if is_final t.status then Ok () else Error (Error.Invalid_status t.status)
  in
  let* () = Field.validate_headers t.headers in
  Field.validate_trailers t.trailers

let encode ?(framing = Framing.Known_length) ?(padding = 0) ?(truncate = false)
    t =
  let* () = validate t in
  let b = Buffer.create 512 in
  Varint.add b (Framing.indicator Framing.Response framing);
  List.iter
    (fun (i : informational) ->
      Varint.add b i.status;
      Wire.add_fields framing b i.headers)
    t.informational;
  Varint.add b t.status;
  Wire.add_sections framing ~truncate ~padding b ~headers:t.headers
    ~content:t.content ~trailers:t.trailers;
  Ok (Buffer.contents b)

let encode_exn ?framing ?padding ?truncate t =
  match encode ?framing ?padding ?truncate t with
  | Ok v -> v
  | Error e -> invalid_arg (Error.to_string e)

(* The status code alone tells an informational response from the final one (RFC
   9292 Section 3.5.1). *)
let read framing d =
  let rec responses acc =
    let status = Wire.Decoder.varint ~what:"status code" d in
    if is_informational status then
      let headers = Wire.read_fields framing ~what:"informational response" d in
      responses (({ status; headers } : informational) :: acc)
    else if is_final status then (List.rev acc, status)
    else Wire.fail (Error.Invalid_status status)
  in
  let informational, status = responses [] in
  let headers, content, trailers = Wire.read_sections framing d in
  let t = { informational; status; headers; content; trailers } in
  match validate t with Ok () -> t | Error e -> Wire.fail e

let decode message =
  let* kind, framing = Framing.peek message in
  match kind with
  | Framing.Request ->
      Error
        (Error.Unexpected_message { expected = "response"; actual = "request" })
  | Framing.Response ->
      Wire.decode
        (fun d ->
          ignore (Wire.Decoder.varint ~what:"framing indicator" d);
          read framing d)
        message

let equal (a : t) (b : t) = a = b

let pp_fields fmt fields =
  List.iter (fun field -> Format.fprintf fmt "@,%a" Field.pp field) fields

let pp fmt t =
  Format.fprintf fmt "@[<v>";
  List.iter
    (fun (i : informational) ->
      Format.fprintf fmt "%d" i.status;
      pp_fields fmt i.headers;
      Format.fprintf fmt "@,")
    t.informational;
  Format.fprintf fmt "%d" t.status;
  pp_fields fmt t.headers;
  Format.fprintf fmt "@,content: %d bytes" (String.length t.content);
  if t.trailers <> [] then (
    Format.fprintf fmt "@,trailers:";
    pp_fields fmt t.trailers);
  Format.fprintf fmt "@]"
