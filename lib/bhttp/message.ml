(* Binary HTTP messages of either kind (RFC 9292 Section 3). *)

type t = Request of Request.t | Response of Response.t

let encode ?framing ?padding ?truncate = function
  | Request r -> Request.encode ?framing ?padding ?truncate r
  | Response r -> Response.encode ?framing ?padding ?truncate r

let decode message =
  match Framing.peek message with
  | Error _ as e -> e
  | Ok (Framing.Request, _) ->
      Result.map (fun r -> Request r) (Request.decode message)
  | Ok (Framing.Response, _) ->
      Result.map (fun r -> Response r) (Response.decode message)

let equal a b =
  match (a, b) with
  | Request a, Request b -> Request.equal a b
  | Response a, Response b -> Response.equal a b
  | Request _, Response _ | Response _, Request _ -> false

let pp fmt = function
  | Request r -> Request.pp fmt r
  | Response r -> Response.pp fmt r
