#!/usr/bin/env python3
"""Extract the examples of the RFCs into test corpora.

The hexadecimal values are read from the RFC text itself, which is pinned by
its SHA-256 digest, and are never transcribed by hand. Every extraction checks
what it finds against properties the RFC states, and fails rather than emit a
corpus it cannot account for.

    curl -O https://www.rfc-editor.org/rfc/rfc9292.txt
    python3 tools/extract_rfc_vectors.py rfc9292 rfc9292.txt \\
        test/vectors/rfc9292.json
"""

from __future__ import annotations

import argparse
import hashlib
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


Extractor = Callable[[str], list[dict[str, Any]]]

SOURCES: dict[str, tuple[str, str, Extractor]] = {
    "rfc9292": (RFC9292_URL, RFC9292_SHA256, extract_rfc9292),
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
