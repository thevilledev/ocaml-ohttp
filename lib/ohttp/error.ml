(* Errors returned by the public API. Messages describe classes of invalid input
   and never contain key material or message content. *)

type t =
  | Invalid_key_config of string
  | Invalid_key_id of int
  | Unsupported_kem of int
  | No_supported_suite
  | Truncated_message of string
  | Unknown_key_id of int
  | Unsupported_suite of { kem : int; kdf : int; aead : int }
  | Decapsulation_failed
  | Chunk_too_large of int
  | Bhttp of Bhttp.Error.t
  | Continue_expectation
  | Method_not_allowed of string
  | Unsupported_media_type of string option
  | Unexpected_status of int
  | Unexpected_content_type of string option
  | Hpke of Hpke.Error.t

let to_string = function
  | Invalid_key_config msg -> "invalid key configuration: " ^ msg
  | Invalid_key_id n -> Printf.sprintf "key identifier %d is not a byte" n
  | Unsupported_kem n -> Printf.sprintf "unsupported KEM 0x%04x" n
  | No_supported_suite -> "the key configuration offers no supported suite"
  | Truncated_message what -> "truncated encapsulated message: " ^ what
  | Unknown_key_id n -> Printf.sprintf "unknown key identifier %d" n
  | Unsupported_suite { kem; kdf; aead } ->
      Printf.sprintf
        "the key does not offer KEM 0x%04x with KDF 0x%04x and AEAD 0x%04x" kem
        kdf aead
  | Decapsulation_failed -> "decapsulation failed"
  | Chunk_too_large n -> Printf.sprintf "chunk of %d bytes is too large" n
  | Bhttp e -> "binary http error: " ^ Bhttp.Error.to_string e
  | Continue_expectation -> "a 100-continue expectation cannot be encapsulated"
  | Method_not_allowed meth ->
      Printf.sprintf "method %s is not allowed" (String.escaped meth)
  | Unsupported_media_type None -> "no content type"
  | Unsupported_media_type (Some t) | Unexpected_content_type (Some t) ->
      Printf.sprintf "unexpected content type %s" (String.escaped t)
  | Unexpected_content_type None -> "the response has no content type"
  | Unexpected_status n ->
      Printf.sprintf "status %d in place of an encapsulated response" n
  | Hpke e -> Format.asprintf "hpke error: %a" Hpke.Error.pp e

let pp fmt e = Format.pp_print_string fmt (to_string e)
