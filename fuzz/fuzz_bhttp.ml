(* Crowbar fuzzing of the Binary HTTP decoder: decoding arbitrary bytes must be
   total, and anything that decodes must survive re-encoding. Build with [dune
   build --profile fuzz fuzz/fuzz_bhttp.exe].

   Unlike a canonical format, the bytes themselves need not come back. RFC 9292
   lets an encoder choose the size of every integer, omit trailing empty
   sections, and append padding, and the decoder lowercases field names. The
   decoded message is the fixed point. *)

open Crowbar
open Bhttp

let pp_message fmt = function
  | Ok m -> Message.pp fmt m
  | Error e -> Error.pp fmt e

let eq_message a b =
  match (a, b) with
  | Ok a, Ok b -> Message.equal a b
  | Error a, Error b -> a = b
  | Ok _, Error _ | Error _, Ok _ -> false

let reencoded ?framing ?truncate message =
  match Message.encode ?framing ?truncate message with
  | Ok encoded -> Message.decode encoded
  | Error e ->
      fail (Format.asprintf "a decoded message does not encode: %a" Error.pp e)

let fixed_point bytes =
  match Message.decode bytes with
  | Error _ -> ()
  | Ok message ->
      let check = check_eq ~pp:pp_message ~eq:eq_message (Ok message) in
      check (reencoded message);
      check (reencoded ~truncate:true message);
      check (reencoded ~framing:Framing.Indeterminate_length message);
      check
        (reencoded ~framing:Framing.Indeterminate_length ~truncate:true message)
  | exception e ->
      fail (Printf.sprintf "Message.decode raised %s" (Printexc.to_string e))

(* The kind-specific decoders agree with the one that reads either kind. *)
let kinds_agree bytes =
  match (Message.decode bytes, Request.decode bytes, Response.decode bytes) with
  | Ok (Message.Request a), Ok b, Error _ ->
      check_eq ~pp:Request.pp ~eq:Request.equal a b
  | Ok (Message.Response a), Error _, Ok b ->
      check_eq ~pp:Response.pp ~eq:Response.equal a b
  | Error _, Error _, Error _ -> ()
  | _ -> fail "the decoders disagree about the kind of a message"
  | exception e ->
      fail (Printf.sprintf "decoding raised %s" (Printexc.to_string e))

let () =
  add_test ~name:"message" [ bytes ] fixed_point;
  add_test ~name:"kinds" [ bytes ] kinds_agree;
  (* Crowbar rarely guesses a framing indicator, so give it one. *)
  add_test ~name:"message with an indicator"
    [ range 4; bytes ]
    (fun indicator rest ->
      fixed_point (String.make 1 (Char.chr indicator) ^ rest));
  add_test ~name:"varint" [ bytes ] (fun b ->
      match Varint.decode b ~pos:0 with
      | Error _ -> ()
      | Ok (n, next) ->
          (* The shortest encoding decodes to the same value. *)
          check_eq
            (Ok (n, Varint.size n))
            (Varint.decode (Varint.encode n) ~pos:0);
          check (next <= String.length b && next = 1 lsl Char.code b.[0] lsr 6)
      | exception e ->
          fail (Printf.sprintf "Varint.decode raised %s" (Printexc.to_string e)))
