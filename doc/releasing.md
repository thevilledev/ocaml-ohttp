# Release checklist

[README](../README.md) · [Development](development.md) ·
[Changelog](../CHANGES.md)

Use this checklist to prepare an opam release of `bhttp`, `ohttp`, and the
adapters for HTTP libraries: `ohttp-cohttp`, `ohttp-cohttp-lwt`,
`ohttp-cohttp-eio`, and `ohttp-piaf`. They are released together, from one
tag, and each requires the others of the same version that it depends on.

## 0. Release hpke first

`ohttp` requires `hpke` 0.4.0, which is in the opam repository. If a release
needs a newer `hpke`, publish that `hpke` first: opam-repository does not
accept `pin-depends`, so no `.opam` file here may carry one when it is
submitted.

## 1. Review the release contents

- Check the version, date, and user-visible changes in
  [CHANGES.md](../CHANGES.md).
- Review every `.opam` file: dependency lower bounds, OCaml and Dune
  requirements, synopsis, description, license, and repository links. The Eio
  adapters require OCaml 5.1.
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
opam lint *.opam
opam exec -- dune build @all @doc @fmt
opam exec -- dune runtest
opam exec -- dune build -p bhttp @install @runtest
opam exec -- dune build -p bhttp,ohttp @install @runtest
opam exec -- dune build -p bhttp,ohttp,ohttp-cohttp,ohttp-cohttp-lwt,ohttp-cohttp-eio,ohttp-piaf @install @runtest
opam exec -- dune exec examples/basic.exe
opam exec -- dune exec examples/e2e.exe -- --require
opam exec -- dune build --profile fuzz fuzz/fuzz_bhttp.exe fuzz/fuzz_ohttp.exe
opam exec -- _build/default/fuzz/fuzz_bhttp.exe --repeat 2000 --seed 9292
opam exec -- _build/default/fuzz/fuzz_ohttp.exe --repeat 2000 --seed 9458
tools/differential/run.sh
```

Repeat the build and the tests on the oldest supported compiler, without the
Eio adapters; see [development](development.md#setup). `dune build -p bhttp`
must pass without `ohttp`: `bhttp` is installable on its own.

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
opam install ./ohttp-cohttp.opam --with-test
opam install ./ohttp-cohttp-lwt.opam --with-test
opam install ./ohttp-cohttp-eio.opam --with-test
opam install ./ohttp-piaf.opam --with-test
```

## 4. Publish the validated candidate

Tag the commit that passed, and publish the packages from that tag with
`dune-release` or `opam publish`: `bhttp` first, then `ohttp`, then
`ohttp-cohttp`, then the adapters.
