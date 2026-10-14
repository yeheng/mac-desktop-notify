//! Bounded, timeout-protected HTTP/1.1 transport, also used over AF_UNIX.
use crate::api::{error, Request};
use futures::channel::{mpsc, oneshot};
use futures::SinkExt;
use serde_json::Value;
use std::io::{self, Read, Write};
use std::net::TcpListener;
use std::os::unix::{
    fs::{FileTypeExt, MetadataExt, PermissionsExt},
    net::{UnixListener, UnixStream},
};
use std::path::PathBuf;
use std::sync::{
    atomic::{AtomicBool, AtomicUsize, Ordering},
    Arc,
};
use std::time::Duration;

pub(crate) struct Envelope {
    pub request: Request,
    pub reply: oneshot::Sender<(u16, Value)>,
}
type Sender = mpsc::Sender<Envelope>;
trait Connection: Read + Write + Send {
    fn read_timeout(&self, duration: Duration) -> io::Result<()>;
}
impl Connection for std::net::TcpStream {
    fn read_timeout(&self, duration: Duration) -> io::Result<()> {
        self.set_read_timeout(Some(duration))
    }
}
impl Connection for UnixStream {
    fn read_timeout(&self, duration: Duration) -> io::Result<()> {
        self.set_read_timeout(Some(duration))
    }
}

pub(crate) struct Listeners {
    stopping: Arc<AtomicBool>,
    hub: crate::events::EventHub,
    socket: Option<(PathBuf, u64)>,
    pub http: bool,
    pub http_address: Option<std::net::SocketAddr>,
    pub unix: bool,
}
impl Drop for Listeners {
    fn drop(&mut self) {
        self.stopping.store(true, Ordering::Release);
        self.hub.broadcast(serde_json::json!({"type":"shutdown"}));
        if let Some((path, inode)) = &self.socket {
            if std::fs::symlink_metadata(path).is_ok_and(|m| m.ino() == *inode) {
                let _ = std::fs::remove_file(path);
            }
        }
    }
}

impl Listeners {
    pub fn start(
        sender: Sender,
        config: crate::config::Config,
        hub: crate::events::EventHub,
    ) -> Self {
        let stopping = Arc::new(AtomicBool::new(false));
        let active = Arc::new(AtomicUsize::new(0));
        let mut result = Self {
            stopping: stopping.clone(),
            hub: hub.clone(),
            socket: None,
            http: false,
            http_address: None,
            unix: false,
        };
        if config.http_enabled {
            match TcpListener::bind(("127.0.0.1", config.http_port)) {
                Ok(listener) => {
                    if listener.set_nonblocking(true).is_ok() {
                        result.http = true;
                        result.http_address = listener.local_addr().ok();
                        eprintln!("HTTP: http://{}", listener.local_addr().unwrap());
                        let stopping = stopping.clone();
                        let sender = sender.clone();
                        let active = active.clone();
                        let hub = hub.clone();
                        std::thread::spawn(move || {
                            while !stopping.load(Ordering::Acquire) {
                                match listener.accept() {
                                    Ok((stream, _)) => {
                                        let _ =
                                            stream.set_read_timeout(Some(Duration::from_secs(5)));
                                        let _ =
                                            stream.set_write_timeout(Some(Duration::from_secs(5)));
                                        dispatch(
                                            stream,
                                            sender.clone(),
                                            active.clone(),
                                            hub.clone(),
                                        );
                                    }
                                    Err(e) if e.kind() == io::ErrorKind::WouldBlock => {
                                        std::thread::sleep(Duration::from_millis(25))
                                    }
                                    Err(e) => {
                                        eprintln!("HTTP accept: {e}");
                                        break;
                                    }
                                }
                            }
                        });
                    }
                }
                Err(e) => eprintln!("HTTP listener unavailable: {e}"),
            }
        }
        if config.socket_enabled {
            let preferred = std::env::var("NC_SOCKET_PATH").unwrap_or_else(|_| {
                format!(
                    "{}/Library/Application Support/MacDesktopNotify/api.sock",
                    std::env::var("HOME").unwrap_or_default()
                )
            });
            let path = resolve_socket_path(&preferred);
            match bind_unix(&path) {
                Ok(listener) => {
                    if listener.set_nonblocking(true).is_ok() {
                        result.unix = true;
                        result.socket = std::fs::symlink_metadata(&path)
                            .ok()
                            .map(|m| (path.clone(), m.ino()));
                        eprintln!("Unix socket: {}", path.display());
                        std::thread::spawn(move || {
                            while !stopping.load(Ordering::Acquire) {
                                match listener.accept() {
                                    Ok((stream, _)) => {
                                        let _ =
                                            stream.set_read_timeout(Some(Duration::from_secs(5)));
                                        let _ =
                                            stream.set_write_timeout(Some(Duration::from_secs(5)));
                                        dispatch(
                                            stream,
                                            sender.clone(),
                                            active.clone(),
                                            hub.clone(),
                                        );
                                    }
                                    Err(e) if e.kind() == io::ErrorKind::WouldBlock => {
                                        std::thread::sleep(Duration::from_millis(25))
                                    }
                                    Err(e) => {
                                        eprintln!("Socket accept: {e}");
                                        break;
                                    }
                                }
                            }
                        });
                    }
                }
                Err(e) => eprintln!("Unix listener unavailable ({}): {e}", path.display()),
            }
        }
        result
    }
}

fn resolve_socket_path(preferred: &str) -> PathBuf {
    if preferred.len() <= 103 {
        return preferred.into();
    }
    let hash = preferred.bytes().fold(0xcbf29ce484222325u64, |h, b| {
        (h ^ b as u64).wrapping_mul(0x100000001b3)
    });
    // Derive uid without depending on a mutable environment variable.
    let uid = std::fs::metadata(std::env::var("HOME").unwrap_or_else(|_| "/".into()))
        .map(|m| m.uid())
        .unwrap_or(0);
    format!("/tmp/mdn-{uid}-{:012x}.sock", hash & 0xffffffffffff).into()
}
fn bind_unix(path: &PathBuf) -> io::Result<UnixListener> {
    if let Ok(metadata) = std::fs::symlink_metadata(path) {
        if !metadata.file_type().is_socket() {
            return Err(io::Error::new(
                io::ErrorKind::AlreadyExists,
                "path is not a socket",
            ));
        }
        match UnixStream::connect(path) {
            Ok(_) => {
                return Err(io::Error::new(
                    io::ErrorKind::AddrInUse,
                    "another instance owns this socket",
                ))
            }
            Err(e)
                if matches!(
                    e.kind(),
                    io::ErrorKind::ConnectionRefused | io::ErrorKind::NotFound
                ) =>
            {
                std::fs::remove_file(path)?
            }
            Err(e) => return Err(e),
        }
    }
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    let listener = UnixListener::bind(path)?;
    if let Err(e) = std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600)) {
        let _ = std::fs::remove_file(path);
        return Err(e);
    }
    Ok(listener)
}
fn dispatch<S: Connection + 'static>(
    mut stream: S,
    sender: Sender,
    active: Arc<AtomicUsize>,
    hub: crate::events::EventHub,
) {
    if active.fetch_add(1, Ordering::AcqRel) >= 16 {
        active.fetch_sub(1, Ordering::AcqRel);
        let _ = write_response(&mut stream, error(503, "服务繁忙", None));
        return;
    }
    std::thread::spawn(move || {
        struct Slot(Arc<AtomicUsize>);
        impl Drop for Slot {
            fn drop(&mut self) {
                self.0.fetch_sub(1, Ordering::AcqRel);
            }
        }
        let _slot = Slot(active);
        let response = match read_request(&mut stream) {
            Ok(request)
                if request.target.split('?').next() == Some("/v1/events")
                    && request.headers.iter().any(|(k, v)| {
                        k.eq_ignore_ascii_case("upgrade") && v.eq_ignore_ascii_case("websocket")
                    }) =>
            {
                websocket(stream, request, sender, hub);
                return;
            }
            Ok(request) => {
                let (reply, receive) = oneshot::channel();
                let mut sender = sender;
                if futures::executor::block_on(sender.send(Envelope { request, reply })).is_err() {
                    error(503, "服务已停止", None)
                } else {
                    futures::executor::block_on(receive)
                        .unwrap_or_else(|_| error(503, "服务已停止", None))
                }
            }
            Err((code, reason)) => error(code, reason, None),
        };
        let _ = write_response(&mut stream, response);
    });
}
fn read_request(reader: &mut impl Read) -> Result<Request, (u16, &'static str)> {
    let mut buffer = Vec::new();
    let mut chunk = [0u8; 4096];
    let head_end = loop {
        if let Some(i) = buffer.windows(4).position(|b| b == b"\r\n\r\n") {
            break i + 4;
        }
        if buffer.len() > 8195 {
            return Err((431, "请求头过大"));
        }
        let n = reader.read(&mut chunk).map_err(|_| (400, "请求读取失败"))?;
        if n == 0 {
            return Err((400, "请求不完整"));
        }
        buffer.extend_from_slice(&chunk[..n]);
    };
    if head_end > 8196 {
        return Err((431, "请求头过大"));
    }
    let head = std::str::from_utf8(&buffer[..head_end]).map_err(|_| (400, "请求头不合法"))?;
    let mut lines = head.split("\r\n");
    let mut first = lines.next().unwrap_or_default().split_whitespace();
    let method = first.next().ok_or((400, "缺少方法"))?.to_owned();
    let target = first.next().ok_or((400, "缺少路径"))?.to_owned();
    if !target.starts_with('/')
        || !matches!(first.next(), Some("HTTP/1.1" | "HTTP/1.0"))
        || first.next().is_some()
    {
        return Err((400, "请求行不合法"));
    }
    let mut length = None;
    let mut headers = Vec::new();
    for line in lines.filter(|l| !l.is_empty()) {
        let (name, value) = line.split_once(':').ok_or((400, "请求头不合法"))?;
        headers.push((name.to_owned(), value.trim().to_owned()));
        if name.eq_ignore_ascii_case("transfer-encoding") {
            return Err((400, "不支持 Transfer-Encoding"));
        }
        if name.eq_ignore_ascii_case("content-length") {
            let n = value
                .trim()
                .parse::<usize>()
                .map_err(|_| (400, "Content-Length 不合法"))?;
            if length.replace(n).is_some() {
                return Err((400, "重复 Content-Length"));
            }
        }
    }
    let length = length.unwrap_or(0);
    if length > 32768 {
        return Err((413, "请求体过大"));
    }
    while buffer.len() < head_end + length {
        let n = reader.read(&mut chunk).map_err(|_| (400, "请求读取失败"))?;
        if n == 0 {
            return Err((400, "请求体不完整"));
        }
        buffer.extend_from_slice(&chunk[..n]);
    }
    Ok(Request {
        method,
        target,
        body: buffer[head_end..head_end + length].to_vec(),
        headers,
    })
}
fn write_response(writer: &mut impl Write, (code, body): (u16, Value)) -> io::Result<()> {
    let body = serde_json::to_vec(&body)?;
    let reason = match code {
        200 => "OK",
        400 => "Bad Request",
        404 => "Not Found",
        405 => "Method Not Allowed",
        413 => "Payload Too Large",
        431 => "Request Header Fields Too Large",
        _ => "Service Unavailable",
    };
    write!(writer,"HTTP/1.1 {code} {reason}\r\nContent-Type: application/json; charset=utf-8\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",body.len())?;
    writer.write_all(&body)
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn accepts_fragmented_body() {
        struct Fragments(&'static [u8]);
        impl Read for Fragments {
            fn read(&mut self, b: &mut [u8]) -> io::Result<usize> {
                if self.0.is_empty() {
                    return Ok(0);
                }
                b[0] = self.0[0];
                self.0 = &self.0[1..];
                Ok(1)
            }
        }
        let r = read_request(&mut Fragments(
            b"POST /v1/push HTTP/1.1\r\nContent-Length: 2\r\n\r\n{}",
        ))
        .unwrap();
        assert_eq!(r.body, b"{}");
    }
    #[test]
    fn rejects_ambiguous_framing() {
        for raw in [
            "POST / HTTP/1.1\r\nContent-Length: 1\r\nContent-Length: 2\r\n\r\nx",
            "POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n",
            "POST / HTTP/1.1\r\nContent-Length: 1048577\r\n\r\n",
        ] {
            assert!(read_request(&mut raw.as_bytes()).is_err());
        }
    }
    #[test]
    fn socket_never_unlinks_live_listener_or_file() {
        let path = std::env::temp_dir().join(format!("nc-{}.sock", uuid::Uuid::new_v4()));
        std::fs::write(&path, b"keep").unwrap();
        assert!(bind_unix(&path).is_err());
        assert_eq!(std::fs::read(&path).unwrap(), b"keep");
        std::fs::remove_file(&path).unwrap();
        let listener = bind_unix(&path).unwrap();
        assert!(bind_unix(&path).is_err());
        assert_eq!(
            std::fs::metadata(&path).unwrap().permissions().mode() & 0o777,
            0o600
        );
        drop(listener);
        let listener = bind_unix(&path).unwrap();
        drop(listener);
        std::fs::remove_file(&path).unwrap();
    }
}

fn call(mut sender: Sender, request: Request) -> (u16, Value) {
    let (reply, receive) = oneshot::channel();
    if futures::executor::block_on(sender.send(Envelope { request, reply })).is_err() {
        return error(503, "服务已停止", None);
    }
    futures::executor::block_on(receive).unwrap_or_else(|_| error(503, "服务已停止", None))
}
fn websocket<S: Connection>(
    mut stream: S,
    request: Request,
    sender: Sender,
    hub: crate::events::EventHub,
) {
    use tungstenite::{
        protocol::{Role, WebSocketConfig},
        Message, WebSocket,
    };
    let mut head = tungstenite::http::Request::builder()
        .method(request.method.as_str())
        .uri(request.target.as_str());
    for (key, value) in &request.headers {
        head = head.header(key, value);
    }
    let response = head
        .body(())
        .ok()
        .and_then(|head| tungstenite::handshake::server::create_response(&head).ok());
    let Some(response) = response else {
        let _ = write_response(&mut stream, error(400, "WebSocket 握手不合法", None));
        return;
    };
    if write!(stream, "HTTP/1.1 101 Switching Protocols\r\n").is_err() {
        return;
    }
    for (key, value) in response.headers() {
        if write!(stream, "{key}: {}\r\n", value.to_str().unwrap_or_default()).is_err() {
            return;
        }
    }
    if stream.write_all(b"\r\n").is_err() {
        return;
    }
    let config = WebSocketConfig::default()
        .max_message_size(Some(65536))
        .max_frame_size(Some(65536));
    let _ = stream.read_timeout(Duration::from_millis(100));
    let mut socket = WebSocket::from_raw_socket(stream, Role::Server, Some(config));
    let events = hub.subscribe();
    let (_, status) = call(
        sender.clone(),
        Request {
            method: "GET".into(),
            target: "/v1/status".into(),
            body: vec![],
            headers: vec![],
        },
    );
    if socket
        .send(Message::text(
            serde_json::json!({"type":"hello","unreadCount":status["unreadCount"]}).to_string(),
        ))
        .is_err()
    {
        return;
    }
    loop {
        while let Ok(event) = events.try_recv() {
            if event["type"] == "shutdown" {
                let _ = socket.close(None);
                return;
            }
            if socket.send(Message::text(event.to_string())).is_err() {
                return;
            }
        }
        match socket.read() {
            Ok(Message::Text(text)) => {
                let frame: Value = match serde_json::from_str(text.as_str()) {
                    Ok(v) => v,
                    Err(_) => {
                        let _=socket.send(Message::text(serde_json::json!({"type":"result","ok":false,"error":"帧不是合法 JSON"}).to_string()));
                        continue;
                    }
                };
                let reference = frame.get("ref").cloned();
                let path = match frame["op"].as_str() {
                    Some("push") => Some("/v1/push"),
                    Some("clear") => Some("/v1/clear"),
                    // Swift guards the exec door up front: an absent `script`
                    // gets its own error instead of the generic decode one.
                    Some("exec") if frame.get("script").and_then(Value::as_str).is_none() => {
                        let mut result = serde_json::Map::new();
                        result.insert("ok".into(), Value::Bool(false));
                        result.insert("error".into(), Value::String("缺少 script".into()));
                        if let Some(reference) = reference {
                            result.insert("ref".into(), reference);
                        }
                        if socket
                            .send(Message::text(Value::Object(result).to_string()))
                            .is_err()
                        {
                            return;
                        }
                        continue;
                    }
                    Some("exec") => Some("/v1/exec"),
                    _ => None,
                };
                let (status, result) = if let Some(path) = path {
                    call(
                        sender.clone(),
                        Request {
                            method: "POST".into(),
                            target: path.into(),
                            body: serde_json::to_vec(&frame).unwrap_or_default(),
                            headers: vec![],
                        },
                    )
                } else {
                    error(400, "未知操作", None)
                };
                let mut result = result.as_object().cloned().unwrap_or_default();
                // The `field` hint is HTTP-only in Swift's WS result frames.
                result.remove("field");
                result.insert("type".into(), "result".into());
                if let Some(reference) = reference {
                    result.insert("ref".into(), reference);
                }
                result
                    .entry("ok".to_owned())
                    .or_insert(Value::Bool(status == 200));
                if socket
                    .send(Message::text(Value::Object(result).to_string()))
                    .is_err()
                {
                    return;
                }
            }
            Ok(Message::Close(_)) => {
                let _ = socket.flush();
                return;
            }
            Ok(_) => {
                if socket.flush().is_err() {
                    return;
                }
            }
            Err(tungstenite::Error::Io(e))
                if matches!(
                    e.kind(),
                    io::ErrorKind::WouldBlock | io::ErrorKind::TimedOut
                ) =>
            {
                continue
            }
            Err(_) => return,
        }
    }
}
