//! A differential-testing peer over martinthomson/ohttp (the `ohttp` and
//! `bhttp` crates).
//!
//! The driver in ../differential.ml starts this program and exchanges one JSON
//! object per line with it: a request on standard input, its answer on
//! standard output, strictly in turn. Every byte string is lowercase
//! hexadecimal. The protocol is described in ../README.md and, in more detail,
//! at the top of ../go/main.go.

use std::{
    cell::RefCell,
    collections::HashMap,
    io::{self, BufRead, Cursor, Write},
    panic::{AssertUnwindSafe, catch_unwind},
    pin::Pin,
    rc::Rc,
    task::{Context, Poll},
};

use bhttp::{Message, Mode, StatusCode};
use futures::{
    AsyncReadExt, AsyncWriteExt,
    executor::block_on,
    io::{AsyncWrite, Cursor as AsyncCursor},
};
use ohttp::{
    ClientRequest, ClientResponse, KeyConfig, Server, ServerResponse, SymmetricSuite,
    hpke::{Aead, Kdf, Kem},
};
use serde_json::{Map, Value, json};

const VERSION: &str = "0.8.0";

enum Failure {
    Unsupported(String),
    Rejected(String),
    Internal(String),
}

type Answer = Result<Map<String, Value>, Failure>;

fn rejected(e: impl std::fmt::Display) -> Failure {
    Failure::Rejected(e.to_string())
}

fn internal(e: impl std::fmt::Display) -> Failure {
    Failure::Internal(e.to_string())
}

fn bytes(request: &Value, name: &str) -> Result<Vec<u8>, Failure> {
    let s = request[name]
        .as_str()
        .ok_or_else(|| internal(format!("{name}: expected a string")))?;
    hex::decode(s).map_err(|e| internal(format!("{name}: {e}")))
}

fn unhex(v: &Value) -> Result<Vec<u8>, Failure> {
    hex::decode(v.as_str().ok_or_else(|| internal("expected a string"))?).map_err(internal)
}

fn answer(pairs: Vec<(&str, Value)>) -> Answer {
    Ok(pairs.into_iter().map(|(k, v)| (k.to_string(), v)).collect())
}

/// A sink that the stream writers can own while the harness keeps the bytes.
#[derive(Clone, Default)]
struct Shared(Rc<RefCell<Vec<u8>>>);

impl AsyncWrite for Shared {
    fn poll_write(self: Pin<&mut Self>, _: &mut Context<'_>, buf: &[u8]) -> Poll<io::Result<usize>> {
        self.0.borrow_mut().extend_from_slice(buf);
        Poll::Ready(Ok(buf.len()))
    }
    fn poll_flush(self: Pin<&mut Self>, _: &mut Context<'_>) -> Poll<io::Result<()>> {
        Poll::Ready(Ok(()))
    }
    fn poll_close(self: Pin<&mut Self>, _: &mut Context<'_>) -> Poll<io::Result<()>> {
        Poll::Ready(Ok(()))
    }
}

/// The stream types of `ohttp` live in a private module and cannot be named,
/// so what happens between two operations is kept as a closure.
type Continuation = Box<dyn FnOnce(&Value) -> Answer>;

#[derive(Default)]
struct State {
    next: u64,
    clients: HashMap<u64, ClientResponse>,
    gateways: HashMap<u64, ServerResponse>,
    continuations: HashMap<u64, Continuation>,
}

impl State {
    fn handle(&mut self) -> u64 {
        self.next += 1;
        self.next
    }
}

fn key_config(request: &Value) -> Result<KeyConfig, Failure> {
    let kem = u16::try_from(request["kem"].as_u64().unwrap_or(u64::MAX))
        .ok()
        .and_then(|id| Kem::try_from(id).ok())
        .ok_or_else(|| Failure::Unsupported("unknown KEM".into()))?;
    let mut symmetric = Vec::new();
    for pair in request["symmetric"].as_array().ok_or_else(|| internal("symmetric"))? {
        let id = |i: usize| u16::try_from(pair[i].as_u64().unwrap_or(u64::MAX)).ok();
        let kdf = id(0).and_then(|id| Kdf::try_from(id).ok());
        let aead = id(1).and_then(|id| Aead::try_from(id).ok());
        match (kdf, aead) {
            (Some(kdf), Some(aead)) => symmetric.push(SymmetricSuite::new(kdf, aead)),
            _ => return Err(Failure::Unsupported("unknown KDF or AEAD".into())),
        }
    }
    let key_id = u8::try_from(request["key_id"].as_u64().unwrap_or(u64::MAX)).map_err(internal)?;
    KeyConfig::derive(key_id, kem, symmetric, &bytes(request, "seed")?).map_err(rejected)
}

fn fields(section: &bhttp::FieldSection) -> Value {
    Value::Array(
        section
            .iter()
            .map(|f| json!([hex::encode(f.name()), hex::encode(f.value())]))
            .collect(),
    )
}

fn bhttp_decode(request: &Value) -> Answer {
    let data = bytes(request, "message")?;
    let message = Message::read_bhttp(&mut Cursor::new(&data[..])).map_err(rejected)?;
    let control = message.control();
    let decoded = if control.is_request() {
        json!({
            "kind": "request",
            "method": hex::encode(control.method().unwrap_or_default()),
            "scheme": hex::encode(control.scheme().unwrap_or_default()),
            "authority": hex::encode(control.authority().unwrap_or_default()),
            "path": hex::encode(control.path().unwrap_or_default()),
            "headers": fields(message.header()),
            "content": hex::encode(message.content()),
            "trailers": fields(message.trailer()),
        })
    } else {
        json!({
            "kind": "response",
            "informational": message.informational().iter().map(|i| json!({
                "status": i.status().code(),
                "headers": fields(i.fields()),
            })).collect::<Vec<_>>(),
            "status": control.status().map_or(0, StatusCode::code),
            "headers": fields(message.header()),
            "content": hex::encode(message.content()),
            "trailers": fields(message.trailer()),
        })
    };
    answer(vec![("decoded", decoded)])
}

fn bhttp_encode(request: &Value) -> Answer {
    let d = &request["decoded"];
    let mode = match request["framing"].as_str() {
        Some("known") => Mode::KnownLength,
        Some("indeterminate") => Mode::IndeterminateLength,
        _ => return Err(internal("framing")),
    };
    let mut message = match d["kind"].as_str() {
        Some("request") => Message::request(
            unhex(&d["method"])?,
            unhex(&d["scheme"])?,
            unhex(&d["authority"])?,
            unhex(&d["path"])?,
        ),
        Some("response") => {
            // The crate builds informational responses only when it reads them.
            if d["informational"].as_array().is_some_and(|i| !i.is_empty()) {
                return Err(Failure::Unsupported("encoding informational responses".into()));
            }
            let status = d["status"].as_u64().ok_or_else(|| internal("status"))?;
            Message::response(StatusCode::try_from(status).map_err(rejected)?)
        }
        _ => return Err(internal("kind")),
    };
    let empty = Vec::new();
    for f in d["headers"].as_array().unwrap_or(&empty) {
        message.put_header(unhex(&f[0])?, unhex(&f[1])?);
    }
    message.write_content(unhex(&d["content"])?);
    for f in d["trailers"].as_array().unwrap_or(&empty) {
        message.put_trailer(unhex(&f[0])?, unhex(&f[1])?);
    }
    let mut encoded = Vec::new();
    message.write_bhttp(mode, &mut encoded).map_err(rejected)?;
    answer(vec![("message", json!(hex::encode(encoded)))])
}

fn chunks(request: &Value, name: &str) -> Result<Vec<Vec<u8>>, Failure> {
    request[name]
        .as_array()
        .ok_or_else(|| internal(name))?
        .iter()
        .map(unhex)
        .collect()
}

/// Every write is one chunk, and closing writes an empty final chunk.
async fn write_chunks<W: AsyncWrite + Unpin>(mut writer: W, chunks: Vec<Vec<u8>>) -> io::Result<()> {
    for chunk in chunks {
        if !chunk.is_empty() {
            writer.write_all(&chunk).await?;
        }
    }
    writer.close().await
}

fn handle(state: &mut State, request: &Value) -> Answer {
    match request["op"].as_str().unwrap_or_default() {
        "hello" => answer(vec![
            ("name", json!("martinthomson/ohttp")),
            ("version", json!(VERSION)),
            ("protocol", json!(1)),
            // What the crate's pure-Rust HPKE backend provides: see
            // `Config::supported` in its src/rh/hpke.rs.
            ("kems", json!([0x0020, 0x0010])),
            ("kdfs", json!([1])),
            ("aeads", json!([1, 3])),
            ("features", json!([
                "bhttp-field-order", "bhttp-rich", "bhttp-indeterminate",
                "config-list", "multi-suite-config", "chunked"
            ])),
        ]),

        "config_derive" => {
            let config = key_config(request)?;
            answer(vec![("config", json!(hex::encode(config.encode().map_err(rejected)?)))])
        }

        "config_parse" => {
            let configs = if request["config_list"].is_string() {
                KeyConfig::decode_list(&bytes(request, "config_list")?).map_err(rejected)?
            } else {
                vec![KeyConfig::decode(&bytes(request, "config")?).map_err(rejected)?]
            };
            let mut encoded = Vec::new();
            for c in &configs {
                encoded.push(json!(hex::encode(c.encode().map_err(rejected)?)));
            }
            answer(vec![("configs", Value::Array(encoded))])
        }

        "client_encapsulate" => {
            let client = ClientRequest::from_encoded_config(&bytes(request, "config")?).map_err(rejected)?;
            let (enc_request, response) = client.encapsulate(&bytes(request, "request")?).map_err(rejected)?;
            let h = state.handle();
            state.clients.insert(h, response);
            answer(vec![("enc_request", json!(hex::encode(enc_request))), ("handle", json!(h))])
        }

        "client_decapsulate" => {
            let h = request["handle"].as_u64().unwrap_or_default();
            let context = state.clients.remove(&h).ok_or_else(|| internal("unknown handle"))?;
            let response = context.decapsulate(&bytes(request, "enc_response")?).map_err(rejected)?;
            answer(vec![("response", json!(hex::encode(response)))])
        }

        "gateway_decapsulate" => {
            let server = Server::new(key_config(request)?).map_err(rejected)?;
            let (plaintext, response) = server.decapsulate(&bytes(request, "enc_request")?).map_err(rejected)?;
            let h = state.handle();
            state.gateways.insert(h, response);
            answer(vec![("request", json!(hex::encode(plaintext))), ("handle", json!(h))])
        }

        "gateway_encapsulate" => {
            let h = request["handle"].as_u64().unwrap_or_default();
            let context = state.gateways.remove(&h).ok_or_else(|| internal("unknown handle"))?;
            let enc_response = context.encapsulate(&bytes(request, "response")?).map_err(rejected)?;
            answer(vec![("enc_response", json!(hex::encode(enc_response)))])
        }

        "chunked_client_encapsulate" => {
            let client = ClientRequest::from_encoded_config(&bytes(request, "config")?).map_err(rejected)?;
            let sink = Shared::default();
            let mut stream = client.encapsulate_stream(sink.clone()).map_err(rejected)?;
            block_on(write_chunks(&mut stream, chunks(request, "chunks")?)).map_err(rejected)?;
            let h = state.handle();
            state.continuations.insert(h, Box::new(move |request: &Value| {
                let source = AsyncCursor::new(bytes(request, "enc_response")?);
                let mut reader = Box::pin(stream.response(source).map_err(rejected)?);
                let mut response = Vec::new();
                block_on(reader.read_to_end(&mut response)).map_err(rejected)?;
                answer(vec![("response", json!(hex::encode(response)))])
            }));
            let enc_request = sink.0.borrow().clone();
            answer(vec![("enc_request", json!(hex::encode(enc_request))), ("handle", json!(h))])
        }

        "chunked_gateway_decapsulate" => {
            let server = Server::new(key_config(request)?).map_err(rejected)?;
            let source = AsyncCursor::new(bytes(request, "enc_request")?);
            let mut stream = Box::pin(server.decapsulate_stream(source));
            let mut plaintext = Vec::new();
            block_on(stream.read_to_end(&mut plaintext)).map_err(rejected)?;
            let h = state.handle();
            state.continuations.insert(h, Box::new(move |request: &Value| {
                let sink = Shared::default();
                let mut writer = Box::pin(stream.response(sink.clone()).map_err(rejected)?);
                block_on(write_chunks(&mut writer, chunks(request, "chunks")?)).map_err(rejected)?;
                let enc_response = sink.0.borrow().clone();
                answer(vec![("enc_response", json!(hex::encode(enc_response)))])
            }));
            answer(vec![("request", json!(hex::encode(plaintext))), ("handle", json!(h))])
        }

        "chunked_client_decapsulate" | "chunked_gateway_encapsulate" => {
            let h = request["handle"].as_u64().unwrap_or_default();
            let next = state.continuations.remove(&h).ok_or_else(|| internal("unknown handle"))?;
            next(request)
        }

        "bhttp_decode" => bhttp_decode(request),
        "bhttp_encode" => bhttp_encode(request),
        op => Err(Failure::Unsupported(format!("operation {op:?}"))),
    }
}

fn main() {
    ohttp::init();
    // A panic inside a library is an answer too; keep its message off stderr.
    std::panic::set_hook(Box::new(|_| {}));
    let mut state = State::default();
    let stdout = io::stdout();
    for line in io::stdin().lock().lines() {
        let Ok(line) = line else { break };
        let request: Value = serde_json::from_str(&line).unwrap_or(Value::Null);
        let result = catch_unwind(AssertUnwindSafe(|| handle(&mut state, &request)))
            .unwrap_or_else(|payload| {
                let message = payload
                    .downcast_ref::<String>()
                    .map(String::as_str)
                    .or_else(|| payload.downcast_ref::<&str>().copied())
                    .unwrap_or("unknown");
                Err(Failure::Internal(format!("panic: {message}")))
            });
        let mut out = Map::new();
        out.insert("id".into(), request["id"].clone());
        match result {
            Ok(fields) => {
                out.insert("ok".into(), json!(true));
                out.extend(fields);
            }
            Err(failure) => {
                let (kind, message) = match failure {
                    Failure::Unsupported(m) => ("unsupported", m),
                    Failure::Rejected(m) => ("rejected", m),
                    Failure::Internal(m) => ("internal", m),
                };
                out.insert("ok".into(), json!(false));
                out.insert("error".into(), json!({"kind": kind, "message": message}));
            }
        }
        let mut lock = stdout.lock();
        let _ = writeln!(lock, "{}", Value::Object(out));
        let _ = lock.flush();
    }
}
