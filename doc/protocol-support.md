# Protocol support

[README](../README.md) · [Getting started](getting-started.md) ·
[Interoperability](interoperability.md) · [Security](../SECURITY.md)

What `bhttp` and `ohttp` implement, and what they leave to the application.

## Binary HTTP (RFC 9292)

| Area | Coverage |
| --- | --- |
| Framing | Known-length and indeterminate-length, for requests and responses, read and written |
| Messages | Control data, header fields, content, trailer fields, and any number of informational responses |
| Integers | Every size when reading, since Section 3 does not ask for the shortest; the shortest when writing |
| Truncation and padding | Missing empty sections at the end read as empty, and zero padding is accepted and checked; both can be written (Section 3.8) |
| Validation | Field names and values, the forbidden pseudo-fields and the place of the others, status code ranges, and the framing indicator (Sections 3.3 to 3.6) |
| Fields | Order and repeated names are kept; names are lowercased; the `cookie` exception when values are combined |

Beyond the RFC, a request's method must be a token, and its scheme, authority,
and path may hold no control character, space, or DEL. Connection-specific
fields are accepted, as the RFC requires, and
`Field.without_connection_specific` removes them.

Messages are read and written whole. There is no incremental decoder yet, so a
message has to fit in memory, including one that arrives in chunks.

## Oblivious HTTP (RFC 9458)

| Area | Coverage |
| --- | --- |
| Key configurations | Both encodings: a single configuration (Section 3.1) and `application/ohttp-keys` (Section 3.2). Configurations for unknown KEMs are skipped, unknown KDF and AEAD identifiers are kept and never selected, and a malformed list is rejected whole |
| Encapsulation | Requests and responses, for clients and gateways (Sections 4.3 and 4.4), with the labels as a parameter for other media types (Section 4.6) |
| Gateways | Several keys, addressed by identifier; only the algorithms that a key advertises are accepted |
| HTTP binding | Media types, the fields of each message, the checks on what comes back, the two classes of error, and the `ohttp-key` problem type (Section 5), without I/O |
| Informational responses | A `100-continue` expectation is refused by the client and answered with an encapsulated 417 by the gateway (Section 5.1) |
| Discovery | The well-known path and the `Accept` field of RFC 9540. DNS records are out of scope |
| Replay | A cache of the encapsulated keys of recent requests, the check of their `date` field in the three formats of RFC 9110, and the `date` problem type through which a client corrects its clock (Section 6.5) |

### Algorithms

Every combination that the `hpke` package provides: 99 suites.

| Kind | Identifiers |
| --- | --- |
| KEM, Diffie-Hellman | `0x0010` DHKEM(P-256, HKDF-SHA256), `0x0011` DHKEM(P-384, HKDF-SHA384), `0x0012` DHKEM(P-521, HKDF-SHA512), `0x0020` DHKEM(X25519, HKDF-SHA256), `0x0021` DHKEM(X448, HKDF-SHA512) |
| KEM, post-quantum/traditional hybrid | `0x647a` MLKEM768-X25519 (X-Wing), `0x0050` MLKEM768-P256, `0x0051` MLKEM1024-P384 |
| KEM, post-quantum | `0x0040` ML-KEM-512, `0x0041` ML-KEM-768, `0x0042` ML-KEM-1024 |
| KDF | `0x0001` HKDF-SHA256, `0x0002` HKDF-SHA384, `0x0003` HKDF-SHA512 |
| AEAD | `0x0001` AES-128-GCM, `0x0002` AES-256-GCM, `0x0003` ChaCha20Poly1305 |

RFC 9458 mandates none of them. DHKEM(X25519, HKDF-SHA256) with HKDF-SHA256
and AES-128-GCM is what deployed gateways accept, and is what a key offers
first by default.

### Post-quantum KEMs

An Oblivious HTTP request is sealed once, to the gateway's public key, and
anyone who records it can open it on the day that key is broken. A KEM that
resists a quantum computer protects recorded requests against that day.

- **Use X-Wing** (MLKEM768-X25519, `0x647a`) unless there is a reason to choose
  another. A hybrid stays as strong as its elliptic-curve half if ML-KEM turns
  out weaker than believed, and X-Wing is the hybrid that other
  implementations provide: [ohttp-go](interoperability.md), through CIRCL,
  exchanges requests with this library under it. Of the pure ML-KEM KEMs,
  draft-ietf-hpke-pq prefers ML-KEM-768 and ML-KEM-1024 to ML-KEM-512.
- **They cost bytes.** An X-Wing key configuration is about 1.2 KB, and the
  encapsulated key that starts every request is 1120 bytes, against 32 for
  X25519. A response is no larger.
- **They follow drafts.** The KEMs are those of draft-ietf-hpke-pq-05, which
  is not yet an RFC. The encodings of keys and ciphertexts are those of FIPS
  203 and are not expected to change; the derivation of a key pair from a seed
  may. CIRCL already derives X-Wing keys from a seed differently, so a
  configuration derived from the same seed on each side differs, although
  keys and exchanges interoperate.
- **Only what a client picks protects it.** A client that chooses an X25519
  configuration gets none of this. A gateway can serve an X-Wing key beside an
  X25519 one, with a key identifier each, while clients move over. Every client
  must still be served the same configurations (Sections 6.1 and 7), or the
  choice itself tells them apart.
- **Not the SHAKE KDFs.** draft-ietf-hpke-pq also defines the one-stage KDFs
  SHAKE128 (`0x0010`) and SHAKE256 (`0x0011`). RFC 9458 derives the key and
  nonce of a response with the `Extract` and `Expand` of the suite's KDF
  (Section 4.4), which a one-stage KDF does not have, and no specification says
  how Oblivious HTTP should use one. A configuration that offers them is read
  and re-encoded as it came, and they are never chosen.
- **Not X25519Kyber768Draft00** (`0x0030`), the Kyber of the NIST
  competition, which ML-KEM replaced. ohttp-go and CIRCL still know it; a
  configuration that names it is skipped.

## Chunked Oblivious HTTP (experimental)

[draft-ietf-ohai-chunked-ohttp-08](https://datatracker.ietf.org/doc/draft-ietf-ohai-chunked-ohttp/)
is in the RFC Editor's queue, so its wire format is settled. `Ohttp.Chunked`
implements all of it: both media types, chunked requests and responses, the
final-chunk sentinel, and the size limit of Section 3. It is marked
experimental because its own interface may change, and because only some
implementations provide the chunked variant.

Senders and receivers work on pieces of a byte stream. What they carry is
still a whole Binary HTTP message on each side, until `bhttp` can read one
incrementally.

## Application responsibilities and gaps

- **Carrying the messages.** The adapter packages do it over cohttp-lwt,
  cohttp-eio, and Piaf, and `Ohttp.Service` is what an adapter for another
  library wraps. See [HTTP libraries](http-libraries.md).
- **Key configurations.** Fetching them over an authenticated channel, giving
  every client the same ones, and rotating them (RFC 9458 Sections 6.1 and 7).
- **Replay.** Checking each request that is not idempotent with
  `Ohttp.Replay`, which remembers the encapsulated keys of recent requests,
  checks their `date` field, and answers with the `date` problem type (Section
  6.5). The cache lives in one process; a gateway that runs on several
  machines needs to share it.
- **The relay.** The adapters' relay handlers pass on the content and its type
  and nothing else. A deployed relay has the other duties of Section 6.2 too,
  such as limits and traffic analysis defences.
- **Targets.** A gateway decides which targets it serves. The adapters forward
  only to the authorities that the gateway lists, and refuse the rest with a
  sealed 403.
- **Limits.** The adapters read each message in full and do not limit its
  size, or the rate of requests.
- **Padding.** Available on request, never applied by default.

## Verification

- The examples of RFC 9292 Section 5, RFC 9458 Appendix A, and the chunked
  draft's Appendix A, byte for byte and in both directions. The values are
  extracted from the text of each document, which is pinned by digest:
  [provenance](../test/vectors/PROVENANCE.md).
- What RFC 9292 makes acceptable and invalid, case by case, and every way of
  breaking an exchange: truncation at every byte, a changed bit at every
  position, the wrong key, suite, context, or labels.
- Properties over generated messages, every prefix of them, and corrupted
  input, and Crowbar fuzzing of every decoder.
- [Two other implementations](interoperability.md), in both roles, with what
  they produced replayed by the test suites.
