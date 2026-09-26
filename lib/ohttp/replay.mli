(** Defences against replayed requests (RFC 9458 Section 6.5).

    A relay, or anyone who sees an Encapsulated Request, can send it to the
    gateway again, and the gateway cannot tell the copy from the original. A
    gateway that serves requests that are not idempotent defends itself in two
    ways, which this module combines in {!check}:

    - it remembers the encapsulated keys of the requests it has accepted
      recently, and refuses one it has seen, which is what {!Cache} does;
    - it asks clients to send a [date] field, and refuses a request whose date
      is too far from its own clock, so that it only needs to remember keys for
      as long as a date is accepted.

    Nothing here reads a clock: every function that needs the time takes it as
    [now], in seconds since the Unix epoch, as [Unix.gettimeofday] gives it. *)

(** HTTP dates (RFC 9110 Section 5.6.7). *)
module Date : sig
  val parse : ?now:float -> string -> float option
  (** [parse s] is the time that [s] names, in seconds since the epoch, if it is
      a date in one of the three formats that a recipient must accept: the
      IMF-fixdate ["Sun, 06 Nov 1994 08:49:37 GMT"], and the obsolete RFC 850
      ["Sunday, 06-Nov-94 08:49:37 GMT"] and asctime
      ["Sun Nov  6 08:49:37 1994"]. The day of the week must be the right one.

      [now] resolves the two-digit year of the RFC 850 format: a date more than
      50 years after [now] is taken to be a century earlier. Without it, years
      from 70 are taken to be in the 1900s and the others in the 2000s. *)

  val format : float -> string
  (** [format t] is the IMF-fixdate of [t], rounded down to the second. Raises
      [Invalid_argument] outside the years 0 to 9999. *)
end

val date_field : now:float -> Bhttp.Field.t
(** The [date] field that a client adds to its request. A client that was told
    that its clock is wrong adds the offset that {!date_of_problem} lets it
    compute. *)

(** Encapsulated keys of recent requests. *)
module Cache : sig
  type t

  val create : window:float -> capacity:int -> t
  (** [create ~window ~capacity] remembers a key for [window] seconds after it
      was added, and at most [capacity] keys at once. Raises [Invalid_argument]
      unless both are positive.

      With a date check that accepts dates within [tolerance] seconds of the
      gateway's clock, [window] must be at least [2 *. tolerance]: a request
      stays acceptable for that long. {!Replay.create} does this. *)

  val add : t -> now:float -> string -> [ `New | `Replayed | `Full ]
  (** [add cache ~now key] forgets what has expired, then remembers [key] and
      returns [`New], unless it is already remembered ([`Replayed]), or the
      cache holds [capacity] keys ([`Full]). The two refusals leave the cache as
      it was. A full cache must be treated as a refusal: letting a request
      through without remembering it would let it be replayed.

      Only a digest of [key] is kept, so that the cache does not grow with the
      KEM: the encapsulated key of X-Wing is 1120 bytes. *)

  val length : t -> int
  (** How many keys are remembered, including those that have expired since the
      last {!add}. *)
end

type t
(** What a gateway remembers: a {!Cache} and the date policy that bounds it. *)

val create : ?require_date:bool -> tolerance:float -> capacity:int -> unit -> t
(** [create ~tolerance ~capacity ()] accepts dates within [tolerance] seconds of
    the gateway's clock, and remembers the keys of up to [capacity] requests for
    [2 *. tolerance] seconds.

    [require_date] is [true] by default: a request without a valid [date] field
    is refused. If it is [false], such a request is accepted and its key
    remembered like any other, but it can be replayed once the key has been
    forgotten. Raises [Invalid_argument] unless [tolerance] and [capacity] are
    positive. *)

type rejection =
  | Date_missing  (** The request has no valid [date] field. *)
  | Date_skewed of float
      (** The request's date minus the gateway's clock, in seconds, is beyond
          the tolerance. *)
  | Replayed  (** The encapsulated key has been accepted before. *)
  | Full  (** The cache is full, so the request cannot be remembered. *)

val check :
  t -> now:float -> enc:string -> Bhttp.Request.t -> (unit, rejection) result
(** [check t ~now ~enc request] decides whether to serve a request that has been
    decapsulated, and remembers its encapsulated key [enc] if so. [enc] is
    {!Gateway.encapsulated_key} of the request's context, or
    {!Chunked.Gateway.encapsulated_key}.

    Call it only after decapsulation succeeds: a key that did not decrypt a
    request proves nothing, and remembering it would let anyone fill the cache.
    A rejected request is still answered through its context, with
    {!rejection_response}. *)

val rejection_response : now:float -> rejection -> Bhttp.Response.t
(** The response to encapsulate for a rejected request:
    - for a missing or skewed date, a 400 with the problem type
      [https://iana.org/assignments/http-problem-types#date] and the gateway's
      [date] field, from which the client can correct its clock and retry (RFC
      9458 Section 6.5);
    - for a replay, a 400;
    - for a full cache, a 503. *)

val date_of_problem : Bhttp.Response.t -> float option
(** [date_of_problem response] is the gateway's time, if [response] is its
    report that the request's date was not acceptable. A client may retry once
    with a [date] field corrected by the difference between this time and its
    own clock. It must encapsulate the request anew: sending the same
    Encapsulated Request again would be refused as a replay, and would let the
    gateway link the two. *)

val pp_rejection : Format.formatter -> rejection -> unit
