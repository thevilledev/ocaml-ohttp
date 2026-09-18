(** Errors returned by the public API. Messages describe classes of invalid
    input and never contain key material or message content. *)

type t =
  | Invalid_key_config of string
      (** A key configuration, or a list of them, is malformed. *)
  | Invalid_key_id of int  (** A key identifier outside 0 to 255. *)
  | Unsupported_kem of int
      (** A key configuration names a KEM that this library does not provide. *)
  | No_supported_suite
      (** A key configuration offers no KDF and AEAD that this library provides
          and the caller accepts. *)
  | Truncated_message of string
      (** An encapsulated message is too short to hold the named part. *)
  | Unknown_key_id of int
      (** A request names a key that the gateway does not hold. *)
  | Unsupported_suite of { kem : int; kdf : int; aead : int }
      (** A request names algorithms that the addressed key does not offer. *)
  | Decapsulation_failed
      (** An encapsulated message did not decrypt. Every failure that a peer can
          cause is reported this way, so that a gateway does not tell its peer
          which step failed. *)
  | Chunk_too_large of int
      (** A chunk of a chunked message is larger than the receiver accepts, or
          than the sender is set to produce. The argument is its length. *)
  | Hpke of Hpke.Error.t  (** A failure that is not the peer's doing. *)

val to_string : t -> string
val pp : Format.formatter -> t -> unit
