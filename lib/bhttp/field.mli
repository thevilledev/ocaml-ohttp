(** Field lines (RFC 9292 Section 3.6).

    A field is a name and a value. Decoded names are always lowercase, and
    encoders lowercase the names they are given, as HTTP field names are
    case-insensitive (RFC 9110 Section 5.1). The order of fields is preserved,
    as are repeated names. *)

type t = string * string

val pp : Format.formatter -> t -> unit
(** Print a field as [name: value], with bytes outside printable ASCII escaped.
*)

val lowercase : t list -> t list
(** Lowercase every field name, as decoding and encoding do. *)

val is_token : string -> bool
(** Whether a string is a token (RFC 9110 Section 5.6.2): one or more of the
    characters allowed in a field name or a method. *)

val validate_headers : t list -> (unit, Error.t) result
(** Check a header section. A name is a token (RFC 9110 Section 5.6.2),
    optionally prefixed with [:] to form a pseudo-field. A value holds no NUL,
    CR, or LF, and neither starts nor ends with a space or a tab (RFC 9113
    Section 8.2.1). The pseudo-fields [:method], [:scheme], [:authority],
    [:path], and [:status] are forbidden, as control data carries them. Other
    pseudo-fields must precede every regular field. *)

val validate_trailers : t list -> (unit, Error.t) result
(** As {!validate_headers}, but a trailer section holds no pseudo-field. *)

val get : string -> t list -> string option
(** [get name fields] is the value of the first field called [name], compared
    without regard to case. *)

val get_all : string -> t list -> string list
(** Every value of the fields called [name], in order. *)

val combined : string -> t list -> string option
(** Every value of the fields called [name], joined with [", "] (RFC 9110
    Section 5.3), or with ["; "] for [cookie] (RFC 9113 Section 8.2.3). [None]
    if there is no such field. *)

val is_connection_specific : string -> bool
(** Whether [name] is one of the connection-specific fields of RFC 9110 Section
    7.6.1: [connection], [proxy-connection], [keep-alive], [te],
    [transfer-encoding], and [upgrade]. *)

val without_connection_specific : t list -> t list
(** Remove the connection-specific fields, and every field that a [connection]
    field nominates. RFC 9292 Section 3.6 recommends this when a message is
    converted from HTTP/1.1, although such fields do not make a message invalid.
*)
