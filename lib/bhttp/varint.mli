(** Variable-length integers (RFC 9000 Section 16), as used by every length and
    numeric value of RFC 9292.

    An integer occupies 1, 2, 4, or 8 bytes. RFC 9292 Section 3 does not require
    the shortest form, so {!decode} accepts any of them. *)

val max_value : int
(** The largest encodable value: [2^62 - 1], or [max_int] where that is smaller.
*)

val size : int -> int
(** [size n] is the length in bytes of the shortest encoding of [n]. Raises
    [Invalid_argument] if [n] is negative or exceeds {!max_value}. *)

val add : Buffer.t -> int -> unit
(** [add b n] appends the shortest encoding of [n]. Raises [Invalid_argument] if
    [n] is negative or exceeds {!max_value}. *)

val add_sized : Buffer.t -> size:int -> int -> unit
(** [add_sized b ~size n] appends the encoding of [n] on exactly [size] bytes,
    which need not be the shortest. Raises [Invalid_argument] if [size] is not
    1, 2, 4, or 8, or if [n] does not fit. *)

val encode : int -> string
(** [encode n] is the shortest encoding of [n]. *)

val decode : string -> pos:int -> (int * int, Error.t) result
(** [decode s ~pos] reads one integer at [pos] and returns it with the position
    that follows it. Raises [Invalid_argument] if [pos] is outside [s]. *)
