(** Binary HTTP requests (RFC 9292 Sections 3.1, 3.2, and 3.4). *)

type t = {
  meth : string;  (** The method, such as ["GET"]. *)
  scheme : string;  (** The scheme, such as ["https"]. *)
  authority : string;
      (** The authority, such as ["example.com"]. It may be empty, in which case
          a [host] field usually names the target (RFC 9292 Section 3.4). *)
  path : string;  (** The path and query, such as ["/index.html?q=1"]. *)
  headers : Field.t list;
  content : string;
  trailers : Field.t list;
}

val make :
  ?scheme:string ->
  ?authority:string ->
  ?headers:Field.t list ->
  ?content:string ->
  ?trailers:Field.t list ->
  meth:string ->
  path:string ->
  unit ->
  t
(** [scheme] defaults to ["https"]; everything else defaults to empty. *)

val validate : t -> (unit, Error.t) result
(** Check what {!encode} and {!decode} enforce: the field rules of
    {!Field.validate_headers} and {!Field.validate_trailers}, a method that is a
    token, and a scheme, authority, and path free of control characters, spaces,
    and DEL. The last rule is stricter than RFC 9292 requires; it keeps a
    request from being split when a gateway replays it over HTTP/1.1. *)

val encode :
  ?framing:Framing.t ->
  ?padding:int ->
  ?truncate:bool ->
  t ->
  (string, Error.t) result
(** [encode request] is the binary form of [request], or the error that
    {!validate} reports. Field names are lowercased.

    - [framing] defaults to {!Framing.Known_length}, which every implementation
      reads. Indeterminate-length content is written as a single chunk.
    - [padding] is a number of zero bytes to append (RFC 9292 Section 3.8), 0 by
      default. Raises [Invalid_argument] if negative.
    - [truncate] omits every trailing empty section (RFC 9292 Section 3.8),
      including an empty header section as the example of RFC 9458 Appendix A
      does. It is [false] by default. *)

val encode_exn :
  ?framing:Framing.t -> ?padding:int -> ?truncate:bool -> t -> string
(** As {!encode}, but raises [Invalid_argument] on an invalid request. *)

val decode : string -> (t, Error.t) result
(** [decode message] reads a request in either framing. Integers need not use
    their shortest encoding, trailing empty sections may be missing, and zero
    padding may follow; a message that is truncated anywhere else, or that
    {!validate} rejects, is an error. Field names are lowercased. *)

val equal : t -> t -> bool
val pp : Format.formatter -> t -> unit
