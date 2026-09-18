(** The client's side of an exchange (RFC 9458 Sections 4.3 and 4.4).

    {[
      let* encapsulated, context = Client.encapsulate ~rng config request in
      (* POST [encapsulated] to the relay as message/ohttp-req, and read the
         message/ohttp-res that comes back. *)
      let* response = Client.decapsulate context encapsulated_response in
    ]}

    Requests and responses are byte strings: Binary HTTP messages from {!Bhttp}
    unless the application has agreed on something else. *)

type response_context
(** What opens the response to one request. It holds a secret of that exchange
    and nothing of the HPKE context, so it is immutable and can be kept for as
    long as a response is awaited. *)

val encapsulate :
  rng:Mirage_crypto_rng.g ->
  ?labels:Encapsulation.labels ->
  ?preference:Suite.symmetric list ->
  Key_config.t ->
  string ->
  (string * response_context, Error.t) result
(** [encapsulate ~rng config request] is an Encapsulated Request for the gateway
    that published [config], and the context for its response. Every call sets
    up a fresh HPKE context, as RFC 9458 Section 6.1 requires.

    The algorithms are chosen by {!Key_config.select} with [preference].
    [labels] defaults to {!Encapsulation.bhttp_labels}. *)

type sender_setup =
  Hpke.Suite.encryption Hpke.Suite.t ->
  recipient:Hpke.Public_key.t ->
  info:string ->
  (Hpke.Suite.encryption Hpke.Rfc9180.sender_setup, Hpke.Error.t) result
(** How an HPKE sender context is established. {!encapsulate} uses
    [Hpke.Rfc9180.setup_base_sender ~rng]. *)

val encapsulate_with :
  setup:sender_setup ->
  ?labels:Encapsulation.labels ->
  ?preference:Suite.symmetric list ->
  Key_config.t ->
  string ->
  (string * response_context, Error.t) result
(** As {!encapsulate}, with the HPKE sender context set up by [setup]. Only the
    [hpke] package can build a sender context, so [setup] cannot weaken the
    exchange unless it comes from [hpke.for_testing], whose deterministic
    senders reproduce published test vectors. *)

val decapsulate : response_context -> string -> (string, Error.t) result
(** [decapsulate context encapsulated_response] is the response, or
    {!Error.Decapsulation_failed} if it is not the gateway's answer to the
    request that produced [context]. *)
