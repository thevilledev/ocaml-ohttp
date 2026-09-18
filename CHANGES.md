# Changelog

## Unreleased

- Add `bhttp`, a codec for Binary HTTP (RFC 9292): known-length and
  indeterminate-length requests and responses, informational responses,
  trailers, padding, and truncation. Decoding accepts every integer size and
  every truncation that the RFC allows, and rejects invalid messages; encoding
  refuses to produce them.
- Scaffold the `ohttp` package.
