(* The key pair that the peers of tools/differential derive from a seed.

   It is RFC 9180 DeriveKeyPair, as [Hpke.derive_key_pair] computes it, for
   every KEM but X-Wing (MLKEM768-X25519). There CIRCL, under ohttp-go, hashes
   the seed with SHAKE256 to the 32 bytes of an X-Wing private key, without the
   labels and the suite identifier of LabeledDerive that draft-ietf-hpke-pq
   specifies, so the same seed gives another key pair. A recording names keys by
   their seed, so it is read with the peer's derivation. *)

let derive_key_pair kem ~ikm =
  match (kem : Hpke.Kem.id) with
  | Mlkem768_x25519 ->
      Result.map
        (fun private_key ->
          (private_key, Hpke.Private_key.public_key private_key))
        (Hpke.Private_key.of_bytes ~kem
           (Mlkem.Fips202.shake256 ~output_length:32 ikm))
  | P256 | P384 | P521 | X25519 | X448 | Mlkem512 | Mlkem768 | Mlkem1024
  | Mlkem768_p256 | Mlkem1024_p384 ->
      Hpke.derive_key_pair kem ~ikm
