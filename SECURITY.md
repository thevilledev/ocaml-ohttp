# Security

These libraries have not received an independent cryptographic audit and are
not production-ready. They are published for interoperability review.

## Scope

- Decoding untrusted input is designed to fail closed. Binary HTTP messages,
  key configurations, and encapsulated messages are rejected unless they are
  well formed, and none of the decoders raises. A list of key configurations
  with any malformed part is rejected whole, as RFC 9458 Section 3.2 requires.
- A gateway accepts only the KEM, KDF, and AEAD that the addressed key
  advertises, whatever else the library provides, and reports every failure
  that a peer can cause as one error, `Decapsulation_failed`, so that it does
  not tell its peer which step failed. `Http_binding.Gateway.error_response`
  answers all of them alike. That includes the post-quantum KEMs: ML-KEM
  decapsulates a tampered ciphertext to an unrelated secret, so the request
  fails when it is opened, and a hybrid refuses an invalid elliptic-curve
  element; both are `Decapsulation_failed`.
- Every request uses a fresh HPKE context (RFC 9458 Section 6.1), and every
  response a fresh nonce, which a gateway draws even for a replayed request.
- Response contexts are immutable values that hold the exported secret of one
  exchange, and nothing of the HPKE context.
- A Binary HTTP request cannot carry a line break, a space, or a control
  character in its method, scheme, authority, or path. This is stricter than
  RFC 9292, and keeps a request from being split when a gateway replays it
  over HTTP/1.1. Field values cannot carry NUL, CR, or LF.
- A chunked message is complete only when `Chunked.Receiver.finish` succeeds.
  Data is returned as it arrives, so a caller that acts on it earlier accepts
  the risks of truncation that Section 7.1 of the draft describes. Chunks
  beyond the size limit are refused from their length, before they are
  buffered.
- The random generator is always an argument. The libraries never reach for a
  global one.

## Limitations

- Secret key material lives in ordinary OCaml strings and cannot be reliably
  zeroised; the runtime and garbage collector may copy it.
- Replay protection is the gateway's to apply. `Replay.check` keeps the
  encapsulated keys of recent requests and checks their `date` field, as RFC
  9458 Section 6.5 describes, but only for a gateway that calls it, and only
  within one process. Requests that are not idempotent need it. With
  `~require_date:false`, a request without a date can be replayed once its key
  has been forgotten, and a full cache refuses requests rather than let one
  through unremembered.
- Post-quantum protection covers only requests that a client seals to a
  post-quantum key. The ML-KEM and hybrid KEMs follow draft-ietf-hpke-pq-05,
  which may still change, and the ML-KEM implementation of the `mlkem`
  package is as unaudited as these libraries.
- Key configurations are only parsed. A client must fetch them over a channel
  that authenticates the gateway, and must get the same ones as every other
  client, or the gateway can tell clients apart (RFC 9458 Sections 6.1 and 7).
  Rotation is the gateway's business: `Gateway.create` takes several keys so
  that an old one can stay beside a new one.
- A gateway's keys must not be used for anything else that uses HPKE with the
  same labels (RFC 9458 Section 6.4).
- Nothing pads messages unless asked to. The length of an encapsulated message
  reveals the length of what it carries; `?padding` is there for callers that
  need to hide it (RFC 9458 Section 6.2.3).
- The relay and the gateway of `examples/` are demonstrations. They do not
  limit request sizes or rates, and the relay does none of the traffic
  analysis defences of RFC 9458 Section 6.2.
- `Ohttp.Chunked` follows a draft, and its interface may change.
- `hpke.for_testing` is a dependency of the tests only. `Client.encapsulate_with`
  accepts a sender setup so that the tests can reproduce published vectors; with
  any setup that the `hpke` library itself provides, it is as safe as
  `Client.encapsulate`.

## Reporting

Report suspected vulnerabilities privately to <ville@vesilehto.fi> rather
than through public issues.
