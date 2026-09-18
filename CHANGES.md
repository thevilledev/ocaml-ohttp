# Changelog

## Unreleased

- Add `ohttp`, an implementation of Oblivious HTTP (RFC 9458): key
  configurations in both of their encodings, and request and response
  encapsulation for clients and gateways over every KEM, KDF, and AEAD of the
  `hpke` package. A gateway accepts only what its keys advertise, and reports
  everything that a peer can cause as one error. The example of RFC 9458
  Appendix A is reproduced byte for byte in both directions.
- Validate both packages against chris-wood/ohttp-go and martinthomson/ohttp
  with a differential harness, in both roles and for every suite in common, and
  replay what they produced in the test suites.
- Add `Ohttp.Chunked`, an experimental implementation of chunked Oblivious HTTP
  (draft-ietf-ohai-chunked-ohttp-08): incremental senders and receivers for
  requests and responses, which take a stream in whatever slices a transport
  delivers and detect truncation. The draft's example is reproduced byte for
  byte in both directions. The interface may change before the draft is
  published as an RFC.
- Add `bhttp`, a codec for Binary HTTP (RFC 9292): known-length and
  indeterminate-length requests and responses, informational responses,
  trailers, padding, and truncation. Decoding accepts every integer size and
  every truncation that the RFC allows, and rejects invalid messages; encoding
  refuses to produce them.
