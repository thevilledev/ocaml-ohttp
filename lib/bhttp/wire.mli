(** The parts shared by request and response encodings (RFC 9292 Sections 3.1,
    3.2, 3.6, and 3.8). Private to the library. *)

exception Decode_error of Error.t
(** Raised by every reader below; {!decode} turns it into a result. *)

val fail : Error.t -> 'a

module Decoder : sig
  type t

  val at_end : t -> bool

  val varint : what:string -> t -> int
  (** [what] names the integer in the [Truncated] error. *)

  val bytes : what:string -> t -> string
  (** A length-prefixed byte string. *)
end

val decode : (Decoder.t -> 'a) -> string -> ('a, Error.t) result
(** Run a reader over a whole message. *)

val read_fields : Framing.t -> what:string -> Decoder.t -> Field.t list
(** A complete field section. Names are lowercased but not validated. *)

val read_sections :
  Framing.t -> Decoder.t -> Field.t list * string * Field.t list
(** The header section, content, and trailer section that follow control data,
    then padding. The input may end before any of the three, which then reads as
    empty. *)

val add_bytes : Buffer.t -> string -> unit
(** A length-prefixed byte string. *)

val add_fields : Framing.t -> Buffer.t -> Field.t list -> unit
(** A complete field section. Names are lowercased. *)

val add_sections :
  Framing.t ->
  truncate:bool ->
  padding:int ->
  Buffer.t ->
  headers:Field.t list ->
  content:string ->
  trailers:Field.t list ->
  unit
(** The counterpart of {!read_sections}. With [truncate], every trailing empty
    section is omitted. *)
