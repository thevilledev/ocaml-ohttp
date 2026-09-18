# Test-vector provenance

Every fixture in this directory comes from a pinned, immutable source, and is
reproducible with a script in `tools/`. Fixtures are not refreshed from moving
branches; a change must cite its source revision and update this file.

Hexadecimal values are never transcribed by hand. `tools/extract_rfc_vectors.py`
reads them from the text of the RFC, refuses a text whose SHA-256 digest differs
from the one pinned below, and checks what it extracts against properties that
the RFC itself states.

## Licenses

| Fixture | Origin | License |
| --- | --- | --- |
| `rfc9292.json` | RFC 9292, Copyright (c) 2022 IETF Trust and the persons identified as the document authors | IETF Trust Legal Provisions (BCP 78) |
| `rfc9458.json` | RFC 9458, Copyright (c) 2024 IETF Trust and the persons identified as the document authors | IETF Trust Legal Provisions (BCP 78) |
| `chunked-ohttp-08.json` | draft-ietf-ohai-chunked-ohttp-08, Copyright (c) 2026 IETF Trust and the persons identified as the document authors | IETF Trust Legal Provisions (BCP 78) |
| `ohttp-go-vectors.json` | Generated for this project with [chris-wood/ohttp-go](https://github.com/chris-wood/ohttp-go) | ISC, as the rest of the project |

RFC 9292, RFC 9458, and the chunked OHTTP draft are IETF-stream documents. The
files reproduce only the example values of RFC 9292 Section 5, RFC 9458
Appendix A, and the draft's Appendix A, with a citation of their source.

## RFC 9292

| Source | SHA-256 of the text |
| --- | --- |
| <https://www.rfc-editor.org/rfc/rfc9292.txt> | `82499b50f19e8667459710b270a3b56eb594494d87f5d6b6f29e79c0e1176e51` |

`rfc9292.json` holds the four encoded messages of Section 5: Figure 8
(known-length request, 135 bytes), Figure 9 (the same request with
indeterminate length and ten bytes of padding, 144 bytes), Figure 11
(indeterminate-length response with two informational responses, 368 bytes), and
Figure 13 (known-length response with a trailer section, 48 bytes). The
extractor decodes each hex dump, checks it against the ASCII rendering printed
beside it, and fails unless every message has the length given here.

The HTTP/1.1 messages that these encodings stand for, Figures 7, 10, and 12, are
plain text and are written out in `test/bhttp/test_vectors.ml`. The tests check
both directions: each encoding decodes to its message, and each message encodes
to exactly the bytes of the RFC.

```sh
curl -O https://www.rfc-editor.org/rfc/rfc9292.txt
python3 tools/extract_rfc_vectors.py rfc9292 rfc9292.txt test/vectors/rfc9292.json
```

## RFC 9458

| Source | SHA-256 of the text |
| --- | --- |
| <https://www.rfc-editor.org/rfc/rfc9458.txt> | `55f13cb7b3501e29f9edbbbbd9c8a3e13b84799d609d0e01443f543effa99350` |

`rfc9458.json` holds the fourteen values of Appendix A in the order they
appear: the gateway's X25519 secret key, its key configuration, the Binary HTTP
request, the client's ephemeral secret key and public key, the HPKE `info`, the
Encapsulated Request, the Binary HTTP response, the exported secret, the salt,
the pseudorandom key, the AEAD key and nonce, and the Encapsulated Response. The
appendix does not print the response nonce on its own; the extractor takes it
from the end of the salt and records it as `response_nonce`.

The extractor fails unless it finds exactly fourteen values of the expected
lengths, and unless they agree with each other: the `info` is the request label
and the header of the Encapsulated Request, the request carries the ephemeral
public key, the salt is that key and the nonce that starts the Encapsulated
Response, and the pseudorandom key, AEAD key, and AEAD nonce follow from the
salt and secret by plain HKDF-SHA256, which the script computes itself.

The tests reproduce every value, in both directions. The gateway's direction
needs the response nonce, which a fixed generator replays. The client's
direction needs the ephemeral secret key, which RFC 9180 derives from
randomness in a way that cannot be inverted, so the test sets up its sender
with `hpke.for_testing`.

The HTTP/1.1 messages of the appendix give `Content-Length: 78` and
`Content-Length: 38` for messages of 80 and 35 bytes. The hexadecimal values
are authoritative.

```sh
curl -O https://www.rfc-editor.org/rfc/rfc9458.txt
python3 tools/extract_rfc_vectors.py rfc9458 rfc9458.txt test/vectors/rfc9458.json
```

## Chunked OHTTP

| Source | SHA-256 of the text |
| --- | --- |
| <https://www.ietf.org/archive/id/draft-ietf-ohai-chunked-ohttp-08.txt> | `c7fa23ec2b34b75744c2ba5275d628d5607c30125c7c9a32fb05f14f0688c207` |

The archive URL of a numbered draft is immutable. Revision 08 is the one in the
RFC Editor's queue; when the RFC is published, the fixture moves to its text.

`chunked-ohttp-08.json` holds the values of the draft's Appendix A. They are
those of RFC 9458 Appendix A with other keys, except that the Encapsulated
Request and Response are printed one part to a line, "to show where these
chunks start", and that the nonces of the three response chunks follow. The
extractor removes the page breaks of the draft, keeps those lines apart, and
records what the appendix says each chunk holds as `request_chunks` and
`response_chunks`: 12 and 13 bytes of the request and an empty final chunk, and
1 and 2 bytes of the response and an empty final chunk.

Besides the checks of the RFC 9458 extraction, it verifies that every non-final
chunk starts with its own length, that every final chunk starts with a zero
length, and that the three chunk nonces are the base nonce XORed with 0, 1, and
2. The third nonce ends in `44` where addition would give `48`, which makes
this vector the test of that distinction.

```sh
curl -O https://www.ietf.org/archive/id/draft-ietf-ohai-chunked-ohttp-08.txt
python3 tools/extract_rfc_vectors.py chunked-ohttp-08 \
  draft-ietf-ohai-chunked-ohttp-08.txt test/vectors/chunked-ohttp-08.json
```

## ohttp-go

`ohttp-go-vectors.json` is the unmodified output of the vector generator that
[chris-wood/ohttp-go](https://github.com/chris-wood/ohttp-go) ships in
`ohttp_test.go`, at module version `v0.0.0-20260205154755-776f22a178b8` (commit
`776f22a178b8`), generated on 2026-09-18 with Go 1.27.1. Its SHA-256 is
`4d2aa32a0b43952d3ca3a1213f7c2455fb4f9ba4103fc95d552d0ce451f862f4`.

```sh
git clone https://github.com/chris-wood/ohttp-go && cd ohttp-go
git checkout 776f22a178b8 && rm -rf vendor
OHTTP_TEST_VECTORS_OUT=ohttp-go-vectors.json \
  go test -mod=mod -run 'TestVectorGenerate$' -count=1 .
```

The generator draws a fresh seed, ephemeral key, and response nonce on every
run, so a new run gives different bytes; the recorded file is the fixture. It
holds one exchange over DHKEM(X25519, HKDF-SHA256), HKDF-SHA256, and
AES-128-GCM. ohttp-go checks such a file only by sealing and opening again. Here
the recorded bytes are the known answers: the seed must derive the recorded key
configuration, the recorded Encapsulated Request must open to the request, and
the recorded Encapsulated Response must open under the secret that the
gateway's side of the same HPKE context exports.
