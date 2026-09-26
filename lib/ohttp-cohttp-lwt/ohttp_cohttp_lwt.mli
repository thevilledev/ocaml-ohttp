(** Oblivious HTTP over cohttp-lwt.

    The client, relay, and gateway of {!Ohttp.Service}, as calls and server
    callbacks of cohttp-lwt. The client, the relay, and the forwarding to
    targets make requests of their own, with any client of cohttp-lwt: that of
    [cohttp-lwt-unix], or of [cohttp-lwt-jsoo], or of a MirageOS unikernel.

    {[
    module Ohttp_client = Ohttp_cohttp_lwt.Make (Cohttp_lwt_unix.Client)

    (* A gateway for one target, over cohttp-lwt-unix. *)
    let gateway =
      Ohttp_cohttp_lwt.Gateway.handler service
        (Ohttp_client.Target.forward
           ~targets:[ ("example.com", Uri.of_string "https://example.com") ])

    let () =
      Lwt_main.run
        (Cohttp_lwt_unix.Server.create
           (Cohttp_lwt_unix.Server.make ~callback:(fun _conn -> gateway) ()))
    ]}

    Contents are read in full: an encapsulated message is only opened when it is
    complete. *)

type handler =
  Http.Request.t ->
  Cohttp_lwt.Body.t ->
  (Http.Response.t * Cohttp_lwt.Body.t) Lwt.t
(** The callback of a cohttp-lwt server, without its connection:
    [Cohttp_lwt_unix.Server.make ~callback:(fun _conn -> handler) ()]. *)

type forward = Bhttp.Request.t -> Bhttp.Response.t Lwt.t
(** How a gateway gets a response for a request that it has decapsulated: from a
    target, with {!Make.Target.forward}, from an application in the same
    process, with {!Target.of_handler}, or in any other way. *)

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
      [Unix.gettimeofday] by default.

      An exception raised by [forward] is answered with a sealed 500: once the
      encapsulation is removed, every answer goes back sealed. *)
end

(** Targets that live in the same process as the gateway. *)
module Target : sig
  val of_handler : handler -> forward
  (** [of_handler handler] answers a request by calling [handler], as though
      [handler] had received it from a client: a gateway in front of an
      application that already serves cohttp-lwt. *)
end

module Make (Http_client : Cohttp_lwt.S.Client) : sig
  (** A client: fetches key configurations, and sends requests through a relay.
  *)
  module Client : sig
    val key_configs :
      ?ctx:Http_client.ctx ->
      Uri.t ->
      (Ohttp.Key_config.t list, Ohttp.Error.t) result Lwt.t
    (** Fetches the key configurations at a URI, such as a gateway's
        {!Ohttp.Http_binding.well_known_gateway_path}.

        This is a plain [GET]. A client must obtain key configurations in a way
        that authenticates the gateway and gives every client the same ones (RFC
        9458 Sections 6.1 and 7): over HTTPS from a source that it trusts, for
        one. *)

    val call :
      ?ctx:Http_client.ctx ->
      rng:Mirage_crypto_rng.g ->
      ?preference:Ohttp.Suite.symmetric list ->
      ?framing:Bhttp.Framing.t ->
      ?padding:int ->
      ?date:bool ->
      ?now:(unit -> float) ->
      relay:Uri.t ->
      Ohttp.Key_config.t ->
      Bhttp.Request.t ->
      (Bhttp.Response.t, Ohttp.Error.t) result Lwt.t
    (** [call ~rng ~relay config request] sends [request] to the gateway of
        [config] through the relay at [relay], and gives its response.

        With [date], [true] by default, the request carries a [date] field from
        [now], [Unix.gettimeofday] by default. If the gateway refuses it as too
        far from its clock, the request is sent once more with the gateway's
        time (see {!Ohttp.Service.Client.finish}).

        An answer that the gateway did not seal is an error, and so is a request
        that cannot be encapsulated. A failure to reach the relay is the
        exception of [Http_client]. *)
  end

  (** A relay, which forwards to one gateway. *)
  module Relay : sig
    val handler : ?ctx:Http_client.ctx -> gateway:Uri.t -> handler
    (** Forwards every [POST] of an Encapsulated Request to [gateway], and its
        answer back, through {!Ohttp.Service.Relay}. Nothing else about the
        client goes to the gateway: not its address, and no field but the
        content type. A gateway that does not answer gives a 502.

        A relay that serves more than this mounts the handler at the path of its
        choosing. *)
  end

  (** Targets that the gateway reaches over HTTP. *)
  module Target : sig
    val forward :
      ?ctx:Http_client.ctx -> targets:(string * Uri.t) list -> forward
    (** Sends a request to the URI that [targets] gives for its authority (see
        {!Ohttp_cohttp.target}), and gives its response. A request for another
        authority gets a 403, and one that the target does not answer a 504. *)
  end
end
