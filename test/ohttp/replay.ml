(* Open a recorded exchange that another implementation produced.

   A recording holds the gateway's key, an Encapsulated Request, and the
   Encapsulated Response that answered it. The client's HPKE context is gone,
   but the gateway's can be rebuilt from its key, and both sides export the same
   secret. That makes the recorded response a known answer without any need to
   reproduce the randomness of whoever produced it. *)

open Ohttp

let ( let* ) = Result.bind
let hpke_error = function Ok v -> Ok v | Error e -> Error (Error.Hpke e)

let open_response ?(labels = Encapsulation.bhttp_labels) ~private_key
    ~encapsulated_request encapsulated_response =
  let* _, kem_id, kdf_id, aead_id =
    Encapsulation.parse_header encapsulated_request
  in
  let kem = Hpke.Private_key.kem private_key in
  let* suite =
    match Suite.symmetric_of_ints (kdf_id, aead_id) with
    | Some pair when Hpke.Kem.to_int kem = kem_id -> Ok (Suite.make kem pair)
    | Some _ | None ->
        Error
          (Error.Unsupported_suite
             { kem = kem_id; kdf = kdf_id; aead = aead_id })
  in
  let header = String.sub encapsulated_request 0 Encapsulation.header_length in
  let enc =
    String.sub encapsulated_request Encapsulation.header_length
      (Hpke.Kem.encapsulated_key_size kem)
  in
  let* receiver =
    hpke_error
      (Hpke.Rfc9180.setup_base_receiver (Suite.hpke suite)
         ~recipient:private_key ~encapsulated_key:enc
         ~info:(Encapsulation.info ~label:labels.request ~header))
  in
  let* secret =
    hpke_error
      (Hpke.Rfc9180.Receiver.export receiver ~context:labels.response
         ~length:(Suite.response_nonce_length suite.aead))
  in
  Encapsulation.open_response suite ~enc ~secret encapsulated_response
