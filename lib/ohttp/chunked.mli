(** Chunked Oblivious HTTP (draft-ietf-ohai-chunked-ohttp-08).

    {b Experimental.} The draft is in the RFC Editor's queue, so its wire format
    is settled, but this interface may still change, and only some
    implementations provide the chunked variant.

    A chunked message is sealed and opened piece by piece, so that a request or
    a response can be produced and consumed before all of it exists. The header
    and the key schedule are those of {!Client} and {!Gateway} under other
    labels; what follows the header is a sequence of chunks, each sealed on its
    own and preceded by its length. The last chunk has a length of zero, runs to
    the end of the stream, and is sealed with the additional data ["final"], so
    that a message cut short cannot pass for a complete one.

    Nothing here performs I/O. A {!Sender} turns pieces of a message into bytes
    to write, and a {!Receiver} turns bytes read, split in any way at all, into
    pieces of the message.

    A chunked request is sent as {!Media_type.ohttp_chunked_request} and must be
    answered with {!Media_type.ohttp_chunked_response}. Both should carry the
    field [incremental: ?1], so that intermediaries forward them as they arrive.
    A client that is set up for chunked messages should not fall back to plain
    ones (Section 7 of the draft): a gateway that refuses one kind and accepts
    the other could otherwise tell clients apart. *)

val labels : Encapsulation.labels
(** ["message/bhttp chunked request"] and ["message/bhttp chunked response"]. *)

val max_chunk_size : int
(** 16384. Every receiver accepts a chunk that holds this much data before it is
    sealed, and a sender should produce no larger one unless it knows that its
    peer accepts it (Section 3 of the draft). *)

val chunk_nonce : nonce:string -> counter:int -> string
(** The nonce of the response chunk number [counter], counting from 0: the
    response nonce of {!Encapsulation.val-response_keys} XORed with the counter
    as a big-endian integer of the same length (Section 6.2 of the draft). *)

module Sender : sig
  type t
  (** One direction of one exchange, to be used from a single thread. *)

  val chunk : t -> string -> (string, Error.t) result
  (** [chunk sender data] is a non-final chunk, ready to write: its length and
      then [data], sealed. Returns {!Error.Chunk_too_large} if [data] is longer
      than the sender's limit. Raises [Invalid_argument] if [data] is empty,
      which only the final chunk may be, or if the final chunk has already been
      produced. *)

  val final : t -> string -> (string, Error.t) result
  (** [final sender data] is the final chunk, after which the stream must end.
      [data] may be empty. *)
end

module Receiver : sig
  type t
  (** One direction of one exchange, to be used from a single thread. Once an
      error is returned, every later call returns it again. *)

  val feed : t -> string -> (string list, Error.t) result
  (** [feed receiver bytes] takes the next bytes of the stream, however the
      transport happened to split them, and returns the data of every non-final
      chunk that they complete, in order.

      Data that is returned is authentic and in order, but the message it
      belongs to may yet turn out to be truncated. Acting on it before {!finish}
      succeeds is the early processing that Section 7.1 of the draft warns
      about. *)

  val finish : t -> (string, Error.t) result
  (** [finish receiver] declares the end of the stream and returns the data of
      the final chunk. It fails with {!Error.Truncated_message} if the stream
      ended before a final chunk, and with {!Error.Decapsulation_failed} if what
      claims to be the final chunk is not. Raises [Invalid_argument] if called
      twice. *)
end

module Client : sig
  type response_context

  val request :
    rng:Mirage_crypto_rng.g ->
    ?preference:Suite.symmetric list ->
    ?max_chunk_size:int ->
    Key_config.t ->
    (string * Sender.t * response_context, Error.t) result
  (** [request ~rng config] starts a chunked request: the header to write first,
      the sender for the chunks that follow it, and the context for the
      response. *)

  val request_with :
    setup:Client.sender_setup ->
    ?preference:Suite.symmetric list ->
    ?max_chunk_size:int ->
    Key_config.t ->
    (string * Sender.t * response_context, Error.t) result
  (** As {!request}, with the HPKE sender context set up as
      {!Ohttp.Client.encapsulate_with} describes. *)

  val response : ?max_chunk_size:int -> response_context -> Receiver.t
  (** The receiver for the response, which may start to arrive before the
      request has been sent in full. *)
end

module Gateway : sig
  type request

  val request : ?max_chunk_size:int -> Gateway.t -> request
  (** Start to receive a chunked request for one of the gateway's keys. *)

  val receiver : request -> Receiver.t
  (** The receiver for the request. Its errors are those of
      {!Ohttp.Gateway.decapsulate}. *)

  val response :
    rng:Mirage_crypto_rng.g ->
    ?max_chunk_size:int ->
    request ->
    (string * Sender.t, Error.t) result
  (** [response ~rng request] starts the response: the response nonce to write
      first, and the sender for the chunks that follow it. The request need not
      be complete, but its header must have been received; otherwise this
      returns {!Error.Truncated_message}. It may be called once. *)
end

(** {1 Building blocks} *)

val response_receiver :
  ?max_chunk_size:int -> Suite.t -> enc:string -> secret:string -> Receiver.t
(** The receiver for a response, from the encapsulated key of its request and
    the secret that the HPKE context exports for the response label. Like the
    functions of {!Encapsulation}, it takes the secret as an argument, so that a
    recorded exchange can be opened from the gateway's side of the context.
    Applications should use {!Client.response}. *)

(** {1 Whole messages} *)

val seal_all : ?chunk_size:int -> Sender.t -> string -> (string, Error.t) result
(** [seal_all sender message] is every chunk of a message that is already
    complete: pieces of [chunk_size] bytes, {!max_chunk_size} by default, and
    whatever remains, which may be nothing, as the final chunk. *)

val open_all : Receiver.t -> string -> (string, Error.t) result
(** [open_all receiver bytes] is the message of a stream that is already
    complete. *)
