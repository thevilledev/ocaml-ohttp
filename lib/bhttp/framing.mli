(** Framing indicator (RFC 9292 Section 3.3). *)

(** How the lengths of field sections and content are delimited. *)
type t =
  | Known_length
      (** Every section carries a length prefix (RFC 9292 Section 3.1). *)
  | Indeterminate_length
      (** Sections end with a zero terminator, and content is sent as chunks, so
          a message can be produced before its size is known (RFC 9292 Section
          3.2). *)

type kind = Request | Response

val indicator : kind -> t -> int
(** The framing indicator, from 0 to 3, that starts a message. *)

val of_indicator : int -> (kind * t) option

val peek : string -> (kind * t, Error.t) result
(** [peek message] reads only the framing indicator of [message]. *)

val kind_to_string : kind -> string
val pp : Format.formatter -> t -> unit
