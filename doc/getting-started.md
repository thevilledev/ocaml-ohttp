# Getting started

[README](../README.md) · [HTTP libraries](http-libraries.md) ·
[Protocol support](protocol-support.md) · [Development](development.md)

This guide installs `bhttp` and `ohttp`, runs an exchange, and explains how to
use the libraries from an application. They are unaudited; read
[Security](../SECURITY.md) for their limitations and for what is left to the
application.

## Install

Requirements: OCaml **4.14 or later**, opam with an active switch, and Dune
**3.12 or later**. opam installs Dune and the dependencies as needed.

`ohttp` needs `hpke` 0.4.0, for the post-quantum and hybrid KEMs, and runs
only on 64-bit OCaml, as `hpke` does. Until 0.4.0 is on opam, `ohttp.opam`
pins its release candidate with `pin-depends`, and opam fetches it when you
install from a checkout.

### From source

Until the first opam release is published, install from a checkout:

```sh
git clone https://github.com/thevilledev/ocaml-ohttp.git
cd ocaml-ohttp
opam install .
```

`opam install .` installs every package of the checkout, the adapters for
HTTP libraries included, and the Eio adapters need OCaml 5. To install only
what you use, name the packages:

```sh
opam install ./bhttp.opam ./ohttp.opam ./ohttp-cohttp.opam ./ohttp-cohttp-lwt.opam
```

If you only want to build and run the examples in the checkout, use
`opam install . --deps-only` instead. `bhttp` has no dependencies, and
`opam install ./bhttp.opam` installs it alone. For test and documentation
dependencies, follow the [development setup](development.md#setup).

### From the opam repository

Once the packages have been accepted:

```sh
opam install ohttp              # brings in bhttp
opam install ohttp-cohttp-lwt   # or ohttp-cohttp-eio, or ohttp-piaf
```

## Run the example

```sh
opam exec -- dune exec examples/basic.exe
```

```text
gateway received GET https://example.com/hello
client received 200: hello from the target
```

[`examples/basic.ml`](../examples/basic.ml) runs one exchange with no network
in between. Every value that would cross the network is a string in it: the
key configurations that the client fetches, the Encapsulated Request that it
posts to a relay, and the Encapsulated Response that comes back.

To see the same over real HTTP, install an HTTP library and run all four
parties on your machine:

```sh
opam install cohttp-lwt-unix
opam exec -- dune build @e2e
```

```text
ok    the client fetched the key configuration
ok    the target answered through the relay and the gateway
ok    the gateway refuses other targets, inside the encapsulation
ok    a replayed request is refused
ok    a client with a wrong clock corrects it and retries
ok    an unknown key is refused in the clear, with a 400
```

[HTTP libraries](http-libraries.md) walks through that code, and shows the
separate programs.

## Use it with an HTTP library

The adapter packages do the HTTP for each party. Over cohttp-lwt-unix, a
gateway for one target, and a client that calls it through a relay:

```ocaml
module Ohttp_client = Ohttp_cohttp_lwt.Make (Cohttp_lwt_unix.Client)

let gateway =
  Ohttp_cohttp_lwt.Gateway.handler
    (Ohttp.Service.Gateway.create ~rng
       ~replay:(Ohttp.Replay.create ~tolerance:60. ~capacity:100_000 ())
       (Result.get_ok (Ohttp.Gateway.create [ key ])))
    (Ohttp_client.Target.forward
       ~targets:[ ("example.com", Uri.of_string "https://example.com") ])

let call config =
  Ohttp_client.Client.call ~rng
    ~relay:(Uri.of_string "https://relay.example/relay")
    config
    (Bhttp.Request.make ~meth:"GET" ~authority:"example.com" ~path:"/" ())
```

[HTTP libraries](http-libraries.md) has the same for cohttp-eio and Piaf, the
relay, and what the adapters leave to the application. The rest of this guide
uses `ohttp` directly, which is what an application does with a library that
has no adapter.

## Use it in a Dune project

```lisp
(executable
 (name main)
 (libraries ohttp bhttp mirage-crypto-rng.unix))
```

Randomness is an explicit argument everywhere. Seed a generator once at startup
and pass it on:

```ocaml
Mirage_crypto_rng_unix.use_default ();
let rng = Mirage_crypto_rng.default_generator () in
```

### As a client

```ocaml
let ( let* ) = Result.bind

let ask ~rng ~post key_configs =
  (* [key_configs] is the content of application/ohttp-keys, fetched from the
     gateway over a channel that authenticates it. *)
  let* configs = Ohttp.Key_config.decode_list key_configs in
  let* config, _suite = Ohttp.Key_config.select_from_list configs in
  let request =
    Bhttp.Request.make ~meth:"GET" ~authority:"example.com" ~path:"/" ()
  in
  let* encapsulated, context =
    Ohttp.Http_message.encapsulate_request ~rng config request
  in
  (* [post] sends a POST to the relay with your HTTP library. *)
  let status, headers, body =
    post ~headers:Ohttp.Http_binding.Client.request_headers encapsulated
  in
  let* () = Ohttp.Http_binding.Client.check_response ~status ~headers in
  Ohttp.Http_message.decapsulate_response context body
```

`check_response` matters. Anything but a 200 of type `message/ohttp-res` was
not sealed by the gateway, and may come from the relay, so its content
deserves no trust. It often means that the key configuration is out of date.

### As a gateway

```ocaml
let answer ~rng ~ask_target gateway ~meth ~headers body =
  let received =
    Result.bind (Ohttp.Http_binding.Gateway.check_request ~meth ~headers)
      (fun () -> Ohttp.Http_message.decapsulate_request gateway body)
  in
  match received with
  | Error e ->
      (* The encapsulation is still on: answer in the clear, with a 4xx. *)
      let r = Ohttp.Http_binding.Gateway.error_response e in
      (r.status, r.headers, r.body)
  | Ok (inner, context) -> (
      (* It is off: from here on, every answer goes back sealed. *)
      let response =
        match inner with
        | Ok request -> ask_target request
        | Error response -> response
      in
      match Ohttp.Http_message.encapsulate_response ~rng context response with
      | Ok sealed -> (200, Ohttp.Http_binding.Gateway.response_headers, sealed)
      | Error e ->
          let r = Ohttp.Http_binding.Gateway.error_response e in
          (r.status, r.headers, r.body))
```

The gateway's keys come from `Ohttp.Gateway.Key.generate`, and
`Ohttp.Gateway.encoded_key_configs` is what it serves as
`application/ohttp-keys`. A gateway decides which targets it forwards to; one
that forwards anywhere is an open proxy.

For a post-quantum key, pass `Hpke.Kem.Mlkem768_x25519` (X-Wing) to
`Gateway.Key.generate`. Clients choose among the configurations that a gateway
serves, so a gateway can offer an X-Wing key beside an X25519 one while
clients move over. See [protocol support](protocol-support.md#post-quantum-kems).

### Against replay

Anyone who sees an Encapsulated Request can send it again, and the gateway
cannot tell the copy apart (RFC 9458 Section 6.5). A gateway that serves
requests that are not idempotent checks each one with `Ohttp.Replay`, once the
encapsulation is off:

```ocaml
let replay = Ohttp.Replay.create ~tolerance:60. ~capacity:100_000 ()

let serve ~ask_target context request =
  let now = Unix.gettimeofday () in
  match
    Ohttp.Replay.check replay ~now
      ~enc:(Ohttp.Gateway.encapsulated_key context)
      request
  with
  | Ok () -> ask_target request
  | Error rejection -> Ohttp.Replay.rejection_response ~now rejection
```

It refuses a request whose `date` field is more than `tolerance` seconds from
the gateway's clock, and one whose encapsulated key it has seen, which it
remembers for twice the tolerance. The client adds the field with
`Ohttp.Replay.date_field`. If its clock is wrong, the gateway says so with its
own time, which `Ohttp.Replay.date_of_problem` reads, and the client retries
once with a corrected date and a new encapsulation. The cohttp examples do
both.

## Two encodings of a key configuration

RFC 9458 has two, and mistaking one for the other is the usual reason that two
implementations do not talk:

| Function | Encoding | Seen in |
| --- | --- | --- |
| `Key_config.encode`, `decode` | one configuration (Section 3.1) | the example of Appendix A; some tools print this |
| `Key_config.encode_list`, `decode_list` | each configuration prefixed with its length (Section 3.2) | the media type `application/ohttp-keys`: what a gateway serves |

## Binary HTTP on its own

`bhttp` has no dependencies and is useful without `ohttp`:

```ocaml
let encoded =
  Bhttp.Response.encode_exn
    (Bhttp.Response.make ~status:200
       ~headers:[ ("content-type", "text/plain") ]
       ~content:"hello" ())
in
Bhttp.Response.decode encoded
```

Decoding accepts both framings, integers of any size, missing empty sections at
the end, and zero padding, and lowercases field names. Encoding takes
`~framing`, `~padding`, and `~truncate`; the defaults produce what every
implementation reads.

## Next steps

- [HTTP libraries](http-libraries.md): the adapters for cohttp-lwt,
  cohttp-eio, and Piaf, and what another library needs.
- [Protocol support](protocol-support.md): what is implemented, and what is
  left to the application.
- The API reference: `opam exec -- dune build @doc`, then open
  `_build/default/_doc/_html/index.html`.
