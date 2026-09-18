# HTTP libraries

[README](../README.md) · [Getting started](getting-started.md) ·
[Protocol support](protocol-support.md)

Oblivious HTTP sits on top of HTTP; it does not replace it. A client makes one
`POST` to a relay. A gateway receives one `POST`, and may make an ordinary
request to a target. `ohttp` and `bhttp` therefore perform no I/O and depend on
no HTTP library: every OCaml HTTP library can carry their messages, and an
application keeps the one it already uses.

## What an HTTP library has to do

| Party | It needs to | With |
| --- | --- | --- |
| Client | `GET` the key configurations | `Http_binding.Client.key_config_request_headers`, `check_key_config_response`, `Key_config.decode_list` |
| Client | `POST` a string to the relay and read a string back | `Http_message.encapsulate_request`, `Http_binding.Client.request_headers`, `check_response`, `Http_message.decapsulate_response` |
| Relay | pass the content and its type on, and nothing else | nothing from these libraries: a relay cannot read what it carries |
| Gateway | serve a string, and answer a `POST` with a string | `Gateway.encoded_key_configs`, `Http_binding.Gateway.check_request`, `Http_message.decapsulate_request`, `encapsulate_response`, `error_response` |

Everything in the right-hand column takes and returns strings, integers, and
lists of pairs of strings.

## Messages

A `Bhttp.Request.t` is a method, a scheme, an authority, a path, fields,
content, and trailers; a `Bhttp.Response.t` is a status code with the same, and
any informational responses before it. Fields are `(string * string) list`, in
order, with lowercase names. Every HTTP library can produce and consume that:

| Library | Fields to a list | A list to fields |
| --- | --- | --- |
| `http`, cohttp 6, cohttp-eio | `Http.Header.to_list` | `Http.Header.of_list` |
| httpun, h2, piaf | `Headers.to_list` | `Headers.of_list` |
| curl, ezcurl | already a list of pairs or of lines | |

Three things need care when converting from HTTP/1.1:

- **The authority.** HTTP/1.1 carries it in the `Host` field, Binary HTTP in
  its control data. Move it, or leave the authority empty and keep the field:
  RFC 9292 allows both, and Figure 8 of the RFC does the latter.
- **Connection-specific fields.** `connection`, `keep-alive`,
  `transfer-encoding`, `upgrade`, and whatever `connection` nominates describe
  one hop and mean nothing inside a message. `Bhttp.Field.without_connection_specific`
  removes them, as RFC 9292 Section 3.6 recommends.
- **`expect: 100-continue`.** It cannot work through an encapsulation that is
  only opened when it is complete. `Http_message.encapsulate_request` refuses
  it, and a gateway answers it with an encapsulated 417 (RFC 9458 Section 5.1).

[`examples/cohttp_adapter.ml`](../examples/cohttp_adapter.ml) is all of this for
cohttp, in some forty lines. cohttp 6 takes its types from the `http` package,
as cohttp-eio does, so the same file serves both.

## The cohttp examples

[`examples/services.ml`](../examples/services.ml) has the four parties over
cohttp-lwt-unix. The gateway's handler is the pattern to copy:

```ocaml
match received with
(* The encapsulation is still on: answer in the clear, with a 4xx. *)
| Error e -> refuse e
(* It is off: from here on, every answer goes back sealed. *)
| Ok (inner, context) ->
    let* response =
      match inner with
      | Ok request -> ask_target ~targets request
      | Error response -> Lwt.return response
    in
    ...
```

`dune build @e2e` runs them in one process. They are also separate programs:

```sh
opam install cohttp-lwt-unix
opam exec -- dune build ./examples

# A gateway for one target, a relay in front of it, and a client.
_build/default/examples/ohttp_gateway.exe 8081 example.com=https://example.com &
_build/default/examples/ohttp_relay.exe 8082 http://127.0.0.1:8081/gateway &
_build/default/examples/ohttp_client.exe \
  http://127.0.0.1:8081/.well-known/ohttp-gateway \
  http://127.0.0.1:8082/relay https://example.com/
```

The relay and the gateway are demonstrations, not servers to deploy: see
[Security](../SECURITY.md). Without cohttp-lwt-unix the same programs build as
stubs that say what is missing, so that the rest of the repository builds
anywhere.

## Why there is no adapter package yet

An installable `ohttp-cohttp`, with a ready-made `call` through a relay, is a
small step from `services.ml`. It waits until the interfaces here have settled,
since a package is harder to change than an example. If you write the same few
lines for another library, they are welcome as an example.
