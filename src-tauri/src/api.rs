//! HTTP + WebSocket + Unix socket 三通道 API。
//!
//! Swift `HTTPServer/HTTPCodec/APIRouter/WSEventHub/APIListenerService` 的
//! 移植：同一套路由同时挂在 127.0.0.1 TCP 与 Unix socket 上；`/v1/events`
//! 升级为 WebSocket 后可收命令帧、收事件帧。协议要点（刻意对齐）：
//!
//! - HTTP/1.1 每响应 `Connection: close`（无 keep-alive）；
//! - 头 ≤ 8 KiB、体 ≤ 32 KiB（超限 413，不是畸形）；
//! - Host 头必须是本机名（DNS rebinding 防御），WS 另有 Origin 闸；
//! - 错误形状统一 `{"error":…, "field":…?}`；405 = 已知路径错方法；
//! - 校验/归一化全部走 validator 一条管线（HTTP 与 WS 两扇门共享，
//!   Swift APIRouter 的教训：管线写两遍就会漏字段）。

use std::collections::HashMap;
use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};
use std::os::unix::net::{UnixListener, UnixStream};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use serde::Deserialize;
use serde_json::{json, Value};

use crate::manager::ToastState;
use crate::model::{CardPayload, PushOutcome};
use crate::stack::StackEvent;
use crate::validator;

// ── 桥接：actor 往返（测试换假实现） ──────────────────────────────────

pub trait ApiBridge: Send + Sync + 'static {
    /// 同步投递并等待去向应答（HTTP/WS 门要 outcome）。
    fn deliver(&self, item: CardPayload) -> PushOutcome;
    fn send(&self, event: StackEvent);
    fn snapshot(&self) -> Option<ToastState>;
    /// 历史全量 + 已读 id 集（/v1/history 与 unreadCount 的数据源）。
    fn history(&self) -> (Vec<CardPayload>, Vec<uuid::Uuid>);
}

pub struct ActorBridge;

impl ApiBridge for ActorBridge {
    fn deliver(&self, item: CardPayload) -> PushOutcome {
        let (tx, rx) = tokio::sync::oneshot::channel();
        crate::stack::send(StackEvent::Deliver {
            item,
            reply: Some(tx),
        });
        rx.blocking_recv().unwrap_or(PushOutcome::Withheld)
    }

    fn send(&self, event: StackEvent) {
        crate::stack::send(event);
    }

    fn snapshot(&self) -> Option<ToastState> {
        crate::notifier::STATE_MIRROR.lock().unwrap().clone()
    }

    fn history(&self) -> (Vec<CardPayload>, Vec<uuid::Uuid>) {
        crate::notifier::history_mirror()
    }
}

// ── WS 事件扇出（Swift WSEventHub） ────────────────────────────────────

static HUB: OnceLock<tokio::sync::broadcast::Sender<String>> = OnceLock::new();

fn hub() -> tokio::sync::broadcast::Sender<String> {
    HUB.get_or_init(|| tokio::sync::broadcast::channel(64).0)
        .clone()
}

static LAST_UNREAD: AtomicU64 = AtomicU64::new(0);

/// unreadCount 变化 → 一帧扇出给所有 WS 会话（Swift unreadCountDidChange）。
pub fn on_unread_count(count: usize) {
    let count = count as u64;
    if LAST_UNREAD.swap(count, Ordering::SeqCst) != count {
        let _ = hub().send(json!({"type": "unreadCount", "count": count}).to_string());
    }
}

/// ack 帧扇出（Phase 4.1 的回执写入后调用；键形状对齐 Swift ackDidRecord）。
pub fn on_ack(ack: &Value) {
    let _ = hub().send(ack.to_string());
}

// ── HTTP codec（Swift HTTPCodec 移植） ─────────────────────────────────

pub const MAX_HEAD_LENGTH: usize = 8192;
pub const MAX_BODY_LENGTH: usize = 32768;

pub struct HttpHead {
    pub method: String,
    pub path: String,
    pub query: HashMap<String, String>,
    pub headers: HashMap<String, String>,
    pub content_length: usize,
}

pub enum HeadResult {
    NeedMore,
    Malformed,
    Head(HttpHead, Vec<u8>),
}

fn find_subslice(haystack: &[u8], needle: &[u8]) -> Option<usize> {
    haystack
        .windows(needle.len())
        .position(|w| w == needle)
}

/// percent 解码；失败回退原文（键值同一策略——Swift 同款）。
fn percent_decode(raw: &str) -> String {
    let bytes = raw.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        match bytes[i] {
            b'%' if i + 2 < bytes.len() + 1 && i + 2 <= bytes.len() - 1 + 1 && i + 2 < bytes.len() + 1 => {
                let hex = bytes.get(i + 1..i + 3);
                match hex.and_then(|h| {
                    u8::from_str_radix(std::str::from_utf8(h).ok()?, 16).ok()
                }) {
                    Some(b) => {
                        out.push(b);
                        i += 3;
                    }
                    None => {
                        out.push(bytes[i]);
                        i += 1;
                    }
                }
            }
            b => {
                out.push(b);
                i += 1;
            }
        }
    }
    String::from_utf8(out).unwrap_or_else(|_| raw.to_owned())
}

pub fn parse_request_head(data: &[u8]) -> HeadResult {
    let delim = b"\r\n\r\n";
    let Some(pos) = find_subslice(data, delim) else {
        // 头部缓冲可能已含 ≤3 字节 delimiter 前缀，仍然可以顶到上限。
        return if data.len() > MAX_HEAD_LENGTH + 3 {
            HeadResult::Malformed
        } else {
            HeadResult::NeedMore
        };
    };
    if pos > MAX_HEAD_LENGTH {
        return HeadResult::Malformed;
    }
    let head_text = String::from_utf8_lossy(&data[..pos]);
    let mut lines = head_text.split("\r\n");
    let Some(request_line) = lines.next() else {
        return HeadResult::Malformed;
    };
    let parts: Vec<&str> = request_line.split(' ').filter(|p| !p.is_empty()).collect();
    // `METHOD SP target SP HTTP-version`；短于此或没有 HTTP/ 版本词 = 非法。
    if parts.len() < 3 || !parts[2].starts_with("HTTP/") {
        return HeadResult::Malformed;
    }
    let method = parts[0].to_uppercase();
    let target = parts[1];

    let (path, query) = match target.split_once('?') {
        Some((path, qs)) => {
            let mut query = HashMap::new();
            for pair in qs.split('&') {
                let (k, v) = pair.split_once('=').unwrap_or((pair, ""));
                query.insert(percent_decode(k), percent_decode(v));
            }
            (path.to_owned(), query)
        }
        None => (target.to_owned(), HashMap::new()),
    };

    let mut headers = HashMap::new();
    for line in lines {
        let Some(colon) = line.find(':') else {
            return HeadResult::Malformed;
        };
        let key = line[..colon].trim().to_lowercase();
        let value = line[colon + 1..].trim().to_owned();
        headers.insert(key, value);
    }

    // 负 Content-Length 畸形；解析失败 = 视作无体（0）；超长不是畸形——
    // 服务器用 413 回答后关闭（spec §8）。
    let content_length = match headers.get("content-length") {
        Some(v) => match v.parse::<i64>() {
            Ok(n) if n < 0 => return HeadResult::Malformed,
            Ok(n) => n as usize,
            Err(_) => 0,
        },
        None => 0,
    };

    HeadResult::Head(
        HttpHead {
            method,
            path,
            query,
            headers,
            content_length,
        },
        data[pos + 4..].to_vec(),
    )
}

pub fn response(status: u16, reason: &str, body: &[u8]) -> Vec<u8> {
    let head = format!(
        "HTTP/1.1 {status} {reason}\r\nContent-Type: application/json; charset=utf-8\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
        body.len()
    );
    let mut out = head.into_bytes();
    out.extend_from_slice(body);
    out
}

pub fn reason_for(status: u16) -> &'static str {
    match status {
        200 => "OK",
        400 => "Bad Request",
        403 => "Forbidden",
        404 => "Not Found",
        405 => "Method Not Allowed",
        413 => "Payload Too Large",
        101 => "Switching Protocols",
        _ => "Status",
    }
}

/// Host 头必须点名本机（DNS rebinding / 浏览器顺手打本地端口的防御）。
/// 缺席 = 非浏览器客户端（Unix socket 上的 curl），放行。
pub fn is_local_host(host_header: Option<&str>) -> bool {
    let Some(host) = host_header.filter(|h| !h.is_empty()) else {
        return true;
    };
    let mut host = host.to_lowercase();
    if host.starts_with('[') {
        if let Some(close) = host.find(']') {
            host.truncate(close + 1);
        }
    } else if let Some(colon) = host.find(':') {
        host.truncate(colon);
    }
    host == "127.0.0.1" || host == "localhost" || host == "[::1]"
}

/// WS 升级的 Origin 白名单（浏览器攻不破 Origin 头；file:// 给本地面板）。
pub fn is_allowed_origin(origin: &str) -> bool {
    matches!(
        origin.to_lowercase().as_str(),
        "http://127.0.0.1"
            | "http://localhost"
            | "https://127.0.0.1"
            | "https://localhost"
            | "ws://127.0.0.1"
            | "ws://localhost"
            | "file://"
    )
}

/// RFC 6455 的 Sec-WebSocket-Key：存在且是合法 base64（Swift handshakeKey）。
fn valid_ws_key(key: &str) -> bool {
    if key.is_empty() || key.len() % 4 != 0 {
        return false;
    }
    let bytes = key.as_bytes();
    for (i, b) in bytes.iter().enumerate() {
        let ok = b.is_ascii_alphanumeric() || *b == b'+' || *b == b'/';
        let is_pad = *b == b'=' && i >= bytes.len() - 2;
        if !(ok || is_pad) {
            return false;
        }
    }
    true
}

// ── 路由（Swift APIRouter 移植：一条管线，两扇门） ────────────────────

#[derive(Deserialize, Default)]
#[serde(rename_all = "camelCase")]
struct ClearDto {
    group: Option<String>,
}

#[derive(Deserialize, Default)]
#[serde(rename_all = "camelCase")]
struct SilenceDto {
    minutes: Option<i64>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ExecDto {
    script: String,
    input: Option<Value>,
    timeout_ms: Option<i64>,
}

/// exec 预算钳制（Swift performExec 同款）：默认 10s，夹到 100ms…10s。
/// 钳制住在路由层，HTTP 与 WS 两扇门超时行为一致。
pub fn clamp_exec_timeout(timeout_ms: Option<i64>) -> i64 {
    timeout_ms.unwrap_or(10_000).clamp(100, 10_000)
}

pub fn default_silence_minutes() -> i64 {
    60
}
pub fn max_silence_minutes() -> i64 {
    1440
}

/// 静默请求的纯语义（Swift resolveSilence）：None=默认一小时；≤0=恢复；
/// 其余 clamp 到 1440。坏 JSON 是 400，绝不悄悄恢复。
#[derive(Debug, PartialEq)]
pub enum SilenceRequest {
    Silence(i64),
    Resume,
}

pub fn resolve_silence(minutes: Option<i64>) -> SilenceRequest {
    let minutes = minutes.unwrap_or_else(default_silence_minutes);
    if minutes <= 0 {
        return SilenceRequest::Resume;
    }
    SilenceRequest::Silence(minutes.min(max_silence_minutes()))
}

fn now_epoch() -> f64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs_f64())
        .unwrap_or(0.0)
}

/// 静默管线（HTTP POST 与 WS silence 帧共用）。返回 (silenced, until)。
fn apply_silence(bridge: &Arc<dyn ApiBridge>, minutes: Option<i64>) -> (bool, Option<f64>) {
    match resolve_silence(minutes) {
        SilenceRequest::Resume => {
            bridge.send(StackEvent::Silence(None));
            (false, None)
        }
        SilenceRequest::Silence(m) => {
            bridge.send(StackEvent::Silence(Some(m as f64)));
            (true, Some(now_epoch() + m as f64 * 60.0))
        }
    }
}

/// 历史条目 wire 形状（Swift HistoryItemDTO）：body（不是 bodyMarkdown），
/// timeout/group/native 缺席即省略。
#[derive(serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct HistoryItemDto {
    pub id: uuid::Uuid,
    pub title: String,
    pub body: String,
    pub urgency: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub timeout: Option<f64>,
    pub timestamp: f64,
    pub actions: Vec<crate::model::NotificationAction>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub group: Option<String>,
    pub tags: Vec<String>,
    pub read: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub native: Option<bool>,
}

pub fn history_item_dto(item: &CardPayload, read: bool) -> HistoryItemDto {
    HistoryItemDto {
        id: item.id,
        title: item.title.clone(),
        body: item.body_markdown.clone(),
        urgency: serde_json::to_value(item.urgency)
            .ok()
            .and_then(|v| v.as_str().map(str::to_owned))
            .unwrap_or_else(|| "normal".into()),
        timeout: item.timeout,
        timestamp: item.timestamp,
        actions: item.actions.clone(),
        group: item.group.clone(),
        tags: item.tags.clone(),
        read,
        native: item.native,
    }
}

fn known_path(path: &str) -> bool {
    matches!(
        path,
        "/v1/push" | "/v1/clear" | "/v1/exec" | "/v1/silence" | "/v1/history" | "/v1/status"
    )
}

/// 一次请求 → 一次 JSON 应答。错误形状统一 `{"error", "field"?}`。
pub fn route(
    bridge: &Arc<dyn ApiBridge>,
    method: &str,
    path: &str,
    query: &HashMap<String, String>,
    body: Option<&[u8]>,
) -> (u16, Value) {
    match (method, path) {
        ("POST", "/v1/push") => {
            let Some(body) = body else {
                return validator::error(400, "请求体不是合法 JSON", None);
            };
            match validator::validate(body) {
                Ok(item) => {
                    let outcome = bridge.deliver(item.clone());
                    (
                        200,
                        json!({"outcome": outcome.label(), "id": item.id.to_string()}),
                    )
                }
                Err((status, e)) => (status, e),
            }
        }
        ("POST", "/v1/clear") => {
            // 无体/空体 = 清全部；有体必须解析——坏 JSON 是 400，
            // 绝不悄悄清全部（spec §8）。
            match body.filter(|b| !b.is_empty()) {
                None => {
                    bridge.send(StackEvent::ClearAll);
                    (200, json!({"ok": true}))
                }
                Some(raw) => match serde_json::from_slice::<ClearDto>(raw) {
                    Ok(dto) => {
                        match validator::norm_group(dto.group.as_deref()) {
                            Some(key) => bridge.send(StackEvent::ClearGroup(key)),
                            None => bridge.send(StackEvent::ClearAll),
                        }
                        (200, json!({"ok": true}))
                    }
                    Err(_) => validator::error(400, "请求体不是合法 JSON", None),
                },
            }
        }
        ("POST", "/v1/exec") => {
            // 手动执行：同步等结果（预算在路由层钳制，两扇门一致），三态
            // 响应 ok/result/error/logs（Swift ExecResponse 同构；脚本失败
            // 也是 200，错误在载荷里）。
            let Some(body) = body else {
                return validator::error(400, "请求体不是合法 JSON", None);
            };
            match serde_json::from_slice::<ExecDto>(body) {
                Ok(dto) => {
                    let budget = clamp_exec_timeout(dto.timeout_ms);
                    let outcome = crate::script_host::dispatch_exec(
                        &dto.script,
                        dto.input.unwrap_or_else(|| json!({})),
                        budget,
                    );
                    (200, outcome)
                }
                Err(_) => validator::error(400, "请求体不是合法 JSON", None),
            }
        }
        ("POST", "/v1/silence") => {
            // 无体/空体 = 一小时（菜单项同款默认）；有体必须解析。
            let minutes = match body.filter(|b| !b.is_empty()) {
                None => None,
                Some(raw) => match serde_json::from_slice::<SilenceDto>(raw) {
                    Ok(dto) => dto.minutes,
                    Err(_) => return validator::error(400, "请求体不是合法 JSON", None),
                },
            };
            let (silenced, until) = apply_silence(bridge, minutes);
            let mut v = json!({"ok": true, "silenced": silenced});
            if let Some(until) = until {
                v["until"] = until.into();
            }
            (200, v)
        }
        ("DELETE", "/v1/silence") => {
            bridge.send(StackEvent::Silence(None));
            (200, json!({"ok": true, "silenced": false}))
        }
        ("GET", "/v1/history") => {
            let requested = query
                .get("limit")
                .and_then(|v| v.parse::<i64>().ok())
                .unwrap_or(20);
            let limit = requested.clamp(1, crate::history::MAX_HISTORY_COUNT as i64) as usize;
            let (items, read_ids) = bridge.history();
            let start = items.len().saturating_sub(limit);
            let read: std::collections::HashSet<uuid::Uuid> = read_ids.into_iter().collect();
            let dtos: Vec<Value> = items[start..]
                .iter()
                .map(|item| {
                    serde_json::to_value(history_item_dto(item, read.contains(&item.id)))
                        .unwrap_or(Value::Null)
                })
                .collect();
            let unread_count = items.iter().filter(|i| !read.contains(&i.id)).count();
            (
                200,
                json!({"items": dtos, "unreadCount": unread_count}),
            )
        }
        ("GET", "/v1/status") => {
            let (items, read_ids) = bridge.history();
            let read: std::collections::HashSet<uuid::Uuid> = read_ids.into_iter().collect();
            let unread_count = items.iter().filter(|i| !read.contains(&i.id)).count();
            let silenced = bridge.snapshot().map(|s| s.silenced).unwrap_or(false);
            let flags = flags();
            (
                200,
                json!({
                    "unreadCount": unread_count,
                    "historyCount": items.len(),
                    "silenced": silenced,
                    // v4 删了待显示队列，但字段保留恒 0（不破坏既有客户端）。
                    "pendingCount": 0,
                    "listening": {
                        "unixSocket": flags.socket.load(Ordering::SeqCst),
                        "http": flags.http.load(Ordering::SeqCst),
                    },
                }),
            )
        }
        (m, p) if known_path(p) => {
            let _ = m;
            validator::error(405, "方法不允许", None)
        }
        _ => validator::error(404, "未知路径", None),
    }
}

// ── WS 命令帧（Swift APIRouter.handleWSCommand 移植） ──────────────────

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct WsCommand {
    op: String,
    #[serde(rename = "ref")]
    #[allow(dead_code)]
    ref_: Option<String>,
    title: Option<String>,
    body: Option<String>,
    urgency: Option<String>,
    timeout: Option<f64>,
    group: Option<String>,
    actions: Option<Vec<Value>>,
    blocks: Option<Vec<Value>>,
    island: Option<Value>,
    script: Option<String>,
    click_url: Option<String>,
    tags: Option<Vec<Value>>,
    native: Option<Value>,
    input: Option<Value>,
    timeout_ms: Option<i64>,
    minutes: Option<i64>,
}

/// 结果帧：nil 字段省略（Swift JSONEncoder encodeIfPresent 同款），
/// 但 silence 的 result 对象里 until 显式 null（Swift .null 同款）。
fn ws_result(ref_id: Option<&str>, ok: bool) -> Value {
    let mut v = json!({"type": "result", "ok": ok});
    if let Some(r) = ref_id {
        v["ref"] = r.into();
    }
    v
}

fn ws_result_error(ref_id: Option<&str>, error: &str) -> Value {
    let mut v = ws_result(ref_id, false);
    v["error"] = error.into();
    v
}

/// 一帧命令 → 一帧结果。永不抛：错误都是 ok:false 结果帧，
/// 客户端可以按 ref 关联。
pub fn handle_ws_command(bridge: &Arc<dyn ApiBridge>, text: &str) -> Value {
    let cmd: WsCommand = match serde_json::from_str(text) {
        Ok(cmd) => cmd,
        Err(_) => return ws_result_error(None, "帧不是合法 JSON"),
    };
    let ref_id = cmd.ref_.clone();
    let ref_id = ref_id.as_deref();
    match cmd.op.as_str() {
        "push" => {
            // 帧 → 同一 push 管线的 JSON 体（HTTP 门同款 validate）。
            let body = json!({
                "title": cmd.title,
                "body": cmd.body,
                "urgency": cmd.urgency,
                "timeout": cmd.timeout,
                "group": cmd.group,
                "actions": cmd.actions.unwrap_or_default(),
                "blocks": cmd.blocks,
                "island": cmd.island,
                "script": cmd.script,
                "clickUrl": cmd.click_url,
                "tags": cmd.tags.unwrap_or_default(),
                "native": cmd.native,
            });
            match validator::validate(body.to_string().as_bytes()) {
                Ok(item) => {
                    let outcome = bridge.deliver(item.clone());
                    let mut v = ws_result(ref_id, true);
                    v["outcome"] = outcome.label().into();
                    v["id"] = item.id.to_string().into();
                    v
                }
                Err((_, e)) => {
                    ws_result_error(ref_id, e["error"].as_str().unwrap_or("非法推送"))
                }
            }
        }
        "silence" => {
            let (silenced, until) = apply_silence(bridge, cmd.minutes);
            let mut v = ws_result(ref_id, true);
            // until 显式 null（Swift result .object 里 .null 不省略）。
            v["result"] = json!({"silenced": silenced, "until": until});
            v
        }
        "clear" => {
            match validator::norm_group(cmd.group.as_deref()) {
                Some(key) => bridge.send(StackEvent::ClearGroup(key)),
                None => bridge.send(StackEvent::ClearAll),
            }
            ws_result(ref_id, true)
        }
        "exec" => {
            let Some(script) = cmd.script.as_deref() else {
                return ws_result_error(ref_id, "缺少 script");
            };
            let budget = clamp_exec_timeout(cmd.timeout_ms);
            let outcome = crate::script_host::dispatch_exec(
                script,
                cmd.input.unwrap_or_else(|| json!({})),
                budget,
            );
            // 结果帧（Swift WSResultFrame）：ok 随载荷，result/error 各自
            // 缺席省略，logs 始终在——客户端可按 ref 关联。
            let mut v = ws_result(ref_id, outcome["ok"].as_bool().unwrap_or(false));
            if let Some(result) = outcome.get("result") {
                v["result"] = result.clone();
            }
            if let Some(error) = outcome.get("error") {
                v["error"] = error.clone();
            }
            v["logs"] = outcome
                .get("logs")
                .cloned()
                .unwrap_or_else(|| json!([]));
            v
        }
        _ => ws_result_error(ref_id, "未知操作"),
    }
}

// ── WS 会话 ────────────────────────────────────────────────────────────

trait RawStream: Read + Write + Send + 'static {
    fn set_timeout(&self, d: Option<Duration>) -> std::io::Result<()>;
}

impl RawStream for TcpStream {
    fn set_timeout(&self, d: Option<Duration>) -> std::io::Result<()> {
        self.set_read_timeout(d)
    }
}

impl RawStream for UnixStream {
    fn set_timeout(&self, d: Option<Duration>) -> std::io::Result<()> {
        self.set_read_timeout(d)
    }
}

fn ws_session<S: RawStream>(mut stream: S, key: &str, bridge: Arc<dyn ApiBridge>) {
    // 手工 101 握手（Swift WSCodec.upgradeResponse），帧层交给 tungstenite：
    // accept key 是 RFC 6455 的 SHA1+base64，tungstenite 公开同款函数。
    let accept = tungstenite::handshake::derive_accept_key(key.as_bytes());
    let handshake = format!(
        "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: {accept}\r\n\r\n"
    );
    if stream.write_all(handshake.as_bytes()).is_err() {
        return;
    }
    let _ = stream.flush();

    // 轮询读：200ms 超时让广播帧与读帧在同一线程交错。
    // tungstenite 对 WouldBlock 是可恢复的（partial 帧状态保留）。
    let _ = stream.set_timeout(Some(Duration::from_millis(200)));
    let mut ws = tungstenite::protocol::WebSocket::from_raw_socket(
        stream,
        tungstenite::protocol::Role::Server,
        None,
    );

    // hello 帧（Swift hub.register 同款）。
    let unread = bridge
        .snapshot()
        .map(|s| s.unread_count)
        .unwrap_or(0);
    if ws
        .send(tungstenite::protocol::Message::Text(
            json!({"type": "hello", "unreadCount": unread}).to_string().into(),
        ))
        .is_err()
    {
        return;
    }

    let mut rx = hub().subscribe();
    loop {
        use tungstenite::protocol::Message;
        loop {
            match ws.read() {
                Ok(Message::Text(text)) => {
                    let result = handle_ws_command(&bridge, text.as_str());
                    if ws.send(Message::Text(result.to_string().into())).is_err() {
                        return;
                    }
                }
                Ok(Message::Close(_)) => return,
                Ok(_) => {}
                Err(tungstenite::Error::Io(e))
                    if e.kind() == std::io::ErrorKind::WouldBlock
                        || e.kind() == std::io::ErrorKind::TimedOut =>
                {
                    break;
                }
                Err(_) => return,
            }
        }
        while let Ok(event) = rx.try_recv() {
            if ws
                .send(tungstenite::protocol::Message::Text(event.into()))
                .is_err()
            {
                return;
            }
        }
        let _ = ws.flush();
        std::thread::sleep(Duration::from_millis(15));
    }
}

// ── 连接泵（Swift ConnectionHandler 移植） ─────────────────────────────

const READ_DEADLINE: Duration = Duration::from_secs(30);

fn handle_connection<S: RawStream>(mut stream: S, bridge: Arc<dyn ApiBridge>) {
    let mut buf: Vec<u8> = Vec::new();
    let mut chunk = [0u8; 65536];
    let head = loop {
        match parse_request_head(&buf) {
            HeadResult::NeedMore => {
                let _ = stream.set_timeout(Some(READ_DEADLINE));
                match stream.read(&mut chunk) {
                    Ok(0) | Err(_) => return,
                    Ok(n) => buf.extend_from_slice(&chunk[..n]),
                }
            }
            HeadResult::Malformed => return,
            HeadResult::Head(head, rest) => break (head, rest),
        }
    };
    let (head, mut body_buf) = head;

    // DNS rebinding 防御：Host 头必须点名本机（路由之前的闸）。
    if !is_local_host(head.headers.get("host").map(String::as_str)) {
        let body = r#"{"error":"非本机 Host 请求被拒绝"}"#.as_bytes();
        let _ = stream.write_all(&response(403, reason_for(403), body));
        return;
    }
    if head.content_length > MAX_BODY_LENGTH {
        let body = r#"{"error":"请求体过大"}"#.as_bytes();
        let _ = stream.write_all(&response(413, reason_for(413), body));
        return;
    }

    let is_upgrade = head
        .headers
        .get("upgrade")
        .map(|v| v.to_lowercase().contains("websocket"))
        .unwrap_or(false);
    if is_upgrade {
        // WS 没有同源闸可言，浏览器可随意尝试——Origin 是分辨器。
        if let Some(origin) = head.headers.get("origin") {
            if !is_allowed_origin(origin) {
                let body = r#"{"error":"非本机 Origin，拒绝升级"}"#.as_bytes();
                let _ = stream.write_all(&response(403, reason_for(403), body));
                return;
            }
        }
        // RFC 6455 §4.2.1：只讲 13。
        if let Some(v) = head.headers.get("sec-websocket-version") {
            if v != "13" {
                let body = r#"{"error":"Sec-WebSocket-Version 不受支持"}"#.as_bytes();
                let _ = stream.write_all(&response(400, reason_for(400), body));
                return;
            }
        }
        if head.path == "/v1/events" {
            match head.headers.get("sec-websocket-key") {
                Some(key) if valid_ws_key(key) => {
                    ws_session(stream, key, bridge);
                    return;
                }
                _ => {
                    let body = r#"{"error":"Sec-WebSocket-Key 缺失或不是合法 base64"}"#.as_bytes();
                    let _ = stream.write_all(&response(400, reason_for(400), body));
                    return;
                }
            }
        }
        // 升级被拒：升级请求没有体，按无体常规路由（Swift 同款）。
    } else {
        while body_buf.len() < head.content_length {
            match stream.read(&mut chunk) {
                Ok(0) | Err(_) => return,
                Ok(n) => body_buf.extend_from_slice(&chunk[..n]),
            }
        }
    }

    let body = if head.content_length == 0 || is_upgrade {
        None
    } else {
        Some(&body_buf[..head.content_length])
    };
    let (status, value) = route(&bridge, &head.method, &head.path, &head.query, body);
    let _ = stream.write_all(&response(status, reason_for(status), value.to_string().as_bytes()));
}

// ── 监听器（Swift APIListenerService 移植） ────────────────────────────

pub struct Flags {
    pub http: AtomicBool,
    pub socket: AtomicBool,
    pub http_error: Mutex<Option<String>>,
    pub socket_error: Mutex<Option<String>>,
    pub socket_notice: Mutex<Option<String>>,
}

static FLAGS: OnceLock<Arc<Flags>> = OnceLock::new();
static SOCKET_OWNED: AtomicBool = AtomicBool::new(false);
static SOCKET_PATH: Mutex<Option<String>> = Mutex::new(None);

pub fn flags() -> Arc<Flags> {
    FLAGS
        .get_or_init(|| {
            Arc::new(Flags {
                http: AtomicBool::new(false),
                socket: AtomicBool::new(false),
                http_error: Mutex::new(None),
                socket_error: Mutex::new(None),
                socket_notice: Mutex::new(None),
            })
        })
        .clone()
}

/// 默认 socket 路径是客户端契约的一部分（README 协议表），保持
/// `MacDesktopNotify/api.sock`——与 Swift 版同路径。
pub fn default_socket_path() -> String {
    let home = std::env::var("HOME").unwrap_or_default();
    format!("{home}/Library/Application Support/MacDesktopNotify/api.sock")
}

/// `sockaddr_un.sun_path` 103 可用字节；超长改向短路径（Swift 同款）。
pub fn resolve_socket_path(preferred: &str) -> (String, Option<String>) {
    if preferred.len() <= 103 {
        return (preferred.to_owned(), None);
    }
    let short = short_socket_path(preferred);
    (
        short.clone(),
        Some(format!(
            "socket 路径 {} 字节超过 103，已改向 {short}",
            preferred.len()
        )),
    )
}

/// `/tmp/mdn-<uid>-<hash 后 12 位>.sock`（FNV-1a 64，纯函数映射）。
pub fn short_socket_path(preferred: &str) -> String {
    extern "C" {
        fn getuid() -> u32;
    }
    let mut hash: u64 = 0xcbf2_9ce4_8422_2325;
    for byte in preferred.as_bytes() {
        hash ^= *byte as u64;
        hash = hash.wrapping_mul(0x0000_0100_0000_01b3);
    }
    let uid = unsafe { getuid() };
    format!("/tmp/mdn-{uid}-{:x}.sock", hash & 0xffff_ffff_ffff)
}

/// 存活探测：stale 文件拒不拒绝连接一眼可辨（Swift socketIsLive）。
fn socket_is_live(path: &str) -> bool {
    UnixStream::connect(path).is_ok()
}

fn start_tcp(bridge: Arc<dyn ApiBridge>, port: u16) {
    let listener = match TcpListener::bind(("127.0.0.1", port)) {
        Ok(l) => l,
        Err(e) => {
            *flags().http_error.lock().unwrap() = Some(format!("端口 {port} 无法监听：{e}"));
            return;
        }
    };
    flags().http.store(true, Ordering::SeqCst);
    *flags().http_error.lock().unwrap() = None;
    std::thread::spawn(move || {
        for stream in listener.incoming() {
            let Ok(stream) = stream else { continue };
            let bridge = bridge.clone();
            std::thread::spawn(move || handle_connection(stream, bridge));
        }
    });
}

fn start_unix(bridge: Arc<dyn ApiBridge>, preferred: &str) {
    let (path, notice) = resolve_socket_path(preferred);
    *flags().socket_notice.lock().unwrap() = notice;
    if std::path::Path::new(&path).exists() {
        // 文件在 ≠ 死了：先探测，活着就是另一个实例的——绝不拔线。
        if socket_is_live(&path) {
            *flags().socket_error.lock().unwrap() = Some("另一个实例正在使用该 socket".into());
            return;
        }
        if let Err(e) = std::fs::remove_file(&path) {
            *flags().socket_error.lock().unwrap() = Some(format!("旧 socket 文件无法移除：{e}"));
            return;
        }
    }
    if let Some(dir) = std::path::Path::new(&path).parent() {
        let _ = std::fs::create_dir_all(dir);
    }
    let listener = match UnixListener::bind(&path) {
        Ok(l) => l,
        Err(e) => {
            *flags().socket_error.lock().unwrap() = Some(format!("Unix socket 无法监听：{e}"));
            return;
        }
    };
    // NWListener 没有权限参数；收紧刚建好的文件（0600）。
    use std::os::unix::fs::PermissionsExt;
    let _ = std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600));
    SOCKET_OWNED.store(true, Ordering::SeqCst);
    *SOCKET_PATH.lock().unwrap() = Some(path);
    flags().socket.store(true, Ordering::SeqCst);
    *flags().socket_error.lock().unwrap() = None;
    std::thread::spawn(move || {
        for stream in listener.incoming() {
            let Ok(stream) = stream else { continue };
            let bridge = bridge.clone();
            std::thread::spawn(move || handle_connection(stream, bridge));
        }
    });
}

/// 启动两路监听（配置开关各管各的；失败进 flags 供 /v1/status 与设置页）。
pub fn start(bridge: Arc<dyn ApiBridge>) {
    let config = crate::config::Config::load();
    if config.http_enabled {
        start_tcp(bridge.clone(), config.http_port);
    }
    if config.socket_enabled {
        start_unix(bridge, config.socket_path.as_deref().unwrap_or(&default_socket_path()));
    }
}

/// 进程退出时只回收「本进程绑定」的 socket 文件。
pub fn cleanup_socket() {
    if SOCKET_OWNED.swap(false, Ordering::SeqCst) {
        if let Some(path) = SOCKET_PATH.lock().unwrap().take() {
            let _ = std::fs::remove_file(path);
        }
    }
}

// ── 测试 ───────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::{Urgency, now_secs};
    use std::sync::Mutex as StdMutex;
    use uuid::Uuid;

    struct FakeBridge {
        events: StdMutex<Vec<String>>,
        items: StdMutex<Vec<CardPayload>>,
        read: StdMutex<Vec<Uuid>>,
    }

    impl FakeBridge {
        fn new() -> Self {
            Self {
                events: StdMutex::new(Vec::new()),
                items: StdMutex::new(Vec::new()),
                read: StdMutex::new(Vec::new()),
            }
        }
        fn events(&self) -> Vec<String> {
            self.events.lock().unwrap().clone()
        }
    }

    impl ApiBridge for FakeBridge {
        fn deliver(&self, item: CardPayload) -> PushOutcome {
            self.items.lock().unwrap().push(item);
            PushOutcome::Displayed
        }
        fn send(&self, event: StackEvent) {
            let label = match &event {
                StackEvent::ClearAll => "clear-all".into(),
                StackEvent::ClearGroup(key) => format!("clear-group:{key}"),
                StackEvent::Silence(None) => "resume".into(),
                StackEvent::Silence(Some(m)) => format!("silence:{m}"),
                _ => "other".into(),
            };
            self.events.lock().unwrap().push(label);
        }
        fn snapshot(&self) -> Option<ToastState> {
            None
        }
        fn history(&self) -> (Vec<CardPayload>, Vec<Uuid>) {
            (
                self.items.lock().unwrap().clone(),
                self.read.lock().unwrap().clone(),
            )
        }
    }

    fn bridge() -> Arc<FakeBridge> {
        Arc::new(FakeBridge::new())
    }

    fn as_dyn(b: &Arc<FakeBridge>) -> Arc<dyn ApiBridge> {
        b.clone()
    }

    fn item(title: &str) -> CardPayload {
        CardPayload {
            id: Uuid::new_v4(),
            title: title.into(),
            body_markdown: "body".into(),
            urgency: Urgency::default(),
            timeout: None,
            timestamp: now_secs(),
            actions: vec![],
            group: None,
            tags: vec![],
            read: false,
            click_url: None,
            island: None,
            script: None,
            occurrences: 1,
            native: None,
        }
    }

    #[test]
    fn codec_parses_and_rejects() {
        let raw = b"POST /v1/push?a=1&b=%E4%BA%2C&c=%E5%90%8D HTTP/1.1\r\nHost: 127.0.0.1:4770\r\nContent-Length: 2\r\n\r\n{}";
        match parse_request_head(raw) {
            HeadResult::Head(head, rest) => {
                assert_eq!(head.method, "POST");
                assert_eq!(head.path, "/v1/push");
                assert_eq!(head.query.get("a").unwrap(), "1");
                assert_eq!(head.query.get("b").unwrap(), "%E4%BA%2C"); // 非法 UTF-8 序列回退原文（Swift removingPercentEncoding 同款）
                assert_eq!(head.query.get("c").unwrap(), "\u{540d}");
                assert_eq!(head.content_length, 2);
                assert_eq!(rest, br#"{}"#);
            }
            _ => panic!("expected head"),
        }
        assert!(matches!(parse_request_head(b"GET / HTTP/1.1"), HeadResult::NeedMore));
        assert!(matches!(
            parse_request_head(b"garbage\r\n\r\n"),
            HeadResult::Malformed
        ));
    }

    #[test]
    fn host_and_origin_gates() {
        assert!(is_local_host(None));
        assert!(is_local_host(Some("127.0.0.1:4770")));
        assert!(is_local_host(Some("localhost")));
        assert!(is_local_host(Some("[::1]:4770")));
        assert!(!is_local_host(Some("evil.example.com")));
        assert!(is_allowed_origin("http://127.0.0.1"));
        assert!(is_allowed_origin("file://"));
        assert!(!is_allowed_origin("http://evil.example.com"));
    }

    #[test]
    fn silence_resolve_clamps_like_swift() {
        assert_eq!(resolve_silence(None), SilenceRequest::Silence(60));
        assert_eq!(resolve_silence(Some(0)), SilenceRequest::Resume);
        assert_eq!(resolve_silence(Some(-5)), SilenceRequest::Resume);
        assert_eq!(resolve_silence(Some(30)), SilenceRequest::Silence(30));
        assert_eq!(resolve_silence(Some(10_000)), SilenceRequest::Silence(1440));
    }

    #[test]
    fn push_route_delivers_and_shapes_error() {
        let b = bridge();
        let d = as_dyn(&b);
        let (status, v) = route(&d, "POST", "/v1/push", &HashMap::new(), Some(r#"{"title":"t"}"#.as_bytes()));
        assert_eq!(status, 200);
        assert_eq!(v["outcome"], "displayed");
        assert_eq!(v["id"].as_str().unwrap().len(), 36);

        // 缺 title：400 + field 提示。
        let (status, v) = route(&d, "POST", "/v1/push", &HashMap::new(), Some(r#"{"body":"x"}"#.as_bytes()));
        assert_eq!(status, 400);
        assert_eq!(v["field"], "title");
        // 无体 / 坏 JSON。
        let (status, _) = route(&d, "POST", "/v1/push", &HashMap::new(), None);
        assert_eq!(status, 400);
    }

    #[test]
    fn clear_semantics_two_doors_agree() {
        let b = bridge();
        let d = as_dyn(&b);
        let _ = route(&d, "POST", "/v1/clear", &HashMap::new(), None);
        let _ = route(&d, "POST", "/v1/clear", &HashMap::new(), Some(b""));
        let _ = route(&d, "POST", "/v1/clear", &HashMap::new(), Some(r#"{"group":"ci"}"#.as_bytes()));
        let _ = route(&d, "POST", "/v1/clear", &HashMap::new(), Some(r#"{"group":" "} "#.as_bytes()));
        let (status, _) = route(&d, "POST", "/v1/clear", &HashMap::new(), Some(b"not json"));
        assert_eq!(status, 400);
        assert_eq!(
            b.events(),
            vec!["clear-all", "clear-all", "clear-group:ci", "clear-all"]
        );
    }

    #[test]
    fn silence_two_doors_agree() {
        let b = bridge();
        let d = as_dyn(&b);
        let (status, v) = route(&d, "POST", "/v1/silence", &HashMap::new(), None);
        assert_eq!(status, 200);
        assert_eq!(v["silenced"], true);
        assert!(v["until"].is_number());
        let (status, v) = route(&d, "POST", "/v1/silence", &HashMap::new(), Some(r#"{"minutes":0}"#.as_bytes()));
        assert_eq!(status, 200);
        assert_eq!(v["silenced"], false);
        assert!(v.get("until").is_none()); // until 缺席省略（HTTP 门）
        let _ = route(&d, "DELETE", "/v1/silence", &HashMap::new(), None);
        assert_eq!(
            b.events(),
            vec!["silence:60", "resume", "resume"]
        );
    }

    #[test]
    fn history_suffix_limit_and_wire_shape() {
        let b = bridge();
        for i in 0..25 {
            b.items.lock().unwrap().push(item(&format!("t{i}")));
        }
        b.read.lock().unwrap().push(b.items.lock().unwrap()[0].id);
        let d = as_dyn(&b);
        let mut q = HashMap::new();
        q.insert("limit".into(), "5".into());
        let (status, v) = route(&d, "GET", "/v1/history", &q, None);
        assert_eq!(status, 200);
        assert_eq!(v["items"].as_array().unwrap().len(), 5); // suffix：最新 5 条
        assert_eq!(v["items"][0]["title"], "t20");
        assert_eq!(v["unreadCount"], 24);
        // wire 形状：body（非 bodyMarkdown）、timeout 缺席省略。
        let first = &v["items"][0];
        assert!(first.get("timeout").is_none());
        assert_eq!(first["body"], "body");
    }

    #[test]
    fn status_shape_has_pending_zero() {
        let b = bridge();
        b.items.lock().unwrap().push(item("t"));
        let d = as_dyn(&b);
        let (status, v) = route(&d, "GET", "/v1/status", &HashMap::new(), None);
        assert_eq!(status, 200);
        assert_eq!(v["pendingCount"], 0);
        assert_eq!(v["historyCount"], 1);
        assert_eq!(v["unreadCount"], 1);
    }

    #[test]
    fn method_and_path_gates() {
        let b = bridge();
        let d = as_dyn(&b);
        let (status, v) = route(&d, "GET", "/v1/push", &HashMap::new(), None);
        assert_eq!(status, 405);
        assert_eq!(v["error"], "方法不允许");
        let (status, v) = route(&d, "GET", "/v1/nope", &HashMap::new(), None);
        assert_eq!(status, 404);
        assert_eq!(v["error"], "未知路径");
    }

    #[test]
    fn ws_frames_two_doors_one_pipeline() {
        let b = bridge();
        let d = as_dyn(&b);
        // 垃圾帧。
        let v = handle_ws_command(&d, "not json");
        assert_eq!(v["error"], "帧不是合法 JSON");
        assert!(v.get("ref").is_none());
        // push 帧。
        let v = handle_ws_command(&d, r#"{"op":"push","ref":"r1","title":"t"}"#);
        assert_eq!(v["ok"], true);
        assert_eq!(v["ref"], "r1");
        assert_eq!(v["outcome"], "displayed");
        // 缺 title 的语义拒绝（不是帧解码失败）。
        let v = handle_ws_command(&d, r#"{"op":"push","ref":"r2"}"#);
        assert_eq!(v["ok"], false);
        assert_eq!(v["ref"], "r2");
        // silence：until 显式 null。
        let v = handle_ws_command(&d, r#"{"op":"silence","minutes":0}"#);
        assert_eq!(v["result"]["silenced"], false);
        assert!(v["result"]["until"].is_null());
        // clear + 未知操作。
        let v = handle_ws_command(&d, r#"{"op":"clear","group":"ci"}"#);
        assert_eq!(v["ok"], true);
        let v = handle_ws_command(&d, r#"{"op":"nope"}"#);
        assert_eq!(v["error"], "未知操作");
        assert_eq!(
            b.events(),
            vec!["resume", "clear-group:ci"]
        );
    }

    #[test]
    fn exec_timeout_clamps_like_swift() {
        assert_eq!(clamp_exec_timeout(None), 10_000);
        assert_eq!(clamp_exec_timeout(Some(0)), 100);
        assert_eq!(clamp_exec_timeout(Some(-5)), 100);
        assert_eq!(clamp_exec_timeout(Some(50)), 100);
        assert_eq!(clamp_exec_timeout(Some(1_500)), 1_500);
        assert_eq!(clamp_exec_timeout(Some(99_999)), 10_000);
    }

    #[test]
    fn exec_route_answers_outcome_payload() {
        // 不存在的脚本：加载在 spawn 之前快速失败，测试不依赖 bun。
        // 语义与 Swift execScript 同款：脚本失败也是 200，错误在载荷里。
        let b = bridge();
        let d = as_dyn(&b);
        let (status, v) = route(
            &d,
            "POST",
            "/v1/exec",
            &HashMap::new(),
            Some(r#"{"script":"definitely-missing","input":{"a":1},"timeoutMs":100}"#.as_bytes()),
        );
        assert_eq!(status, 200);
        assert_eq!(v["ok"], false);
        assert_eq!(v["error"], "脚本未找到：definitely-missing");
        assert!(v["logs"].is_array());
        // 坏 JSON / 无体是 400。
        let (status, _) = route(&d, "POST", "/v1/exec", &HashMap::new(), Some(b"not json"));
        assert_eq!(status, 400);
        let (status, _) = route(&d, "POST", "/v1/exec", &HashMap::new(), None);
        assert_eq!(status, 400);
    }

    #[test]
    fn ws_exec_frame_carries_outcome_and_missing_script_error() {
        let b = bridge();
        let d = as_dyn(&b);
        let v = handle_ws_command(&d, r#"{"op":"exec","ref":"e1","script":"definitely-missing"}"#);
        assert_eq!(v["type"], "result");
        assert_eq!(v["ref"], "e1");
        assert_eq!(v["ok"], false);
        assert_eq!(v["error"], "脚本未找到：definitely-missing");
        assert!(v["logs"].is_array());
        let v = handle_ws_command(&d, r#"{"op":"exec","ref":"e2"}"#);
        assert_eq!(v["ok"], false);
        assert_eq!(v["error"], "缺少 script");
    }

    #[test]
    fn socket_path_redirect_and_key_validation() {
        let (short, notice) = resolve_socket_path("/tmp/x.sock");
        assert_eq!(short, "/tmp/x.sock");
        assert!(notice.is_none());
        let long = format!("/tmp/{}", "a".repeat(200));
        let (short, notice) = resolve_socket_path(&long);
        assert!(short.starts_with("/tmp/mdn-"));
        assert!(notice.is_some());
        assert!(valid_ws_key("dGhlIHNhbXBsZSBub25jZQ=="));
        assert!(!valid_ws_key(""));
        assert!(!valid_ws_key("not base64!!"));
    }
}
