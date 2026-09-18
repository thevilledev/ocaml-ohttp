# Changelog

## 0.1.0 — unreleased

- Add `bhttp`, a codec for Binary HTTP (RFC 9292): known-length and
  indeterminate-length requests and responses, informational responses,
  trailers, padding, and truncation. Decoding accepts every integer size and
  every truncation that the RFC allows, and rejects invalid messages; encoding
  refuses to produce them.
- Add `ohttp`, an implementation of Oblivious HTTP (RFC 9458): key
  configurations in both of their encodings, and request and response
  encapsulation for clients and gateways over every KEM, KDF, and AEAD of the
  `hpke` package. A gateway accepts only what its keys advertise, and reports
  everything that a peer can cause as one error.
- Add `Ohttp.Http_message` and `Ohttp.Http_binding`: exchanges of Binary HTTP
  messages, and the fields, checks, and error responses of RFC 9458 Section 5,
  without I/O. Examples over cohttp-lwt-unix show a client, a relay, a gateway,
  and a target, and run end to end with `dune build @e2e`.
- Add `Ohttp.Chunked`, an experimental implementation of chunked Oblivious HTTP
  (draft-ietf-ohai-chunked-ohttp-08): incremental senders and receivers for
  requests and responses, which take a stream in whatever slices a transport
  delivers and detect truncation. The interface may change before the draft is
  published as an RFC.
- Reproduce the examples of RFC 9292 Section 5, RFC 9458 Appendix A, and the
  draft's Appendix A byte for byte, in both directions, from values that a
  script extracts from the pinned text of each document.
- Validate both packages against chris-wood/ohttp-go and martinthomson/ohttp
  with a differential harness, in both roles and for every suite in common, and
  replay what they produced in the test suites.
- Require `hpke` 0.2.0, for the suite's KDF and AEAD and for the deterministic
  senders of `hpke.for_testing`.
- Remain an unaudited, non-production release intended for interoperability
  review.
