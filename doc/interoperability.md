# Interoperability

[README](../README.md) · [Protocol support](protocol-support.md) ·
[Development](development.md) · [Provenance](../test/vectors/PROVENANCE.md)

Test vectors show that an implementation agrees with a document. They do not
show that it agrees with what is deployed. `bhttp` and `ohttp` are therefore
run against two other implementations, by the two authors of RFC 9458:

| Peer | Implementation | Version |
| --- | --- | --- |
| Go | [chris-wood/ohttp-go](https://github.com/chris-wood/ohttp-go), which Cloudflare's gateway builds on | `v0.0.0-20260205154755-776f22a178b8` |
| Rust | [martinthomson/ohttp](https://github.com/martinthomson/ohttp), the `ohttp` and `bhttp` crates | `0.8.0` |

No public relay or gateway can be used without an agreement with its operator,
so everything runs on one machine: see
[`tools/differential`](../tools/differential/README.md). The driver plays the
client against their gateway and the gateway against their client, and
compares what each side's Binary HTTP codec makes of the same bytes. What the
peers sealed is recorded, and `dune runtest` replays it without them.

## Results

From `tools/differential/run.sh --count 16 --seed 9458`, the run that recorded
the corpus in `test/vectors/differential`:

| | Go | Rust |
| --- | --- | --- |
| Key configuration derived from a seed, byte for byte | 144 of 144, over all 36 suites | 16 of 16, over the 4 suites it provides |
| Exchanges, this library as the client | 576 of 576 | 64 of 64 |
| Exchanges, this library as the gateway | 576 of 576 | 64 of 64 |
| Tampered requests and responses, unknown keys | refused by both sides | refused by both sides |
| `application/ohttp-keys` with several keys and suites | no list parser | read alike |
| Chunked exchanges, this library as the client | not provided | 32 of 32 |
| Chunked exchanges, this library as the gateway | not provided | 16 of 32: see below |
| Chunked streams without their end | | refused by both sides |
| Messages that this library encoded, padded or not | 128 of 128 | 256 of 256 |
| Messages that the peer encoded | 64 of 64 | 88 of 88 |

The Rust crate's own HPKE backend provides X25519 and P-256 with HKDF-SHA256
and AES-128-GCM or ChaCha20Poly1305; ohttp-go provides everything that this
library does, through CIRCL.

## Known differences

Where a peer departs from an RFC, or uses a freedom that an RFC gives, the
driver has a rule with the reason. A rule for a fixed case is pinned: if the
peer stops differing, the run fails, so this list cannot go stale. Any other
difference fails the run. In none of them does this library depart from the
RFCs.

### ohttp-go

- **It rejects truncated messages.** RFC 9292 Section 3.8 lets an encoder omit
  empty sections at the end, and requires a decoder to read them as empty.
  ohttp-go requires every length prefix. It rejects Figure 8 of RFC 9292
  without the last two bytes, which Section 5.1 says can each be removed, and
  the request of RFC 9458 Appendix A, which ends after its control data. This
  is why `bhttp` does not truncate unless asked to.
- **It folds the `Host` field into the authority.** It reads a request into
  `net/http` types, where an empty authority is filled from `Host`. Figure 8
  keeps the two apart, "as is required for ensuring that the request is
  reproduced accurately".
- **It does not check padding**, which Section 3.8 permits.
- It has no indeterminate-length framing, informational responses, or
  `application/ohttp-keys` parser, keeps one value for a repeated field name,
  drops the query of a request that it encodes, and panics on a request with
  trailers. The driver generates only what it can carry, so these are
  documented here and not measured.

### martinthomson/ohttp

- **It rejects truncated indeterminate-length messages.** The `bhttp` crate
  reads a missing section as empty only in known-length messages. RFC 9292
  Section 3.2 allows the same for indeterminate-length ones, and Section 5.1
  says of Figure 9 that "anything up to 12 bytes can be removed from this
  message without affecting its meaning"; the crate rejects it without its
  last 11 or 12.
- **It does not validate what it reads.** Field names with bytes that a field
  name cannot hold, field values with line breaks, the forbidden
  pseudo-fields, a pseudo-field after a regular field or in the trailers, and
  non-zero padding are all accepted, which RFC 9292 Sections 3.6 and 3.8 make
  invalid (except for padding, where checking is optional).
- **Its chunked client panics under ChaCha20Poly1305.** The `ohttp` crate keeps
  the nonce of a chunked response in 16 bytes (`ClientResponseState::Header` in
  `src/stream.rs`), but slices it to max(Nn, Nk), which is 32 for an AEAD with
  a 32-byte key. Every chunked response under ChaCha20Poly1305 ends in "range
  end index 32 out of range for slice of length 16". That is the half of the
  chunked exchanges above that fail; the AES-128-GCM half passes. Its gateway
  side draws a nonce of the right length, and interoperates.

## Reproducing

```sh
tools/differential/run.sh                  # whichever peers can be built
tools/differential/run.sh --only chunked/  # one group of categories
```

The Go peer needs Go. The Rust peer needs Docker, since it is built in a
container; it runs without a network. See
[`tools/differential/README.md`](../tools/differential/README.md) for the
protocol between the driver and a peer, which is what another implementation
would need to join in.
