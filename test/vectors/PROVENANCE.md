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

RFC 9292 is an IETF-stream document. The file reproduces only the example
values of its Section 5, with a citation of their source.

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
