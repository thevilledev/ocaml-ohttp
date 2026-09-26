# ohttp

**Oblivious HTTP for OCaml.** `ohttp` implements
[RFC 9458](https://www.rfc-editor.org/rfc/rfc9458.html), which lets a client
send an HTTP request through a relay so that no single party sees both who is
asking and what is asked. `bhttp` implements the message format that it
carries, Binary HTTP ([RFC 9292](https://www.rfc-editor.org/rfc/rfc9292.html)),
and is a package of its own.

Neither is an HTTP library, and neither depends on one. An encapsulated message
is a string, and any HTTP library can post it.

> **Status:** unaudited and not production-ready. Intended for interoperability
> review. Read the [security limitations](SECURITY.md) before using the
> libraries. `ohttp` needs `hpke` 0.4.0, whose release candidate is not on
> opam; see [getting started](doc/getting-started.md#install).

## Try it

You need OCaml **4.14 or later** and an active opam switch:

```sh
git clone https://github.com/thevilledev/ocaml-ohttp.git
cd ocaml-ohttp
opam install . --deps-only
opam exec -- dune exec examples/basic.exe
```

The example runs one exchange between a client and a gateway:

```text
gateway received GET https://example.com/hello
client received 200: hello from the target
```

With `cohttp-lwt-unix` installed, `opam exec -- dune build @e2e` runs a client,
a relay, a gateway, and a target over real HTTP on your machine. Read the
[example source](examples/basic.ml) and the
[getting started guide](doc/getting-started.md) to use the libraries in your own
project.

## What it provides

- `bhttp`: requests and responses in both framings of RFC 9292, with
  informational responses, trailers, padding, and truncation. No dependencies.
- `ohttp`: key configurations in both of their encodings, and request and
  response encapsulation for clients and gateways, over every KEM, KDF, and
  AEAD of the [`hpke`](https://github.com/thevilledev/ocaml-hpke) package,
  including X-Wing and the other post-quantum KEMs.
- Replay protection for gateways: a cache of recent requests, the `date`
  check, and the `date` problem through which clients correct their clocks.
- The fields, checks, and error responses of the HTTP binding (RFC 9458
  Section 5), without I/O, and [examples](examples/) over cohttp.
- Chunked Oblivious HTTP
  ([draft-ietf-ohai-chunked-ohttp-08](https://datatracker.ietf.org/doc/draft-ietf-ohai-chunked-ohttp/)),
  experimental.
- The examples of both RFCs and of the draft reproduced byte for byte, and
  [interoperability](doc/interoperability.md) with the Go and Rust
  implementations of the RFC's authors, checked in both roles.

Applications fetch and authenticate key configurations, carry the messages,
and decide which requests to check for replay. See [protocol support](doc/protocol-support.md) for
the exact feature set and known gaps.

## Documentation

| I want to… | Start here |
| --- | --- |
| Install the libraries and understand the example | [Getting started](doc/getting-started.md) |
| Use them with cohttp, or with another HTTP library | [HTTP libraries](doc/http-libraries.md) |
| Check supported features and algorithms | [Protocol support](doc/protocol-support.md) |
| See how other implementations compare | [Interoperability](doc/interoperability.md) |
| Build, test, or find a module | [Development guide](doc/development.md) |
| Prepare an opam release | [Release checklist](doc/releasing.md) |
| Review limitations or report a vulnerability | [Security](SECURITY.md) |
| See what changed | [Changelog](CHANGES.md) |

## License

[ISC](LICENSE).
