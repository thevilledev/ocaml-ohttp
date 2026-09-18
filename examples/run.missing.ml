(* What the examples do where cohttp-lwt-unix is not installed. *)

let missing () =
  prerr_endline
    "This example needs cohttp-lwt-unix: opam install cohttp-lwt-unix";
  (* Not a failure, unless the caller says that it is one. *)
  exit (if Array.mem "--require" Sys.argv then 1 else 0)

let client = missing
let gateway = missing
let relay = missing
let e2e = missing
