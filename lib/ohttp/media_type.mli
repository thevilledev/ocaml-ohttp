(** Media types of Oblivious HTTP (RFC 9458 Section 9) and Binary HTTP (RFC 9292
    Section 7). *)

val ohttp_request : string
(** ["message/ohttp-req"], an encapsulated request. *)

val ohttp_response : string
(** ["message/ohttp-res"], an encapsulated response. *)

val ohttp_chunked_request : string
(** ["message/ohttp-chunked-req"], a chunked encapsulated request
    (draft-ietf-ohai-chunked-ohttp). *)

val ohttp_chunked_response : string
(** ["message/ohttp-chunked-res"], a chunked encapsulated response. *)

val ohttp_keys : string
(** ["application/ohttp-keys"], a list of key configurations. *)

val bhttp : string
(** ["message/bhttp"], the default content of an encapsulated message. *)

val problem_json : string
(** ["application/problem+json"], a problem document (RFC 9457). *)

val matches : string -> string -> bool
(** [matches media_type content_type] is [true] when the [Content-Type] field
    value [content_type] names [media_type]. Type and subtype are compared
    without regard to case, and parameters and surrounding whitespace are
    ignored (RFC 9110 Section 8.3.1). *)
