(** Oblivious HTTP over Piaf.

    The client, relay, and gateway of {!Ohttp.Service}, as calls and server
    handlers of Piaf, over HTTP/1.1 or HTTP/2.

    {[
    Eio_main.run @@ fun env ->
    Eio.Switch.run @@ fun sw ->
    (* A gateway for one target. Build each handler once: the requests in flight
       are counted in [service]. *)
    let gateway =
      Ohttp_piaf.Gateway.handler service
        (Ohttp_piaf.Target.forward env
           ~targets:[ ("example.com", Uri.of_string "http://127.0.0.1:8000") ])
    in
    let config =
      Piaf.Server.Config.create (`Tcp (Eio.Net.Ipaddr.V4.any, 8080))
    in
    ignore
      (Piaf.Server.Command.start ~sw env (Piaf.Server.create ~config gateway))
    ]}

    Contents are read in full: an encapsulated message is only opened when it is
    complete. Each read is limited (see
    {!Ohttp.Service.default_max_request_size} and
    {!Ohttp.Service.default_max_response_size}): what is longer is refused as
    soon as its declared length or what has arrived of it passes the limit, and
    the rest of it is read without being kept, since Piaf is done with a message
    only once its body has been read. Every request that the client, the relay,
    or the forwarding to a target makes is a [Piaf.Client.Oneshot] request, in a
    switch of its own that it leaves when the response has been read. *)

type 'ctx handler = 'ctx Piaf.Server.ctx -> Piaf.Response.t
(** A handler of a Piaf server, for any context:
    [Piaf.Server.create ~config handler]. *)

type forward = Bhttp.Request.t -> Bhttp.Response.t
(** How a gateway gets a response for a request that it has decapsulated: from a
    target, with {!Target.forward}, or in any other way. *)

type error = [ `Ohttp of Ohttp.Error.t | `Piaf of Piaf.Error.t ]
(** A client's failure: of the protocol, or of the transport. *)

val pp_error : Format.formatter -> error -> unit

(** A gateway: its key configurations, and the resource to which relays send
    Encapsulated Requests. *)
module Gateway : sig
  val handler :
    ?path:string ->
    ?now:(unit -> float) ->
    Ohttp.Service.Gateway.t ->
    forward ->
    'ctx handler
  (** Serves {!key_configs} at a [GET] of
      {!Ohttp.Http_binding.well_known_gateway_path}, {!requests} at [path],
      ["/gateway"] by default, and a 404 elsewhere. *)

  val key_configs : Ohttp.Service.Gateway.t -> 'ctx handler
  (** Answers with the key configurations, whatever the request. *)

  val requests :
    ?now:(unit -> float) -> Ohttp.Service.Gateway.t -> forward -> 'ctx handler
  (** Answers an Encapsulated Request with an Encapsulated Response, through
      {!Ohttp.Service.Gateway.receive}. [now] is the clock of the replay check,
      [Unix.gettimeofday] by default; [fun () -> Eio.Time.now clock] is the
      clock of an Eio environment.

      A request longer than the [max_request_size] of [service] is answered with
      {!Ohttp.Service.content_too_large}, and one that arrives while
      [max_in_flight] are being answered with {!Ohttp.Service.busy}, both in the
      clear.

      An exception raised by [forward], other than a cancellation, is answered
      with a sealed 500: once the encapsulation is removed, every answer goes
      back sealed. *)
end

(** A client: fetches key configurations, and sends requests through a relay. *)
module Client : sig
  val key_configs :
    ?config:Piaf.Config.t ->
    ?max_response_size:int ->
    Eio_unix.Stdenv.base ->
    Uri.t ->
    (Ohttp.Key_config.t list, error) result
  (** Fetches the key configurations at a URI, such as a gateway's
      {!Ohttp.Http_binding.well_known_gateway_path}.

      This is a plain [GET]. A client must obtain key configurations in a way
      that authenticates the gateway and gives every client the same ones (RFC
      9458 Sections 6.1 and 7): over HTTPS from a source that it trusts, for
      one.

      An answer longer than [max_response_size],
      {!Ohttp.Service.default_max_response_size} by default, is
      [`Ohttp Content_too_large]. *)

  val call :
    ?config:Piaf.Config.t ->
    ?max_response_size:int ->
    Eio_unix.Stdenv.base ->
    rng:Mirage_crypto_rng.g ->
    ?preference:Ohttp.Suite.symmetric list ->
    ?framing:Bhttp.Framing.t ->
    ?padding:int ->
    ?date:bool ->
    ?now:(unit -> float) ->
    relay:Uri.t ->
    Ohttp.Key_config.t ->
    Bhttp.Request.t ->
    (Bhttp.Response.t, error) result
  (** [call env ~rng ~relay config request] sends [request] to the gateway of
      [config] through the relay at [relay], and gives its response.

      With [date], [true] by default, the request carries a [date] field from
      [now], [Unix.gettimeofday] by default. If the gateway refuses it as too
      far from its clock, the request is sent once more with the gateway's time
      (see {!Ohttp.Service.Client.finish}).

      An answer that the gateway did not seal is an error, and so is a request
      that cannot be encapsulated, and an answer longer than
      [max_response_size], {!Ohttp.Service.default_max_response_size} by default
      ([`Ohttp Content_too_large]). *)
end

(** A relay, which forwards to one gateway. *)
module Relay : sig
  val handler :
    ?config:Piaf.Config.t ->
    Eio_unix.Stdenv.base ->
    Ohttp.Service.Relay.t ->
    gateway:Uri.t ->
    'ctx handler
  (** [handler env relay ~gateway] forwards every [POST] of an Encapsulated
      Request to [gateway], and its answer back, through {!Ohttp.Service.Relay}.
      Nothing else about the client goes to the gateway: not its address, and no
      field but the content type. A gateway that does not answer gives a 502,
      and so does one whose answer is longer than the [max_response_size] of
      [relay].

      A request longer than the [max_request_size] of [relay] is answered with
      {!Ohttp.Service.content_too_large}, and one that arrives while
      [max_in_flight] are being forwarded with {!Ohttp.Service.busy}. The
      requests in flight are counted in [relay], which is meant to serve every
      request. *)
end

(** Targets that the gateway reaches over HTTP. *)
module Target : sig
  val forward :
    ?config:Piaf.Config.t ->
    ?max_response_size:int ->
    Eio_unix.Stdenv.base ->
    targets:(string * Uri.t) list ->
    forward
  (** Sends a request to the URI that [targets] gives for its authority (see
      {!Ohttp.Service.Gateway.target}), and gives its response. A request for
      another authority gets a 403, one that the target does not answer a 504,
      and one whose answer is longer than [max_response_size],
      {!Ohttp.Service.default_max_response_size} by default, a 502. *)
end
