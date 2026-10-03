# Changelog

## 0.1.0 — 2026-10-03

- Add `bhttp`, a codec for Binary HTTP (RFC 9292): known-length and
  indeterminate-length requests and responses, informational responses,
  trailers, padding, and truncation. Decoding accepts every integer size and
  every truncation that the RFC allows, and rejects invalid messages; encoding
  refuses to produce them.
- Add `ohttp`, an implementation of Oblivious HTTP (RFC 9458): key
  configurations in both of their encodings, and request and response
  encapsulation for clients and gateways over every KEM, KDF, and AEAD of the
  `hpke` package: 99 suites. A gateway accepts only what its keys advertise,
  and reports everything that a peer can cause as one error.
- Provide the post-quantum KEMs of draft-ietf-hpke-pq-05 through `hpke`:
  MLKEM768-X25519 (X-Wing), MLKEM768-P256, MLKEM1024-P384, and ML-KEM-512, 768,
  and 1024, beside the Diffie-Hellman KEMs, X448 among them. X-Wing is the one
  to choose. The one-stage SHAKE KDFs of the same draft are read in a key
  configuration but never chosen, since RFC 9458 derives the response keys
  with `Extract` and `Expand`.
- Add `Ohttp.Replay`, the defences of RFC 9458 Section 6.5 without I/O: a
  bounded cache of the encapsulated keys of recent requests, the check of a
  request's `date` field in the three formats of RFC 9110, and the `date`
  problem type, through which a client learns the gateway's time and retries.
  `Gateway.encapsulated_key` and `Chunked.Gateway.encapsulated_key` give the
  key to remember. The cohttp examples apply both sides.
- Add `Ohttp.Http_message` and `Ohttp.Http_binding`: exchanges of Binary HTTP
  messages, and the fields, checks, and error responses of RFC 9458 Section 5,
  without I/O. Examples over cohttp-lwt-unix show a client, a relay, a gateway,
  and a target, and run end to end with `dune build @e2e`.
- Add `Ohttp.Service`: the client, relay, and gateway of RFC 9458 Section 5 as
  steps from HTTP messages to HTTP messages, without I/O. The client adds a
  `date` field and retries once, encapsulated anew, with the gateway's time
  when the gateway refuses its date; the relay passes on the content and its
  type and nothing else; the gateway serves its key configurations, checks for
  replay, forwards only to the targets it lists, and seals every answer once
  the encapsulation is off.
- Add adapters for HTTP libraries, one package each, built on `Ohttp.Service`:
  `ohttp-cohttp-lwt` for any client of cohttp-lwt, with targets in the same
  process; `ohttp-cohttp-eio`; and `ohttp-piaf`, over HTTP/1.1 and HTTP/2.
  Each has a client that fetches key configurations and calls through a relay,
  a relay handler, a gateway handler, and forwarding to targets. `ohttp-cohttp`
  has the conversions between the types of the `http` package and those of
  `bhttp` that the two cohttp adapters share. The cohttp examples now use
  `ohttp-cohttp-lwt`.
- Bound what a relay or a gateway holds. `Ohttp.Service.Gateway.create` and
  the new `Ohttp.Service.Relay.create` take the longest request to read, 1 MiB
  by default, and how many requests to handle at once, 256; a relay also takes
  the longest answer to read from its gateway, 8 MiB. The adapters' relay
  handlers take an `Ohttp.Service.Relay.t`, and their clients and
  `Target.forward` a `?max_response_size`, 8 MiB by default. A message over its
  limit is refused from its `content-length` or once its content has been
  counted past the limit, with a 413, a 502, or `Error.Content_too_large`, and
  a request beyond the number in flight with a 503. Rates and timeouts remain
  the deployment's.
- Add `Ohttp.Chunked`, an experimental implementation of chunked Oblivious HTTP
  (draft-ietf-ohai-chunked-ohttp-08): incremental senders and receivers for
  requests and responses, which take a stream in whatever slices a transport
  delivers and detect truncation. The interface may change before the draft is
  published as an RFC.
- Reproduce the examples of RFC 9292 Section 5, RFC 9458 Appendix A, and the
  draft's Appendix A byte for byte, in both directions, from values that a
  script extracts from the pinned text of each document.
- Validate both packages against chris-wood/ohttp-go and martinthomson/ohttp
  with a differential harness, in both roles and for every suite in common,
  X448 and X-Wing with ohttp-go included, and replay what they produced in the
  test suites.
- Require `hpke` 0.4.0, for the post-quantum KEMs, the suite's KDF and AEAD,
  and the deterministic senders of `hpke.for_testing`. Like `hpke` since
  0.3.0, `ohttp` needs a 64-bit OCaml. `bhttp` still has no dependencies.
- Remain an unaudited, non-production release intended for interoperability
  review.
