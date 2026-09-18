(** Binary HTTP messages as JSON, for corpora and for the peers of
    tools/differential.

    Every string is lowercase hexadecimal, as a method, a path, or a field value
    can hold bytes that JSON text cannot.

    {v
    {"kind": "request", "method": H, "scheme": H, "authority": H, "path": H,
     "headers": [[H, H], ...], "content": H, "trailers": [[H, H], ...]}
    {"kind": "response", "informational": [{"status": N, "headers": [...]}, ...],
     "status": N, "headers": [...], "content": H, "trailers": [...]}
    v} *)

val to_json : Bhttp.Message.t -> Yojson.Safe.t
val of_json : Yojson.Safe.t -> (Bhttp.Message.t, string) result
