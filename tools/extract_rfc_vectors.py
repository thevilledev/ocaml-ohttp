#!/usr/bin/env python3
"""Extract the examples of the RFCs into test corpora.

The hexadecimal values are read from the RFC text itself, which is pinned by
its SHA-256 digest, and are never transcribed by hand. Every extraction checks
what it finds against properties the RFC states, and fails rather than emit a
corpus it cannot account for.

    curl -O https://www.rfc-editor.org/rfc/rfc9292.txt
    python3 tools/extract_rfc_vectors.py rfc9292 rfc9292.txt \\
        test/vectors/rfc9292.json

    curl -O https://www.rfc-editor.org/rfc/rfc9458.txt
    python3 tools/extract_rfc_vectors.py rfc9458 rfc9458.txt \\
        test/vectors/rfc9458.json

    curl -O https://www.ietf.org/archive/id/draft-ietf-ohai-chunked-ohttp-08.txt
    python3 tools/extract_rfc_vectors.py chunked-ohttp-08 \\
        draft-ietf-ohai-chunked-ohttp-08.txt test/vectors/chunked-ohttp-08.json
"""

from __future__ import annotations

import argparse
import hashlib
import hmac
import json
import re
from pathlib import Path
from typing import Any, Callable

RFC9292_URL = "https://www.rfc-editor.org/rfc/rfc9292.txt"
RFC9292_SHA256 = "82499b50f19e8667459710b270a3b56eb594494d87f5d6b6f29e79c0e1176e51"

# Figure number, name, and the length the message must have.
RFC9292_FIGURES = (
    (8, "known-length request", 135),
    (9, "indeterminate-length request", 144),
    (11, "indeterminate-length response", 368),
    (13, "known-length response", 48),
)

# "   00034745 54056874 74707300 0a2f6865  ..GET.https../he": an indent of
# three, up to four groups of eight digits, and an ASCII rendering from column
# 40 onwards.
DUMP_INDENT = 3
DUMP_WIDTH = 35
DUMP_TEXT_COLUMN = 40


def fail(message: str) -> None:
    raise SystemExit(f"extract_rfc_vectors: {message}")


def figure_block(lines: list[str], figure: int) -> list[str]:
    """The lines of the artwork that the caption "Figure N:" follows."""
    captions = [
        index
        for index, line in enumerate(lines)
        if re.match(rf"\s+Figure {figure}: ", line)
    ]
    if len(captions) != 1:
        fail(f"expected one caption for figure {figure}, found {len(captions)}")
    end = captions[0] - 1
    while end >= 0 and not lines[end].strip():
        end -= 1
    start = end
    while start > 0 and lines[start - 1].strip():
        start -= 1
    return lines[start : end + 1]


def dump_bytes(block: list[str], figure: int) -> bytes:
    """Decode a hex dump, checking it against its own ASCII rendering."""
    result = bytearray()
    for line in block:
        digits = line[DUMP_INDENT : DUMP_INDENT + DUMP_WIDTH].replace(" ", "")
        if not re.fullmatch(r"(?:[0-9a-f]{2})+", digits):
            fail(f"figure {figure}: not a hex dump line: {line!r}")
        chunk = bytes.fromhex(digits)
        rendering = "".join(
            chr(byte) if 0x20 <= byte <= 0x7E else "." for byte in chunk
        )
        if line[DUMP_TEXT_COLUMN:].rstrip() != rendering.rstrip():
            fail(f"figure {figure}: ASCII rendering disagrees: {line!r}")
        result += chunk
    return bytes(result)


def extract_rfc9292(text: str) -> list[dict[str, Any]]:
    lines = text.splitlines()
    vectors = []
    for figure, name, length in RFC9292_FIGURES:
        message = dump_bytes(figure_block(lines, figure), figure)
        if len(message) != length:
            fail(f"figure {figure}: expected {length} bytes, found {len(message)}")
        vectors.append({"name": name, "figure": figure, "message": message.hex()})
    # Section 5.1 says that Figure 9 "contains 10 bytes of padding" after the
    # three terminators of its empty sections.
    if not vectors[1]["message"].endswith("00" * 13):
        fail("figure 9: expected three terminators and ten bytes of padding")
    return vectors


RFC9458_URL = "https://www.rfc-editor.org/rfc/rfc9458.txt"
RFC9458_SHA256 = "55f13cb7b3501e29f9edbbbbd9c8a3e13b84799d609d0e01443f543effa99350"

# The values of Appendix A in the order they appear, with their lengths.
RFC9458_VALUES = (
    ("skR", 32),
    ("key_config", 45),
    ("request", 25),
    ("skE", 32),
    ("pkE", 32),
    ("info", 29),
    ("encapsulated_request", 80),
    ("response", 3),
    ("secret", 16),
    ("salt", 48),
    ("prk", 32),
    ("aead_key", 16),
    ("aead_nonce", 12),
    ("encapsulated_response", 35),
)


def hex_paragraph_lines(lines: list[str]) -> list[list[bytes]]:
    """Paragraphs that consist of nothing but indented hexadecimal digits."""
    paragraphs: list[list[bytes]] = []
    current: list[bytes] | None = None
    for line in lines + [""]:
        if re.fullmatch(r" {3}(?:[0-9a-f]{2})+", line):
            current = (current or []) + [bytes.fromhex(line.strip())]
        else:
            if current is not None and not line.strip():
                paragraphs.append(current)
            current = None
    return paragraphs


def hex_paragraphs(lines: list[str]) -> list[bytes]:
    return [b"".join(paragraph) for paragraph in hex_paragraph_lines(lines)]


def hkdf_expand_sha256(prk: bytes, info: bytes, length: int) -> bytes:
    """RFC 5869 HKDF-Expand for outputs of at most one hash length."""
    assert length <= 32
    return hmac.new(prk, info + b"\x01", hashlib.sha256).digest()[:length]


def extract_rfc9458(text: str) -> list[dict[str, Any]]:
    lines = text.splitlines()
    starts = [
        index
        for index, line in enumerate(lines)
        if line.startswith("Appendix A.  Complete Example")
    ]
    ends = [index for index, line in enumerate(lines) if line == "Acknowledgments"]
    if not starts or not ends:
        fail("cannot find Appendix A")
    paragraphs = hex_paragraphs(lines[starts[-1] : ends[-1]])
    if len(paragraphs) != len(RFC9458_VALUES):
        fail(f"expected {len(RFC9458_VALUES)} values, found {len(paragraphs)}")
    values: dict[str, bytes] = {}
    for (name, length), value in zip(RFC9458_VALUES, paragraphs):
        if len(value) != length:
            fail(f"{name}: expected {length} bytes, found {len(value)}")
        values[name] = value

    # The appendix does not print the response nonce on its own: it is the end
    # of the salt, and the start of the Encapsulated Response.
    request, salt = values["encapsulated_request"], values["salt"]
    response_nonce = salt[32:]
    header = request[:7]
    checks = {
        "the info ends with the request header": values["info"][-7:] == header,
        "the info starts with the request label": values["info"][:-7]
        == b"message/bhttp request\x00",
        "the request carries pkE": request[7:39] == values["pkE"],
        "the key configuration has the key identifier of the header": values[
            "key_config"
        ][:3]
        == header[:3],
        "the salt starts with pkE": salt[:32] == values["pkE"],
        "the response starts with the response nonce": values[
            "encapsulated_response"
        ][:16]
        == response_nonce,
        # Section 4.4: Extract and Expand are plain HKDF, without HPKE labels.
        "prk = Extract(salt, secret)": hmac.new(
            salt, values["secret"], hashlib.sha256
        ).digest()
        == values["prk"],
        'aead_key = Expand(prk, "key", Nk)': hkdf_expand_sha256(
            values["prk"], b"key", 16
        )
        == values["aead_key"],
        'aead_nonce = Expand(prk, "nonce", Nn)': hkdf_expand_sha256(
            values["prk"], b"nonce", 12
        )
        == values["aead_nonce"],
    }
    for description, holds in checks.items():
        if not holds:
            fail(f"Appendix A is inconsistent: {description}")

    vector: dict[str, Any] = {
        "name": "appendix A",
        "key_id": header[0],
        "kem_id": int.from_bytes(header[1:3], "big"),
        "kdf_id": int.from_bytes(header[3:5], "big"),
        "aead_id": int.from_bytes(header[5:7], "big"),
    }
    for name, _ in RFC9458_VALUES:
        vector[name] = values[name].hex()
        if name == "secret":
            vector["response_nonce"] = response_nonce.hex()
    return [vector]


CHUNKED_URL = "https://www.ietf.org/archive/id/draft-ietf-ohai-chunked-ohttp-08.txt"
CHUNKED_SHA256 = "c7fa23ec2b34b75744c2ba5275d628d5607c30125c7c9a32fb05f14f0688c207"

# The values of the draft's Appendix A in the order they appear. A value that
# the draft splits over lines "to show where these chunks start" has the length
# of each line; the others have a single length.
CHUNKED_VALUES: tuple[tuple[str, int | tuple[int, ...]], ...] = (
    ("skR", 32),
    ("key_config", 45),
    ("request", 25),
    ("skE", 32),
    ("pkE", 32),
    ("info", 37),
    # header, encapsulated key, 12 and 13 bytes of request, and an empty final
    # chunk, each chunk with its length prefix and a 16-byte tag
    ("encapsulated_request", (7, 32, 1 + 12 + 16, 1 + 13 + 16, 1 + 0 + 16)),
    ("response", 3),
    ("secret", 16),
    ("salt", 48),
    ("prk", 32),
    ("aead_key", 16),
    ("aead_nonce", 12),
    # response nonce, 1 and 2 bytes of response, and an empty final chunk
    ("encapsulated_response", (16, 1 + 1 + 16, 1 + 2 + 16, 1 + 0 + 16)),
    ("chunk_nonces", (12, 12, 12)),
)


def unpaginate(text: str) -> list[str]:
    """Remove the page breaks of an Internet-Draft, with their running header
    and footer, and the blank lines that surround them."""
    lines = text.splitlines()
    result: list[str] = []
    index = 0
    while index < len(lines):
        if "\f" in lines[index] or re.search(r"\[Page \d+\]\s*$", lines[index]):
            while result and not result[-1].strip():
                result.pop()
            index += 1
            while index < len(lines) and (
                not lines[index].strip()
                or "\f" in lines[index]
                or lines[index].startswith("Internet-Draft")
            ):
                index += 1
            result.append("")
            continue
        result.append(lines[index])
        index += 1
    return result


def extract_chunked(text: str) -> list[dict[str, Any]]:
    lines = unpaginate(text)
    starts = [i for i, line in enumerate(lines) if line.startswith("Appendix A.  Example")]
    ends = [i for i, line in enumerate(lines) if line == "Acknowledgments"]
    if not starts or not ends:
        fail("cannot find Appendix A")
    paragraphs = hex_paragraph_lines(lines[starts[-1] : ends[-1]])
    if len(paragraphs) != len(CHUNKED_VALUES):
        fail(f"expected {len(CHUNKED_VALUES)} values, found {len(paragraphs)}")
    values: dict[str, bytes] = {}
    parts: dict[str, list[bytes]] = {}
    for (name, lengths), paragraph in zip(CHUNKED_VALUES, paragraphs):
        if isinstance(lengths, int):
            value = b"".join(paragraph)
            if len(value) != lengths:
                fail(f"{name}: expected {lengths} bytes, found {len(value)}")
            values[name] = value
        else:
            found = tuple(len(line) for line in paragraph)
            if found != lengths:
                fail(f"{name}: expected lines of {lengths} bytes, found {found}")
            parts[name] = paragraph

    request, response = parts["encapsulated_request"], parts["encapsulated_response"]
    header, response_nonce = request[0], response[0]
    nonce = int.from_bytes(values["aead_nonce"], "big")
    checks = {
        "the info ends with the request header": values["info"][-7:] == header,
        "the info starts with the chunked request label": values["info"][:-7]
        == b"message/bhttp chunked request\x00",
        "the request carries pkE": request[1] == values["pkE"],
        "the salt is pkE and the response nonce": values["salt"]
        == values["pkE"] + response_nonce,
        "every non-final chunk starts with its length": all(
            chunk[0] == len(chunk) - 1 for chunk in request[2:4] + response[1:3]
        ),
        "every final chunk starts with a zero length": request[4][0] == 0
        and response[3][0] == 0,
        "prk = Extract(salt, secret)": hmac.new(
            values["salt"], values["secret"], hashlib.sha256
        ).digest()
        == values["prk"],
        'aead_key = Expand(prk, "key", Nk)': hkdf_expand_sha256(
            values["prk"], b"key", 16
        )
        == values["aead_key"],
        'aead_nonce = Expand(prk, "nonce", Nn)': hkdf_expand_sha256(
            values["prk"], b"nonce", 12
        )
        == values["aead_nonce"],
        # Section 6.2: the counter is XORed into the nonce, not added to it.
        "chunk_nonce = aead_nonce XOR counter": parts["chunk_nonces"]
        == [(nonce ^ counter).to_bytes(12, "big") for counter in range(3)],
    }
    for description, holds in checks.items():
        if not holds:
            fail(f"Appendix A is inconsistent: {description}")

    vector: dict[str, Any] = {
        "name": "appendix A",
        "key_id": header[0],
        "kem_id": int.from_bytes(header[1:3], "big"),
        "kdf_id": int.from_bytes(header[3:5], "big"),
        "aead_id": int.from_bytes(header[5:7], "big"),
    }
    for name, _ in CHUNKED_VALUES:
        if name in values:
            vector[name] = values[name].hex()
        else:
            vector[name] = [part.hex() for part in parts[name]]
        if name == "secret":
            vector["response_nonce"] = response_nonce.hex()
    # What the appendix says each chunk holds, for the tests to seal and expect.
    vector["request_chunks"] = [values["request"][:12].hex(), values["request"][12:].hex(), ""]
    vector["response_chunks"] = [values["response"][:1].hex(), values["response"][1:].hex(), ""]
    return [vector]


Extractor = Callable[[str], list[dict[str, Any]]]

SOURCES: dict[str, tuple[str, str, Extractor]] = {
    "rfc9292": (RFC9292_URL, RFC9292_SHA256, extract_rfc9292),
    "rfc9458": (RFC9458_URL, RFC9458_SHA256, extract_rfc9458),
    "chunked-ohttp-08": (CHUNKED_URL, CHUNKED_SHA256, extract_chunked),
}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", choices=sorted(SOURCES))
    parser.add_argument("input", type=Path, help="the pinned text of the source")
    parser.add_argument("output", type=Path, help="path for the corpus")
    args = parser.parse_args()

    url, expected_sha256, extract = SOURCES[args.source]
    source_bytes = args.input.read_bytes()
    sha256 = hashlib.sha256(source_bytes).hexdigest()
    if sha256 != expected_sha256:
        fail(f"expected source SHA-256 {expected_sha256}, found {sha256}")

    output = {
        "source": {"url": url, "sha256": sha256},
        "vectors": extract(source_bytes.decode("utf-8")),
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(output, indent=2) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
