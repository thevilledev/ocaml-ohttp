(* Framing indicator (RFC 9292 Section 3.3). *)

type t = Known_length | Indeterminate_length
type kind = Request | Response

let indicator kind framing =
  match (kind, framing) with
  | Request, Known_length -> 0
  | Response, Known_length -> 1
  | Request, Indeterminate_length -> 2
  | Response, Indeterminate_length -> 3

let of_indicator = function
  | 0 -> Some (Request, Known_length)
  | 1 -> Some (Response, Known_length)
  | 2 -> Some (Request, Indeterminate_length)
  | 3 -> Some (Response, Indeterminate_length)
  | _ -> None

let peek message =
  match Varint.decode message ~pos:0 with
  | Error (Error.Truncated _) -> Error (Error.Truncated "framing indicator")
  | Error _ as e -> e
  | Ok (n, _) -> (
      match of_indicator n with
      | Some v -> Ok v
      | None -> Error (Error.Invalid_framing_indicator n))

let kind_to_string = function Request -> "request" | Response -> "response"

let pp fmt t =
  Format.pp_print_string fmt
    (match t with
    | Known_length -> "known-length"
    | Indeterminate_length -> "indeterminate-length")
