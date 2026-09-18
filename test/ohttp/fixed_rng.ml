(* A generator that replays given bytes, so that a test can choose what the
   library draws: here, the response nonce of a published vector. It fails once
   the bytes run out, which also shows that nothing more was drawn. *)

module Generator = struct
  type g = { data : string; mutable offset : int }

  let block = 1
  let create ?time:_ () = { data = ""; offset = 0 }

  let generate_into ~g buffer ~off length =
    if length > String.length g.data - g.offset then
      invalid_arg "fixed test RNG exhausted";
    Bytes.blit_string g.data g.offset buffer off length;
    g.offset <- g.offset + length

  let reseed ~g:_ _ = ()
  let accumulate ~g:_ _ = `Acc (fun _ -> ())
  let seeded ~g:_ = true
  let pools = 0
end

let of_string data =
  Mirage_crypto_rng.create ~g:{ Generator.data; offset = 0 } (module Generator)
