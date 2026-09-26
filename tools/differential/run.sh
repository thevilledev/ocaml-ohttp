#!/bin/sh
# Build the peers and run the differential driver against them.
#
#   tools/differential/run.sh [--count N] [--seed N] [--only PREFIX]
#                             [--output-dir DIR]
#
# The Go peer needs Go, and network access the first time, for its modules.
# The Rust peer needs Docker, and network access the first time, for its base
# image and crates; afterwards it runs without a network. A peer whose tools
# are missing is skipped, unless --output-dir asks for a corpus: a recorded
# corpus that silently lacks a peer would be worse than none.
set -eu

root=$(cd "$(dirname "$0")/../.." && pwd)
out=${DIFFERENTIAL_BUILD_DIR:-$root/_build/differential}
mkdir -p "$out"

recording=false
for arg in "$@"; do
  [ "$arg" = "--output-dir" ] && recording=true
done

set --  "$@" --rfc9292 "$root/test/vectors/rfc9292.json"

if command -v go >/dev/null 2>&1; then
  (cd "$root/tools/differential/go" && go build -o "$out/go-peer" .)
  # Inside the module, which may select a newer toolchain than the one on PATH.
  go_version=$(cd "$root/tools/differential/go" && go version | cut -d' ' -f3)
  set -- "$@" --peer "go=$out/go-peer" --source "go=$go_version"
elif $recording; then
  echo "recording needs the Go peer, and go is not installed" >&2
  exit 3
fi

if docker info >/dev/null 2>&1; then
  DOCKER_BUILDKIT=1 docker build -q -t ocaml-ohttp/rust-peer:0.8.0 \
    "$root/tools/differential/rust" >/dev/null
  rust_image=$(docker image inspect -f '{{.Id}}' ocaml-ohttp/rust-peer:0.8.0)
  set -- "$@" --peer "rust=$root/tools/differential/rust/peer.sh" \
    --source "rust-image=$rust_image"
elif $recording; then
  echo "recording needs the Rust peer, and docker is not running" >&2
  exit 3
fi

if $recording; then
  set -- "$@" --require go --require rust
fi

(cd "$root" && opam exec -- dune build ./tools/differential/differential.exe)
exec "$root/_build/default/tools/differential/differential.exe" "$@"
