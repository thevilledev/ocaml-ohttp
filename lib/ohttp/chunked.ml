(* Chunked Oblivious HTTP (draft-ietf-ohai-chunked-ohttp-08). *)

let ( let* ) = Result.bind
let hpke_error = function Ok v -> Ok v | Error e -> Error (Error.Hpke e)

let labels : Encapsulation.labels =
  {
    request = "message/bhttp chunked request";
    response = "message/bhttp chunked response";
  }

let max_chunk_size = 16384
let final_aad = "final"

let chunk_nonce ~nonce ~counter =
  if counter < 0 then invalid_arg "Chunked.chunk_nonce: negative counter";
  let length = String.length nonce in
  String.mapi
    (fun i c ->
      (* The counter fills the last bytes of a big-endian integer as long as the
         nonce; a native int has no bits beyond its own width. *)
      let shift = 8 * (length - 1 - i) in
      let byte =
        if shift < Sys.int_size then (counter lsr shift) land 0xff else 0
      in
      Char.chr (Char.code c lxor byte))
    nonce

(* The keys of one direction. Requests use the HPKE context, which numbers its
   own messages; responses use the exported key with a counter. *)
type 'hpke keys =
  | Hpke of 'hpke
  | Aead of { key : Hpke.Aead.key; nonce : string; mutable counter : int }

let next_nonce ~nonce ~counter =
  (* 256^Nn chunks would reuse a nonce; a native int runs out long before. *)
  if counter = max_int then Error (Error.Hpke Hpke.Error.Message_limit_reached)
  else Ok (chunk_nonce ~nonce ~counter)

module Sender = struct
  type t = {
    keys : Hpke.Suite.encryption Hpke.Rfc9180.Sender.t keys;
    limit : int;
    mutable finished : bool;
  }

  let seal t ~aad data =
    match t.keys with
    | Hpke context ->
        hpke_error (Hpke.Rfc9180.Sender.seal context ~aad ~plaintext:data)
    | Aead a ->
        let* nonce = next_nonce ~nonce:a.nonce ~counter:a.counter in
        let* sealed =
          hpke_error (Hpke.Aead.seal a.key ~nonce ~aad ~plaintext:data)
        in
        a.counter <- a.counter + 1;
        Ok sealed

  let check t data =
    if t.finished then invalid_arg "Chunked.Sender: the final chunk was sent";
    if String.length data > t.limit then
      Error (Error.Chunk_too_large (String.length data))
    else Ok ()

  let chunk t data =
    if data = "" then invalid_arg "Chunked.Sender.chunk: empty non-final chunk";
    let* () = check t data in
    let* sealed = seal t ~aad:"" data in
    Ok (Bhttp.Varint.encode (String.length sealed) ^ sealed)

  let final t data =
    let* () = check t data in
    let* sealed = seal t ~aad:final_aad data in
    t.finished <- true;
    Ok (Bhttp.Varint.encode 0 ^ sealed)
end

module Receiver = struct
  type opener = Hpke.Suite.encryption Hpke.Rfc9180.Receiver.t keys

  type state =
    (* What precedes the chunks: a request header for a gateway, a response
       nonce for a client. [start] turns it into keys once [length] says how
       much of it there is. *)
    | Preamble of {
        what : string;
        length : string -> (int option, Error.t) result;
        start : string -> (opener, Error.t) result;
      }
    | Chunks of opener
    | Final of opener  (** A zero length was read: the rest is one chunk. *)
    | Finished
    | Failed of Error.t

  (* Bytes that are not yet a whole chunk. The transport may deliver a chunk a
     few bytes at a time, so bytes are appended to a buffer and consumed from an
     offset, and the buffer is compacted only after a chunk has been taken out
     of it. Every byte is then copied a bounded number of times, however the
     stream is split. *)
  type t = {
    mutable state : state;
    mutable buffer : Buffer.t;
    mutable consumed : int;
    limit : int;
  }

  let tag_length = 16
  let available t = Buffer.length t.buffer - t.consumed

  let take t n =
    let v = Buffer.sub t.buffer t.consumed n in
    t.consumed <- t.consumed + n;
    v

  let compact t =
    if t.consumed > 0 then begin
      let rest = Buffer.sub t.buffer t.consumed (available t) in
      t.buffer <- Buffer.create (max 256 (String.length rest));
      Buffer.add_string t.buffer rest;
      t.consumed <- 0
    end

  let open_chunk opener ~aad sealed =
    (* "A receiver MUST treat the receipt of a chunk that contains no data as
       equivalent to a decryption error, unless that chunk is the final
       chunk." *)
    if aad = "" && String.length sealed <= tag_length then
      Error Error.Decapsulation_failed
    else
      match opener with
      | Hpke context -> (
          match Hpke.Rfc9180.Receiver.open_ context ~aad ~ciphertext:sealed with
          | Ok data -> Ok data
          | Error Hpke.Error.Open_error -> Error Error.Decapsulation_failed
          | Error e -> Error (Error.Hpke e))
      | Aead a -> (
          let* nonce = next_nonce ~nonce:a.nonce ~counter:a.counter in
          match Hpke.Aead.open_ a.key ~nonce ~aad ~ciphertext:sealed with
          | Ok data ->
              a.counter <- a.counter + 1;
              Ok data
          | Error Hpke.Error.Open_error -> Error Error.Decapsulation_failed
          | Error e -> Error (Error.Hpke e))

  (* Consume whatever is complete. *)
  let rec drain t acc =
    match t.state with
    | Failed e -> Error e
    | Finished -> invalid_arg "Chunked.Receiver: the stream was finished"
    | Final _ ->
        if available t > t.limit + tag_length then
          Error (Error.Chunk_too_large (available t))
        else Ok (List.rev acc)
    | Preamble { length; start; _ } -> (
        (* No preamble is longer than a header with a P-521 key. *)
        let* needed =
          length (Buffer.sub t.buffer t.consumed (min (available t) 8))
        in
        match needed with
        | Some n when available t >= n ->
            let* opener = start (take t n) in
            t.state <- Chunks opener;
            drain t acc
        | Some _ | None -> Ok (List.rev acc))
    | Chunks opener -> (
        if available t = 0 then Ok (List.rev acc)
        else
          let prefix = Buffer.sub t.buffer t.consumed (min (available t) 8) in
          match Bhttp.Varint.decode prefix ~pos:0 with
          | Error (Bhttp.Error.Truncated _) -> Ok (List.rev acc)
          | Error _ -> Error (Error.Chunk_too_large max_int)
          | Ok (0, next) ->
              t.consumed <- t.consumed + next;
              t.state <- Final opener;
              drain t acc
          | Ok (length, _) when length > t.limit + tag_length ->
              Error (Error.Chunk_too_large length)
          | Ok (length, next) ->
              if available t - next < length then Ok (List.rev acc)
              else begin
                t.consumed <- t.consumed + next;
                let* data = open_chunk opener ~aad:"" (take t length) in
                drain t (data :: acc)
              end)

  let fail t e =
    t.state <- Failed e;
    t.buffer <- Buffer.create 0;
    t.consumed <- 0;
    Error e

  let feed t bytes =
    (match t.state with
    | Failed _ | Finished -> ()
    | Preamble _ | Chunks _ | Final _ -> Buffer.add_string t.buffer bytes);
    match drain t [] with
    | Ok chunks ->
        compact t;
        Ok chunks
    | Error e -> fail t e

  let finish t =
    let result =
      match t.state with
      | Failed e -> Error e
      | Finished -> invalid_arg "Chunked.Receiver: the stream was finished"
      | Preamble { what; _ } -> Error (Error.Truncated_message what)
      | Chunks _ -> Error (Error.Truncated_message "final chunk")
      | Final opener -> open_chunk opener ~aad:final_aad (take t (available t))
    in
    match result with
    | Ok data ->
        t.state <- Finished;
        t.buffer <- Buffer.create 0;
        t.consumed <- 0;
        Ok data
    | Error e -> fail t e

  let create ~limit state =
    { state; buffer = Buffer.create 256; consumed = 0; limit }
end

let response_keys (suite : Suite.t) ~enc ~secret ~response_nonce =
  let* { Encapsulation.key; nonce; _ } =
    Encapsulation.response_keys suite ~enc ~secret ~response_nonce
  in
  (* Every chunk is sealed under this key, so it is prepared once. *)
  let* key = hpke_error (Hpke.Aead.key suite.aead key) in
  Ok (Aead { key; nonce; counter = 0 })

let response_receiver ?(max_chunk_size = max_chunk_size) (suite : Suite.t) ~enc
    ~secret =
  let nonce_length = Suite.response_nonce_length suite.aead in
  Receiver.create ~limit:max_chunk_size
    (Receiver.Preamble
       {
         what = "response nonce";
         length = (fun _ -> Ok (Some nonce_length));
         start =
           (fun response_nonce ->
             response_keys suite ~enc ~secret ~response_nonce);
       })

module Client = struct
  type response_context = { suite : Suite.t; enc : string; secret : string }

  let request_with ~(setup : Client.sender_setup) ?preference
      ?(max_chunk_size = max_chunk_size) config =
    let* suite = Key_config.select ?preference config in
    let header =
      Encapsulation.header ~key_id:(Key_config.key_id config) suite
    in
    let* { Hpke.Rfc9180.encapsulated_key = enc; context } =
      hpke_error
        (setup (Suite.hpke suite)
           ~recipient:(Key_config.public_key config)
           ~info:(Encapsulation.info ~label:labels.request ~header))
    in
    let* secret =
      hpke_error
        (Hpke.Rfc9180.Sender.export context ~context:labels.response
           ~length:(Suite.response_nonce_length suite.aead))
    in
    Ok
      ( header ^ enc,
        { Sender.keys = Hpke context; limit = max_chunk_size; finished = false },
        { suite; enc; secret } )

  let request ~rng = request_with ~setup:(Hpke.Rfc9180.setup_base_sender ~rng)

  let response ?max_chunk_size { suite; enc; secret } =
    response_receiver ?max_chunk_size suite ~enc ~secret
end

module Gateway = struct
  type started = { suite : Suite.t; enc : string; secret : string }

  type request = {
    receiver : Receiver.t;
    started : started option ref;
    mutable responded : bool;
  }

  let request ?(max_chunk_size = max_chunk_size) gateway =
    let started = ref None in
    let length pending =
      if String.length pending < Encapsulation.header_length then Ok None
      else Result.map Option.some (Gateway.header_length gateway pending)
    in
    let start header =
      let* suite, enc, receiver =
        Gateway.setup_receiver ~labels gateway header
      in
      let* secret =
        hpke_error
          (Hpke.Rfc9180.Receiver.export receiver ~context:labels.response
             ~length:(Suite.response_nonce_length suite.aead))
      in
      started := Some { suite; enc; secret };
      Ok (Hpke receiver)
    in
    {
      receiver =
        Receiver.create ~limit:max_chunk_size
          (Receiver.Preamble { what = "header"; length; start });
      started;
      responded = false;
    }

  let receiver t = t.receiver
  let encapsulated_key t = Option.map (fun { enc; _ } -> enc) !(t.started)

  let response ~rng ?(max_chunk_size = max_chunk_size) t =
    if t.responded then invalid_arg "Chunked.Gateway.response: called twice";
    match !(t.started) with
    | None -> Error (Error.Truncated_message "header")
    | Some { suite; enc; secret } ->
        let response_nonce =
          Mirage_crypto_rng.generate ~g:rng
            (Suite.response_nonce_length suite.aead)
        in
        let* keys = response_keys suite ~enc ~secret ~response_nonce in
        t.responded <- true;
        Ok
          ( response_nonce,
            { Sender.keys; limit = max_chunk_size; finished = false } )
end

let seal_all ?(chunk_size = max_chunk_size) sender message =
  if chunk_size <= 0 then invalid_arg "Chunked.seal_all: chunk_size";
  let b = Buffer.create (String.length message + 64) in
  let rec go pos =
    let left = String.length message - pos in
    if left >= chunk_size && left > 0 then (
      let* sealed = Sender.chunk sender (String.sub message pos chunk_size) in
      Buffer.add_string b sealed;
      go (pos + chunk_size))
    else
      let* sealed = Sender.final sender (String.sub message pos left) in
      Buffer.add_string b sealed;
      Ok (Buffer.contents b)
  in
  go 0

let open_all receiver bytes =
  let* chunks = Receiver.feed receiver bytes in
  let* last = Receiver.finish receiver in
  Ok (String.concat "" (chunks @ [ last ]))
