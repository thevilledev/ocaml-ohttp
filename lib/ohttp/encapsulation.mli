(** The byte layout and key schedule of encapsulated messages (RFC 9458 Sections
    4.1 to 4.4).

    These are the pure functions that {!Client} and {!Gateway} are built from.
    They take every secret and every random value as an argument, so each step
    can be checked against published intermediate values. Applications should
    use {!Client} and {!Gateway}. *)

type labels = { request : string; response : string }
(** The strings that bind a message to its media type. RFC 9458 Section 4.6 lets
    another protocol reuse the encapsulation with labels of its own. *)

val bhttp_labels : labels
(** ["message/bhttp request"] and ["message/bhttp response"]. *)

val header_length : int
(** 7. *)

val header : key_id:int -> Suite.t -> string
(** [hdr]: the key identifier, then the KEM, KDF, and AEAD identifiers. *)

val parse_header : string -> (int * int * int * int, Error.t) result
(** The key, KEM, KDF, and AEAD identifiers at the start of an Encapsulated
    Request. *)

val info : label:string -> header:string -> string
(** The [info] of the HPKE context: the label, a zero byte, and the header. *)

type response_keys = {
  salt : string;
  prk : string;
  key : string;
  nonce : string;
}

val response_keys :
  Suite.t ->
  enc:string ->
  secret:string ->
  response_nonce:string ->
  (response_keys, Error.t) result
(** The key and nonce of a response, with the intermediate values that lead to
    them:

    {v
    salt = concat(enc, response_nonce)
    prk = Extract(salt, secret)
    aead_key = Expand(prk, "key", Nk)
    aead_nonce = Expand(prk, "nonce", Nn)
    v}

    [Extract] and [Expand] are the plain HKDF functions of the suite, without
    the labels that HPKE adds inside its own key schedule. [secret] is what the
    HPKE context exports for the response label. *)

val seal_response :
  Suite.t ->
  enc:string ->
  secret:string ->
  response_nonce:string ->
  string ->
  (string, Error.t) result
(** An Encapsulated Response: [response_nonce] followed by the sealed response.
    [response_nonce] must be fresh, uniformly random, and
    {!Suite.response_nonce_length} bytes long. *)

val open_response :
  Suite.t -> enc:string -> secret:string -> string -> (string, Error.t) result
(** The response inside an Encapsulated Response, or
    {!Error.Decapsulation_failed}. *)
