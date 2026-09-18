(* Errors returned by the public API. Messages describe classes of invalid input
   and never contain field values or message content. *)

type t =
  | Truncated of string
  | Too_large of string
  | Invalid_framing_indicator of int
  | Unexpected_message of { expected : string; actual : string }
  | Invalid_control_data of string
  | Invalid_status of int
  | Invalid_field_name of string
  | Invalid_field_value of string
  | Forbidden_pseudo_field of string
  | Misplaced_pseudo_field of string
  | Invalid_padding

(* Field names come from the peer and can hold any byte. *)
let quote name = "\"" ^ String.escaped name ^ "\""

let to_string = function
  | Truncated what -> "truncated message: " ^ what
  | Too_large what -> "integer too large for this platform: " ^ what
  | Invalid_framing_indicator n ->
      Printf.sprintf "invalid framing indicator %d" n
  | Unexpected_message { expected; actual } ->
      Printf.sprintf "expected a %s, got a %s" expected actual
  | Invalid_control_data msg -> "invalid control data: " ^ msg
  | Invalid_status n -> Printf.sprintf "invalid status code %d" n
  | Invalid_field_name name -> "invalid field name " ^ quote name
  | Invalid_field_value name -> "invalid value for field " ^ quote name
  | Forbidden_pseudo_field name -> "forbidden pseudo-field " ^ quote name
  | Misplaced_pseudo_field name -> "misplaced pseudo-field " ^ quote name
  | Invalid_padding -> "padding contains a non-zero byte"

let pp fmt e = Format.pp_print_string fmt (to_string e)
