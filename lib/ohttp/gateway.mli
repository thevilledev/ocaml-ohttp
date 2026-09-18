(** The gateway's side of an exchange (RFC 9458 Sections 4.3 and 4.4).

    {[
      let* request, context = Gateway.decapsulate gateway encapsulated in
      (* Handle [request] or forward it to the target. *)
      let* encapsulated_response = Gateway.encapsulate ~rng context response in
    ]} *)

module Key : sig
  type t
  (** An HPKE private key with the key configuration that advertises it.

      RFC 9458 Section 6.4: a gateway's keys must not be valid for any other
      protocol that uses HPKE with the same labels. *)

  val generate :
    rng:Mirage_crypto_rng.g ->
    key_id:int ->
    ?symmetric:Suite.symmetric list ->
    Hpke.Kem.id ->
    (t, Error.t) result
  (** [symmetric] defaults to {!Suite.default_symmetric}. *)

  val derive :
    key_id:int ->
    ?symmetric:Suite.symmetric list ->
    Hpke.Kem.id ->
    ikm:string ->
    (t, Error.t) result
  (** The key that RFC 9180 [DeriveKeyPair] derives from [ikm], which must be
      secret and hold at least as much entropy as a private key. Other
      implementations derive the same key from the same input. *)

  val of_private_key :
    key_id:int ->
    ?symmetric:Suite.symmetric list ->
    Hpke.Private_key.t ->
    (t, Error.t) result

  val key_id : t -> int
  val config : t -> Key_config.t
end

type t
(** The keys that a gateway accepts requests for. *)

val create : Key.t list -> (t, Error.t) result
(** Returns {!Error.Invalid_key_config} if the list is empty or if two keys
    share an identifier. A rotation keeps the old key beside the new one until
    clients have fetched the new configuration. *)

val key_configs : t -> Key_config.t list
(** The configurations of the keys, in the order given to {!create}. *)

val encoded_key_configs : t -> string
(** The content to serve as [application/ohttp-keys]. *)

type response_context
(** What seals the response to one request. It is immutable, and holds a secret
    of that exchange and nothing of the HPKE context. *)

val decapsulate :
  ?labels:Encapsulation.labels ->
  t ->
  string ->
  (string * response_context, Error.t) result
(** [decapsulate gateway encapsulated_request] is the request and the context
    for its response.

    A request must name a key that the gateway holds, that key's KEM, and a KDF
    and AEAD that the key offers, whatever else this library provides.
    {!Error.Unknown_key_id} and {!Error.Unsupported_suite} tell a client that
    its key configuration is out of date; everything else that a peer can cause
    is {!Error.Decapsulation_failed}. All of them are answered without
    encapsulation (RFC 9458 Section 5.2). *)

val encapsulate :
  rng:Mirage_crypto_rng.g ->
  response_context ->
  string ->
  (string, Error.t) result
(** [encapsulate ~rng context response] is an Encapsulated Response. It draws
    {!Suite.response_nonce_length} bytes from [rng] for the response nonce, and
    nothing else. *)
