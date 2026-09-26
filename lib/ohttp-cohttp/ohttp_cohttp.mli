(** Between the messages of the [http] package and those of {!Bhttp}.

    cohttp 6 takes its types from the [http] package, and so do cohttp-lwt and
    cohttp-eio: this is what the adapters [ohttp-cohttp-lwt] and
    [ohttp-cohttp-eio] share, and what an adapter for another library over the
    same types can use. *)

(** {1 Fields} *)

val fields : Http.Header.t -> (string * string) list
(** The fields in order, with lowercase names, and without those that are
    specific to a connection ({!Bhttp.Field.without_connection_specific}): they
    describe one hop, and mean nothing inside an encapsulated message. *)

val header : (string * string) list -> Http.Header.t

(** {1 Messages} *)

val request_to_bhttp :
  scheme:string -> Http.Request.t -> string -> Bhttp.Request.t
(** [request_to_bhttp ~scheme request content] is a request that a server
    received, as a Binary HTTP request. HTTP/1.1 gives the authority in the
    [host] field, which moves into the control data. *)

val request_of_bhttp : Bhttp.Request.t -> Http.Request.t
(** The method, target, and fields of a Binary HTTP request, whose content is
    sent with it. The authority becomes the [host] field, unless the request has
    one. *)

val request_headers : Bhttp.Request.t -> Http.Header.t
(** The fields of {!request_of_bhttp}. *)

val response_to_bhttp : Http.Response.t -> string -> Bhttp.Response.t
(** [response_to_bhttp response content] is a response that a client received,
    as a Binary HTTP response. *)

(** {1 Resources} *)

val path : Http.Request.t -> string
(** The path of the request's target, without its query. *)

val gateway_resource :
  ?path:string -> Http.Request.t -> [ `Key_configs | `Requests | `Not_found ]
(** Which resource of a gateway a request is for: a [GET] of
    {!Ohttp.Http_binding.well_known_gateway_path} is for its key configurations,
    anything at [path], ["/gateway"] by default, is for its Encapsulated
    Requests, and anything else is for neither. *)

val target :
  targets:(string * Uri.t) list ->
  Bhttp.Request.t ->
  (Uri.t, Bhttp.Response.t) result
(** {!Ohttp.Service.Gateway.target}, with URIs: where a gateway sends a request
    that it has decapsulated, or the response to give instead. *)
