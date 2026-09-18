(** Key configurations (RFC 9458 Section 3).

    A key configuration tells a client how to reach a gateway's key: its
    identifier, its KEM and public key, and the KDF and AEAD pairs it may be
    used with. There are two encodings, and mistaking one for the other is the
    most common interoperability failure:

    - {!encode} and {!decode} handle a single configuration (Section 3.1), as
      the example of Appendix A prints it;
    - {!encode_list} and {!decode_list} handle the media type
      [application/ohttp-keys] (Section 3.2), in which every configuration is
      prefixed with its length. This is what a gateway serves. *)

type t

val create :
  key_id:int -> Hpke.Public_key.t -> Suite.symmetric list -> (t, Error.t) result
(** [create ~key_id public_key symmetric] describes a key that offers the
    [symmetric] pairs, in order of preference. Returns {!Error.Invalid_key_id}
    unless [key_id] is a byte, and {!Error.Invalid_key_config} if [symmetric] is
    empty or too long to encode. *)

val key_id : t -> int
val kem : t -> Hpke.Kem.id
val public_key : t -> Hpke.Public_key.t

val symmetric : t -> Suite.symmetric list
(** The pairs that this library provides, in the configuration's order. *)

val symmetric_ids : t -> (int * int) list
(** Every KDF and AEAD identifier pair of the configuration, including those
    that this library does not know. They are preserved so that a decoded
    configuration encodes to the bytes it came from. *)

val offers : t -> Suite.symmetric -> bool

val select : ?preference:Suite.symmetric list -> t -> (Suite.t, Error.t) result
(** Choose the algorithms for a request: the first pair of [preference] that the
    configuration offers or, without [preference], the first pair of the
    configuration that this library provides. Returns
    {!Error.No_supported_suite} if there is none. *)

val select_from_list :
  ?preference:Suite.symmetric list -> t list -> (t * Suite.t, Error.t) result
(** The first configuration of a list for which {!select} succeeds. *)

val encode : t -> string
(** A single configuration (RFC 9458 Section 3.1). *)

val decode : string -> (t, Error.t) result
(** A single configuration. Returns {!Error.Unsupported_kem} for a KEM that this
    library does not provide, and {!Error.Invalid_key_config} for anything
    malformed, including trailing bytes. Unknown KDF and AEAD identifiers are
    kept, not rejected. *)

val encode_list : t list -> string
(** The content of [application/ohttp-keys] (RFC 9458 Section 3.2). *)

val decode_list : string -> (t list, Error.t) result
(** The content of [application/ohttp-keys]. A configuration with a KEM that
    this library does not provide is skipped, which its length prefix makes
    possible. Any malformed part rejects the whole list, as RFC 9458 Section 3.2
    requires: "Clients MUST discard incorrectly encoded key configuration
    collections". An empty input is malformed; the result can still be empty
    when every configuration was skipped. *)

val equal : t -> t -> bool
val pp : Format.formatter -> t -> unit
