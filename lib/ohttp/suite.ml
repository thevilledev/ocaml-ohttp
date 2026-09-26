(* HPKE algorithms as Oblivious HTTP names them (RFC 9458 Section 3.1). *)

type symmetric = { kdf : Hpke.Kdf.id; aead : Hpke.Aead.id }
type t = { kem : Hpke.Kem.id; kdf : Hpke.Kdf.id; aead : Hpke.Aead.id }

let make kem ({ kdf; aead } : symmetric) = { kem; kdf; aead }
let symmetric ({ kdf; aead; _ } : t) : symmetric = { kdf; aead }

let symmetric_of_ints (kdf, aead) =
  match (Hpke.Kdf.of_int kdf, Hpke.Aead.of_int aead) with
  | Ok kdf, Ok aead -> Some { kdf; aead }
  | Error _, _ | _, Error _ -> None

let symmetric_to_ints ({ kdf; aead } : symmetric) =
  (Hpke.Kdf.to_int kdf, Hpke.Aead.to_int aead)

let default_symmetric : symmetric list =
  [
    { kdf = Hpke.Kdf.Hkdf_sha256; aead = Hpke.Aead.Aes_128_gcm };
    { kdf = Hpke.Kdf.Hkdf_sha256; aead = Hpke.Aead.Chacha20_poly1305 };
  ]

let all_kems =
  Hpke.Kem.
    [
      X25519;
      P256;
      P384;
      P521;
      X448;
      Mlkem768_x25519;
      Mlkem768_p256;
      Mlkem1024_p384;
      Mlkem512;
      Mlkem768;
      Mlkem1024;
    ]

let all_symmetric : symmetric list =
  List.concat_map
    (fun kdf ->
      List.map
        (fun aead -> { kdf; aead })
        Hpke.Aead.[ Aes_128_gcm; Aes_256_gcm; Chacha20_poly1305 ])
    Hpke.Kdf.[ Hkdf_sha256; Hkdf_sha384; Hkdf_sha512 ]

let hpke { kem; kdf; aead } = Hpke.Suite.create ~kem ~kdf ~aead

let response_nonce_length aead =
  max (Hpke.Aead.nonce_size aead) (Hpke.Aead.key_size aead)

let pp_symmetric fmt ({ kdf; aead } : symmetric) =
  Format.fprintf fmt "%a, %a" Hpke.Kdf.pp kdf Hpke.Aead.pp aead

let pp fmt { kem; kdf; aead } =
  Format.fprintf fmt "%a, %a, %a" Hpke.Kem.pp kem Hpke.Kdf.pp kdf Hpke.Aead.pp
    aead
