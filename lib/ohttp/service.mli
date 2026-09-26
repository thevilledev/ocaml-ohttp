(** The client, relay, and gateway of RFC 9458 Section 5, as steps from HTTP
    messages to HTTP messages.

    Nothing here performs I/O. Each party is a function from what it received to
    what it sends, and the HTTP library in between does the sending: this is
    what the adapter packages [ohttp-cohttp-lwt], [ohttp-cohttp-eio], and
    [ohttp-dream] wrap, and what an adapter for another library wraps too.

    A message is its status, where it has one, its fields, and its content. The
    fields are pairs of a lowercase name and a value, and the content is read in
    full: an encapsulated message is only opened when it is complete. *)

type request = { headers : (string * string) list; body : string }
(** A request to send: the method and the URI are the party's to choose, and are
    given with each step. *)

type response = Http_binding.Gateway.error_response = {
  status : int;
  headers : (string * string) list;
  body : string;
}

(** A client: sends an Encapsulated Request to a relay, and opens the
    Encapsulated Response that comes back. *)
module Client : sig
  val key_configs :
    status:int ->
    headers:(string * string) list ->
    string ->
    (Key_config.t list, Error.t) result
  (** The key configurations in the answer to a [GET] sent with
      {!Http_binding.Client.key_config_request_headers}.

      Key configurations must be fetched in a way that authenticates the
      gateway, and the same ones must be given to every client (RFC 9458
      Sections 6.1 and 7): that is up to the application, and not something that
      a [GET] shows. *)

  type exchange
  (** A request that has been sent, and what is needed to open its response. *)

  val start :
    rng:Mirage_crypto_rng.g ->
    ?preference:Suite.symmetric list ->
    ?framing:Bhttp.Framing.t ->
    ?padding:int ->
    ?now:float ->
    Key_config.t ->
    Bhttp.Request.t ->
    (request * exchange, Error.t) result
  (** The [POST] to send to the relay for [request], and the exchange that opens
      its response.

      With [now], in seconds since the epoch, the request carries a [date] field
      for that time, in place of any it had. A gateway that checks for replay
      may refuse a request without one ({!Replay}), and tells a client whose
      date is too far from its clock what its time is: see {!finish}.

      The other arguments are those of {!Http_message.encapsulate_request}. *)

  type outcome =
    | Response of Bhttp.Response.t  (** The gateway's answer. *)
    | Retry of request * exchange
        (** The gateway refused the date of the request, and said what its time
            is. Send this [POST] in place of the first: the same request,
            encapsulated anew, with the gateway's time as its date (RFC 9458
            Section 6.5). It is given at most once for each call of {!start},
            and only when it had [now]. *)

  val finish :
    exchange ->
    status:int ->
    headers:(string * string) list ->
    string ->
    (outcome, Error.t) result
  (** What the relay's answer means. An answer that is not a 200 of type
      [message/ohttp-res] is an error: it was not sealed by the gateway, and its
      content deserves no trust (see {!Http_binding.Client.check_response}). *)
end

(** A relay: passes an Encapsulated Request on to one gateway, and its answer
    back, and nothing that identifies the client (RFC 9458 Sections 5 and 6.2).
    It cannot read what it carries. *)
module Relay : sig
  val request :
    meth:string ->
    headers:(string * string) list ->
    string ->
    (request, response) result
  (** The [POST] to send to the gateway for a client's request: its content, and
      its content type and no other field. For anything other than a [POST] of
      type [message/ohttp-req], the answer to give the client instead: a 405 or
      a 415. A relay that forwarded anything would be an open proxy. *)

  val response :
    status:int -> headers:(string * string) list -> string -> response
  (** The answer to give the client for the gateway's: its status and content,
      with only the fields that describe them: [content-type], [cache-control],
      and, for a 405, [allow]. *)

  val unreachable : response
  (** The answer to give the client when the gateway does not answer: a 502. *)
end

(** A gateway: serves its key configurations, and answers each Encapsulated
    Request with an Encapsulated Response. *)
module Gateway : sig
  type t

  val create :
    rng:Mirage_crypto_rng.g ->
    ?replay:Replay.t ->
    ?checks_replay:(Bhttp.Request.t -> bool) ->
    ?framing:Bhttp.Framing.t ->
    ?padding:int ->
    Gateway.t ->
    t
  (** A gateway with the keys of a {!Ohttp.Gateway.t}.

      With [replay], every request for which [checks_replay] holds is checked
      with {!Replay.check}, and a rejected one is answered, sealed, with
      {!Replay.rejection_response}. [checks_replay] holds for every request by
      default; a gateway that trusts its targets to be idempotent for some
      requests, such as [GET], can leave those out (RFC 9458 Section 6.5).

      [rng] seals the responses, which [framing] and [padding] shape as with
      {!Http_message.encapsulate_response}. *)

  val key_configs : t -> response
  (** The answer to a [GET] of {!Http_binding.well_known_gateway_path}: the key
      configurations, in the [application/ohttp-keys] format. *)

  type step =
    | Respond of response
        (** The answer to give, which needs nothing from a target. *)
    | Forward of Bhttp.Request.t * (Bhttp.Response.t -> response)
        (** The request to answer, and what seals its answer. The gateway gets a
            response for the request, from a target or of its own making, and
            gives what the function returns for it. A request that cannot be
            answered, because no target is known for its authority or none
            answers, is answered with a response of the gateway's making too,
            such as a 403, 502, or 504, and sealed like any other (RFC 9458
            Section 5). *)

  val target :
    targets:(string * string) list ->
    Bhttp.Request.t ->
    (string, Bhttp.Response.t) result
  (** [target ~targets request] is the URI to which a gateway sends [request].
      [targets] maps each authority that the gateway serves to the URI at which
      it reaches that target, such as ["http://127.0.0.1:8000"], and the
      request's path is appended to it.

      A request for any other authority is answered with a 403, and one whose
      path does not start with ["/"] with a 400: a gateway that sent requests
      wherever its clients asked would be an open proxy. *)

  val receive :
    t ->
    now:float ->
    meth:string ->
    headers:(string * string) list ->
    string ->
    step
  (** [receive gateway ~now ~meth ~headers content] is the step for a request to
      the gateway's resource. [now] is the time in seconds since the epoch, for
      the replay check.

      A request whose encapsulation cannot be removed is answered in the clear
      with {!Http_binding.Gateway.val-error_response}. Once it is removed, every
      answer is sealed: a request that does not decode, that expects
      [100-continue], or that fails the replay check is answered with a
      [Respond] whose content is an Encapsulated Response. *)
end
