(** Lowercase hexadecimal encoding. *)

val encode : string -> string
val decode : string -> (string, string) result

val decode_exn : string -> string
(** Raises [Invalid_argument] on malformed input. *)
