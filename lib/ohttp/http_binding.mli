(** How encapsulated messages travel over HTTP (RFC 9458 Section 5, and RFC 9540
    for finding a gateway).

    Nothing here performs I/O: these are the fields to send, and the checks to
    make on what comes back, for whichever HTTP library carries the messages.
    Fields are pairs of a lowercase name and a value. *)

val well_known_gateway_path : string
(** ["/.well-known/ohttp-gateway"]: where a gateway is found on the host of its
    target, and where its key configurations are fetched from (RFC 9540 Sections
    4 and 5). *)

module Client : sig
  val request_headers : (string * string) list
  (** The fields of the [POST] that carries an Encapsulated Request to a relay:
      its content type, and nothing else. Any other field must be one that the
      relay removes, and must not depend on the request (RFC 9458 Section 5). *)

  val check_response :
    status:int -> headers:(string * string) list -> (unit, Error.t) result
  (** Whether a relay's answer carries an Encapsulated Response: a 200 of type
      [message/ohttp-res]. Anything else was not sealed by the gateway, and may
      have been produced or changed by the relay, so its content deserves no
      trust. It can mean that the key configuration is out of date (RFC 9458
      Sections 5.2 and 5.3). *)

  val key_config_request_headers : (string * string) list
  (** The [accept] field of the [GET] that fetches key configurations. *)

  val check_key_config_response :
    status:int -> headers:(string * string) list -> (unit, Error.t) result
  (** Whether an answer carries [application/ohttp-keys], to be read with
      {!Key_config.decode_list}. Key configurations must be fetched in a way
      that authenticates the gateway, and the same ones must be given to every
      client (RFC 9458 Sections 6.1 and 7). *)
end

module Gateway : sig
  val check_request :
    meth:string -> headers:(string * string) list -> (unit, Error.t) result
  (** Whether a request carries an Encapsulated Request: a [POST] of type
      [message/ohttp-req]. *)

  val response_headers : (string * string) list
  (** The fields of the 200 that carries an Encapsulated Response: its content
      type, and [cache-control: no-store]. *)

  val key_config_response_headers : (string * string) list

  type error_response = {
    status : int;
    headers : (string * string) list;
    body : string;
  }

  val error_response : Error.t -> error_response
  (** The answer to a request whose encapsulation could not be removed, which
      therefore cannot be encapsulated itself (RFC 9458 Section 5.2).

      An unknown key, algorithms that the key does not offer, and a request that
      does not decrypt are answered with a 400 and the problem type
      [https://iana.org/assignments/http-problem-types#ohttp-key] (Section 5.3),
      since each of them is what a client with an outdated key configuration
      runs into. The three are not told apart. Other invalid requests get a 400,
      405, 413, or 415, and a failure not of the client's doing a 500. *)
end
