(* The client's side of an exchange (RFC 9458 Sections 4.3 and 4.4). *)

type response_context = { suite : Suite.t; enc : string; secret : string }

type sender_setup =
  Hpke.Suite.encryption Hpke.Suite.t ->
  recipient:Hpke.Public_key.t ->
  info:string ->
  (Hpke.Suite.encryption Hpke.Rfc9180.sender_setup, Hpke.Error.t) result

let ( let* ) = Result.bind
let hpke_error = function Ok v -> Ok v | Error e -> Error (Error.Hpke e)

let encapsulate_with ~(setup : sender_setup)
    ?(labels = Encapsulation.bhttp_labels) ?preference config request =
  let* suite = Key_config.select ?preference config in
  let header = Encapsulation.header ~key_id:(Key_config.key_id config) suite in
  let info = Encapsulation.info ~label:labels.request ~header in
  let* { Hpke.Rfc9180.encapsulated_key = enc; context } =
    hpke_error
      (setup (Suite.hpke suite) ~recipient:(Key_config.public_key config) ~info)
  in
  let* sealed =
    hpke_error (Hpke.Rfc9180.Sender.seal context ~aad:"" ~plaintext:request)
  in
  (* Exporting now, and not when the response arrives, leaves nothing of the
     mutable HPKE context in what the caller holds on to. *)
  let* secret =
    hpke_error
      (Hpke.Rfc9180.Sender.export context ~context:labels.response
         ~length:(Suite.response_nonce_length suite.aead))
  in
  Ok (header ^ enc ^ sealed, { suite; enc; secret })

let encapsulate ~rng =
  encapsulate_with ~setup:(Hpke.Rfc9180.setup_base_sender ~rng)

let decapsulate { suite; enc; secret } encapsulated =
  Encapsulation.open_response suite ~enc ~secret encapsulated
