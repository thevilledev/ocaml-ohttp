(** Oblivious HTTP over cohttp-eio.

    The client, relay, and gateway of {!Ohttp.Service}, as calls and server
    callbacks of cohttp-eio.

    {[
    Eio_main.run @@ fun env ->
    let client = Cohttp_eio.Client.make ~https:None (Eio.Stdenv.net env) in
    (* A gateway for one target. *)
    let gateway =
      Ohttp_cohttp_eio.Gateway.handler service
        (Ohttp_cohttp_eio.Target.forward client
           ~targets:[ ("example.com", Uri.of_string "http://127.0.0.1:8000") ])
    in
    Eio.Switch.run @@ fun sw ->
    let socket =
      Eio.Net.listen ~sw ~backlog:128 (Eio.Stdenv.net env)
        (`Tcp (Eio.Net.Ipaddr.V4.any, 8080))
    in
    Cohttp_eio.Server.run socket ~on_error:raise
      (Cohttp_eio.Server.make ~callback:(fun _conn -> gateway) ())
    ]}

    Contents are read in full: an encapsulated message is only opened when it is
    complete. Every request that the client, the relay, or the forwarding to a
    target makes runs in a switch of its own, which it leaves when the response
    has been read. *)

type handler = Http.Request.t -> Cohttp_eio.Body.t -> Cohttp_eio.Server.response
(** The callback of a cohttp-eio server, without its connection:
    [Cohttp_eio.Server.make ~callback:(fun _conn -> handler) ()]. *)

type forward = Bhttp.Request.t -> Bhttp.Response.t
(** How a gateway gets a response for a request that it has decapsulated: from a
    target, with {!Target.forward}, or in any other way. *)

(** A gateway: its key configurations, and the resource to which relays send
    Encapsulated Requests. *)
module Gateway : sig
  val handler :
    ?path:string ->
    ?now:(unit -> float) ->
    Ohttp.Service.Gateway.t ->
    forward ->
    handler
  (** Serves {!key_configs} at {!Ohttp.Http_binding.well_known_gateway_path},
      {!requests} at [path], ["/gateway"] by default, and a 404 elsewhere. *)

  val key_configs : Ohttp.Service.Gateway.t -> handler
  (** Answers with the key configurations, whatever the request. *)

  val requests :
    ?now:(unit -> float) -> Ohttp.Service.Gateway.t -> forward -> handler
  (** Answers an Encapsulated Request with an Encapsulated Response, through
      {!Ohttp.Service.Gateway.receive}. [now] is the clock of the replay check,
      [Unix.gettimeofday] by default; [fun () -> Eio.Time.now clock] is the
      clock of an Eio environment.

      An exception raised by [forward], other than a cancellation, is answered
      with a sealed 500: once the encapsulation is removed, every answer goes
      back sealed. *)
end

(** A client: fetches key configurations, and sends requests through a relay. *)
module Client : sig
  val key_configs :
    Cohttp_eio.Client.t ->
    Uri.t ->
    (Ohttp.Key_config.t list, Ohttp.Error.t) result
  (** Fetches the key configurations at a URI, such as a gateway's
      {!Ohttp.Http_binding.well_known_gateway_path}.

      This is a plain [GET]. A client must obtain key configurations in a way
      that authenticates the gateway and gives every client the same ones (RFC
      9458 Sections 6.1 and 7): over HTTPS from a source that it trusts, for
      one. *)

  val call :
    Cohttp_eio.Client.t ->
    rng:Mirage_crypto_rng.g ->
    ?preference:Ohttp.Suite.symmetric list ->
    ?framing:Bhttp.Framing.t ->
    ?padding:int ->
    ?date:bool ->
    ?now:(unit -> float) ->
    relay:Uri.t ->
    Ohttp.Key_config.t ->
    Bhttp.Request.t ->
    (Bhttp.Response.t, Ohttp.Error.t) result
  (** [call client ~rng ~relay config request] sends [request] to the gateway of
      [config] through the relay at [relay], and gives its response.

      With [date], [true] by default, the request carries a [date] field from
      [now], [Unix.gettimeofday] by default. If the gateway refuses it as too
      far from its clock, the request is sent once more with the gateway's time
      (see {!Ohttp.Service.Client.finish}).

      An answer that the gateway did not seal is an error, and so is a request
      that cannot be encapsulated. A failure to reach the relay is the exception
      of cohttp-eio. *)
end

(** A relay, which forwards to one gateway. *)
module Relay : sig
  val handler : Cohttp_eio.Client.t -> gateway:Uri.t -> handler
  (** Forwards every [POST] of an Encapsulated Request to [gateway], and its
      answer back, through {!Ohttp.Service.Relay}. Nothing else about the client
      goes to the gateway: not its address, and no field but the content type. A
      gateway that does not answer gives a 502. *)
end

(** Targets that the gateway reaches over HTTP. *)
module Target : sig
  val forward : Cohttp_eio.Client.t -> targets:(string * Uri.t) list -> forward
  (** Sends a request to the URI that [targets] gives for its authority (see
      {!Ohttp_cohttp.target}), and gives its response. A request for another
      authority gets a 403, and one that the target does not answer a 504. *)
end
