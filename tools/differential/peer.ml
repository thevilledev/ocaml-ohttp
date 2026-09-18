(* A peer is another implementation behind the line protocol of README.md: one
   JSON object per line each way, strictly in turn. *)

type error_kind = Unsupported | Rejected | Internal
type error = { kind : error_kind; message : string }

type t = {
  name : string;
  pid : int;
  input : in_channel;
  output : out_channel;
  input_fd : Unix.file_descr;
  timeout : float;
  mutable next_id : int;
  mutable version : string;
  mutable kems : int list;
  mutable kdfs : int list;
  mutable aeads : int list;
  mutable features : string list;
}

let member name = function
  | `Assoc members -> (
      match List.assoc_opt name members with Some v -> v | None -> `Null)
  | _ -> `Null

let to_string = function `String s -> Some s | _ -> None
let to_int = function `Int n -> Some n | _ -> None
let to_list f = function `List l -> List.filter_map f l | _ -> []
let internal message = Error { kind = Internal; message }

let ask t op fields =
  let id = t.next_id in
  t.next_id <- id + 1;
  let request = `Assoc (("id", `Int id) :: ("op", `String op) :: fields) in
  match
    output_string t.output (Yojson.Safe.to_string request);
    output_char t.output '\n';
    flush t.output;
    (* A peer answers a request at once or not at all. *)
    match Unix.select [ t.input_fd ] [] [] t.timeout with
    | [], _, _ -> None
    | _ -> Some (input_line t.input)
  with
  | exception End_of_file -> internal "the peer exited"
  | exception Sys_error msg -> internal ("the peer is gone: " ^ msg)
  | None -> internal (Printf.sprintf "no answer within %.0f seconds" t.timeout)
  | Some line -> (
      match Yojson.Safe.from_string line with
      | exception Yojson.Json_error msg -> internal ("not JSON: " ^ msg)
      | answer -> (
          if member "id" answer <> `Int id then internal "answer out of turn"
          else
            match member "ok" answer with
            | `Bool true -> Ok answer
            | _ ->
                let e = member "error" answer in
                let message =
                  Option.value ~default:"" (to_string (member "message" e))
                in
                let kind =
                  match to_string (member "kind" e) with
                  | Some "unsupported" -> Unsupported
                  | Some "rejected" -> Rejected
                  | _ -> Internal
                in
                Error { kind; message }))

(* [spec] is NAME=COMMAND. The command is a single executable; one that needs
   arguments, such as `docker run`, goes into a script. *)
let spawn ~timeout spec =
  match String.index_opt spec '=' with
  | None -> Error ("expected NAME=PATH, got " ^ spec)
  | Some i -> (
      let name = String.sub spec 0 i
      and path = String.sub spec (i + 1) (String.length spec - i - 1) in
      let request_read, request_write = Unix.pipe ~cloexec:true () in
      let answer_read, answer_write = Unix.pipe ~cloexec:true () in
      match
        Unix.create_process path [| path |] request_read answer_write
          Unix.stderr
      with
      | exception Unix.Unix_error (e, _, _) ->
          Error (Printf.sprintf "%s: %s" path (Unix.error_message e))
      | pid -> (
          Unix.close request_read;
          Unix.close answer_write;
          let t =
            {
              name;
              pid;
              input = Unix.in_channel_of_descr answer_read;
              output = Unix.out_channel_of_descr request_write;
              input_fd = answer_read;
              timeout;
              next_id = 1;
              version = "";
              kems = [];
              kdfs = [];
              aeads = [];
              features = [];
            }
          in
          match ask t "hello" [] with
          | Error e -> Error (name ^ ": " ^ e.message)
          | Ok hello ->
              if member "protocol" hello <> `Int 1 then
                Error (name ^ ": unknown protocol version")
              else begin
                t.version <-
                  Option.value ~default:"" (to_string (member "version" hello));
                t.kems <- to_list to_int (member "kems" hello);
                t.kdfs <- to_list to_int (member "kdfs" hello);
                t.aeads <- to_list to_int (member "aeads" hello);
                t.features <- to_list to_string (member "features" hello);
                Ok t
              end))

let has t feature = List.mem feature t.features

let close t =
  close_out_noerr t.output;
  (try ignore (Unix.waitpid [] t.pid) with Unix.Unix_error _ -> ());
  close_in_noerr t.input
