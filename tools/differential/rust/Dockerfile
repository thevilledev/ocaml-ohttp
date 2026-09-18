# The Rust peer of tools/differential, built where no Rust toolchain is
# installed. See ../README.md.
#
#   docker build -t ocaml-ohttp/rust-peer:0.8.0 tools/differential/rust
FROM rust:1.90-slim-bookworm AS build
WORKDIR /src
COPY Cargo.toml Cargo.lock* ./
COPY src ./src
RUN --mount=type=cache,target=/usr/local/cargo/registry \
    --mount=type=cache,target=/src/target \
    cargo build --release --locked \
    && cp target/release/peer /usr/local/bin/peer

FROM debian:bookworm-slim
COPY --from=build /usr/local/bin/peer /usr/local/bin/peer
ENTRYPOINT ["/usr/local/bin/peer"]
