(** Binary HTTP messages of either kind (RFC 9292 Section 3). *)

type t = Request of Request.t | Response of Response.t

val encode :
  ?framing:Framing.t ->
  ?padding:int ->
  ?truncate:bool ->
  t ->
  (string, Error.t) result
(** As {!Request.encode} or {!Response.encode}. *)

val decode : string -> (t, Error.t) result
(** Read a message whose kind is not known in advance; the framing indicator
    decides it. *)

val equal : t -> t -> bool
val pp : Format.formatter -> t -> unit
