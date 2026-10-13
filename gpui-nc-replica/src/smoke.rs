//! Opt-in real-app integration check. Uses isolated temporary data and ports.
use serde_json::{json, Value};
use std::{
    io::{Read, Write},
    net::{SocketAddr, TcpStream},
    os::unix::net::UnixStream,
    path::PathBuf,
    time::Duration,
};
pub(crate) fn prepare() -> PathBuf {
    let directory = PathBuf::from(format!("/tmp/nc-smoke-{}", uuid::Uuid::new_v4()));
    std::fs::create_dir_all(directory.join("scripts")).unwrap();
    for (name, source) in [
        (
            "greet",
            "console.log('hello', input.name); return {answer:42};",
        ),
        (
            "backfill",
            "return {title:'Generated',body:'**Markdown** from JavaScriptCore'};",
        ),
        ("loop", "while(true) {}"),
        (
            "notify",
            "var id=notify.push({title:'Script child'}); return {id:id};",
        ),
    ] {
        std::fs::write(directory.join("scripts").join(format!("{name}.js")), source).unwrap();
    }
    std::env::set_var("NC_HTTP", "1");
    std::env::set_var("NC_HTTP_PORT", "0");
    std::env::set_var("NC_SOCKET", "1");
    std::env::set_var("NC_SILENCED", "0");
    std::env::set_var("NC_SOCKET_PATH", directory.join("api.sock"));
    std::env::set_var("NC_SCRIPTS_DIR", directory.join("scripts"));
    std::env::set_var("NC_HISTORY_PATH", directory.join("history.json"));
    std::env::set_var("NC_ACKS_DIR", directory.join("acks"));
    directory
}
fn exchange(
    mut stream: impl Read + Write,
    method: &str,
    path: &str,
    body: Value,
) -> Result<(u16, Value), String> {
    let bytes = if body.is_null() {
        vec![]
    } else {
        serde_json::to_vec(&body).unwrap()
    };
    write!(
        stream,
        "{method} {path} HTTP/1.1\r\nHost: localhost\r\nContent-Length: {}\r\n\r\n",
        bytes.len()
    )
    .map_err(|e| e.to_string())?;
    stream.write_all(&bytes).map_err(|e| e.to_string())?;
    let mut output = vec![];
    stream.read_to_end(&mut output).map_err(|e| e.to_string())?;
    let separator = output
        .windows(4)
        .position(|b| b == b"\r\n\r\n")
        .ok_or("missing HTTP header")?;
    let status = String::from_utf8_lossy(&output[..separator])
        .split_whitespace()
        .nth(1)
        .ok_or("missing HTTP status")?
        .parse()
        .map_err(|_| "invalid HTTP status")?;
    Ok((
        status,
        serde_json::from_slice(&output[separator + 4..]).map_err(|e| e.to_string())?,
    ))
}
fn tcp(address: SocketAddr, method: &str, path: &str, body: Value) -> Result<(u16, Value), String> {
    let stream =
        TcpStream::connect_timeout(&address, Duration::from_secs(3)).map_err(|e| e.to_string())?;
    stream
        .set_read_timeout(Some(Duration::from_secs(20)))
        .map_err(|e| e.to_string())?;
    exchange(stream, method, path, body)
}
pub(crate) fn run(address: SocketAddr, directory: PathBuf) -> Result<(), String> {
    macro_rules! ensure {
        ($condition:expr,$message:expr) => {
            if !($condition) {
                return Err($message.into());
            }
        };
    }
    std::thread::sleep(Duration::from_millis(300));
    let (_, status) = tcp(address, "GET", "/v1/status", Value::Null)?;
    ensure!(
        status["listening"]["http"] == true && status["listening"]["unixSocket"] == true,
        "listeners unavailable"
    );
    let (_, first) = tcp(
        address,
        "POST",
        "/v1/push",
        json!({"title":"HTTP material check","body":"Native vibrancy · smooth entry","group":"smoke","timeout":60,"actions":[{"label":"查看","url":"https://example.com"}],"island":{"text":"测试中","progress":0.6}}),
    )?;
    ensure!(first["outcome"] == "displayed", "HTTP push failed");
    std::thread::sleep(Duration::from_millis(500));
    let (_, second) = exchange(
        UnixStream::connect(directory.join("api.sock")).map_err(|e| e.to_string())?,
        "POST",
        "/v1/push",
        json!({"title":"Unix replacement","group":"smoke","body":"Same pipeline, same group"}),
    )?;
    ensure!(
        first["id"] != second["id"],
        "replacement did not get a new ID"
    );
    let (_, history) = tcp(address, "GET", "/v1/history", Value::Null)?;
    ensure!(
        history["items"].as_array().is_some_and(|v| v.len() == 1),
        "group collapse failed"
    );
    let (status, _) = tcp(address, "POST", "/v1/clear", json!({"group":5}))?;
    ensure!(status == 400, "malformed clear was accepted");
    let (_, history) = tcp(address, "GET", "/v1/history?limit=0", Value::Null)?;
    ensure!(
        history["items"].as_array().is_some_and(|v| v.len() == 1),
        "invalid clear deleted history"
    );
    let (mut ws, _) =
        tungstenite::connect(format!("ws://{address}/v1/events")).map_err(|e| e.to_string())?;
    let hello: Value = serde_json::from_str(
        ws.read()
            .map_err(|e| e.to_string())?
            .to_text()
            .map_err(|e| e.to_string())?,
    )
    .map_err(|e| e.to_string())?;
    ensure!(hello["type"] == "hello", "missing websocket hello");
    ws.send(tungstenite::Message::text(
        json!({"op":"push","ref":"ws-1","title":"WebSocket push"}).to_string(),
    ))
    .map_err(|e| e.to_string())?;
    loop {
        let message: Value = serde_json::from_str(
            ws.read()
                .map_err(|e| e.to_string())?
                .to_text()
                .map_err(|e| e.to_string())?,
        )
        .map_err(|e| e.to_string())?;
        if message["type"] == "result" {
            ensure!(
                message["ref"] == "ws-1" && message["ok"] == true,
                "websocket command failed"
            );
            break;
        }
    }
    ws.close(None).map_err(|e| e.to_string())?;
    let (_, exec) = tcp(
        address,
        "POST",
        "/v1/exec",
        json!({"script":"greet","input":{"name":"Codex"}}),
    )?;
    ensure!(
        exec["ok"] == true && exec["result"]["answer"] == 42 && exec["logs"][0] == "hello Codex",
        "JavaScriptCore result/logs failed"
    );
    let (_, exec) = tcp(
        address,
        "POST",
        "/v1/exec",
        json!({"script":"loop","timeoutMs":100}),
    )?;
    ensure!(
        exec["ok"] == false && exec["error"] == "timeout",
        "script watchdog failed"
    );
    let (_, exec) = tcp(address, "POST", "/v1/exec", json!({"script":"notify"}))?;
    ensure!(
        exec["ok"] == true && exec["result"]["id"].as_str().is_some_and(|s| !s.is_empty()),
        "script notify bridge failed"
    );
    let (_, pushed) = tcp(
        address,
        "POST",
        "/v1/push",
        json!({"script":"backfill","group":"generated"}),
    )?;
    let mut filled = false;
    for _ in 0..40 {
        let (_, history) = tcp(address, "GET", "/v1/history?limit=50", Value::Null)?;
        if history["items"]
            .as_array()
            .unwrap()
            .iter()
            .any(|n| n["id"] == pushed["id"] && n["title"] == "Generated")
        {
            filled = true;
            break;
        }
        std::thread::sleep(Duration::from_millis(50));
    }
    ensure!(filled, "script backfill did not update original UUID");
    let (_, clear) = tcp(address, "POST", "/v1/clear", Value::Null)?;
    ensure!(clear["ok"] == true, "clear failed");
    let (_, status) = tcp(address, "GET", "/v1/status", Value::Null)?;
    ensure!(
        status["historyCount"] == 0 && status["unreadCount"] == 0,
        "clear counts diverged"
    );
    std::thread::sleep(Duration::from_millis(700));
    eprintln!("SMOKE PASS: native app, HTTP, Unix socket, group replacement, malformed clear, WebSocket, scripts/logs/timeout/notify/backfill, history/status");
    Ok(())
}
