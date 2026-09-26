(* The client, relay, and gateway of RFC 9458 Section 5, as steps from HTTP
   messages to HTTP messages. *)

type request = { headers : (string * string) list; body : string }

type response = Http_binding.Gateway.error_response = {
  status : int;
  headers : (string * string) list;
  body : string;
}

let default_max_request_size = 1 lsl 20
let default_max_response_size = 8 lsl 20
let default_max_in_flight = 256

let limit name ~default = function
  | None -> default
  | Some n when n > 0 -> n
  | Some _ -> invalid_arg ("Ohttp.Service: " ^ name ^ " must be positive")

(* Only digits: a value that int_of_string would read otherwise, such as "0x10"
   or "-1", is left to the count of what is read. *)
let exceeds ~max_size headers =
  List.exists
    (fun (name, value) ->
      String.lowercase_ascii name = "content-length"
      &&
      let value = String.trim value in
      value <> ""
      && String.for_all (function '0' .. '9' -> true | _ -> false) value
      && (String.length value > 18 || int_of_string value > max_size))
    headers

let plain ?(headers = []) status = { status; headers; body = "" }
let content_too_large = plain 413
let busy = plain ~headers:[ ("retry-after", "1") ] 503

(* The requests that a party is handling, which may run on several domains. *)
module In_flight = struct
  type t = { max : int; count : int Atomic.t }

  let create max = { max; count = Atomic.make 0 }

  let admit t =
    Atomic.fetch_and_add t.count 1 < t.max
    ||
    (Atomic.decr t.count;
     false)

  let release t = Atomic.decr t.count
end

module Client = struct
  let key_configs ~status ~headers content =
    Result.bind (Http_binding.Client.check_key_config_response ~status ~headers)
      (fun () -> Key_config.decode_list content)

  type exchange = {
    rng : Mirage_crypto_rng.g;
    preference : Suite.symmetric list option;
    framing : Bhttp.Framing.t option;
    padding : int option;
    config : Key_config.t;
    request : Bhttp.Request.t;
    (* Whether the request carried a date, and so may be sent once more with the
       gateway's. *)
    may_retry : bool;
    context : Client.response_context;
  }

  let send ~rng ?preference ?framing ?padding ~now ~may_retry config
      (request : Bhttp.Request.t) =
    let dated =
      match now with
      | None -> request
      | Some now ->
          {
            request with
            headers =
              Replay.date_field ~now
              :: List.filter
                   (fun (name, _) ->
                     not (String.equal (String.lowercase_ascii name) "date"))
                   request.headers;
          }
    in
    Result.map
      (fun (body, context) ->
        ( { headers = Http_binding.Client.request_headers; body },
          {
            rng;
            preference;
            framing;
            padding;
            config;
            request;
            may_retry;
            context;
          } ))
      (Http_message.encapsulate_request ~rng ?preference ?framing ?padding
         config dated)

  let start ~rng ?preference ?framing ?padding ?now config request =
    send ~rng ?preference ?framing ?padding ~now ~may_retry:(now <> None) config
      request

  type outcome = Response of Bhttp.Response.t | Retry of request * exchange

  let finish exchange ~status ~headers content =
    let ( let* ) = Result.bind in
    let* () = Http_binding.Client.check_response ~status ~headers in
    let* response =
      Http_message.decapsulate_response exchange.context content
    in
    match Replay.date_of_problem response with
    | Some time when exchange.may_retry ->
        (* Encapsulated anew: the same Encapsulated Request would be refused as
           a replay, and would let the gateway link the two. *)
        let* retry =
          send ~rng:exchange.rng ?preference:exchange.preference
            ?framing:exchange.framing ?padding:exchange.padding ~now:(Some time)
            ~may_retry:false exchange.config exchange.request
        in
        let request, exchange = retry in
        Ok (Retry (request, exchange))
    | _ -> Ok (Response response)
end

module Relay = struct
  type t = {
    max_request_size : int;
    max_response_size : int;
    in_flight : In_flight.t;
  }

  let create ?max_request_size ?max_response_size ?max_in_flight () =
    {
      max_request_size =
        limit "max_request_size" ~default:default_max_request_size
          max_request_size;
      max_response_size =
        limit "max_response_size" ~default:default_max_response_size
          max_response_size;
      in_flight =
        In_flight.create
          (limit "max_in_flight" ~default:default_max_in_flight max_in_flight);
    }

  let max_request_size t = t.max_request_size
  let max_response_size t = t.max_response_size
  let admit t = In_flight.admit t.in_flight
  let release t = In_flight.release t.in_flight

  let request ~meth ~headers content =
    match Http_binding.Gateway.check_request ~meth ~headers with
    | Ok () ->
        Ok { headers = Http_binding.Client.request_headers; body = content }
    | Error (Error.Method_not_allowed _) ->
        Error (plain ~headers:[ ("allow", "POST") ] 405)
    | Error _ -> Error (plain 415)

  let passed = [ "content-type"; "cache-control"; "allow" ]

  let response ~status ~headers content =
    let headers =
      List.filter_map
        (fun (name, value) ->
          let name = String.lowercase_ascii name in
          if List.mem name passed then Some (name, value) else None)
        headers
    in
    { status; headers; body = content }

  let unreachable = plain 502
end

module Gateway = struct
  type t = {
    gateway : Gateway.t;
    rng : Mirage_crypto_rng.g;
    replay : Replay.t option;
    checks_replay : Bhttp.Request.t -> bool;
    framing : Bhttp.Framing.t option;
    padding : int option;
    max_request_size : int;
    in_flight : In_flight.t;
  }

  let create ~rng ?replay ?(checks_replay = fun _ -> true) ?framing ?padding
      ?max_request_size ?max_in_flight gateway =
    {
      gateway;
      rng;
      replay;
      checks_replay;
      framing;
      padding;
      max_request_size =
        limit "max_request_size" ~default:default_max_request_size
          max_request_size;
      in_flight =
        In_flight.create
          (limit "max_in_flight" ~default:default_max_in_flight max_in_flight);
    }

  let max_request_size t = t.max_request_size
  let admit t = In_flight.admit t.in_flight
  let release t = In_flight.release t.in_flight

  let key_configs t =
    {
      status = 200;
      headers = Http_binding.Gateway.key_config_response_headers;
      body = Gateway.encoded_key_configs t.gateway;
    }

  type step =
    | Respond of response
    | Forward of Bhttp.Request.t * (Bhttp.Response.t -> response)

  let unreplayed t ~now context request =
    match t.replay with
    | Some replay when t.checks_replay request -> (
        match
          Replay.check replay ~now
            ~enc:(Gateway.encapsulated_key context)
            request
        with
        | Ok () -> Ok request
        | Error rejection -> Error (Replay.rejection_response ~now rejection))
    | _ -> Ok request

  let target ~targets (request : Bhttp.Request.t) =
    match List.assoc_opt request.authority targets with
    | None -> Error (Bhttp.Response.make ~status:403 ())
    | Some _ when String.length request.path = 0 || request.path.[0] <> '/' ->
        Error (Bhttp.Response.make ~status:400 ())
    | Some base ->
        let base =
          if String.length base > 0 && base.[String.length base - 1] = '/' then
            String.sub base 0 (String.length base - 1)
          else base
        in
        Ok (base ^ request.path)

  let receive t ~now ~meth ~headers content =
    let received =
      Result.bind (Http_binding.Gateway.check_request ~meth ~headers) (fun () ->
          if String.length content > t.max_request_size then
            Error (Error.Content_too_large t.max_request_size)
          else Http_message.decapsulate_request t.gateway content)
    in
    match received with
    (* The encapsulation is still on: answer in the clear. *)
    | Error e -> Respond (Http_binding.Gateway.error_response e)
    (* It is off: from here on, every answer goes back sealed. *)
    | Ok (inner, context) -> (
        let seal response =
          match
            Http_message.encapsulate_response ~rng:t.rng ?framing:t.framing
              ?padding:t.padding context response
          with
          | Ok body ->
              {
                status = 200;
                headers = Http_binding.Gateway.response_headers;
                body;
              }
          | Error e -> Http_binding.Gateway.error_response e
        in
        match Result.bind inner (unreplayed t ~now context) with
        | Ok request -> Forward (request, seal)
        | Error response -> Respond (seal response))
end
