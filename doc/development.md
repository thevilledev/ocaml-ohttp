# Development

[README](../README.md) · [Getting started](getting-started.md) ·
[Interoperability](interoperability.md) · [Release checklist](releasing.md)

## Setup

```sh
git clone https://github.com/thevilledev/ocaml-ohttp.git
cd ocaml-ohttp
opam install . --deps-only --with-test --with-doc --with-dev-setup
```

The dev setup brings ocamlformat and `cohttp-lwt-unix`.
Without `cohttp-lwt-unix` the examples over HTTP build as stubs that say what
is missing, and with it as programs.

`opam install .` installs the dependencies of every package, the adapters for
HTTP libraries included, and `ohttp-cohttp-eio` and `ohttp-piaf` need OCaml 5.
On OCaml 4.14, name the packages that it can build:

```sh
opam install ./bhttp.opam ./ohttp.opam ./ohttp-cohttp.opam ./ohttp-cohttp-lwt.opam \
  --deps-only --with-test
opam exec -- dune build --only-packages bhttp,ohttp,ohttp-cohttp,ohttp-cohttp-lwt
```

```sh
opam exec -- dune build @all
opam exec -- dune runtest
```

The libraries support OCaml 4.14 and later, apart from the Eio adapters. To
check both ends of that range with two switches:

```sh
PACKAGES=bhttp,ohttp,ohttp-cohttp,ohttp-cohttp-lwt
opam exec --switch 4.14.4 -- dune build --build-dir _build_414 --only-packages $PACKAGES @all
opam exec --switch 4.14.4 -- dune runtest --build-dir _build_414 --only-packages $PACKAGES
```

## API documentation

```sh
opam exec -- dune build @doc
```

The reference lands in `_build/default/_doc/_html/`, one landing page for each
package. Every module has an interface file, which opens with the section of
the RFC that it implements.

## Tests

`dune runtest` runs one Alcotest program for each package.

| Suite | What it checks |
| --- | --- |
| `bhttp`: `varint`, `decode`, `encode`, `field` | The rules of RFC 9292, case by case, on messages assembled by hand |
| `bhttp`: `rfc9292` | The four encodings of Section 5, in both directions |
| `ohttp`: `key_config`, `encapsulation`, `http binding` | Both encodings of a key configuration, every suite, and every way of breaking an exchange |
| `ohttp`: `replay` | HTTP dates in their three formats, the replay cache, and a client correcting its clock through the `date` problem |
| `ohttp`: `service` | The client, relay, and gateway of `Ohttp.Service`: what each sends, what it answers in the clear and sealed, the retry with the gateway's time, the targets a gateway refuses, and its limits |
| `ohttp`: `rfc9458`, `chunked` | Appendix A of the RFC and of the chunked draft, byte for byte in both directions, with every intermediate value |
| `upstream vectors`, `differential` | What ohttp-go and the Rust crates produced, replayed without them |
| `properties` | QCheck: round trips, prefixes, corrupted input, and slicing of chunked streams |
| `ohttp-cohttp` | The conversions between the types of the `http` package and those of `bhttp` |
| `ohttp-cohttp-lwt`, `ohttp-cohttp-eio`, `ohttp-piaf` | A client, a relay, a gateway, and a target over loopback, through each adapter: a call, targets that are refused or do not answer, a wrong clock, an unknown key, requests that the relay and the gateway refuse, and messages beyond their limits, declared or counted, and requests beyond how many they handle at once |

Known-answer tests need two things that a library must not offer in
production. The gateway's direction needs a chosen response nonce, which
`test/ohttp/support/fixed_rng.ml` replays through the generator argument. The
client's direction needs a chosen ephemeral key, which comes from
`hpke.for_testing` through `Client.encapsulate_with`.

### Test vectors

Hexadecimal values are never typed in. `tools/extract_rfc_vectors.py` reads
them from the text of an RFC or draft, refuses a text whose SHA-256 digest is
not the pinned one, and checks what it finds against what the document says
about it. [`test/vectors/PROVENANCE.md`](../test/vectors/PROVENANCE.md) has
the sources and the commands.

### Differential testing

```sh
tools/differential/run.sh
```

runs both roles of every exchange against the Go and Rust implementations;
see [interoperability](interoperability.md) and
[`tools/differential/README.md`](../tools/differential/README.md). It needs Go
and Docker, and is not part of `dune runtest`. What it records is.

### Decoder fuzzing

```sh
opam exec -- dune build --profile fuzz fuzz/fuzz_bhttp.exe fuzz/fuzz_ohttp.exe
opam exec -- _build/default/fuzz/fuzz_bhttp.exe --repeat 2000 --seed 9292
opam exec -- _build/default/fuzz/fuzz_ohttp.exe --repeat 2000 --seed 9458
```

The Crowbar targets cover everything that reads a peer's bytes. Binary HTTP is
not canonical, so its target checks that a decoded message survives
re-encoding, not that the bytes come back. The executables are behind the
`fuzz` profile, so a normal build does not need Crowbar. CI runs the same seeds
with `--repeat 300` to stay quick; run the longer version above when changing a
decoder.

### Formatting

```sh
opam exec -- dune build @fmt        # check
opam exec -- dune fmt               # fix
```

## Repository map

| Path | Purpose |
| --- | --- |
| `lib/bhttp/`, `lib/ohttp/` | Interfaces (`.mli`) and implementations (`.ml`) of the two packages |
| `lib/ohttp-cohttp/`, `lib/ohttp-cohttp-lwt/`, `lib/ohttp-cohttp-eio/`, `lib/ohttp-piaf/` | The adapters for HTTP libraries, one package each |
| `examples/` | `basic.ml`, and a client, relay, gateway, and target over cohttp-lwt-unix |
| `test/bhttp/`, `test/ohttp/` | The test programs, each with a `support/` library that `tools/` shares |
| `test/ohttp-cohttp*/`, `test/ohttp-piaf/` | The test program of each adapter |
| `test/vectors/` | Pinned fixtures, the recorded differential corpus, and provenance |
| `fuzz/` | Crowbar targets |
| `tools/extract_rfc_vectors.py` | Extracts the fixtures from RFC text |
| `tools/differential/` | The differential driver and its Go and Rust peers |
| `doc/` | These guides, and the odoc landing page of each package |
| `*.opam` | Package metadata, written by hand |

### Module map

| Package | Area | Modules |
| --- | --- | --- |
| `bhttp` | Messages | `Request`, `Response`, `Message`, `Field` |
| `bhttp` | Encoding | `Framing`, `Varint`, `Wire` (private), `Hex`, `Error` |
| `ohttp` | Application interface | `Key_config`, `Http_message`, `Http_binding`, `Replay`, `Media_type`, `Error` |
| `ohttp` | The parties, as steps between HTTP messages | `Service` |
| `ohttp` | Exchanges of byte strings | `Client`, `Gateway`, `Suite` |
| `ohttp` | Byte layout and key schedule, as pure functions | `Encapsulation` |
| `ohttp` | Chunked Oblivious HTTP | `Chunked` |
| `ohttp-cohttp` | Conversions for the types of the `http` package | `Ohttp_cohttp` |
| `ohttp-cohttp-lwt`, `ohttp-cohttp-eio`, `ohttp-piaf` | Client, relay, gateway, and targets over each library | `Ohttp_cohttp_lwt`, `Ohttp_cohttp_eio`, `Ohttp_piaf` |

Every test stanza names its package, and the two support libraries depend on
one package each, so that `dune build -p bhttp` never needs `ohttp`. An adapter
depends on `ohttp`, `bhttp`, and its HTTP library, and nothing else of this
repository but `ohttp-cohttp` for the two cohttp adapters.

## CI and packaging

`.github/workflows/ci.yml` builds and tests on OCaml 4.14, without the Eio
adapters, and on 5.4, with every package. It installs each package from its
opam file with its tests, checks formatting, runs the fuzzers with their fixed
seeds, builds and runs the examples with cohttp installed, and runs the
differential driver against the Go peer.
