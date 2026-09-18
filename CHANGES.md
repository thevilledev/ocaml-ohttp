# Changelog

## Unreleased

- Add `ohttp`, an implementation of Oblivious HTTP (RFC 9458): key
  configurations in both of their encodings, and request and response
  encapsulation for clients and gateways over every KEM, KDF, and AEAD of the
  `hpke` package. A gateway accepts only what its keys advertise, and reports
  everything that a peer can cause as one error. The example of RFC 9458
  Appendix A is reproduced byte for byte in both directions.
- Add `bhttp`, a codec for Binary HTTP (RFC 9292): known-length and
  indeterminate-length requests and responses, informational responses,
  trailers, padding, and truncation. Decoding accepts every integer size and
  every truncation that the RFC allows, and rejects invalid messages; encoding
  refuses to produce them.
