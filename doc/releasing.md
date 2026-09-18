# Release checklist

[README](../README.md) · [Development](development.md) ·
[Changelog](../CHANGES.md)

Use this checklist to prepare an opam release of `bhttp` and `ohttp`. They are
released together, from one tag, and `ohttp` requires the `bhttp` of the same
version.

## 0. Release hpke first

`ohttp` requires `hpke` 0.2.0. Until it is in the opam repository, `ohttp`
cannot be, although `bhttp` can. When it is, remove the `opam pin` steps from
`.github/workflows/ci.yml`, from [getting started](getting-started.md), and
from [development](development.md).

## 1. Review the release contents

- Check the version, date, and user-visible changes in
  [CHANGES.md](../CHANGES.md).
- Review `bhttp.opam` and `ohttp.opam`: dependency lower bounds, OCaml and Dune
  requirements, synopsis, description, license, and repository links.
- Keep the package descriptions in `dune-project` consistent with the opam
  files. This repository sets `generate_opam_files` to `false`, so edits to
  `dune-project` do not regenerate them.
- Check [protocol support](protocol-support.md), [interoperability](interoperability.md),
  and [Security](../SECURITY.md) against the release. Retain the unaudited
  status unless it has changed.
- If draft-ietf-ohai-chunked-ohttp has been published as an RFC, move the
  fixture to the RFC's text, update the references, and reconsider the
  experimental status of `Ohttp.Chunked`.
- Keep source-install instructions available until the packages have been
  accepted into the opam repository; then update the README and
  [getting started guide](getting-started.md) to lead with `opam install ohttp`.

## 2. Run local checks

Follow the [development setup](development.md#setup), then run:

```sh
opam lint bhttp.opam ohttp.opam
opam exec -- dune build @all @doc @fmt
opam exec -- dune runtest
opam exec -- dune build -p bhttp @install @runtest
opam exec -- dune build -p bhttp,ohttp @install @runtest
opam exec -- dune exec examples/basic.exe
opam exec -- dune exec examples/e2e.exe -- --require
opam exec -- dune build --profile fuzz fuzz/fuzz_bhttp.exe fuzz/fuzz_ohttp.exe
opam exec -- _build/default/fuzz/fuzz_bhttp.exe --repeat 2000 --seed 9292
opam exec -- _build/default/fuzz/fuzz_ohttp.exe --repeat 2000 --seed 9458
tools/differential/run.sh
```

Repeat the build and the tests on the oldest supported compiler; see
[development](development.md#setup). `dune build -p bhttp` must pass without
`ohttp`: `bhttp` is installable on its own.

The differential run needs Go and Docker, and must end without an `UNEXPECTED`
or a `STALE` line. If a peer has moved on, update its pin in
`tools/differential/`, record the corpus again as
[provenance](../test/vectors/PROVENANCE.md) describes, and update
[interoperability](interoperability.md).

## 3. Validate the packages in a clean environment

```sh
opam switch create ./_opam 5.4.1 --no-install
opam install ./bhttp.opam --with-test
opam install ./ohttp.opam --with-test
```

## 4. Publish the validated candidate

Tag the commit that passed, and publish both packages from that tag with
`dune-release` or `opam publish`, `bhttp` first.
