(* Deterministic test input. The standard library's generator differs between
   OCaml 4.14 and 5, so everything is drawn from an HMAC-DRBG, which is the same
   everywhere. *)

module Drbg = Mirage_crypto_rng.Hmac_drbg (Digestif.SHA256)

type g = Mirage_crypto_rng.g

let create seed =
  Mirage_crypto_rng.create
    ~seed:(Printf.sprintf "ocaml-ohttp differential testing, seed %d" seed)
    (module Drbg)

let bytes g n = Mirage_crypto_rng.generate ~g n

let int g bound =
  if bound <= 0 then invalid_arg "Cases.int";
  let b = bytes g 4 in
  Int32.to_int (Int32.logand (String.get_int32_be b 0) 0x3fff_ffffl) mod bound

let bool g = int g 2 = 0
let pick g list = List.nth list (int g (List.length list))

let string_of g alphabet n =
  String.init n (fun _ -> alphabet.[int g (String.length alphabet)])

(* What a peer can carry. A plain message fits the smallest of them: one that
   keeps fields in a map and its target in a URL. *)
type shape = Plain | Rich

let letters = "abcdefghijklmnopqrstuvwxyz"
let token_chars = letters ^ "0123456789-_.!#$%&'*+^`|~"
let printable = letters ^ "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 -_.:;,=/()<>\"'"

let trim s =
  let is_space c = c = ' ' || c = '\t' in
  let n = String.length s in
  let first = ref 0 and last = ref n in
  while !first < n && is_space s.[!first] do
    incr first
  done;
  while !last > !first && is_space s.[!last - 1] do
    decr last
  done;
  String.sub s !first (!last - !first)

let value g = function
  | Plain -> trim (string_of g printable (int g 24))
  | Rich ->
      (* Anything but NUL, CR, and LF, including obs-text and inner tabs. *)
      trim
        (String.init (int g 24) (fun _ ->
             match int g 20 with
             | 0 -> '\t'
             | 1 -> Char.chr (0x80 + int g 0x80)
             | _ -> Char.chr (0x20 + int g 0x5f)))

let fields g shape ~count =
  match shape with
  | Plain ->
      (* Unique names that no HTTP library treats specially. *)
      List.init count (fun i ->
          ( Printf.sprintf "x-%s-%d" (string_of g letters (1 + int g 8)) i,
            value g Plain ))
  | Rich ->
      let names =
        List.init (max 1 count) (fun _ ->
            string_of g token_chars (1 + int g 10))
      in
      List.init count (fun _ -> (pick g names, value g Rich))

let content g = bytes g (pick g [ 0; 0; 1; 17; 300; 5000 ])

let request g shape : Bhttp.Request.t =
  let segment () = string_of g (letters ^ "0123456789-_.~") (1 + int g 8) in
  let path =
    "/" ^ String.concat "/" (List.init (int g 4) (fun _ -> segment ()))
  in
  match shape with
  | Plain ->
      {
        meth = pick g [ "GET"; "POST"; "PUT"; "DELETE" ];
        scheme = pick g [ "https"; "http" ];
        authority = segment () ^ ".example";
        path;
        headers = fields g Plain ~count:(int g 5);
        content = content g;
        trailers = [];
      }
  | Rich ->
      {
        meth =
          pick g [ "GET"; "POST"; "QUERY"; String.uppercase_ascii (segment ()) ];
        scheme = pick g [ "https"; "http" ];
        authority = (if int g 4 = 0 then "" else segment () ^ ".example:8443");
        path =
          (if bool g then path else path ^ "?" ^ segment () ^ "=" ^ segment ());
        headers = fields g Rich ~count:(int g 6);
        content = content g;
        trailers =
          (if int g 3 = 0 then fields g Rich ~count:(1 + int g 2) else []);
      }

let response g shape : Bhttp.Response.t =
  match shape with
  | Plain ->
      {
        informational = [];
        status = pick g [ 200; 201; 204; 301; 404; 500; 599 ];
        headers = fields g Plain ~count:(int g 5);
        content = content g;
        trailers = [];
      }
  | Rich ->
      {
        informational =
          List.init (int g 3) (fun _ ->
              Bhttp.Response.informational
                ~status:(100 + int g 100)
                (fields g Rich ~count:(int g 3)));
        status = 200 + int g 400;
        headers = fields g Rich ~count:(int g 6);
        content = content g;
        trailers =
          (if int g 3 = 0 then fields g Rich ~count:(1 + int g 2) else []);
      }

let message g shape =
  if bool g then Bhttp.Message.Request (request g shape)
  else Bhttp.Message.Response (response g shape)
