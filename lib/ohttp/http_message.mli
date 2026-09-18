(** Exchanges of Binary HTTP messages: {!Client} and {!Gateway} with the
    encoding and decoding of {!Bhttp} around them, and the rules that RFC 9458
    adds for what is encapsulated. *)

val encapsulate_request :
  rng:Mirage_crypto_rng.g ->
  ?preference:Suite.symmetric list ->
  ?framing:Bhttp.Framing.t ->
  ?padding:int ->
  Key_config.t ->
  Bhttp.Request.t ->
  (string * Client.response_context, Error.t) result
(** An Encapsulated Request for a gateway, and the context for its response.

    [padding] appends zero bytes to the message before it is sealed, which hides
    its length from the relay and from the network (RFC 9458 Section 6.2.3).
    Returns {!Error.Continue_expectation} for a request that expects
    [100-continue], and {!Error.Bhttp} for an invalid one. *)

val decapsulate_response :
  Client.response_context -> string -> (Bhttp.Response.t, Error.t) result

val decapsulate_request :
  Gateway.t ->
  string ->
  ( (Bhttp.Request.t, Bhttp.Response.t) result * Gateway.response_context,
    Error.t )
  result
(** The request inside an Encapsulated Request, and the context for its
    response.

    RFC 9458 Section 5.2 tells two kinds of failure apart, and so does the
    result. If the encapsulation cannot be removed, the outer result is an
    error, to be answered without encapsulation: see
    {!Http_binding.Gateway.val-error_response}. If it can, there is a context,
    and whatever follows must be answered through it, including failures. A
    request that does not decode, or that expects [100-continue] (Section 5.1),
    is therefore given as [Error response]: the response to encapsulate in place
    of one from the target. *)

val encapsulate_response :
  rng:Mirage_crypto_rng.g ->
  ?framing:Bhttp.Framing.t ->
  ?padding:int ->
  Gateway.response_context ->
  Bhttp.Response.t ->
  (string, Error.t) result
(** An Encapsulated Response. A gateway that gets no response from the target
    encapsulates one of its own, such as a 504 (RFC 9458 Section 5). *)

val expects_continue : Bhttp.Request.t -> bool
(** Whether a request has an [expect] field that lists [100-continue]. *)
