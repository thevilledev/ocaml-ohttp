(* Crowbar fuzzing of everything in Oblivious HTTP that reads a peer's bytes:
   key configurations, encapsulated requests and responses, and dates. None of
   it may raise, a key configuration that decodes must encode to the bytes it
   came from, and a date that parses must format to one that parses to the same
   time. Build with [dune build --profile fuzz fuzz/fuzz_ohttp.exe]. *)

open Crowbar
open Ohttp

let pp_hex fmt s = Format.pp_print_string fmt (Bhttp.Hex.encode s)
let get = function Ok v -> v | Error e -> failwith (Error.to_string e)

let total name f input =
  match f input with
  | Ok _ | Error _ -> ()
  | exception e ->
      fail (Printf.sprintf "%s raised %s" name (Printexc.to_string e))

let rng =
  Mirage_crypto_rng.create ~seed:(String.make 64 '\x5a')
    (module Mirage_crypto_rng.Fortuna)

let keys =
  List.mapi
    (fun i kem ->
      get
        (Gateway.Key.derive ~key_id:i ~symmetric:Suite.all_symmetric kem
           ~ikm:(String.make 66 '\x33')))
    Suite.all_kems

let gateway = get (Gateway.create keys)
let symmetric = Array.of_list Suite.all_symmetric

let key_config input =
  match Key_config.decode input with
  | Error _ -> ()
  | Ok config ->
      check_eq ~pp:pp_hex ~eq:String.equal input (Key_config.encode config)
  | exception e ->
      fail (Printf.sprintf "Key_config.decode raised %s" (Printexc.to_string e))

(* A list may hold configurations that are skipped, so its bytes need not come
   back; what was kept must. *)
let key_config_list input =
  match Key_config.decode_list input with
  | Error _ -> ()
  | Ok configs -> (
      let encoded = Key_config.encode_list configs in
      match Key_config.decode_list encoded with
      | Ok again ->
          check_eq ~pp:pp_hex ~eq:String.equal encoded
            (Key_config.encode_list again)
      | Error _ ->
          (* Every configuration was skipped, and nothing encodes to nothing. *)
          check (configs = []))
  | exception e ->
      fail
        (Printf.sprintf "Key_config.decode_list raised %s"
           (Printexc.to_string e))

(* A chunked receiver takes its stream in whatever slices the transport
   delivers, so the fuzzer chooses them too. Nothing that it invents was sealed
   by anyone, so nothing may come out as a complete message. *)
let chunked name receiver slices =
  let rec feed = function
    | [] -> Chunked.Receiver.finish receiver
    | slice :: rest -> (
        match Chunked.Receiver.feed receiver slice with
        | Ok _ -> feed rest
        | Error _ as e -> e)
  in
  match feed slices with
  | Error _ -> ()
  | Ok _ -> fail (name ^ ": a stream that nobody sealed was accepted")
  | exception e ->
      fail (Printf.sprintf "%s raised %s" name (Printexc.to_string e))

let () =
  add_test ~name:"chunked request"
    [ list bytes ]
    (fun slices ->
      chunked "chunked request"
        (Chunked.Gateway.receiver (Chunked.Gateway.request gateway))
        slices);
  add_test ~name:"chunked request with a header"
    [ range (List.length keys); range (Array.length symmetric); list bytes ]
    (fun key pair slices ->
      let key = List.nth keys key in
      let suite =
        Suite.make (Key_config.kem (Gateway.Key.config key)) symmetric.(pair)
      in
      let header =
        Encapsulation.header ~key_id:(Gateway.Key.key_id key) suite
      in
      chunked "chunked request"
        (Chunked.Gateway.receiver (Chunked.Gateway.request gateway))
        (header :: slices));
  add_test ~name:"chunked response"
    [ range (List.length keys); range (Array.length symmetric); list bytes ]
    (fun key pair slices ->
      let config = Gateway.Key.config (List.nth keys key) in
      let _, _, context =
        get
          (Chunked.Client.request ~rng ~preference:[ symmetric.(pair) ] config)
      in
      chunked "chunked response" (Chunked.Client.response context) slices);
  add_test ~name:"key configuration" [ bytes ] key_config;
  add_test ~name:"key configuration list" [ bytes ] key_config_list;
  add_test ~name:"request" [ bytes ]
    (total "Gateway.decapsulate" (Gateway.decapsulate gateway));
  (* Crowbar rarely guesses a header that names a key and a suite it offers, so
     give it one and let it supply the rest. *)
  add_test ~name:"request with a header"
    [ range (List.length keys); range (Array.length symmetric); bytes ]
    (fun key pair rest ->
      let key = List.nth keys key in
      let suite =
        Suite.make (Key_config.kem (Gateway.Key.config key)) symmetric.(pair)
      in
      let header =
        Encapsulation.header ~key_id:(Gateway.Key.key_id key) suite
      in
      match Gateway.decapsulate gateway (header ^ rest) with
      | Error _ -> ()
      | Ok _ -> fail "a request that no client sealed was accepted"
      | exception e ->
          fail
            (Printf.sprintf "Gateway.decapsulate raised %s"
               (Printexc.to_string e)));
  add_test ~name:"response"
    [ range (List.length keys); range (Array.length symmetric); bytes ]
    (fun key pair input ->
      let config = Gateway.Key.config (List.nth keys key) in
      let _, context =
        get
          (Client.encapsulate ~rng
             ~preference:[ symmetric.(pair) ]
             config "request")
      in
      match Client.decapsulate context input with
      | Error _ -> ()
      | Ok _ -> fail "a response that no gateway sealed was accepted"
      | exception e ->
          fail
            (Printf.sprintf "Client.decapsulate raised %s"
               (Printexc.to_string e)));
  add_test ~name:"header" [ bytes ]
    (total "Encapsulation.parse_header" Encapsulation.parse_header);
  add_test ~name:"media type" [ bytes; bytes ] (fun a b ->
      match Media_type.matches a b with
      | (_ : bool) -> ()
      | exception e ->
          fail
            (Printf.sprintf "Media_type.matches raised %s"
               (Printexc.to_string e)));
  add_test ~name:"date" [ bytes; float ] (fun input now ->
      match Replay.Date.parse ~now input with
      | None -> ()
      | Some t ->
          check_eq ~pp:Format.pp_print_float t
            (Option.get (Replay.Date.parse (Replay.Date.format t)))
      | exception e ->
          fail
            (Printf.sprintf "Replay.Date.parse raised %s" (Printexc.to_string e)))
