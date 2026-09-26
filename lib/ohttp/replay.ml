(* Defences against replayed requests (RFC 9458 Section 6.5). *)

module Date = struct
  let ( let* ) = Option.bind
  let short_days = [| "Sun"; "Mon"; "Tue"; "Wed"; "Thu"; "Fri"; "Sat" |]

  let long_days =
    [|
      "Sunday";
      "Monday";
      "Tuesday";
      "Wednesday";
      "Thursday";
      "Friday";
      "Saturday";
    |]

  let months =
    [|
      "Jan";
      "Feb";
      "Mar";
      "Apr";
      "May";
      "Jun";
      "Jul";
      "Aug";
      "Sep";
      "Oct";
      "Nov";
      "Dec";
    |]

  let index names name =
    let rec go i =
      if i = Array.length names then None
      else if String.equal names.(i) name then Some i
      else go (i + 1)
    in
    go 0

  (* Days from 1970-01-01 to a date of the proleptic Gregorian calendar, and
     back: the algorithms of Howard Hinnant's "chrono-Compatible Low-Level Date
     Algorithms". Months count from 1. *)
  let days_from_civil ~year ~month ~day =
    let y = if month <= 2 then year - 1 else year in
    let era = (if y >= 0 then y else y - 399) / 400 in
    let yoe = y - (era * 400) in
    let mp = (month + 9) mod 12 in
    let doy = (((153 * mp) + 2) / 5) + day - 1 in
    let doe = (yoe * 365) + (yoe / 4) - (yoe / 100) + doy in
    (era * 146097) + doe - 719468

  let civil_from_days days =
    let z = days + 719468 in
    let era = (if z >= 0 then z else z - 146096) / 146097 in
    let doe = z - (era * 146097) in
    let yoe = (doe - (doe / 1460) + (doe / 36524) - (doe / 146096)) / 365 in
    let doy = doe - ((365 * yoe) + (yoe / 4) - (yoe / 100)) in
    let mp = ((5 * doy) + 2) / 153 in
    let day = doy - (((153 * mp) + 2) / 5) + 1 in
    let month = if mp < 10 then mp + 3 else mp - 9 in
    let year = yoe + (era * 400) + if month <= 2 then 1 else 0 in
    (year, month, day)

  (* 1970-01-01 was a Thursday; Sunday is 0. *)
  let weekday days = (((days + 4) mod 7) + 7) mod 7

  let days_in_month ~year month =
    match month with
    | 2 ->
        if (year mod 4 = 0 && year mod 100 <> 0) || year mod 400 = 0 then 29
        else 28
    | 4 | 6 | 9 | 11 -> 30
    | _ -> 31

  let digits s pos n =
    let rec go i acc =
      if i = pos + n then Some acc
      else
        match s.[i] with
        | '0' .. '9' as c -> go (i + 1) ((acc * 10) + Char.code c - 48)
        | _ -> None
    in
    if pos < 0 || pos + n > String.length s then None else go pos 0

  let char s pos c = pos < String.length s && s.[pos] = c
  let sub s pos n = if pos + n > String.length s then "" else String.sub s pos n

  (* "HH:MM:SS", where a second of 60 is a leap second. *)
  let time s pos =
    let* hour = digits s pos 2 in
    let* minute = digits s (pos + 3) 2 in
    let* second = digits s (pos + 6) 2 in
    if
      char s (pos + 2) ':'
      && char s (pos + 5) ':'
      && hour <= 23 && minute <= 59 && second <= 60
    then Some ((hour * 3600) + (minute * 60) + second)
    else None

  let make ~weekday:day_of_week ~year ~month ~day ~seconds =
    if day < 1 || day > days_in_month ~year (month + 1) then None
    else
      let days = days_from_civil ~year ~month:(month + 1) ~day in
      if weekday days <> day_of_week then None
      else Some (float_of_int ((days * 86400) + seconds))

  (* "Sun, 06 Nov 1994 08:49:37 GMT" *)
  let imf_fixdate s =
    let* weekday = index short_days (sub s 0 3) in
    let* day = digits s 5 2 in
    let* month = index months (sub s 8 3) in
    let* year = digits s 12 4 in
    let* seconds = time s 17 in
    if
      String.length s = 29
      && char s 3 ',' && char s 4 ' ' && char s 7 ' ' && char s 11 ' '
      && char s 16 ' ' && char s 25 ' '
      && String.equal (sub s 26 3) "GMT"
    then make ~weekday ~year ~month ~day ~seconds
    else None

  (* 0000-01-01T00:00:00Z and 9999-12-31T23:59:59Z *)
  let earliest = -62167219200.
  and latest = 253402300799.

  let in_range t = t >= earliest && t < latest +. 1.

  (* A two-digit year more than 50 years ahead of [now] belongs to the previous
     century (RFC 9110 Section 5.6.7). *)
  let full_year ?now yy =
    match now with
    | Some now when in_range now ->
        let current, _, _ =
          civil_from_days (int_of_float (Float.floor (now /. 86400.)))
        in
        let year = current - (current mod 100) + yy in
        if year > current + 50 && year >= 100 then year - 100 else year
    | Some _ | None -> if yy >= 70 then 1900 + yy else 2000 + yy

  (* "Sunday, 06-Nov-94 08:49:37 GMT" *)
  let rfc850_date ?now s =
    let* i = String.index_opt s ',' in
    let* weekday = index long_days (String.sub s 0 i) in
    let* day = digits s (i + 2) 2 in
    let* month = index months (sub s (i + 5) 3) in
    let* yy = digits s (i + 9) 2 in
    let* seconds = time s (i + 12) in
    if
      String.length s = i + 24
      && char s (i + 1) ' '
      && char s (i + 4) '-'
      && char s (i + 8) '-'
      && char s (i + 11) ' '
      && char s (i + 20) ' '
      && String.equal (sub s (i + 21) 3) "GMT"
    then make ~weekday ~year:(full_year ?now yy) ~month ~day ~seconds
    else None

  (* asctime: "Sun Nov 6 08:49:37 1994", its day padded with a space *)
  let asctime_date s =
    let* weekday = index short_days (sub s 0 3) in
    let* month = index months (sub s 4 3) in
    let* day = if char s 8 ' ' then digits s 9 1 else digits s 8 2 in
    let* seconds = time s 11 in
    let* year = digits s 20 4 in
    if
      String.length s = 24
      && char s 3 ' ' && char s 7 ' ' && char s 10 ' ' && char s 19 ' '
    then make ~weekday ~year ~month ~day ~seconds
    else None

  let parse ?now s =
    if char s 3 ',' then imf_fixdate s
    else if char s 3 ' ' then asctime_date s
    else rfc850_date ?now s

  let format t =
    if not (in_range t) then
      invalid_arg "Replay.Date.format: outside the years 0 to 9999";
    let seconds = int_of_float (Float.floor t) in
    let days = (if seconds >= 0 then seconds else seconds - 86399) / 86400 in
    let time = seconds - (days * 86400) in
    let year, month, day = civil_from_days days in
    Printf.sprintf "%s, %02d %s %04d %02d:%02d:%02d GMT"
      short_days.(weekday days)
      day
      months.(month - 1)
      year (time / 3600)
      (time / 60 mod 60)
      (time mod 60)
end

let date_field ~now = ("date", Date.format now)

let trim s =
  let is_space = function ' ' | '\t' -> true | _ -> false in
  let n = String.length s in
  let first = ref 0 and last = ref n in
  while !first < n && is_space s.[!first] do
    incr first
  done;
  while !last > !first && is_space s.[!last - 1] do
    decr last
  done;
  String.sub s !first (!last - !first)

(* The date of a message with exactly one valid [date] field. *)
let date_of ?now fields =
  match Bhttp.Field.get_all "date" fields with
  | [ value ] -> Date.parse ?now (trim value)
  | _ -> None

module Cache = struct
  type t = {
    window : float;
    capacity : int;
    expiries : (string, float) Hashtbl.t;
    order : (float * string) Queue.t;
  }

  let create ~window ~capacity =
    if not (window > 0.) then invalid_arg "Replay.Cache.create: window";
    if capacity <= 0 then invalid_arg "Replay.Cache.create: capacity";
    {
      window;
      capacity;
      expiries = Hashtbl.create (min capacity 4096);
      order = Queue.create ();
    }

  (* Keys are added in the order of their expiry, as long as the clock does not
     go back; if it does, a key is kept for longer, never for less. *)
  let rec expire t ~now =
    match Queue.peek_opt t.order with
    | Some (expiry, digest) when expiry <= now ->
        ignore (Queue.pop t.order);
        Hashtbl.remove t.expiries digest;
        expire t ~now
    | Some _ | None -> ()

  let add t ~now key =
    expire t ~now;
    let digest = Digestif.SHA256.(to_raw_string (digest_string key)) in
    if Hashtbl.mem t.expiries digest then `Replayed
    else if Hashtbl.length t.expiries >= t.capacity then `Full
    else
      let expiry = now +. t.window in
      Hashtbl.replace t.expiries digest expiry;
      Queue.push (expiry, digest) t.order;
      `New

  let length t = Hashtbl.length t.expiries
end

type t = { cache : Cache.t; tolerance : float; require_date : bool }

let create ?(require_date = true) ~tolerance ~capacity () =
  if not (tolerance > 0.) then invalid_arg "Replay.create: tolerance";
  {
    cache = Cache.create ~window:(2. *. tolerance) ~capacity;
    tolerance;
    require_date;
  }

type rejection = Date_missing | Date_skewed of float | Replayed | Full

let check t ~now ~enc (request : Bhttp.Request.t) =
  let date =
    match date_of ~now request.headers with
    | None -> if t.require_date then Error Date_missing else Ok ()
    | Some date ->
        let skew = date -. now in
        if Float.abs skew > t.tolerance then Error (Date_skewed skew) else Ok ()
  in
  Result.bind date (fun () ->
      match Cache.add t.cache ~now enc with
      | `New -> Ok ()
      | `Replayed -> Error Replayed
      | `Full -> Error Full)

let date_problem_type = "https://iana.org/assignments/http-problem-types#date"

let date_problem_body =
  Printf.sprintf
    {|{"type":"%s","title":"date field in request outside of acceptable range"}|}
    date_problem_type

let rejection_response ~now = function
  | Date_missing | Date_skewed _ ->
      Bhttp.Response.make ~status:400
        ~headers:[ date_field ~now; ("content-type", Media_type.problem_json) ]
        ~content:date_problem_body ()
  | Replayed -> Bhttp.Response.make ~status:400 ()
  | Full -> Bhttp.Response.make ~status:503 ()

let contains s part =
  let n = String.length s and m = String.length part in
  let rec at i =
    i + m <= n && (String.equal (String.sub s i m) part || at (i + 1))
  in
  at 0

let date_of_problem (response : Bhttp.Response.t) =
  let is_problem =
    response.status = 400
    && (match Bhttp.Field.get "content-type" response.headers with
      | Some content_type ->
          Media_type.matches Media_type.problem_json content_type
      | None -> false)
    && contains response.content ("\"" ^ date_problem_type ^ "\"")
  in
  if is_problem then date_of response.headers else None

let pp_rejection fmt = function
  | Date_missing -> Format.pp_print_string fmt "no valid date field"
  | Date_skewed skew ->
      Format.fprintf fmt "date %+.0f seconds from the gateway's clock" skew
  | Replayed -> Format.pp_print_string fmt "replayed request"
  | Full -> Format.pp_print_string fmt "replay cache full"
