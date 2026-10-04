# Differential testing

`differential.exe` plays both roles of Binary HTTP and Oblivious HTTP against
other implementations, and compares what comes back with what it sent or with
its own verdict. `run.sh` builds the peers and runs it:

```sh
tools/differential/run.sh                 # whichever peers can be built
tools/differential/run.sh --only chunked/ # categories with this prefix
tools/differential/run.sh --count 16 --seed 9458 \
  --output-dir test/vectors/differential  # record the corpus; needs every peer
```

It is not part of any package, and `dune runtest` does not run it. What it
records is replayed by `test/bhttp/test_differential.ml` and
`test/ohttp/test_differential.ml`, so the cross-implementation answers are
checked on every test run, without Go, Docker, or a network.

## Peers

| Name | Implementation | How it runs |
| --- | --- | --- |
| `go` | [chris-wood/ohttp-go](https://github.com/chris-wood/ohttp-go), pinned in `go/go.mod` | built with the local Go toolchain |
| `rust` | [martinthomson/ohttp](https://github.com/martinthomson/ohttp), the `ohttp` and `bhttp` crates pinned in `rust/Cargo.toml` and `rust/Cargo.lock` | built and run in Docker, without a network at run time |

A peer says what it can do in its answer to `hello`: the KEMs, KDFs, and AEADs
it provides, and features such as `bhttp-indeterminate`, `bhttp-rich` (repeated
fields, trailers, informational responses, any path), `bhttp-field-order`,
`config-list`, `multi-suite-config`, and `chunked`. The driver gives each peer
only what it can carry, and compares accordingly: field names are compared
without their case, which `bhttp` lowercases, and a peer without
`bhttp-field-order` keeps fields in a map, so its fields are compared as a
sorted list.

## Categories

| Category | What is compared |
| --- | --- |
| `config/derive` | the key configuration derived from a seed, byte for byte |
| `config/derive-draft` | the same, once for each KEM, against the derivation of RFC 9180 and draft-ietf-hpke-pq rather than the peer's own |
| `config/parse`, `config/list`, `config/parse-invalid` | the peer reads our configurations, and refuses malformed ones |
| `ohttp/ocaml-client`, `ohttp/peer-client` | a whole exchange in each direction, for every suite in common |
| `ohttp/tampered-request`, `ohttp/tampered-response`, `ohttp/unknown-key-id` | both sides refuse |
| `bhttp/ocaml-encode`, `bhttp/padded`, `bhttp/peer-encode` | a generated message survives the other side's codec |
| `bhttp/truncated`, `bhttp/prefix`, `bhttp/mutation` | both sides accept or reject the same input, and read it alike |
| `bhttp/rfc-examples`, `bhttp/rfc-truncation`, `bhttp/invalid` | fixed cases: the figures of RFC 9292, whole and cut where Section 5.1 says they can be, and one message for each rule of Sections 3.6 and 3.8 |
| `chunked/ocaml-client`, `chunked/peer-client`, `chunked/truncated` | chunked exchanges in each direction, and a stream without its end |

Cases are drawn from an HMAC-DRBG under `--seed`, so a run is the same on
every OCaml version. What the peers draw is their own.

## Known differences

Where an implementation departs from the RFC, or uses a freedom that the RFC
gives, the driver has a rule in `differential.ml` with the reason, and the
summary marks the category with `*`. A rule for a fixed case is pinned: if the
peer stops differing, the run fails, so the list cannot go stale. Anything
without a rule is printed as `UNEXPECTED` and fails the run.

## Protocol

One JSON object per line each way, strictly in turn, over the peer's standard
input and output. Every byte string is lowercase hexadecimal. A request has an
`id`, which the answer repeats, and an `op`:

```json
{"id": 7, "op": "gateway_decapsulate", "key_id": 1, "kem": 32,
 "symmetric": [[1, 1]], "seed": "…", "enc_request": "…"}
{"id": 7, "ok": true, "request": "…", "handle": 3}
{"id": 7, "ok": false, "error": {"kind": "rejected", "message": "…"}}
```

An error is `unsupported` (the case is skipped), `rejected` (the library
refused the input, which is an answer like any other), or `internal` (the
harness is at fault, or the library panicked). A handle names a context that
lives between two operations, and the second one consumes it.

| `op` | Request | Answer |
| --- | --- | --- |
| `hello` | | `name`, `version`, `protocol`, `kems`, `kdfs`, `aeads`, `features` |
| `config_derive` | `key_id`, `kem`, `symmetric`, `seed` | `config` |
| `config_parse` | `config`, or `config_list` | `configs`, each encoded again |
| `client_encapsulate` | `config`, `request` | `enc_request`, `handle` |
| `client_decapsulate` | `handle`, `enc_response` | `response` |
| `gateway_decapsulate` | `key_id`, `kem`, `symmetric`, `seed`, `enc_request` | `request`, `handle` |
| `gateway_encapsulate` | `handle`, `response` | `enc_response` |
| `bhttp_decode` | `message` | `decoded` |
| `bhttp_encode` | `decoded`, `framing` (`known` or `indeterminate`) | `message` |
| `chunked_client_encapsulate` | `config`, `chunks` | `enc_request`, `handle` |
| `chunked_client_decapsulate` | `handle`, `enc_response` | `response` |
| `chunked_gateway_decapsulate` | as `gateway_decapsulate` | `request`, `handle` |
| `chunked_gateway_encapsulate` | `handle`, `chunks` | `enc_response` |

A key is always given by its seed, from which RFC 9180 `DeriveKeyPair` derives
it, so that a recording can be replayed. A decoded message is the JSON of
`test/bhttp/support/json_message.mli`.
