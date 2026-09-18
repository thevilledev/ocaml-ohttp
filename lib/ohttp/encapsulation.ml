(* The byte layout and key schedule of encapsulated messages (RFC 9458 Sections
   4.1 to 4.4). *)

type labels = { request : string; response : string }

let bhttp_labels =
  { request = "message/bhttp request"; response = "message/bhttp response" }

let ( let* ) = Result.bind
let hpke_error = function Ok v -> Ok v | Error e -> Error (Error.Hpke e)
let header_length = 7

let header ~key_id (suite : Suite.t) =
  let b = Buffer.create header_length in
  Buffer.add_uint8 b key_id;
  Buffer.add_uint16_be b (Hpke.Kem.to_int suite.kem);
  Buffer.add_uint16_be b (Hpke.Kdf.to_int suite.kdf);
  Buffer.add_uint16_be b (Hpke.Aead.to_int suite.aead);
  Buffer.contents b

let parse_header s =
  if String.length s < header_length then
    Error (Error.Truncated_message "header")
  else
    Ok
      ( String.get_uint8 s 0,
        String.get_uint16_be s 1,
        String.get_uint16_be s 3,
        String.get_uint16_be s 5 )

let info ~label ~header = label ^ "\000" ^ header

type response_keys = {
  salt : string;
  prk : string;
  key : string;
  nonce : string;
}

let response_keys (suite : Suite.t) ~enc ~secret ~response_nonce =
  let salt = enc ^ response_nonce in
  let prk = Hpke.Kdf.extract suite.kdf ~salt secret in
  let expand info length =
    hpke_error (Hpke.Kdf.expand suite.kdf ~prk ~info length)
  in
  let* key = expand "key" (Hpke.Aead.key_size suite.aead) in
  let* nonce = expand "nonce" (Hpke.Aead.nonce_size suite.aead) in
  Ok { salt; prk; key; nonce }

let seal_response (suite : Suite.t) ~enc ~secret ~response_nonce response =
  if String.length response_nonce <> Suite.response_nonce_length suite.aead then
    invalid_arg "Encapsulation.seal_response: wrong response nonce length";
  let* { key; nonce; _ } = response_keys suite ~enc ~secret ~response_nonce in
  let* key = hpke_error (Hpke.Aead.key suite.aead key) in
  let* sealed =
    hpke_error (Hpke.Aead.seal key ~nonce ~aad:"" ~plaintext:response)
  in
  Ok (response_nonce ^ sealed)

let open_response (suite : Suite.t) ~enc ~secret encapsulated =
  let nonce_length = Suite.response_nonce_length suite.aead in
  if String.length encapsulated < nonce_length then
    Error (Error.Truncated_message "response nonce")
  else
    let response_nonce = String.sub encapsulated 0 nonce_length in
    let ciphertext =
      String.sub encapsulated nonce_length
        (String.length encapsulated - nonce_length)
    in
    let* { key; nonce; _ } = response_keys suite ~enc ~secret ~response_nonce in
    let* key = hpke_error (Hpke.Aead.key suite.aead key) in
    match Hpke.Aead.open_ key ~nonce ~aad:"" ~ciphertext with
    | Ok response -> Ok response
    | Error Hpke.Error.Open_error -> Error Error.Decapsulation_failed
    | Error e -> Error (Error.Hpke e)
