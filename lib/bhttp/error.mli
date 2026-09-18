(** Errors returned by the public API. Messages describe classes of invalid
    input and never contain field values or message content. *)

type t =
  | Truncated of string
      (** The input ends where RFC 9292 Section 3.8 does not allow truncation.
          The argument names what was being read. *)
  | Too_large of string
      (** An integer does not fit a native [int] on this platform. *)
  | Invalid_framing_indicator of int
  | Unexpected_message of { expected : string; actual : string }
      (** A request was decoded as a response, or the reverse. *)
  | Invalid_control_data of string
  | Invalid_status of int
  | Invalid_field_name of string
  | Invalid_field_value of string  (** The argument is the field's name. *)
  | Forbidden_pseudo_field of string
      (** One of [:method], [:scheme], [:authority], [:path], or [:status]. *)
  | Misplaced_pseudo_field of string
      (** A pseudo-field after a regular field, or in a trailer section. *)
  | Invalid_padding  (** Bytes after the message that are not zero. *)

val to_string : t -> string
val pp : Format.formatter -> t -> unit
