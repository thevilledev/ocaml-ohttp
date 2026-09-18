(** Binary HTTP responses (RFC 9292 Sections 3.1, 3.2, and 3.5). *)

type informational = { status : int; headers : Field.t list }
(** An informational response (RFC 9292 Section 3.5.1): a status code from 100
    to 199 and its header section. *)

type t = {
  informational : informational list;
      (** The informational responses that precede the final one, in order. *)
  status : int;  (** The final status code, from 200 to 599. *)
  headers : Field.t list;
  content : string;
  trailers : Field.t list;
}

val informational : status:int -> Field.t list -> informational

val make :
  ?informational:informational list ->
  ?headers:Field.t list ->
  ?content:string ->
  ?trailers:Field.t list ->
  status:int ->
  unit ->
  t

val validate : t -> (unit, Error.t) result
(** Check what {!encode} and {!decode} enforce: the status code ranges above,
    and the field rules of {!Field.validate_headers} and
    {!Field.validate_trailers}. *)

val encode :
  ?framing:Framing.t ->
  ?padding:int ->
  ?truncate:bool ->
  t ->
  (string, Error.t) result
(** As {!Request.encode}. Reason phrases are not part of the format. *)

val encode_exn :
  ?framing:Framing.t -> ?padding:int -> ?truncate:bool -> t -> string
(** As {!encode}, but raises [Invalid_argument] on an invalid response. *)

val decode : string -> (t, Error.t) result
(** As {!Request.decode}. An informational response is never truncated, since a
    final status code must follow it. *)

val equal : t -> t -> bool
val pp : Format.formatter -> t -> unit
