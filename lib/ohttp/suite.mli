(** HPKE algorithms as Oblivious HTTP names them (RFC 9458 Section 3.1). *)

type symmetric = { kdf : Hpke.Kdf.id; aead : Hpke.Aead.id }
(** A KDF and an AEAD: one entry of a key configuration's list of symmetric
    algorithms. *)

type t = { kem : Hpke.Kem.id; kdf : Hpke.Kdf.id; aead : Hpke.Aead.id }
(** The algorithms of one request: the KEM of the gateway's key and a
    {!type-symmetric} pair that the key offers. *)

val make : Hpke.Kem.id -> symmetric -> t
val symmetric : t -> symmetric

val symmetric_of_ints : int * int -> symmetric option
(** A KDF identifier and an AEAD identifier, or [None] if this library does not
    provide either one. *)

val symmetric_to_ints : symmetric -> int * int

val default_symmetric : symmetric list
(** What a gateway key offers unless told otherwise: HKDF-SHA256 with
    AES-128-GCM, then HKDF-SHA256 with ChaCha20Poly1305, as in the example of
    RFC 9458 Appendix A. RFC 9458 mandates no algorithm; the first pair, with
    DHKEM(X25519, HKDF-SHA256), is what deployed gateways accept. *)

val all_kems : Hpke.Kem.id list
val all_symmetric : symmetric list
val hpke : t -> Hpke.Suite.encryption Hpke.Suite.t

val response_nonce_length : Hpke.Aead.id -> int
(** [max(Nn, Nk)]: the length of the response nonce, and of the secret exported
    for the response (RFC 9458 Section 4.4). *)

val pp_symmetric : Format.formatter -> symmetric -> unit
val pp : Format.formatter -> t -> unit
