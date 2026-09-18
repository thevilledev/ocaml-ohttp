(* The gateway's side of an exchange (RFC 9458 Sections 4.3 and 4.4). *)

let ( let* ) = Result.bind
let hpke_error = function Ok v -> Ok v | Error e -> Error (Error.Hpke e)

module Key = struct
  type t = { private_key : Hpke.Private_key.t; config : Key_config.t }

  let of_private_key ~key_id ?(symmetric = Suite.default_symmetric) private_key
      =
    let* config =
      Key_config.create ~key_id
        (Hpke.Private_key.public_key private_key)
        symmetric
    in
    Ok { private_key; config }

  let generate ~rng ~key_id ?symmetric kem =
    let* private_key, _ = hpke_error (Hpke.generate_key_pair ~rng kem) in
    of_private_key ~key_id ?symmetric private_key

  let derive ~key_id ?symmetric kem ~ikm =
    let* private_key, _ = hpke_error (Hpke.derive_key_pair kem ~ikm) in
    of_private_key ~key_id ?symmetric private_key

  let key_id t = Key_config.key_id t.config
  let config t = t.config
end

type t = Key.t list
type response_context = { suite : Suite.t; enc : string; secret : string }

let create keys =
  let ids = List.map Key.key_id keys in
  if keys = [] then Error (Error.Invalid_key_config "a gateway needs a key")
  else if List.length (List.sort_uniq compare ids) <> List.length ids then
    Error (Error.Invalid_key_config "two keys share an identifier")
  else Ok keys

let key_configs t = List.map Key.config t
let encoded_key_configs t = Key_config.encode_list (key_configs t)

(* What the peer controls must not be told apart by the peer. *)
let peer_error = function
  | Ok v -> Ok v
  | Error (Hpke.Error.Invalid_encapsulation _ | Hpke.Error.Open_error) ->
      Error Error.Decapsulation_failed
  | Error e -> Error (Error.Hpke e)

let decapsulate ?(labels = Encapsulation.bhttp_labels) t encapsulated =
  let* key_id, kem_id, kdf_id, aead_id =
    Encapsulation.parse_header encapsulated
  in
  let* key =
    match List.find_opt (fun key -> Key.key_id key = key_id) t with
    | Some key -> Ok key
    | None -> Error (Error.Unknown_key_id key_id)
  in
  let kem = Key_config.kem key.config in
  let* suite =
    (* The key's own list decides, not what this library could do. *)
    match Suite.symmetric_of_ints (kdf_id, aead_id) with
    | Some pair
      when Hpke.Kem.to_int kem = kem_id && Key_config.offers key.config pair ->
        Ok (Suite.make kem pair)
    | Some _ | None ->
        Error
          (Error.Unsupported_suite
             { kem = kem_id; kdf = kdf_id; aead = aead_id })
  in
  let enc_length = Hpke.Kem.encapsulated_key_size kem in
  let rest = String.length encapsulated - Encapsulation.header_length in
  if rest < enc_length then Error (Error.Truncated_message "encapsulated key")
  else
    let enc = String.sub encapsulated Encapsulation.header_length enc_length in
    let ciphertext =
      String.sub encapsulated
        (Encapsulation.header_length + enc_length)
        (rest - enc_length)
    in
    let header = String.sub encapsulated 0 Encapsulation.header_length in
    let info = Encapsulation.info ~label:labels.request ~header in
    let* context =
      peer_error
        (Hpke.Rfc9180.setup_base_receiver (Suite.hpke suite)
           ~recipient:key.private_key ~encapsulated_key:enc ~info)
    in
    let* request =
      peer_error (Hpke.Rfc9180.Receiver.open_ context ~aad:"" ~ciphertext)
    in
    let* secret =
      hpke_error
        (Hpke.Rfc9180.Receiver.export context ~context:labels.response
           ~length:(Suite.response_nonce_length suite.aead))
    in
    Ok (request, { suite; enc; secret })

let encapsulate ~rng { suite; enc; secret } response =
  let response_nonce =
    Mirage_crypto_rng.generate ~g:rng (Suite.response_nonce_length suite.aead)
  in
  Encapsulation.seal_response suite ~enc ~secret ~response_nonce response
