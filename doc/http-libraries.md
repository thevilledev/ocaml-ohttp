# HTTP libraries

[README](../README.md) · [Getting started](getting-started.md) ·
[Protocol support](protocol-support.md)

Oblivious HTTP sits on top of HTTP; it does not replace it. A client makes one
`POST` to a relay. A gateway receives one `POST`, and may make an ordinary
request to a target. `ohttp` and `bhttp` therefore perform no I/O and depend on
no HTTP library. An adapter package carries their messages over one library,
and an application picks the one for the library it already uses.

## Adapter packages

| Package | HTTP library | OCaml from | Client | Relay | Gateway |
| --- | --- | --- | --- | --- | --- |
| `ohttp-cohttp-lwt` | cohttp-lwt 6: `cohttp-lwt-unix`, `cohttp-lwt-jsoo`, MirageOS | 4.14 | any cohttp-lwt client | ✓ | ✓, and targets in the same process |
| `ohttp-cohttp-eio` | cohttp-eio 6 | 5.1 | ✓ | ✓ | ✓ |
| `ohttp-piaf` | Piaf 0.2, HTTP/1.1 and HTTP/2 | 5.1 | ✓ | ✓ | ✓ |
| `ohttp-cohttp` | the types of the `http` package, which the two cohttp adapters share | 4.14 | | | |

Each adapter has the same parts, over its library's types:

| Part | What it does |
| --- | --- |
| `Client.key_configs` | `GET`s a gateway's key configurations and decodes them |
| `Client.call` | Encapsulates a request with a `date` field, posts it to a relay, checks and opens the answer, and retries once with the gateway's time if the gateway refuses the date |
| `Relay.handler` | Passes a `POST` of type `message/ohttp-req` to one gateway with no field but its content type, and the gateway's answer back, within the relay's [limits](#limits) |
| `Gateway.handler` | Serves the key configurations at `/.well-known/ohttp-gateway` and Encapsulated Requests at `/gateway`, within the gateway's [limits](#limits), checks for replay, and seals every answer once the encapsulation is off |
| `Target.forward` | Sends a decapsulated request to the target that a list of authorities names, and refuses the rest with a sealed 403 |

A gateway's configuration is an `Ohttp.Service.Gateway.t`, which is the same
for every adapter:

```ocaml
let service =
  Ohttp.Service.Gateway.create ~rng
    ~replay:(Ohttp.Replay.create ~tolerance:60. ~capacity:100_000 ())
    (Result.get_ok (Ohttp.Gateway.create [ key ]))
```

With `~replay`, every request is checked for replay; `~checks_replay` leaves
out those that the targets treat as idempotent, such as `GET`s.

A relay's configuration is an `Ohttp.Service.Relay.t`, which holds its limits:

```ocaml
let relay = Ohttp.Service.Relay.create ()

(* Over cohttp-lwt, forwarding to one gateway. *)
let handler =
  Ohttp_client.Relay.handler relay
    ~gateway:(Uri.of_string "https://gateway.example/gateway")
```

Both values count the requests in flight, so each relay or gateway is built
from one value that serves all of its requests.

### cohttp-lwt

```sh
opam install ohttp-cohttp-lwt cohttp-lwt-unix
```

The client, the relay, and `Target.forward` make requests of their own, so they
come from a functor over a client of cohttp-lwt. The gateway's handlers do not.

```ocaml
module Ohttp_client = Ohttp_cohttp_lwt.Make (Cohttp_lwt_unix.Client)

(* A gateway for one target. *)
let gateway =
  Ohttp_cohttp_lwt.Gateway.handler service
    (Ohttp_client.Target.forward
       ~targets:[ ("example.com", Uri.of_string "https://example.com") ])

let () =
  Lwt_main.run
    (Cohttp_lwt_unix.Server.create ~mode:(`TCP (`Port 8081))
       (Cohttp_lwt_unix.Server.make ~callback:(fun _conn -> gateway) ()))

(* A client. *)
let response =
  Ohttp_client.Client.call ~rng
    ~relay:(Uri.of_string "https://relay.example/relay")
    config
    (Bhttp.Request.make ~meth:"GET" ~authority:"example.com" ~path:"/" ())
```

`Ohttp_cohttp_lwt.Target.of_handler` turns a cohttp-lwt callback into a target,
so that a gateway can sit in front of an application in the same process,
without a second hop over the network.

### cohttp-eio

```sh
opam install ohttp-cohttp-eio eio_main
```

```ocaml
Eio_main.run @@ fun env ->
let client = Cohttp_eio.Client.make ~https:None (Eio.Stdenv.net env) in
let gateway =
  Ohttp_cohttp_eio.Gateway.handler service
    (Ohttp_cohttp_eio.Target.forward client
       ~targets:[ ("example.com", Uri.of_string "http://127.0.0.1:8000") ])
in
Eio.Switch.run @@ fun sw ->
let socket =
  Eio.Net.listen ~sw ~backlog:128 (Eio.Stdenv.net env)
    (`Tcp (Eio.Net.Ipaddr.V4.any, 8081))
in
Cohttp_eio.Server.run socket ~on_error:raise
  (Cohttp_eio.Server.make ~callback:(fun _conn -> gateway) ())
```

A client calls `Ohttp_cohttp_eio.Client.call client ~rng ~relay config
request`. Pass `~https` to `Cohttp_eio.Client.make` to reach relays and targets
over TLS.

### Piaf

```sh
opam install ohttp-piaf eio_main
```

```ocaml
Eio_main.run @@ fun env ->
Eio.Switch.run @@ fun sw ->
let gateway =
  Ohttp_piaf.Gateway.handler service
    (Ohttp_piaf.Target.forward env
       ~targets:[ ("example.com", Uri.of_string "https://example.com") ])
in
let config = Piaf.Server.Config.create (`Tcp (Eio.Net.Ipaddr.V4.any, 8081)) in
ignore (Piaf.Server.Command.start ~sw env (Piaf.Server.create ~config gateway))
```

Piaf reports failures as results, so `Ohttp_piaf.Client.call` returns
`` `Ohttp `` for a failure of the protocol and `` `Piaf `` for one of the
transport.

### Limits

A relay and a gateway read each message in full, as they must before opening
it. What they hold at once is bounded by how long a message may be and how many
requests they handle together:

| Limit | Default | Set with | What exceeds it gets |
| --- | --- | --- | --- |
| A request that a relay or a gateway reads | 1 MiB | `~max_request_size` of `Ohttp.Service.Relay.create` and `Ohttp.Service.Gateway.create` | a 413 |
| A response that a client, a relay, or `Target.forward` reads | 8 MiB | `~max_response_size` of `Ohttp.Service.Relay.create`, `Client.call`, `Client.key_configs`, and `Target.forward` | `Content_too_large` at a client, a 502 at a relay, and a sealed 502 at a gateway |
| Requests that a relay or a gateway handles at once | 256 | `~max_in_flight` of `Ohttp.Service.Relay.create` and `Ohttp.Service.Gateway.create` | a 503 with `retry-after: 1` |

A message whose `content-length` is over the limit is refused before its content
is read; one without it is counted as it arrives, and refused once it passes the
limit. What is refused is not kept. Servers read the rest of a refused request
and throw it away, so that the connection can carry the next one, and so do the
clients of cohttp-lwt and Piaf with a refused response; a cohttp-eio client
closes the connection instead.

An Encapsulated Response is a little longer than the response that it seals,
and longer again with `?padding`. A relay in front of a gateway that forwards
answers up to its limit needs a slightly higher `max_response_size`.

### What the adapters leave to the application

- **Key configurations.** `Client.key_configs` is a plain `GET`. A client must
  obtain key configurations in a way that authenticates the gateway, and must
  get the same ones as every other client (RFC 9458 Sections 6.1 and 7).
- **Rates and timeouts.** The [limits](#limits) bound what a relay or a
  gateway holds, not how often a client may ask, nor how slowly a message may
  arrive. A relay is the party that knows its clients, and the one to limit the
  rate of each; a gateway sees only relays. Put rate limits and timeouts in
  the server's configuration or in a proxy in front of it, and the number of
  connections too: cohttp-eio's `Server.run` takes `?max_connections`.
- **Routing.** The relay's handler answers every path, and the gateway's
  handler two; mount them where the deployment needs them. Both gateway
  resources are also available alone, as `Gateway.key_configs` and
  `Gateway.requests`.
- **The relay's other duties.** Traffic analysis defences, and hiding clients
  from each other, are outside what a handler can do (RFC 9458 Section 6.2).

### Other libraries

Dream is not among the adapters: its current release, 1.0.0~alpha8, needs
`mirage-crypto-rng-lwt`, which `mirage-crypto-rng` 2 no longer provides, and
`ohttp` needs `mirage-crypto-rng` 2.4. Dream and Piaf cannot share a switch
either, since they need different versions of `httpun`.

For any other library, `Ohttp.Service` is the adapter without the library: each
party is a function from what it received to what it sends, as strings and
lists of fields.

| Party | Step | From `Ohttp.Service` |
| --- | --- | --- |
| Client | `GET` the key configurations | `Http_binding.Client.key_config_request_headers`, then `Client.key_configs` |
| Client | `POST` to the relay, and open the answer | `Client.start`, then `Client.finish`, which may ask for one `Retry` |
| Relay | pass the content and its type on, and nothing else | `Relay.request`, then `Relay.response`, or `Relay.unreachable` |
| Gateway | serve the key configurations | `Gateway.key_configs` |
| Gateway | answer a `POST` | `Gateway.receive`, which gives a `Respond` or a `Forward` whose function seals the target's answer |
| Gateway | pick a target | `Gateway.target` |

An adapter is these steps with the reading and writing of its library around
them: [`ohttp_cohttp_eio.ml`](../lib/ohttp-cohttp-eio/ohttp_cohttp_eio.ml) is
the shortest, at about 140 lines.

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

`Ohttp_cohttp` has these conversions for the types of the `http` package.
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

## The cohttp examples

[`examples/services.ml`](../examples/services.ml) has the four parties over
cohttp-lwt-unix, through `ohttp-cohttp-lwt`. `dune build @e2e` runs them in
one process. They are also separate programs:

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
