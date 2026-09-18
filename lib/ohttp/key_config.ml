(* Key configurations (RFC 9458 Section 3). *)

type t = {
  key_id : int;
  public_key : Hpke.Public_key.t;
  symmetric_ids : (int * int) list;
}

let ( let* ) = Result.bind
let invalid msg = Error (Error.Invalid_key_config msg)

(* HPKE Symmetric Algorithms Length is a 16-bit count of bytes, "4..65532". *)
let max_symmetric = 65532 / 4

let create ~key_id public_key symmetric =
  if key_id < 0 || key_id > 0xff then Error (Error.Invalid_key_id key_id)
  else if symmetric = [] then invalid "no symmetric algorithms"
  else if List.length symmetric > max_symmetric then
    invalid "too many symmetric algorithms"
  else
    Ok
      {
        key_id;
        public_key;
        symmetric_ids = List.map Suite.symmetric_to_ints symmetric;
      }

let key_id t = t.key_id
let kem t = Hpke.Public_key.kem t.public_key
let public_key t = t.public_key
let symmetric_ids t = t.symmetric_ids
let symmetric t = List.filter_map Suite.symmetric_of_ints t.symmetric_ids
let offers t pair = List.mem pair (symmetric t)

let select ?preference t =
  let offered = symmetric t in
  let chosen =
    match preference with
    | None -> ( match offered with [] -> None | pair :: _ -> Some pair)
    | Some preference ->
        List.find_opt (fun pair -> List.mem pair offered) preference
  in
  match chosen with
  | Some pair -> Ok (Suite.make (kem t) pair)
  | None -> Error Error.No_supported_suite

let rec select_from_list ?preference = function
  | [] -> Error Error.No_supported_suite
  | t :: rest -> (
      match select ?preference t with
      | Ok suite -> Ok (t, suite)
      | Error _ -> select_from_list ?preference rest)

let encode t =
  let b = Buffer.create 64 in
  Buffer.add_uint8 b t.key_id;
  Buffer.add_uint16_be b (Hpke.Kem.to_int (kem t));
  Buffer.add_string b (Hpke.Public_key.to_bytes t.public_key);
  Buffer.add_uint16_be b (4 * List.length t.symmetric_ids);
  List.iter
    (fun (kdf, aead) ->
      Buffer.add_uint16_be b kdf;
      Buffer.add_uint16_be b aead)
    t.symmetric_ids;
  Buffer.contents b

let decode s =
  let n = String.length s in
  if n < 3 then invalid "truncated before the KEM identifier"
  else
    let key_id = String.get_uint8 s 0 in
    let kem_id = String.get_uint16_be s 1 in
    let* kem =
      match Hpke.Kem.of_int kem_id with
      | Ok kem -> Ok kem
      | Error _ -> Error (Error.Unsupported_kem kem_id)
    in
    let public_key_length = Hpke.Kem.public_key_size kem in
    let symmetric_at = 3 + public_key_length in
    if n < symmetric_at + 2 then invalid "truncated public key"
    else
      let* public_key =
        match
          Hpke.Public_key.of_bytes ~kem (String.sub s 3 public_key_length)
        with
        | Ok key -> Ok key
        | Error _ -> invalid "invalid public key"
      in
      let length = String.get_uint16_be s symmetric_at in
      let first = symmetric_at + 2 in
      if length < 4 || length mod 4 <> 0 then
        invalid "symmetric algorithms length is not a positive multiple of 4"
      else if length > n - first then invalid "truncated symmetric algorithms"
      else if length < n - first then invalid "trailing bytes"
      else
        let symmetric_ids =
          List.init (length / 4) (fun i ->
              let at = first + (4 * i) in
              (String.get_uint16_be s at, String.get_uint16_be s (at + 2)))
        in
        Ok { key_id; public_key; symmetric_ids }

let encode_list configs =
  let b = Buffer.create 128 in
  List.iter
    (fun t ->
      let encoded = encode t in
      Buffer.add_uint16_be b (String.length encoded);
      Buffer.add_string b encoded)
    configs;
  Buffer.contents b

let decode_list s =
  let n = String.length s in
  let rec entries pos acc =
    if pos = n then Ok (List.rev acc)
    else if n - pos < 2 then invalid "truncated length prefix"
    else
      let length = String.get_uint16_be s pos in
      if length = 0 then invalid "empty key configuration"
      else if length > n - pos - 2 then invalid "truncated key configuration"
      else
        let next = pos + 2 + length in
        match decode (String.sub s (pos + 2) length) with
        | Ok t -> entries next (t :: acc)
        (* Its length prefix is all that can be known about a configuration for
           an unknown KEM, and all that is needed to step over it. *)
        | Error (Error.Unsupported_kem _) -> entries next acc
        | Error _ as e -> e
  in
  if n = 0 then invalid "empty list" else entries 0 []

let equal a b =
  a.key_id = b.key_id
  && kem a = kem b
  && String.equal
       (Hpke.Public_key.to_bytes a.public_key)
       (Hpke.Public_key.to_bytes b.public_key)
  && a.symmetric_ids = b.symmetric_ids

let pp fmt t =
  Format.fprintf fmt "@[<v>key %d: %a@,public key %s" t.key_id Hpke.Kem.pp
    (kem t)
    (Bhttp.Hex.encode (Hpke.Public_key.to_bytes t.public_key));
  List.iter
    (fun (kdf, aead) ->
      match Suite.symmetric_of_ints (kdf, aead) with
      | Some pair -> Format.fprintf fmt "@,%a" Suite.pp_symmetric pair
      | None -> Format.fprintf fmt "@,unknown KDF 0x%04x, AEAD 0x%04x" kdf aead)
    t.symmetric_ids;
  Format.fprintf fmt "@]"
