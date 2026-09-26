(* The client, relay, and gateway of RFC 9458 Section 5, as steps from HTTP
   messages to HTTP messages. *)

type request = { headers : (string * string) list; body : string }

type response = Http_binding.Gateway.error_response = {
  status : int;
  headers : (string * string) list;
  body : string;
}

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
  let plain ?(headers = []) status = { status; headers; body = "" }

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
  }

  let create ~rng ?replay ?(checks_replay = fun _ -> true) ?framing ?padding
      gateway =
    { gateway; rng; replay; checks_replay; framing; padding }

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
          Http_message.decapsulate_request t.gateway content)
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
